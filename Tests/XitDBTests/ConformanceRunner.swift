import Foundation
import Testing
import XitDBHashing

@testable import XitDB

// `CFGetTypeID` tells a JSON `true` from a `1`; Foundation re-exports it on
// Apple platforms and not on Linux.
#if !canImport(Darwin)
    import CoreFoundation
#endif

// A runner for the conformance scripts, written from the conformance
// repository's SCRIPT-FORMAT.md. Each op is one call on the engine. The
// runner adds no checks and no recovery of its own, and it fails on anything
// in a script that it does not know.

/// A failure of the script itself: an expectation that did not hold, a name
/// used wrongly, an engine error that nothing handled. A script in the
/// fixtures' `failing` folder must end in one of these.
struct ScriptFailure: Error, CustomStringConvertible {
    let description: String
    /// Zig's name of the engine error an op raised that nothing handled,
    /// when that is the failure.
    let unhandled: String?

    init(_ description: String, unhandled: String? = nil) {
        self.description = description
        self.unhandled = unhandled
    }
}

/// Something in a script that this runner does not know: an op, a field, a
/// path part or a tag. It is never a script's fault, so it is kept apart
/// from `ScriptFailure`.
struct UnknownInScript: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// The error the `fail` op raises. It is not an engine error, but it travels
/// like one.
struct ScriptAbort: Error {}

/// The kinds of storage a script can run on.
/// Where a script's database lives, across closing and reopening it. The raw
/// ops of a script write here directly, past the engine.
final class ScriptStorage {
    let kind: StorageKind
    private let directory: TemporaryDirectory?
    private var memoryBytes: [UInt8] = []
    private var memory: MemoryStorage?
    private var open: (any WritableStorage)?

    init(_ kind: StorageKind) throws {
        self.kind = kind
        directory = kind == .memory ? nil : try TemporaryDirectory()
    }

    /// Opens the storage for a database. The script format has syncing off
    /// and the default buffer size.
    func openStorage(readOnly: Bool) throws -> any WritableStorage {
        let storage: any WritableStorage
        switch kind {
        case .memory:
            if readOnly { throw UnknownInScript("the memory storage has no read-only mode") }
            let memory = MemoryStorage(bytes: memoryBytes)
            self.memory = memory
            storage = memory
        case .file:
            let path = try #require(directory).path()
            storage = try FileStorage(path: path, access: readOnly ? .readOnly : .create, durability: .none)
        case .bufferedFile:
            let path = try #require(directory).path()
            storage = try BufferedFileStorage(path: path, access: readOnly ? .readOnly : .create, durability: .none)
        case .bufferedFileSmallWindow:
            // a window most of a script's writes restart or go around, as
            // the storage tests use it
            let path = try #require(directory).path()
            storage = try BufferedFileStorage(
                path: path, access: readOnly ? .readOnly : .create, durability: .none, bufferLimit: 200)
        }
        open = storage
        return storage
    }

    /// Ends the use of the storage, flushing it first as the Zig runner's
    /// `close` does: commits are already in it, but what a sync from 0
    /// that did not finish wrote is not committed, and whether the file is
    /// then longer than a new database decides what opening it does.
    func close() throws {
        try open?.flush()
        if let memory {
            memoryBytes = memory.bytes
        }
        memory = nil
        open = nil
    }

