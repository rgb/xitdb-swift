import CryptoKit
import Foundation
import Testing

@testable import XitDB

// A runner for the conformance scripts, written from the conformance
// repository's SCRIPT-FORMAT.md. Each op is one call on the engine. The
// runner adds no checks and no recovery of its own, and it fails on anything
// in a script that it does not know.

/// A failure of the script itself: an expectation that did not hold, a name
/// used wrongly, an engine error that nothing handled. A script in the
/// fixtures' `failing` folder must end in one of these.
struct ScriptFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
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
enum ScriptStorageKind: String, CaseIterable, CustomTestStringConvertible {
    case memory
    case file
    case bufferedFile

    var testDescription: String { rawValue }
}

/// Where a script's database lives, across closing and reopening it. The raw
/// ops of a script write here directly, past the engine.
final class ScriptStorage {
    let kind: ScriptStorageKind
    private let directory: TemporaryDirectory?
    private var memoryBytes: [UInt8] = []
    private var memory: MemoryStorage?
    private var open: (any WritableStorage)?

    init(_ kind: ScriptStorageKind) throws {
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
        }
        open = storage
        return storage
    }

    /// Ends the use of the storage. Commits are already in it.
    func close() {
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
        case .file, .bufferedFile:
            let file = try FileStorage(path: try #require(directory).path(), access: .create, durability: .none)
            try file.write(bytes.span, at: offset)
        }
    }

    /// Writes bytes at the end while the database is closed.
    func rawAppend(_ bytes: [UInt8]) throws {
        try rawWrite(bytes, at: UInt64(try contents().count))
    }

    /// Everything in the storage as it is now.
    func contents() throws -> [UInt8] {
        try open?.flush()
        switch kind {
        case .memory: return memory?.bytes ?? memoryBytes
        case .file, .bufferedFile: return try #require(directory).contents()
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
    }

    let storage: ScriptStorage
    let random: FixedRandom
    private var names: [String: Value] = [:]
    private var database: Database?
    private var hashSize: UInt16 = 0

    init(storage: ScriptStorage, random: FixedRandom) {
        self.storage = storage
        self.random = random
    }

    /// The committed size, or `nil` while the database is closed.
    func committedSize() throws -> UInt64? {
        try database?.committedSize()
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
        let fileIDBytes = try hexBytes(try document.string("file_id"), "file_id")
        guard fileIDBytes.count == 8 else { throw UnknownInScript("file_id is not eight bytes") }
        let fileID = fileIDBytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }

        database = try Database(
            storage: try storage.openStorage(readOnly: false),
            hashSize: hashSize,
            hashID: hashID,
            fileID: fileID,
            random: random
        )
        return try document.array("ops")
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

    private func formatTag(_ value: Any?, _ what: String) throws -> InlineArray<2, UInt8> {
        let tag = try bytes(value, what)
        guard tag.count == 2 else { throw UnknownInScript("\(what) is not two bytes") }
        return [tag[0], tag[1]]
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

    private static let tagNames: [String: XitDB.Tag] = [
        "none": .none, "index": .index, "array_list": .arrayList, "linked_array_list": .linkedArrayList,
        "hash_map": .hashMap, "kv_pair": .kvPair, "bytes": .bytes, "short_bytes": .shortBytes, "uint": .uint,
        "int": .int, "float": .float, "hash_set": .hashSet, "counted_hash_map": .countedHashMap,
        "counted_hash_set": .countedHashSet, "sorted_map": .sortedMap, "sorted_set": .sortedSet,
        "sorted_kv_pair": .sortedKvPair,
    ]

    private func tag(_ name: String) throws -> XitDB.Tag {
        guard let tag = Self.tagNames[name] else { throw UnknownInScript("unknown tag '\(name)'") }
        return tag
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

    private func writeData(_ value: Any?) throws -> WriteableData {
        let object = try ScriptObject(value, "write data")
        try object.allow("slot", "uint", "int", "float", "bytes", "bytes_object")
        guard object.fields.count == 1 else { throw UnknownInScript("write data needs exactly one field") }
        if object.has("slot") { return .slot(try slot(object.fields["slot"], "a slot")) }
        if object.has("uint") { return .uint(try object.unsigned("uint")) }
        if object.has("int") { return .int(try object.signed("int")) }
        if object.has("float") { return .float(try float(object.fields["float"], "a float")) }
        if object.has("bytes") { return .bytes(try bytes(object.fields["bytes"], "bytes")) }
        let bytesObject = try ScriptObject(object.fields["bytes_object"], "bytes_object")
        try bytesObject.allow("value", "format_tag")
        return .bytesObject(
            Bytes(
                try bytes(bytesObject.fields["value"], "bytes"),
                formatTag: bytesObject.has("format_tag")
                    ? try formatTag(bytesObject.fields["format_tag"], "format_tag") : nil
            )
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
            return .readWrite(database.rootCursor())
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
        }
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

    private static func name(of error: XitDBError) -> String {
        switch error {
        case .unexpectedTag: "UnexpectedTag"
        case .keyNotFound: "KeyNotFound"
        case .writeNotAllowed: "WriteNotAllowed"
        case .cursorNotWriteable: "CursorNotWriteable"
        case .expectedTxStart: "ExpectedTxStart"
        case .nestedTopLevelWrite: "NestedTopLevelWrite"
        case .invalidDatabase: "InvalidDatabase"
        case .invalidVersion: "InvalidVersion"
        case .invalidHashSize: "InvalidHashSize"
        case .truncatedDatabase: "TruncatedDatabase"
        case .invalidEnumTag: "InvalidEnumTag"
        case .invalidBTreeNode: "InvalidBTreeNode"
        case .invalidBTreeNodeKind: "InvalidBTreeNodeKind"
        case .invalidRange: "InvalidRange"
        case .invalidLength: "InvalidLength"
        case .targetNotEmpty: "TargetNotEmpty"
        case .keyOffsetExceeded: "KeyOffsetExceeded"
        case .maxShiftExceeded: "MaxShiftExceeded"
        case .maxSizeExceeded: "MaxSizeExceeded"
        case .streamTooLong: "StreamTooLong"
        case .endOfStream: "EndOfStream"
        case .unexpectedWriterPosition: "UnexpectedWriterPosition"
        case .expectedSlotPosition: "ExpectedSlotPosition"
        case .pathPartMustBeAtEnd: "PathPartMustBeAtEnd"
        case .notImplemented: "NotImplemented"
        // A failed write to the storage is what Zig's writer interface
        // reports as WriteFailed.
        case .storageFailure: "WriteFailed"
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
                if topLevel { throw ScriptFailure("the op '\(name)' raised \(raised), which nothing handles") }
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
        let closedOps = ["close", "reopen", "raw_append", "raw_write"]
        if closedOps.contains(name) && !topLevel {
            throw UnknownInScript("'\(name)' inside a callback")
        }
        if database == nil && !["reopen", "raw_append", "raw_write"].contains(name) {
            throw ScriptFailure("the op '\(name)' while the database is closed")
        }

        switch name {
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
            try cursor.writer { writer in
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
            try openDatabase("run_context").runContext { cursor in try self.callback(context, &cursor) }

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
            }
            try expectNull(op, isNull: result == nil)
            try expectSlot(op, result)
            try bind(try op.optionalString("as"), .slot(result))

        case "slot":
            try op.allow("op", "note", "expect_error", "on", "as", "expect")
            let result = try read(try op.string("on")) {
                try $0.slot()
            } readOnly: {
                try $0.slot()
            }
            try expectSlot(op, result)
            try bind(try op.optionalString("as"), .slot(result))

        case "read_only":
            try op.allow("op", "note", "expect_error", "on", "as")
            try bind(try op.string("as"), .readOnly(try readWrite(try op.string("on")).readOnly()))

        case "read_key_value_pair":
            try op.allow("op", "note", "expect_error", "on", "key_as", "value_as", "expect_hash")
            let pairHash: [UInt8]
            let key: Value
            let value: Value
            switch try bound(try op.string("on")) {
            case .readWrite(let cursor):
                let pair = try cursor.readKeyValuePair()
                (pairHash, key, value) = (pair.hash, .readWrite(pair.keyCursor), .readWrite(pair.valueCursor))
            case .readOnly(let cursor):
                let pair = try cursor.readKeyValuePair()
                (pairHash, key, value) = (pair.hash, .readOnly(pair.keyCursor), .readOnly(pair.valueCursor))
            case .nullCursor: throw ScriptFailure("a null cursor was used")
            case .slot: throw ScriptFailure("a slot was used as a cursor")
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
                try $0.readUint()
            } readOnly: {
                try $0.readUint()
            }
            if op.has("expect"), try op.unsigned("expect") != result {
                throw ScriptFailure("read_uint gave \(result)")
            }

        case "read_int":
            try op.allow("op", "note", "expect_error", "on", "expect")
            let result = try read(try op.string("on")) {
                try $0.readInt()
            } readOnly: {
                try $0.readInt()
            }
            if op.has("expect"), try op.signed("expect") != result {
                throw ScriptFailure("read_int gave \(result)")
            }

        case "read_float":
            try op.allow("op", "note", "expect_error", "on", "expect")
            let result = try read(try op.string("on")) {
                try $0.readFloat()
            } readOnly: {
                try $0.readFloat()
            }
            if op.has("expect"), try float(op.fields["expect"], "expect").bitPattern != result.bitPattern {
                throw ScriptFailure("read_float gave the bits \(String(result.bitPattern, radix: 16))")
            }

        case "read_bytes":
            try op.allow("op", "note", "expect_error", "on", "expect", "expect_format_tag")
            let result = try read(try op.string("on")) {
                try $0.readBytesObjectAlloc()
            } readOnly: {
                try $0.readBytesObjectAlloc()
            }
            if op.has("expect"), try bytes(op.fields["expect"], "expect") != result.value {
                throw ScriptFailure("read_bytes gave \(result.value)")
            }
            if op.has("expect_format_tag") {
                let expected: InlineArray<2, UInt8>? =
                    op.isNull("expect_format_tag") ? nil : try formatTag(op.fields["expect_format_tag"], "a tag")
                guard Bytes([], formatTag: expected) == Bytes([], formatTag: result.formatTag) else {
                    throw ScriptFailure("read_bytes gave another format tag")
                }
            }

        case "count":
            try op.allow("op", "note", "expect_error", "on", "expect")
            let result = try read(try op.string("on")) {
                try $0.count()
            } readOnly: {
                try $0.count()
            }
            if op.has("expect"), try op.unsigned("expect") != result {
                throw ScriptFailure("count gave \(result)")
            }

        case "close":
            try op.allow("op", "note")
            database = nil
            names = [:]
            storage.close()

        case "reopen":
            try op.allow("op", "note", "expect_error", "read_only", "hash_size")
            if database != nil { throw ScriptFailure("reopen while the database is open") }
            // The hash size is always stated, the script's or the op's, and
            // never taken from the file.
            let size = op.has("hash_size") ? UInt16(try op.unsigned("hash_size")) : hashSize
            let opened = try storage.openStorage(readOnly: try op.bool("read_only", default: false))
            do {
                database = try Database(storage: opened, hashSize: size, hashID: nil, fileID: nil, random: random)
            } catch {
                // A failed reopen leaves the database closed.
                storage.close()
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

        default:
            throw UnknownInScript("unknown op '\(name)'")
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

    var testDescription: String { name }

    /// The milestone that brings what this script still needs, or `nil` if
    /// it can run now.
    var waitsFor: String? {
        if collections.contains("linked_array_list") { return "M5" }
        if collections.contains("sorted_map") { return "M6" }
        return nil
    }

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
                features: entry["features"] as? [String] ?? []
            )
        }
    }()

    /// Runs the script on a storage kind and holds it to what Zig did.
    ///
    /// A script that must pass is given the commit IDs from its sidecar, has
    /// its committed size checked after every top-level op, and must leave
    /// the file Zig wrote. A script that must fail has to end in a
    /// `ScriptFailure`.
    func run(on kind: ScriptStorageKind) throws {
        let script = try JSONSerialization.jsonObject(with: Data(try fixtureFile(script)))

        guard mustPass else {
            // Some of these commit before they fail, so the random source
            // has to return something. Any values will do.
            let runner = ScriptRunner(
                storage: try ScriptStorage(kind),
                random: FixedRandom((1...64).map { UInt64($0) })
            )
            do {
                for op in try runner.start(script) {
                    try runner.run(op, topLevel: true)
                }
            } catch is ScriptFailure {
                return
            }
            throw ScriptFailure("\(name) must fail, and it ran to the end")
        }

        let sidecarJSON = try JSONSerialization.jsonObject(with: Data(try fixtureFile(try #require(sidecar))))
        let sidecar = try ScriptObject(sidecarJSON, "the sidecar")
        try sidecar.allow("format", "file_id", "initial_size", "file_size", "ops")
        guard try sidecar.string("format") == "xitdb-sidecar/1" else { throw UnknownInScript("unknown sidecar format") }
        let steps = try sidecar.array("ops").map { try ScriptObject($0, "a sidecar entry") }
        let commitIDs = try steps.compactMap { step -> UInt64? in
            try step.allow("committed_size", "commit_id")
            guard !step.isNull("commit_id") else { return nil }
            return hex(try step.string("commit_id")).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }

        let random = FixedRandom(commitIDs)
        let storage = try ScriptStorage(kind)
        let runner = ScriptRunner(storage: storage, random: random)
        let ops = try runner.start(script)
        guard try runner.committedSize() == (try sidecar.unsigned("initial_size")) else {
            throw ScriptFailure("the new database's committed size is not the sidecar's")
        }
        guard ops.count == steps.count else { throw ScriptFailure("the sidecar has another number of ops") }

        for (index, op) in ops.enumerated() {
            try runner.run(op, topLevel: true)
            let expected: UInt64? =
                steps[index].isNull("committed_size") ? nil : try steps[index].unsigned("committed_size")
            let actual = try runner.committedSize()
            guard actual == expected else {
                throw ScriptFailure(
                    "after op \(index) the committed size is \(String(describing: actual)), and Zig's was \(String(describing: expected))"
                )
            }
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
    }
}