    /// Writes bytes at an offset while the database is closed, leaving zeros
    /// if that is past the end.
    func rawWrite(_ bytes: [UInt8], at offset: UInt64) throws {
        switch kind {
        case .memory:
            let end = Int(offset) + bytes.count
            if end > memoryBytes.count {
                memoryBytes.append(contentsOf: [UInt8](repeating: 0, count: end - memoryBytes.count))
            }
            memoryBytes.replaceSubrange(Int(offset)..<end, with: bytes)
        case .file, .bufferedFile, .bufferedFileSmallWindow:
            let file = try FileStorage(path: try #require(directory).path(), access: .create, durability: .none)
            try file.write(bytes.span, at: offset)
        }
    }

    /// Writes bytes at the end while the database is closed.
    func rawAppend(_ bytes: [UInt8]) throws {
        try rawWrite(bytes, at: UInt64(try contents().count))
    }

    /// Puts `bytes` in place of everything in the storage while the
    /// database is closed: a file that scripts start from, such as a
    /// version 1 database, which nothing creates any more.
    func rawLoad(_ bytes: [UInt8]) throws {
        switch kind {
        case .memory:
            memoryBytes = bytes
        case .file, .bufferedFile, .bufferedFileSmallWindow:
            let file = try FileStorage(path: try #require(directory).path(), access: .truncate, durability: .none)
            try file.write(bytes.span, at: 0)
        }
    }

    /// Cuts the storage to `length` bytes while the database is closed, as
    /// a crash partway through writing a file leaves it.
    func rawTruncate(to length: UInt64) throws {
        switch kind {
        case .memory:
            guard length <= UInt64(memoryBytes.count) else {
                throw UnknownInScript("raw_truncate to more than the file has")
            }
            memoryBytes.removeLast(memoryBytes.count - Int(length))
        case .file, .bufferedFile, .bufferedFileSmallWindow:
            let file = try FileStorage(path: try #require(directory).path(), access: .create, durability: .none)
            guard length <= (try file.length) else { throw UnknownInScript("raw_truncate to more than the file has") }
            try file.truncate(to: length)
        }
    }

    /// Everything in the storage as it is now.
    func contents() throws -> [UInt8] {
        try open?.flush()
        switch kind {
        case .memory: return memory?.bytes ?? memoryBytes
        case .file, .bufferedFile, .bufferedFileSmallWindow: return try #require(directory).contents()
        }
    }
}

/// A JSON object from a script, which fails on a field nobody asked for.
struct ScriptObject {
    let fields: [String: Any]
    let what: String

    init(_ value: Any?, _ what: String) throws {
        guard let fields = value as? [String: Any] else { throw UnknownInScript("\(what) is not an object") }
        self.fields = fields
        self.what = what
    }

    /// Fails unless every field of the object is one of `known`.
    func allow(_ known: String...) throws {
        for name in fields.keys where !known.contains(name) {
            throw UnknownInScript("unknown field '\(name)' in \(what)")
        }
    }

    func has(_ name: String) -> Bool {
        fields[name] != nil
    }

    /// Whether the field is there and is JSON's `null`.
    func isNull(_ name: String) -> Bool {
        fields[name] is NSNull
    }

    func string(_ name: String) throws -> String {
        guard let value = fields[name] as? String else { throw UnknownInScript("\(what) needs a string '\(name)'") }
        return value
    }

    func optionalString(_ name: String) throws -> String? {
        has(name) ? try string(name) : nil
    }

    func bool(_ name: String, default defaultValue: Bool) throws -> Bool {
        guard has(name) else { return defaultValue }
        guard let number = fields[name] as? NSNumber, Self.isBoolean(number) else {
            throw UnknownInScript("\(what) needs a boolean '\(name)'")
        }
        return number.boolValue
    }

    func array(_ name: String) throws -> [Any] {
        guard let value = fields[name] as? [Any] else { throw UnknownInScript("\(what) needs an array '\(name)'") }
        return value
    }

    func unsigned(_ name: String) throws -> UInt64 {
        try Self.unsigned(fields[name], "'\(name)' in \(what)")
    }

    func signed(_ name: String) throws -> Int64 {
        try Self.signed(fields[name], "'\(name)' in \(what)")
    }

    /// Whether a JSON number is really `true` or `false`. Every number casts
    /// to `Bool`, so the cast cannot tell.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// An integer from 0 to 2⁶⁴−1, read exactly and not through a double.
    static func unsigned(_ value: Any?, _ what: String) throws -> UInt64 {
        guard let number = value as? NSNumber, !isBoolean(number), let result = UInt64(number.stringValue) else {
            throw UnknownInScript("\(what) is not an unsigned integer")
        }
        return result
    }

    /// An integer from −2⁶³ to 2⁶³−1, read exactly and not through a double.
    static func signed(_ value: Any?, _ what: String) throws -> Int64 {
        guard let number = value as? NSNumber, !isBoolean(number), let result = Int64(number.stringValue) else {
            throw UnknownInScript("\(what) is not a signed integer")
        }
        return result
    }
}

/// Runs one script against a database.
final class ScriptRunner {
    /// What a name holds.
    enum Value {
        case readWrite(Cursor<ReadWrite>)
        case readOnly(Cursor<ReadOnly>)
        case nullCursor
        case slot(Slot?)
        case iterator(IteratorBox)
        /// A number: a committed size or a replication start.
        case number(UInt64)
        /// A replica's state.
        case replicaState(ReplicaState)
        /// Committed bytes, read from a database and applied to another.
        case committedBytes([UInt8])
    }

    /// An iterator under a name. Unlike a cursor, an iterator is not a
    /// value in a script: `next` moves the one iterator, however it is
    /// reached.
    final class IteratorBox {
        private let advance: () throws(XitDBError) -> Cursor<ReadOnly>?

        init(_ iterator: CollectionIterator) {
            var iterator = iterator
            advance = { () throws(XitDBError) in try iterator.next() }
        }

        func next() throws(XitDBError) -> Cursor<ReadOnly>? {
            try advance()
        }
    }

    /// One of a script's databases: where it lives, and the open database
    /// while it is open.
    final class ScriptDatabase {
        let storage: ScriptStorage
        var database: Database?

        init(storage: ScriptStorage) {
            self.storage = storage
        }
    }

    let random: FixedRandom
    private var names: [String: Value] = [:]
    private var hashSize: UInt16 = 0
    private var scriptHashID: HashID?

    /// The script's databases by name. `main` is there from the start.
    private var databases: [String: ScriptDatabase]

    /// The name of the current database: what `root` means, and what every
    /// op without an `on` acts on.
    private var current = "main"

    /// The two offset maps a `compact` can use, each kept for the whole
    /// script, so that a compaction has to forget the last one. The disk
    /// one is made when a script first asks for it.
    private var memoryOffsets = MemoryOffsetMap()
    private var diskOffsetsStorage: ScriptStorage?
    private var diskOffsets: DiskOffsets?
    /// Whether each `compact` uses the offset map the script does not name.
    var otherOffsetMap = false

    /// The database the last `apply_replicated` at 0 was asked of, whether
    /// or not it went through: the snapshot proof needs to know, since its
    /// `start` may be a bound number. Cleared by the caller.
    var zeroSyncTarget: String?

    init(storage: ScriptStorage, random: FixedRandom) {
        self.random = random
        databases = ["main": ScriptDatabase(storage: storage)]
    }

    /// The current database's place.
    private var currentPlace: ScriptDatabase {
        databases[current]!
    }

    /// The current database, or `nil` while it is closed.
    private var database: Database? {
        get { currentPlace.database }
        set { currentPlace.database = newValue }
    }

    /// The current database's storage.
    private var storage: ScriptStorage {
        currentPlace.storage
    }

    /// The committed size of a database, the current one if no name is
    /// given, or `nil` while it is closed or in no state to say, as the
    /// sidecar records it: a failed sync at 0 leaves no database.
    func committedSize(of name: String? = nil) throws -> UInt64? {
        guard let place = databases[name ?? current] else { throw ScriptFailure("no database called '\(name ?? "")'") }
        guard let database = place.database else { return nil }
        return try? database.committedSize
    }

    /// Everything in a database's storage as it is now.
    func contents(of name: String) throws -> [UInt8] {
        guard let place = databases[name] else { throw ScriptFailure("no database called '\(name)'") }
        return try place.storage.contents()
    }

    /// The names of the script's databases.
    var databaseNames: [String] {
        databases.keys.sorted()
    }

    /// The name of the current database, which every op without an `on`
    /// acts on.
    var currentName: String {
        current
    }

    /// A database of the script while it is open, or `nil`.
    func openDatabase(named name: String) -> Database? {
        databases[name]?.database
    }

    /// Creates the database a script asks for and returns the script's ops.
    func start(_ script: Any) throws -> [Any] {
        let document = try ScriptObject(script, "the script")
        try document.allow("format", "description", "hash_size", "hash_id", "file_id", "ops")
        guard try document.string("format") == "xitdb-script/1" else {
            throw UnknownInScript("unknown script format")
        }
        hashSize = UInt16(try document.unsigned("hash_size"))
        let hashID: HashID?
        if document.isNull("hash_id") {
            hashID = nil
        } else {
            let bytes = try self.bytes(document.fields["hash_id"], "hash_id")
            guard bytes.count == 4 else { throw UnknownInScript("hash_id is not four bytes") }
            hashID = HashID(bytes: [bytes[0], bytes[1], bytes[2], bytes[3]])
        }
        scriptHashID = hashID
        database = try Database(
            creating: try storage.openStorage(readOnly: false),
            hashSize: Int(hashSize),
            hashID: hashID,
            fileID: try fileID(document.fields["file_id"]),
            random: random
        )
        return try document.array("ops")
    }

    private func fileID(_ value: Any?) throws -> UInt64 {
        guard let digits = value as? String else { throw UnknownInScript("file_id is not a string") }
        let fileIDBytes = try hexBytes(digits, "file_id")
        guard fileIDBytes.count == 8 else { throw UnknownInScript("file_id is not eight bytes") }
        return fileIDBytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    // MARK: Values

    private func hexBytes(_ digits: String, _ what: String) throws -> [UInt8] {
        guard digits.count % 2 == 0, digits.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw UnknownInScript("\(what) is not lowercase hex")
        }
        return hex(digits)
    }

    /// Bytes: a string, taken as its UTF-8 with nothing normalised, or
    /// `{"hex": "..."}`.
    private func bytes(_ value: Any?, _ what: String) throws -> [UInt8] {
        if let string = value as? String {
            return Array(string.utf8)
        }
        let object = try ScriptObject(value, what)
        try object.allow("hex")
        return try hexBytes(try object.string("hex"), what)
    }

    private func formatTag(_ value: Any?, _ what: String) throws -> FormatTag {
        let tag = try bytes(value, what)
        guard tag.count == 2 else { throw UnknownInScript("\(what) is not two bytes") }
        return FormatTag(tag[0], tag[1])
    }

    private func hash(_ value: Any?, _ what: String) throws -> KeyHash {
        let object = try ScriptObject(value, what)
        try object.allow("hex", "sha1")
        if object.has("hex") {
            return KeyHash(try hexBytes(try object.string("hex"), what))
        }
        let input = try bytes(object.fields["sha1"], what)
        return KeyHash(Array(Insecure.SHA1.hash(data: Data(input))))
    }

    private static let tagNames: [String: Slot.Tag] = [
        "none": .none, "index": .index, "array_list": .arrayList, "linked_array_list": .linkedArrayList,
        "hash_map": .hashMap, "kv_pair": .kvPair, "bytes": .bytes, "short_bytes": .shortBytes, "uint": .uint,
        "int": .int, "float": .float, "hash_set": .hashSet, "counted_hash_map": .countedHashMap,
        "counted_hash_set": .countedHashSet, "sorted_map": .sortedMap, "sorted_set": .sortedSet,
        "sorted_kv_pair": .sortedKvPair,
    ]

    private func tag(_ name: String) throws -> Slot.Tag {
        guard let tag = Self.tagNames[name] else { throw UnknownInScript("unknown tag '\(name)'") }
        return tag
    }

    /// A number: an integer, or `{"var": NAME}` with a name that holds one.
    private func number(_ value: Any?, _ what: String) throws -> UInt64 {
        if let object = value as? [String: Any], object["var"] != nil {
            let reference = try ScriptObject(object, what)
            try reference.allow("var")
            let name = try reference.string("var")
            guard case .number(let number) = try bound(name) else {
                throw ScriptFailure("'\(name)' does not hold a number")
            }
            return number
        }
        return try ScriptObject.unsigned(value, what)
    }

    /// A slot: a name that holds one, a literal, or `null`.
    private func slot(_ value: Any?, _ what: String) throws -> Slot? {
        if value is NSNull { return nil }
        let object = try ScriptObject(value, what)
        if object.has("var") {
            try object.allow("var")
            let name = try object.string("var")
            guard let bound = names[name] else { throw ScriptFailure("the name '\(name)' is not bound") }
            guard case .slot(let slot) = bound else { throw ScriptFailure("'\(name)' does not hold a slot") }
            return slot
        }
        try object.allow("tag", "value", "full")
        return Slot(
            value: object.has("value") ? try object.unsigned("value") : 0,
            tag: try tag(try object.string("tag")),
            full: try object.bool("full", default: false)
        )
    }

    private func float(_ value: Any?, _ what: String) throws -> Double {
        guard let digits = value as? String else { throw UnknownInScript("\(what) is not a float's hex digits") }
        let bits = try hexBytes(digits, what)
        guard bits.count == 8 else { throw UnknownInScript("\(what) is not sixteen hex digits") }
        return Double(bitPattern: bits.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
    }

    private func writeData(_ value: Any?) throws -> WritableData {
        let object = try ScriptObject(value, "write data")
        try object.allow("slot", "uint", "int", "float", "bytes", "bytes_object")
        guard object.fields.count == 1 else { throw UnknownInScript("write data needs exactly one field") }
        if object.has("slot") { return .slot(try slot(object.fields["slot"], "a slot")) }
        if object.has("uint") { return .uint(try object.unsigned("uint")) }
        if object.has("int") { return .int(try object.signed("int")) }
        if object.has("float") { return .double(try float(object.fields["float"], "a float")) }
        if object.has("bytes") { return .bytes(try bytes(object.fields["bytes"], "bytes")) }
        let bytesObject = try ScriptObject(object.fields["bytes_object"], "bytes_object")
        try bytesObject.allow("value", "format_tag")
        return .bytes(
            try bytes(bytesObject.fields["value"], "bytes"),
            formatTag: bytesObject.has("format_tag")
                ? try formatTag(bytesObject.fields["format_tag"], "format_tag") : nil
        )
    }

    // MARK: Paths

    /// A path's parts, and the callback of its last part if that is a `ctx`.
    /// Everything in the path is evaluated here, before the call starts.
    private func path(_ value: [Any]) throws -> (parts: [PathPart], callback: ScriptObject?) {
        var parts: [PathPart] = []
        var callback: ScriptObject?
        for (index, element) in value.enumerated() {
            if let name = element as? String {
                switch name {
                case "array_list_init": parts.append(.arrayListInit)
                case "array_list_append": parts.append(.arrayListAppend)
                case "linked_array_list_init": parts.append(.linkedArrayListInit)
                case "linked_array_list_append": parts.append(.linkedArrayListAppend)
                default: throw UnknownInScript("unknown path part '\(name)'")
                }
                continue
            }
            let object = try ScriptObject(element, "a path part")
            guard object.fields.count == 1, let name = object.fields.keys.first else {
                throw UnknownInScript("a path part needs exactly one field")
            }
            let payload = object.fields[name]
            switch name {
            case "array_list_get":
                parts.append(.arrayListGet(try ScriptObject.signed(payload, "array_list_get")))
            case "array_list_slice":
                let slice = try ScriptObject(payload, "array_list_slice")
                try slice.allow("size")
                parts.append(.arrayListSlice(size: try slice.unsigned("size")))
            case "linked_array_list_get":
                parts.append(.linkedArrayListGet(try ScriptObject.signed(payload, "linked_array_list_get")))
            case "linked_array_list_slice":
                let slice = try ScriptObject(payload, "linked_array_list_slice")
                try slice.allow("offset", "size")
                parts.append(
                    .linkedArrayListSlice(offset: try slice.unsigned("offset"), size: try slice.unsigned("size")))
            case "linked_array_list_concat":
                let concat = try ScriptObject(payload, "linked_array_list_concat")
                try concat.allow("list")
                // A slot that is null cannot be concatenated: a script failure.
                guard let list = try slot(concat.fields["list"], "list") else {
                    throw ScriptFailure("linked_array_list_concat with a null list")
                }
                parts.append(.linkedArrayListConcat(list))
            case "linked_array_list_insert":
                parts.append(.linkedArrayListInsert(try ScriptObject.signed(payload, "linked_array_list_insert")))
            case "linked_array_list_remove":
                parts.append(.linkedArrayListRemove(try ScriptObject.signed(payload, "linked_array_list_remove")))
            case "sorted_map_init":
                let options = try ScriptObject(payload, "sorted_map_init")
                try options.allow("set")
                parts.append(.sortedMapInit(set: try options.bool("set", default: false)))
            case "sorted_map_get":
                let get = try ScriptObject(payload, "sorted_map_get")
                try get.allow("kv_pair", "key", "value")
                guard get.fields.count == 1 else { throw UnknownInScript("sorted_map_get needs exactly one field") }
                if get.has("kv_pair") {
                    parts.append(.sortedMapGet(.kvPair, SortedKey(try bytes(get.fields["kv_pair"], "a key"))))
                } else if get.has("key") {
                    parts.append(.sortedMapGet(.key, SortedKey(try bytes(get.fields["key"], "a key"))))
                } else {
                    parts.append(.sortedMapGet(.value, SortedKey(try bytes(get.fields["value"], "a key"))))
                }
            case "sorted_map_get_index":
                parts.append(.sortedMapGetIndex(try ScriptObject.signed(payload, "sorted_map_get_index")))
            case "sorted_map_remove":
                parts.append(.sortedMapRemove(SortedKey(try bytes(payload, "a key"))))
            case "hash_map_init":
                let options = try ScriptObject(payload, "hash_map_init")
                try options.allow("counted", "set")
                parts.append(
                    .hashMapInit(
                        counted: try options.bool("counted", default: false),
                        set: try options.bool("set", default: false)
                    )
                )
            case "hash_map_get":
                let get = try ScriptObject(payload, "hash_map_get")
                try get.allow("kv_pair", "key", "value")
                guard get.fields.count == 1 else { throw UnknownInScript("hash_map_get needs exactly one field") }
                if get.has("kv_pair") {
                    parts.append(.hashMapGet(.kvPair, try hash(get.fields["kv_pair"], "a hash")))
                } else if get.has("key") {
                    parts.append(.hashMapGet(.key, try hash(get.fields["key"], "a hash")))
                } else {
                    parts.append(.hashMapGet(.value, try hash(get.fields["value"], "a hash")))
                }
            case "hash_map_remove":
                parts.append(.hashMapRemove(try hash(payload, "a hash")))
            case "write":
                parts.append(.write(try writeData(payload)))
            case "ctx":
                // Only a callback at the end of a path can ever run. One
                // anywhere else is passed as written, and the engine rejects
                // it when the path gets there.
                let context = try ScriptObject(payload, "ctx")
                try context.allow("as", "ops")
                parts.append(.ctx)
                if index == value.count - 1 {
                    callback = context
                }
            default:
                throw UnknownInScript("unknown path part '\(name)'")
            }
        }
        return (parts, callback)
    }

    // MARK: Names

    private func bound(_ name: String) throws -> Value {
        if name == "root" {
            guard let database else { throw ScriptFailure("the database is closed") }
            return .readWrite(database.rootCursor)
        }
        guard let value = names[name] else { throw ScriptFailure("the name '\(name)' is not bound") }
        return value
    }

    private func readWrite(_ name: String) throws -> Cursor<ReadWrite> {
        switch try bound(name) {
        case .readWrite(let cursor): return cursor
        case .readOnly: throw ScriptFailure("'\(name)' is a read-only cursor")
        case .nullCursor: throw ScriptFailure("'\(name)' is a null cursor")
        case .slot: throw ScriptFailure("'\(name)' holds a slot, not a cursor")
        case .iterator: throw ScriptFailure("'\(name)' holds an iterator, not a cursor")
        case .number, .replicaState, .committedBytes:
            throw ScriptFailure("'\(name)' holds a number, a state or bytes, not a cursor")
        }
    }

    private func iterator(_ name: String) throws -> IteratorBox {
        guard case .iterator(let box) = try bound(name) else {
            throw ScriptFailure("'\(name)' does not hold an iterator")
        }
        return box
    }

    private func bind(_ name: String?, _ value: Value) throws {
        guard let name else { return }
        if name == "root" { throw UnknownInScript("'root' cannot be bound") }
        names[name] = value
    }

    /// Stores a cursor back under the name an op was called on, which is how
    /// the ops that take `*Cursor` in Zig update it. `root` is not a name.
    private func update(_ name: String, _ cursor: Cursor<ReadWrite>) {
        if name != "root" {
            names[name] = .readWrite(cursor)
        }
    }

    // MARK: Errors

    static func name(of error: XitDBError) -> String {
        switch error {
        case .unexpectedTag: "UnexpectedTag"
        case .keyNotFound: "KeyNotFound"
        // Zig has one error for a key that is not there and an index that
        // names no element; the scripts expect its name for both.
        case .indexOutOfRange: "KeyNotFound"
        case .writeNotAllowed: "WriteNotAllowed"
        case .cursorNotWritable: "CursorNotWriteable"
        case .expectedTxStart: "ExpectedTxStart"
        case .nestedTopLevelWrite: "NestedTopLevelWrite"
        case .invalidDatabase: "InvalidDatabase"
        case .invalidVersion: "InvalidVersion"
        case .invalidHashSize: "InvalidHashSize"
        case .truncatedDatabase: "TruncatedDatabase"
        case .invalidEnumTag: "InvalidEnumTag"
        case .invalidBTreeNode: "InvalidBTreeNode"
        case .invalidBTreeNodeKind: "InvalidBTreeNodeKind"
        case .invalidCount: "InvalidCount"
        case .staleCursor: "StaleCursor"
        case .immutableBytes: "ImmutableBytes"
        case .byteWriterOpen: "ByteWriterOpen"
        case .snapshotOverwritten: "SnapshotOverwritten"
        case .subCollectionSnapshot: "SubCollectionSnapshot"
        case .structuralSlot: "StructuralSlot"
        case .poisonedTransaction: "PoisonedTransaction"
        case .untrustedRootHeader: "UntrustedRootHeader"
        case .hashSizeMismatch: "HashSizeMismatch"
        case .invalidRange: "InvalidRange"
        case .invalidLength: "InvalidLength"
        case .targetNotEmpty: "TargetNotEmpty"
        case .emptyLastMoment: "EmptyLastMoment"
        // No script creates a database in a storage that holds bytes.
        case .storageNotEmpty: "StorageNotEmpty"
        case .keyOffsetExceeded: "KeyOffsetExceeded"
        case .maxShiftExceeded: "MaxShiftExceeded"
        case .maxSizeExceeded: "MaxSizeExceeded"
        case .streamTooLong: "StreamTooLong"
        case .endOfStream: "EndOfStream"
        case .unexpectedWriterPosition: "UnexpectedWriterPosition"
        case .pathPartMustBeAtEnd: "PathPartMustBeAtEnd"
        case .notImplemented: "NotImplemented"
        // A failed write to the storage is what Zig's writer interface
        // reports as WriteFailed.
        case .storageFailure: "WriteFailed"
        // Nothing a script runs gives the database a type of the script's
        // own; the runner's offset maps and sinks never throw.
        case .callerError: "CallerError"
        }
    }

    // MARK: Running

    /// Runs one op and applies `expect_error` to its result: an op with one
    /// catches that error, and an op without passes its error upward.
    func run(_ value: Any, topLevel: Bool) throws {
        let op = try ScriptObject(value, "an op")
        let name = try op.string("op")
        let expectedError = try op.optionalString("expect_error")
        do {
            try perform(name, op, topLevel: topLevel)
        } catch let failure as ScriptFailure {
            throw failure
        } catch let unknown as UnknownInScript {
            throw unknown
        } catch {
            let raised: String
            if let engineError = error as? XitDBError {
                raised = Self.name(of: engineError)
            } else if error is ScriptAbort {
                raised = "ScriptAbort"
            } else {
                throw error
            }
            guard let expectedError else {
                // Inside a callback the error leaves the callback, and the
                // op that called it raises it in turn. At the top level
                // nothing is left to handle it.
                if topLevel {
                    throw ScriptFailure("the op '\(name)' raised \(raised), which nothing handles", unhandled: raised)
                }
                throw error
            }
            guard expectedError == raised else {
                throw ScriptFailure("the op '\(name)' raised \(raised), and \(expectedError) was expected")
            }
            return
        }
        if let expectedError {
            throw ScriptFailure("the op '\(name)' finished, and \(expectedError) was expected")
        }
    }

    /// Runs a callback: binds its name to the cursor, runs its ops, and
    /// hands back whatever the name holds afterwards.
    private func callback(_ context: ScriptObject, _ cursor: inout Cursor<ReadWrite>) throws {
        let name = try context.string("as")
        try bind(name, .readWrite(cursor))
        for op in try context.array("ops") {
            try run(op, topLevel: false)
        }
        guard case .readWrite(let result)? = names[name] else {
            throw ScriptFailure("'\(name)' does not hold a read-write cursor at the end of its callback")
        }
        cursor = result
    }

    private func openDatabase(_ what: String) throws -> Database {
        guard let database else { throw ScriptFailure("\(what) while the database is closed") }
        return database
    }

    private func perform(_ name: String, _ op: ScriptObject, topLevel: Bool) throws {
        let topLevelOps = [
            "close", "reopen", "recover", "raw_append", "raw_write", "raw_load", "raw_truncate", "create_database",
            "use", "compact", "replica_state", "replication_start", "committed_size", "read_committed",
            "apply_replicated",
        ]
        if topLevelOps.contains(name) && !topLevel {
            throw UnknownInScript("'\(name)' inside a callback")
        }
        let closedOps = [
            "reopen", "recover", "raw_append", "raw_write", "raw_load", "raw_truncate", "create_database", "use",
        ]
        if database == nil && !closedOps.contains(name) {
            throw ScriptFailure("the op '\(name)' while the database is closed")
        }

        switch name {
        case "create_database":
            try op.allow("op", "note", "name", "file_id", "hash_id")
            let name = try op.string("name")
            if databases[name] != nil { throw ScriptFailure("a database called '\(name)' exists already") }
            let hashID: HashID?
            if !op.has("hash_id") {
                hashID = scriptHashID
            } else if op.isNull("hash_id") {
                hashID = nil
            } else {
                let bytes = try self.bytes(op.fields["hash_id"], "hash_id")
                guard bytes.count == 4 else { throw UnknownInScript("hash_id is not four bytes") }
                hashID = HashID(bytes: [bytes[0], bytes[1], bytes[2], bytes[3]])
            }
            let place = ScriptDatabase(storage: try ScriptStorage(storage.kind))
            place.database = try Database(
                creating: try place.storage.openStorage(readOnly: false),
                hashSize: Int(hashSize),
                hashID: hashID,
                fileID: try fileID(op.fields["file_id"]),
                random: random
            )
            databases[name] = place

        case "use":
            try op.allow("op", "note", "name")
            let name = try op.string("name")
            guard databases[name] != nil else { throw ScriptFailure("no database called '\(name)'") }
            current = name

        case "compact":
            try op.allow("op", "note", "expect_error", "into", "file_id", "hash_id", "offset_map")
            let source = try openDatabase("compact")
            let into = try op.string("into")
            let named = try op.string("offset_map")
            guard ["memory", "disk"].contains(named) else { throw UnknownInScript("unknown offset_map") }
            let useDisk = (named == "disk") != otherOffsetMap
            if useDisk && diskOffsets == nil {
                let offsetsStorage = try ScriptStorage(storage.kind)
                diskOffsetsStorage = offsetsStorage
                diskOffsets = try DiskOffsets(storage: try offsetsStorage.openStorage(readOnly: false))
            }
            if let place = databases[into] {
                // an existing database keeps its own file ID and hash ID.
                // Zig's runner refuses a file ID named for it, and passes a
                // hash ID on to an init that ignores it for a database
                // that exists, so one is accepted here and ignored too.
                if op.has("file_id") { throw ScriptFailure("compact into an existing database names a file ID") }
                if op.has("hash_id") && !op.isNull("hash_id") {
                    let bytes = try self.bytes(op.fields["hash_id"], "hash_id")
                    guard bytes.count == 4 else { throw UnknownInScript("hash_id is not four bytes") }
                }
                guard let target = place.database else { throw ScriptFailure("compact into a closed database") }
                if !useDisk {
                    try source.compact(into: target, offsetMap: &memoryOffsets)
                } else {
                    try diskOffsets!.use { map in try source.compact(into: target, offsetMap: &map) }
                }
            } else {
                // a new one, which the engine opens inside the compaction,
                // as Zig's does, and which goes on being a database of the
                // script once the compaction succeeds; a compaction that
                // fails leaves no database of that name, as Zig's runner
                // deletes the file it made. Its hash ID is the one given,
                // or the source's; a null one is the source's too, as
                // Zig's `orelse` makes it
                guard op.has("file_id") else { throw ScriptFailure("compact into a new database needs file_id") }
                var hashID: HashID?
                if op.has("hash_id") && !op.isNull("hash_id") {
                    let bytes = try self.bytes(op.fields["hash_id"], "hash_id")
                    guard bytes.count == 4 else { throw UnknownInScript("hash_id is not four bytes") }
                    hashID = HashID(bytes: [bytes[0], bytes[1], bytes[2], bytes[3]])
                }
                let fileID = try fileID(op.fields["file_id"])
                let place = ScriptDatabase(storage: try ScriptStorage(storage.kind))
                let targetStorage = try place.storage.openStorage(readOnly: false)
                if !useDisk {
                    place.database = try source.compact(
                        into: targetStorage, hashID: hashID, fileID: fileID, offsetMap: &memoryOffsets)
                } else {
                    place.database = try diskOffsets!.use { map in
                        try source.compact(into: targetStorage, hashID: hashID, fileID: fileID, offsetMap: &map)
                    }
                }
                databases[into] = place
            }

        case "write_path":
            try op.allow("op", "note", "expect_error", "on", "path", "as")
            let cursor = try readWrite(try op.string("on"))
            let (parts, context) = try path(try op.array("path"))
            let result: Cursor<ReadWrite>
            if let context {
                result = try cursor.writePath(parts) { cursor in try self.callback(context, &cursor) }
            } else {
                result = try cursor.writePath(parts)
            }
            try bind(try op.optionalString("as"), .readWrite(result))

        case "write":
            try op.allow("op", "note", "expect_error", "on", "data")
            let on = try op.string("on")
            var cursor = try readWrite(on)
            try cursor.write(try writeData(op.fields["data"]))
            update(on, cursor)

        case "write_if_empty":
            try op.allow("op", "note", "expect_error", "on", "data")
            let on = try op.string("on")
            var cursor = try readWrite(on)
            try cursor.writeIfEmpty(try writeData(op.fields["data"]))
            update(on, cursor)

        case "writer":
            try op.allow("op", "note", "expect_error", "on", "format_tag", "steps")
            let on = try op.string("on")
            var cursor = try readWrite(on)
            let tag = op.has("format_tag") ? try formatTag(op.fields["format_tag"], "format_tag") : nil
            let steps = try op.array("steps")
            try cursor.writeBytes { writer in
                if let tag { writer.formatTag = tag }
                for step in steps {
                    let step = try ScriptObject(step, "a writer step")
                    try step.allow("write", "seek")
                    guard step.fields.count == 1 else { throw UnknownInScript("a writer step needs one field") }
                    if step.has("write") {
                        try writer.write(try self.bytes(step.fields["write"], "bytes"))
                    } else {
                        writer.seek(to: try step.unsigned("seek"))
                    }
                }
            }
            update(on, cursor)

        case "freeze":
            try op.allow("op", "note", "expect_error", "on")
            let on = try op.string("on")
            var cursor = try readWrite(on)
            try cursor.freeze()
            update(on, cursor)

        case "db_freeze":
            try op.allow("op", "note", "expect_error")
            try openDatabase("db_freeze").freeze()

        case "run_context":
            try op.allow("op", "note", "expect_error", "ctx")
            let context = try ScriptObject(op.fields["ctx"], "ctx")
            try context.allow("as", "ops")
            try openDatabase("run_context").withTransaction { cursor in try self.callback(context, &cursor) }

        case "fail":
            try op.allow("op", "note")
            throw ScriptAbort()

        case "read_path":
            try op.allow("op", "note", "expect_error", "on", "path", "as", "expect_null")
            let (parts, _) = try path(try op.array("path"))
            let result: Cursor<ReadOnly>?
            switch try bound(try op.string("on")) {
            case .readWrite(let cursor): result = try cursor.readPath(parts)
            case .readOnly(let cursor): result = try cursor.readPath(parts)
            case .nullCursor: throw ScriptFailure("a null cursor was used")
            case .slot: throw ScriptFailure("a slot was used as a cursor")
            case .iterator: throw ScriptFailure("an iterator was used as a cursor")
            case .number, .replicaState, .committedBytes:
                throw ScriptFailure("a number, a state or bytes were used as a cursor")
            }
            try expectNull(op, isNull: result == nil)
            try bind(try op.optionalString("as"), result.map { .readOnly($0) } ?? .nullCursor)

        case "read_path_slot":
            try op.allow("op", "note", "expect_error", "on", "path", "as", "expect_null", "expect")
            let (parts, _) = try path(try op.array("path"))
            let result: Slot?
            switch try bound(try op.string("on")) {
            case .readWrite(let cursor): result = try cursor.readPathSlot(parts)
            case .readOnly(let cursor): result = try cursor.readPathSlot(parts)
            case .nullCursor: throw ScriptFailure("a null cursor was used")
            case .slot: throw ScriptFailure("a slot was used as a cursor")
            case .iterator: throw ScriptFailure("an iterator was used as a cursor")
            case .number, .replicaState, .committedBytes:
                throw ScriptFailure("a number, a state or bytes were used as a cursor")
            }
            try expectNull(op, isNull: result == nil)
            try expectSlot(op, result)
            try bind(try op.optionalString("as"), .slot(result))

        case "slot":
            try op.allow("op", "note", "expect_error", "on", "as", "expect")
            let result = try read(try op.string("on")) {
                try $0.slot
            } readOnly: {
                try $0.slot
            }
            try expectSlot(op, result)
            try bind(try op.optionalString("as"), .slot(result))

        case "read_only":
            try op.allow("op", "note", "expect_error", "on", "as")
            try bind(try op.string("as"), .readOnly(try readWrite(try op.string("on")).readOnly))

        case "read_key_value_pair":
            try op.allow("op", "note", "expect_error", "on", "key_as", "value_as", "expect_hash")
            let pairHash: [UInt8]
            let key: Value
            let value: Value
            switch try bound(try op.string("on")) {
            case .readWrite(let cursor):
                // Zig's pair keeps the cursor's write mode, and a script may
                // write through the pair's cursors; the port's Entry is
                // read-only, so the runner makes the read-write cursors the
                // package would not, at the entry's positions.
                let pair = try cursor.readEntry()
                let keyCursor = Cursor<ReadWrite>(
                    slotPointer: pair.key.slotPointer, database: pair.key.engine, frozenAt: pair.key.frozenAt)
                let valueCursor = Cursor<ReadWrite>(
                    slotPointer: pair.value.slotPointer, database: pair.value.engine, frozenAt: pair.value.frozenAt)
                (pairHash, key, value) = (pair.hash, .readWrite(keyCursor), .readWrite(valueCursor))
            case .readOnly(let cursor):
                let pair = try cursor.readEntry()
                (pairHash, key, value) = (pair.hash, .readOnly(pair.key), .readOnly(pair.value))
            case .nullCursor: throw ScriptFailure("a null cursor was used")
            case .slot: throw ScriptFailure("a slot was used as a cursor")
            case .iterator: throw ScriptFailure("an iterator was used as a cursor")
            case .number, .replicaState, .committedBytes:
                throw ScriptFailure("a number, a state or bytes were used as a cursor")
            }
            if op.has("expect_hash") {
                let expected = try hash(op.fields["expect_hash"], "expect_hash")
                guard KeyHash(pairHash) == expected else {
                    throw ScriptFailure("the pair's hash is not the expected one")
                }
            }
            try bind(try op.optionalString("key_as"), key)
            try bind(try op.optionalString("value_as"), value)

        case "read_uint":
            try op.allow("op", "note", "expect_error", "on", "expect")
            let result = try read(try op.string("on")) {
                try $0.readUInt64()
            } readOnly: {
                try $0.readUInt64()
            }
            if op.has("expect"), try op.unsigned("expect") != result {
                throw ScriptFailure("read_uint gave \(result)")
            }

        case "read_int":
            try op.allow("op", "note", "expect_error", "on", "expect")
            let result = try read(try op.string("on")) {
                try $0.readInt64()
            } readOnly: {
                try $0.readInt64()
            }
            if op.has("expect"), try op.signed("expect") != result {
                throw ScriptFailure("read_int gave \(result)")
            }

        case "read_float":
            try op.allow("op", "note", "expect_error", "on", "expect")
            let result = try read(try op.string("on")) {
                try $0.readDouble()
            } readOnly: {
                try $0.readDouble()
            }
            if op.has("expect"), try float(op.fields["expect"], "expect").bitPattern != result.bitPattern {
                throw ScriptFailure("read_float gave the bits \(String(result.bitPattern, radix: 16))")
            }

        case "read_bytes":
            try op.allow("op", "note", "expect_error", "on", "max_size", "expect", "expect_format_tag")
            // A limit beyond what an Int holds is no limit a value could reach.
            let maxSize = op.has("max_size") ? Int(clamping: try op.unsigned("max_size")) : nil
            let result = try read(try op.string("on")) {
                try $0.readBytesWithFormatTag(maxCount: maxSize)
            } readOnly: {
                try $0.readBytesWithFormatTag(maxCount: maxSize)
            }
            if op.has("expect"), try bytes(op.fields["expect"], "expect") != result.value {
                throw ScriptFailure("read_bytes gave \(result.value)")
            }
            try expectFormatTag(op, result.formatTag, "read_bytes")

        case "read_bytes_into":
            try op.allow("op", "note", "expect_error", "on", "size", "expect", "expect_format_tag")
            let size = try op.unsigned("size")
            guard size <= 1 << 24 else { throw UnknownInScript("a size over 2^24") }
            var buffer = [UInt8](repeating: 0xEE, count: Int(size))
            let result: (count: Int, formatTag: FormatTag?)
            do {
                var span = buffer.mutableSpan
                result = try read(try op.string("on")) {
                    try $0.readBytesWithFormatTag(into: &span)
                } readOnly: {
                    try $0.readBytesWithFormatTag(into: &span)
                }
            }
            if op.has("expect"), try bytes(op.fields["expect"], "expect") != Array(buffer[..<result.count]) {
                throw ScriptFailure("read_bytes_into gave \(Array(buffer[..<result.count]))")
            }
            try expectFormatTag(op, result.formatTag, "read_bytes_into")

        case "read_stream":
            try op.allow("op", "note", "expect_error", "on", "buffer_size", "steps")
            // A buffer size changes nothing here: the reader has no buffer.
            if op.has("buffer_size"), try op.unsigned("buffer_size") > 1 << 24 {
                throw UnknownInScript("a buffer_size over 2^24")
            }
            var reader = try read(try op.string("on")) {
                try $0.reader()
            } readOnly: {
                try $0.reader()
            }
            for step in try op.array("steps") {
                let step = try ScriptObject(step, "a stream step")
                try step.allow("read", "read_all", "seek", "position", "expect")
                if step.has("read") || step.has("read_all") {
                    let all = step.has("read_all")
                    let size = try step.unsigned(all ? "read_all" : "read")
                    guard size <= 1 << 24 else { throw UnknownInScript("a read over 2^24") }
                    var buffer = [UInt8](repeating: 0xEE, count: Int(size))
                    let count: Int
                    do {
                        var span = buffer.mutableSpan
                        if all {
                            try reader.readAll(into: &span)
                            count = Int(size)
                        } else {
                            count = try reader.read(into: &span)
                        }
                    }
                    if step.has("expect"), try bytes(step.fields["expect"], "expect") != Array(buffer[..<count]) {
                        throw ScriptFailure("the stream gave \(Array(buffer[..<count]))")
                    }
                } else if step.has("seek") {
                    guard step.fields.count == 1 else { throw UnknownInScript("a seek step with other fields") }
                    reader.seek(to: try step.unsigned("seek"))
                } else if step.has("position") {
                    guard step.fields.count == 1 else { throw UnknownInScript("a position step with other fields") }
                    if try step.unsigned("position") != reader.position {
                        throw ScriptFailure("the stream's position is \(reader.position)")
                    }
                } else {
                    throw UnknownInScript("a stream step with nothing to do")
                }
            }

        case "iterator":
            try op.allow("op", "note", "expect_error", "on", "from_index", "from_key", "as")
            if op.has("from_index") && op.has("from_key") {
                throw UnknownInScript("an iterator with both from_index and from_key")
            }
            let box: IteratorBox
            if op.has("from_index") {
                let index = try op.signed("from_index")
                box = try read(try op.string("on")) {
                    IteratorBox(try self.iterator(of: $0, from: index))
                } readOnly: {
                    IteratorBox(try self.iterator(of: $0, from: index))
                }
            } else if op.has("from_key") {
                let key = try bytes(op.fields["from_key"], "from_key")
                box = try read(try op.string("on")) {
                    IteratorBox(try self.iterator(of: $0, fromKey: key))
                } readOnly: {
                    IteratorBox(try self.iterator(of: $0, fromKey: key))
                }
            } else {
                box = try read(try op.string("on")) {
                    IteratorBox(try $0.iterator())
                } readOnly: {
                    IteratorBox(try $0.iterator())
                }
            }
            try bind(try op.string("as"), .iterator(box))

        case "next":
            try op.allow("op", "note", "expect_error", "on", "as", "expect_null")
            let result = try iterator(try op.string("on")).next()
            try expectNull(op, isNull: result == nil)
            try bind(try op.optionalString("as"), result.map { .readOnly($0) } ?? .nullCursor)

        case "rank":
            try op.allow("op", "note", "expect_error", "on", "key", "expect")
            let key = try bytes(op.fields["key"], "key")
            // The rank of a `SortedMap(.read_only)` on the cursor, whose
            // init checks the tag.
            let result = try read(try op.string("on")) {
                try SortedMap($0.readOnly).rank(of: key)
            } readOnly: {
                try SortedMap($0).rank(of: key)
            }
            if op.has("expect"), try op.unsigned("expect") != result {
                throw ScriptFailure("rank gave \(result)")
            }

        case "count":
            try op.allow("op", "note", "expect_error", "on", "expect")
            let result = try read(try op.string("on")) {
                try $0.count
            } readOnly: {
                try $0.count
            }
            if op.has("expect"), try op.unsigned("expect") != result {
                throw ScriptFailure("count gave \(result)")
            }

        case "replica_state":
            try op.allow("op", "note", "expect_error", "as")
            let state = try openDatabase("replica_state").replicaState
            try bind(try op.string("as"), .replicaState(state))

        case "replication_start":
            try op.allow("op", "note", "expect_error", "state", "as", "expect")
            let stateName = try op.string("state")
            guard case .replicaState(let state) = try bound(stateName) else {
                throw ScriptFailure("'\(stateName)' does not hold a replica's state")
            }
            let start = try openDatabase("replication_start").replicationStart(for: state)
            if op.has("expect"), try number(op.fields["expect"], "expect") != start {
                throw ScriptFailure("replication_start gave \(start)")
            }
            try bind(try op.optionalString("as"), .number(start))

        case "committed_size":
            try op.allow("op", "note", "expect_error", "as", "expect")
            let size = try openDatabase("committed_size").committedSize
            if op.has("expect"), try number(op.fields["expect"], "expect") != size {
                throw ScriptFailure("committed_size gave \(size)")
            }
            try bind(try op.optionalString("as"), .number(size))

        case "read_committed":
            try op.allow("op", "note", "expect_error", "start", "end", "as", "expect_same")
            let start = try number(op.fields["start"], "start")
            let end = try number(op.fields["end"], "end")
            let read = try openDatabase("read_committed").readCommitted(from: start, to: end)
            if op.has("expect_same") {
                let other = try op.string("expect_same")
                guard case .committedBytes(let expected) = try bound(other) else {
                    throw ScriptFailure("'\(other)' does not hold committed bytes")
                }
                guard read == expected else { throw ScriptFailure("read_committed gave other bytes than '\(other)'") }
            }
            try bind(try op.string("as"), .committedBytes(read))

        case "apply_replicated":
            try op.allow("op", "note", "expect_error", "start", "bytes", "short_by", "stream_short_by")
            let start = try number(op.fields["start"], "start")
            if start == 0 { zeroSyncTarget = current }
            let bytesName = try op.string("bytes")
            guard case .committedBytes(let bytes) = try bound(bytesName) else {
                throw ScriptFailure("'\(bytesName)' does not hold committed bytes")
            }
            // `short_by` is the sync that was interrupted: the bytes end
            // that many short, and so does the length asked for, so the
            // append goes through and fails on the trailer it does not find
            let shortBy = op.has("short_by") ? Int(clamping: try op.unsigned("short_by")) : 0
            guard shortBy <= bytes.count else { throw UnknownInScript("short_by is more than the bytes") }
            let sent = Array(bytes[0..<(bytes.count - shortBy)])
            guard op.has("stream_short_by") else {
                try openDatabase("apply_replicated").applyReplicated(at: start, bytes: sent)
                break
            }
            // `stream_short_by` is the sync whose stream stops part way:
            // the length asked for stays what `short_by` left, and the
            // source gives that many fewer, so the call reads past the end
            // of what it is given
            let streamShortBy = Int(clamping: try op.unsigned("stream_short_by"))
            guard streamShortBy <= sent.count else {
                throw UnknownInScript("stream_short_by is more than the bytes short_by leaves")
            }
            var source = ArrayByteSource(Array(sent[0..<(sent.count - streamShortBy)]))
            try openDatabase("apply_replicated").applyReplicated(at: start, from: &source, count: UInt64(sent.count))

        case "close":
            try op.allow("op", "note")
            database = nil
            names = [:]
            try storage.close()

        case "reopen":
            try op.allow("op", "note", "expect_error", "read_only", "hash_size", "file_id", "hash_id")
            if database != nil { throw ScriptFailure("reopen while the database is open") }
            // The hash size is always stated, the script's or the op's, and
            // never taken from the file.
            let size = op.has("hash_size") ? UInt16(try op.unsigned("hash_size")) : hashSize
            // `reopen` is the original's `Database.init` on the file as it
            // is, which creates again what a creation that did not finish
            // left: with the file ID and hash ID given here, a hash ID of
            // zeros when none is, and a file ID drawn when none is.
            let hashID: HashID?
            if !op.has("hash_id") || op.isNull("hash_id") {
                hashID = nil
            } else {
                let bytes = try self.bytes(op.fields["hash_id"], "hash_id")
                guard bytes.count == 4 else { throw UnknownInScript("hash_id is not four bytes") }
                hashID = HashID(bytes: [bytes[0], bytes[1], bytes[2], bytes[3]])
            }
            let givenFileID: UInt64? = op.has("file_id") ? try fileID(op.fields["file_id"]) : nil
            let opened = try storage.openStorage(readOnly: try op.bool("read_only", default: false))
            do {
                database = try Database(
                    storage: opened, hashSize: size, hashID: hashID, fileID: givenFileID, random: random)
            } catch {
                // A failed reopen leaves the database closed.
                try? storage.close()
                throw error
            }

        case "recover":
            // The port's recovery: the database must be closed, and it is
            // open afterwards. No commit ID: the call draws nothing.
            try op.allow("op", "note", "expect_error")
            if database != nil { throw ScriptFailure("recover while the database is open") }
            let opened = try storage.openStorage(readOnly: false)
            do {
                database = try Database.recover(opened, random: random)
            } catch {
                // A failed recovery leaves the database closed, as a failed
                // reopen does.
                try? storage.close()
                throw error
            }

        case "raw_append":
            try op.allow("op", "note", "bytes")
            if database != nil { throw ScriptFailure("raw_append while the database is open") }
            try storage.rawAppend(try bytes(op.fields["bytes"], "bytes"))

        case "raw_write":
            try op.allow("op", "note", "offset", "bytes")
            if database != nil { throw ScriptFailure("raw_write while the database is open") }
            try storage.rawWrite(try bytes(op.fields["bytes"], "bytes"), at: try op.unsigned("offset"))

        case "raw_load":
            // An input from the fixtures' `inputs` folder takes the place
            // of the file: a version 1 database, which nothing creates.
            try op.allow("op", "note", "input")
            if database != nil { throw ScriptFailure("raw_load while the database is open") }
            let input = try op.string("input")
            guard input.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                throw UnknownInScript("the input '\(input)' is not a name")
            }
            try storage.rawLoad(try fixtureFile("inputs/\(input).db"))

        case "raw_truncate":
            try op.allow("op", "note", "length")
            if database != nil { throw ScriptFailure("raw_truncate while the database is open") }
            try storage.rawTruncate(to: try op.unsigned("length"))

        default:
            throw UnknownInScript("unknown op '\(name)'")
        }
    }

    /// An iterator over an array list from an index: `ArrayList.iteratorFrom`
    /// in Zig, or the linked array list's or the sorted map's, by the tag.
    private func iterator<Access>(of cursor: Cursor<Access>, from index: Int64) throws -> CollectionIterator {
        switch try cursor.slot.tag {
        case .none, .arrayList: return try cursor.iterator(fromArrayListIndex: index)
        case .linkedArrayList: return try cursor.iterator(fromLinkedArrayListIndex: index)
        case .sortedMap, .sortedSet: return try cursor.iterator(fromSortedMapIndex: index)
        default: throw XitDBError.unexpectedTag
        }
    }

    /// An iterator over a sorted map or set from a key:
    /// `SortedMap.iteratorFrom` in Zig.
    private func iterator<Access>(of cursor: Cursor<Access>, fromKey key: [UInt8]) throws -> CollectionIterator {
        switch try cursor.slot.tag {
        case .none, .sortedMap, .sortedSet: return try cursor.iterator(fromSortedMapKey: SortedKey(key))
        default: throw XitDBError.unexpectedTag
        }
    }

    private func expectFormatTag(_ op: ScriptObject, _ tag: FormatTag?, _ what: String) throws {
        guard op.has("expect_format_tag") else { return }
        let expected: FormatTag? =
            op.isNull("expect_format_tag") ? nil : try formatTag(op.fields["expect_format_tag"], "a tag")
        guard Bytes([], formatTag: expected) == Bytes([], formatTag: tag) else {
            throw ScriptFailure("\(what) gave another format tag")
        }
    }

    /// Calls a read on a cursor of either kind.
    private func read<Result>(
        _ name: String,
        _ readWrite: (Cursor<ReadWrite>) throws -> Result,
        readOnly: (Cursor<ReadOnly>) throws -> Result
    ) throws -> Result {
        switch try bound(name) {
        case .readWrite(let cursor): return try readWrite(cursor)
        case .readOnly(let cursor): return try readOnly(cursor)
        case .nullCursor: throw ScriptFailure("'\(name)' is a null cursor")
        case .slot: throw ScriptFailure("'\(name)' holds a slot, not a cursor")
        case .iterator: throw ScriptFailure("'\(name)' holds an iterator, not a cursor")
        case .number, .replicaState, .committedBytes:
            throw ScriptFailure("'\(name)' holds a number, a state or bytes, not a cursor")
        }
    }

    private func expectNull(_ op: ScriptObject, isNull: Bool) throws {
        guard op.has("expect_null") else { return }
        if try op.bool("expect_null", default: false) != isNull {
            throw ScriptFailure(isNull ? "the result is null" : "the result is not null")
        }
    }

    private func expectSlot(_ op: ScriptObject, _ slot: Slot?) throws {
        guard op.has("expect") else { return }
        let expected = try ScriptObject(op.fields["expect"], "expect")
        try expected.allow("tag", "value", "full")
        guard let slot else { throw ScriptFailure("a slot was expected and the result is null") }
        if expected.has("tag"), try tag(try expected.string("tag")) != slot.tag {
            throw ScriptFailure("the slot's tag is \(slot.tag)")
        }
        if expected.has("value"), try expected.unsigned("value") != slot.value {
            throw ScriptFailure("the slot's value is \(slot.value)")
        }
        if expected.has("full"), try expected.bool("full", default: false) != slot.full {
            throw ScriptFailure("the slot's flag is \(slot.full)")
        }
    }
}

/// What the fixtures' manifest says about one script.
struct ConformanceFixture: CustomTestStringConvertible, Sendable {
    let name: String
    let mustPass: Bool
    let script: String
    let database: String?
    let sidecar: String?
    let collections: [String]
    let features: [String]

    /// The files the script's other databases must leave, by the names
    /// the script gives them.
    let otherDatabases: [String: String]

    var testDescription: String { name }

    /// Every script in the copied fixtures, as the manifest lists them.
    static let all: [ConformanceFixture] = {
        guard
            let bytes = try? fixtureFile("manifest.json"),
            let manifest = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
            manifest["format"] as? String == "xitdb-fixtures/1",
            let entries = manifest["fixtures"] as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard
                let name = entry["name"] as? String,
                let outcome = entry["outcome"] as? String,
                let script = entry["script"] as? String,
                entry["format"] as? String == "xitdb-script/1"
            else { return nil }
            return ConformanceFixture(
                name: name,
                mustPass: outcome == "pass",
                script: script,
                database: entry["db"] as? String,
                sidecar: entry["sidecar"] as? String,
                collections: entry["collections"] as? [String] ?? [],
                features: entry["features"] as? [String] ?? [],
                otherDatabases: entry["other_databases"] as? [String: String] ?? [:]
            )
        }
    }()

    /// The engine error a failing script's description pins, if it pins
    /// one: "expected failure: unexpected error X" is Zig's message for an
    /// error X that its last op raised and nothing handled. Any other text
    /// after "expected failure:" is a reason in Zig's own words, whose
    /// wording is not part of the format.
    static func pinnedError(in description: String?) -> String? {
        guard let description, let range = description.range(of: "expected failure: unexpected error ") else {
            return nil
        }
        let name = description[range.upperBound...].prefix { $0.isLetter || $0.isNumber }
        return name.isEmpty ? nil : String(name)
    }

    /// Runs the script on a storage kind and holds it to what Zig did.
    ///
    /// A script that must pass is given the commit IDs from its sidecar, has
    /// its committed size checked after every top-level op, and must leave
    /// the file Zig wrote. A script that must fail has to end in a
    /// `ScriptFailure`, and one whose description pins an unhandled error
    /// has to end in that error, raised by its last op.
    ///
    /// With `otherOffsetMap`, every `compact` uses the offset map the
    /// script does not name, which must change nothing in what is written:
    /// the conformance `check.sh` holds the scripts to that the same way.
    ///
    /// With `proving`, a passing script also runs the snapshot proof: a
    /// snapshot of every open database after every op, held to its copy at
    /// the end (`SnapshotProof`). The proof costs many times the replay in
    /// a debug build, so it has a suite of its own, which the gate runs in
    /// release.
    func run(on kind: StorageKind, otherOffsetMap: Bool = false, proving: Bool = false) throws {
        let script = try JSONSerialization.jsonObject(with: Data(try fixtureFile(script)))

        guard mustPass else {
            let pinned = Self.pinnedError(in: try ScriptObject(script, "the script").optionalString("description"))
            // Some of these commit before they fail, so the random source
            // has to return something. Any values will do.
            let runner = ScriptRunner(
                storage: try ScriptStorage(kind),
                random: FixedRandom((1...64).map { UInt64($0) })
            )
            runner.otherOffsetMap = otherOffsetMap
            let ops = try runner.start(script)
            for (index, op) in ops.enumerated() {
                do {
                    try runner.run(op, topLevel: true)
                } catch let failure as ScriptFailure {
                    guard let pinned else { return }
                    guard index == ops.count - 1 else {
                        throw ScriptFailure("\(name) must fail at its last op, and op \(index) failed: \(failure)")
                    }
                    guard failure.unhandled == pinned else {
                        throw ScriptFailure(
                            "\(name) must raise \(pinned), which nothing handles, and it failed: \(failure)")
                    }
                    return
                }
            }
            throw ScriptFailure("\(name) must fail, and it ran to the end")
        }

        let sidecarJSON = try JSONSerialization.jsonObject(with: Data(try fixtureFile(try #require(sidecar))))
        let sidecar = try ScriptObject(sidecarJSON, "the sidecar")
        try sidecar.allow("format", "file_id", "initial_size", "file_size", "databases", "ops")
        guard try sidecar.string("format") == "xitdb-sidecar/1" else { throw UnknownInScript("unknown sidecar format") }
        let steps = try sidecar.array("ops").map { try ScriptObject($0, "a sidecar entry") }
        let commitIDs = try steps.compactMap { step -> UInt64? in
            try step.allow("db", "committed_size", "commit_id")
            guard !step.isNull("commit_id") else { return nil }
            return hex(try step.string("commit_id")).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }

        let random = FixedRandom(commitIDs)
        let storage = try ScriptStorage(kind)
        let runner = ScriptRunner(storage: storage, random: random)
        runner.otherOffsetMap = otherOffsetMap
        let ops = try runner.start(script)
        guard try runner.committedSize() == (try sidecar.unsigned("initial_size")) else {
            throw ScriptFailure("the new database's committed size is not the sidecar's")
        }
        guard ops.count == steps.count else { throw ScriptFailure("the sidecar has another number of ops") }

        // The snapshot proof: a snapshot of every open database after
        // every op, held to its copy at the end (D25).
        let proof = proving ? SnapshotProof(kind: kind) : nil
        for (index, op) in ops.enumerated() {
            if let proof {
                let opObject = try ScriptObject(op, "an op")
                try proof.before(op: try opObject.string("op"), on: runner.currentName)
            }
            runner.zeroSyncTarget = nil
            try runner.run(op, topLevel: true)
            if let proof, let target = runner.zeroSyncTarget { proof.zeroSynced(target) }
            let expected: UInt64? =
                steps[index].isNull("committed_size") ? nil : try steps[index].unsigned("committed_size")
            // An entry is about the database the op committed in, or the
            // current one; `db` names it when it is not `main`.
            let about = try steps[index].optionalString("db")
            let actual = try runner.committedSize(of: about ?? "main")
            guard actual == expected else {
                throw ScriptFailure(
                    "after op \(index) the committed size of \(about ?? "main") is \(String(describing: actual)), and Zig's was \(String(describing: expected))"
                )
            }
            try proof?.after(step: index, runner)
        }

        guard random.remaining == 0, !random.exhausted else {
            throw ScriptFailure("the commit IDs were not used up exactly: \(random.remaining) left")
        }
        let file = try storage.contents()
        guard UInt64(file.count) == (try sidecar.unsigned("file_size")) else {
            throw ScriptFailure("the file has \(file.count) bytes, and Zig's has \(try sidecar.unsigned("file_size"))")
        }
        if let difference = firstDifference(file, try fixtureFile(try #require(database))) {
            throw ScriptFailure("the file differs from Zig's: \(difference)")
        }

        // The other databases of the script, each against its own file.
        let others = Set(runner.databaseNames).subtracting(["main"])
        guard others == Set(otherDatabases.keys) else {
            throw ScriptFailure(
                "the script made the databases \(others.sorted()), and the manifest lists \(otherDatabases.keys.sorted())"
            )
        }
        let sizes = sidecar.has("databases") ? try ScriptObject(sidecar.fields["databases"], "databases") : nil
        for (name, expectedFile) in otherDatabases {
            let other = try runner.contents(of: name)
            if let sizes {
                let entry = try ScriptObject(sizes.fields[name], "a database entry")
                try entry.allow("file_id", "file_size", "trailers")
                guard UInt64(other.count) == (try entry.unsigned("file_size")) else {
                    throw ScriptFailure(
                        "the database \(name) has \(other.count) bytes, and Zig's has \(try entry.unsigned("file_size"))"
                    )
                }
            }
            if let difference = firstDifference(other, try fixtureFile(expectedFile)) {
                throw ScriptFailure("the database \(name) differs from Zig's: \(difference)")
            }
        }

        // Every snapshot against its copy, and against the final files.
        if let proof {
            var expectedFiles = ["main": try fixtureFile(try #require(database))]
            for (name, expectedFile) in otherDatabases {
                expectedFiles[name] = try fixtureFile(expectedFile)
            }
            try proof.finish(expectedFiles: expectedFiles)
            // A script in which no database has a committed size after any
            // op, by the sidecar's word and not the proof's, has no commit to
            // take a snapshot of: one that only opens files without a first
            // commit. Every other script must have had one checked.
            let hadACommit = steps.contains { !$0.isNull("committed_size") }
            guard proof.checked > 0 || !hadACommit else { throw ScriptFailure("the snapshot proof checked nothing") }
        }
    }
}
