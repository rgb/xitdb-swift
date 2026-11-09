import Foundation
import Testing
import XitDBHashing

@testable import XitDB
@testable import XitDBStore

/// The proof through the layer: every fixture script whose writes the store
/// can express is run through the store, and the file it leaves is held
/// byte for byte to the one Zig left.
///
/// The store hashes keys itself and clones the latest moment into a new
/// transaction, so a script is expressible when its maps are keyed by
/// `{"sha1": "text"}` hashes, its moments are the first or a clone of the
/// latest, its values are plain integers, doubles and bytes without format
/// tags, and it uses no byte writers, slots, freezes, compaction,
/// replication, raw bytes or expected errors. Reads change no bytes and are
/// skipped. What is not expressible is counted, not hidden.
@Suite struct StoreConformanceTests {
    static let passing = ConformanceFixture.all.filter(\.mustPass)

    @Test(arguments: passing)
    func throughTheLayer(fixture: ConformanceFixture) throws {
        // The scripts' callbacks nest deep, as in ConformanceTests.
        try onLargeStack {
            switch try StoreScript(fixture).run() {
            case .expressed: break
            case .notExpressible: break
            }
        }
    }

    /// The subset is pinned, so that a script that stops being expressible
    /// changes this test and the report's number stays true.
    @Test func theSubsetIsKnown() throws {
        try onLargeStack {
            var expressed: [String] = []
            var reasons: [String: Int] = [:]
            for fixture in Self.passing {
                switch try StoreScript(fixture).run() {
                case .expressed: expressed.append(fixture.name)
                case .notExpressible(let reason): reasons[reason, default: 0] += 1
                }
            }
            #expect(expressed.count == 7, "expressed: \(expressed.sorted()); not: \(reasons)")
            #expect(expressed.count + reasons.values.reduce(0, +) == Self.passing.count)
        }
    }
}

/// One fixture script read as store operations.
final class StoreScript {
    enum Outcome {
        /// The script ran through the store and its bytes are Zig's.
        case expressed
        /// The script uses something the layer has no words for.
        case notExpressible(String)
    }

    /// Thrown while translating when the layer has no words for an op.
    struct NotExpressible: Error {
        let reason: String
    }

    let fixture: ConformanceFixture
    private var storage = MemoryStorage()
    private var store: Store?
    private var random: FixedRandom
    private var names: [String: Handle] = [:]
    /// The names `read_path_slot` bound to the latest moment's slot, which a
    /// clone writes back after an append: the store's own transaction.
    private var latestMomentSlots: Set<String> = []
    private var fileID: UInt64 = 0
    private var hashID: HashID?

    init(_ fixture: ConformanceFixture) throws {
        self.fixture = fixture
        random = FixedRandom()
    }

    func run() throws -> Outcome {
        let script = try ScriptObject(
            try JSONSerialization.jsonObject(with: Data(try fixtureFile(fixture.script))), "the script")
        guard let sidecarName = fixture.sidecar, let databaseName = fixture.database else {
            return .notExpressible("no sidecar or database file")
        }
        let sidecar = try ScriptObject(
            try JSONSerialization.jsonObject(with: Data(try fixtureFile(sidecarName))), "the sidecar")
        let commitIDs = try sidecar.array("ops").map { try ScriptObject($0, "a sidecar entry") }.compactMap {
            step -> UInt64? in
            guard !step.isNull("commit_id") else { return nil }
            return hex(try step.string("commit_id")).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
        random = FixedRandom(commitIDs)
        do {
            try open(script)
            for op in try script.array("ops") {
                try run(try ScriptObject(op, "an op"), inContext: false)
            }
        } catch let refusal as NotExpressible {
            return .notExpressible(refusal.reason)
        }
        let expected = try fixtureFile(databaseName)
        let actual = storage.bytes
        guard random.remaining == 0, !random.exhausted else {
            throw ScriptFailure(
                "\(fixture.name): the store used \(commitIDs.count - random.remaining) of \(commitIDs.count) commit IDs"
            )
        }
        if let difference = firstDifference(actual, expected) {
            throw ScriptFailure("\(fixture.name) through the store differs from Zig's file: \(difference)")
        }
        return .expressed
    }

    // MARK: The database

    private func open(_ script: ScriptObject) throws {
        guard try script.unsigned("hash_size") == 20 else {
            throw NotExpressible.because("a hash size other than SHA-1's")
        }
        if script.isNull("hash_id") {
            hashID = nil
        } else {
            guard let idString = script.fields["hash_id"] as? String, idString.utf8.count == 4 else {
                throw NotExpressible.because("a hash ID that is not four characters")
            }
            let idBytes = Array(idString.utf8)
            hashID = HashID(bytes: [idBytes[0], idBytes[1], idBytes[2], idBytes[3]])
        }
        guard let fileIDString = script.fields["file_id"] as? String else { throw NotExpressible.because("no file ID") }
        fileID = hex(fileIDString).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let database = try Database(
            creating: storage, hashSize: 20, hashID: hashID, fileID: fileID, random: random)
        store = try Store(database, hashing: Insecure.SHA1.self)
    }

    // MARK: Ops

    private func run(_ op: ScriptObject, inContext: Bool) throws {
        let name = try op.string("op")
        if op.has("expect_error") { throw NotExpressible.because("an op that expects an error") }
        switch name {
        case "write_path":
            let on = try op.string("on")
            let path = try op.array("path")
            if on == "root" {
                try transaction(path, bindAs: try op.optionalString("as"))
            } else {
                guard let handle = names[on] else {
                    throw NotExpressible.because("a write through a name bound by a read")
                }
                try apply(path[...], from: handle, bindAs: try op.optionalString("as"))
            }
        case "write":
            let on = try op.string("on")
            guard let handle = names[on] else { throw NotExpressible.because("a write through a name bound by a read") }
            try set(op.fields["data"], at: handle)
        case "read_path_slot":
            // The idiom that clones the latest moment: remember the name.
            if try op.string("on") == "root", let path = try? op.array("path"), path.count == 1,
                let get = path[0] as? [String: Any], let index = get["array_list_get"] as? Int, index == -1,
                let bound = try op.optionalString("as")
            {
                latestMomentSlots.insert(bound)
            }
        case "read_path", "read_uint", "read_int", "read_float", "read_bytes", "read_bytes_into", "count", "iterator",
            "next", "slot", "committed_size", "read_key_value_pair", "rank", "read_stream":
            // reads change no bytes; a name a read binds is never written through here
            if let bound = try op.optionalString("as"), names[bound] != nil { names[bound] = nil }
        case "close":
            store = nil
            names = [:]
        case "reopen":
            guard !op.has("read_only"), !op.has("hash_size") else {
                throw NotExpressible.because("a reopen with options")
            }
            store = try Store(try Database(opening: storage, hashSize: 20, random: random), hashing: Insecure.SHA1.self)
        default:
            throw NotExpressible.because("the op \(name)")
        }
    }

    /// A write path from the root: the first moment, or a clone of the
    /// latest, then the rest inside the store's transaction.
    private func transaction(_ path: [Any], bindAs: String?) throws {
        guard let store else { throw ScriptFailure("the database is closed") }
        var parts = path[...]
        guard parts.first as? String == "array_list_init" else {
            throw NotExpressible.because("a root path that is not the history")
        }
        parts = parts.dropFirst()
        guard parts.first as? String == "array_list_append" else {
            throw NotExpressible.because("a root path that does not append a moment")
        }
        parts = parts.dropFirst()
        if let write = parts.first as? [String: Any], let data = write["write"] as? [String: Any] {
            // a clone of the latest moment, or nothing the store can say
            guard let slot = data["slot"] as? [String: Any], let variable = slot["var"] as? String,
                latestMomentSlots.contains(variable)
            else { throw NotExpressible.because("a value written into the history") }
            parts = parts.dropFirst()
        } else if try store.momentCount > 0 {
            throw NotExpressible.because("a fresh moment after the first, which the store would clone")
        }
        guard let initPart = parts.first as? [String: Any], let options = initPart["hash_map_init"] as? [String: Any],
            options.isEmpty
        else { throw NotExpressible.because("a moment that is not a plain hash map") }
        parts = parts.dropFirst()
        let rest = parts
        try store.transaction { moment in
            try apply(rest, from: moment.root, bindAs: bindAs)
        }
    }

    /// The kinds of collection a path's init part names for the place.
    private enum Kind {
        case map(counted: Bool, set: Bool)
        case list
        case linkedList
        case sorted(set: Bool)
    }

    /// Applies the parts of a path from a handle: descents, collection
    /// operations and the value or callback at the end.
    private func apply(_ parts: ArraySlice<Any>, from start: Handle, bindAs: String?) throws {
        var handle = start
        var kind: Kind?
        var index = parts.startIndex
        func next() -> Any? {
            guard index < parts.endIndex else { return nil }
            defer { index += 1 }
            return parts[index]
        }
        while let part = next() {
            if let name = part as? String {
                switch name {
                case "array_list_init": kind = .list
                case "linked_array_list_init": kind = .linkedList
                case "array_list_append":
                    guard kind == nil || isList(kind) else { throw NotExpressible.because("an append on another kind") }
                    handle = try handle.list(UInt64.self).append()
                    kind = nil
                case "linked_array_list_append":
                    handle = try handle.linkedList(UInt64.self).append()
                    kind = nil
                default: throw NotExpressible.because("the path part \(name)")
                }
                continue
            }
            let object = try ScriptObject(part, "a path part")
            guard object.fields.count == 1, let (key, payload) = object.fields.first else {
                throw NotExpressible.because("a path part with several fields")
            }
            switch key {
            case "hash_map_init":
                let options = try ScriptObject(payload, "hash_map_init")
                kind = .map(
                    counted: try options.bool("counted", default: false), set: try options.bool("set", default: false))
            case "sorted_map_init":
                let options = try ScriptObject(payload, "sorted_map_init")
                kind = .sorted(set: try options.bool("set", default: false))
            case "hash_map_get":
                let get = try ScriptObject(payload, "hash_map_get")
                let map = kind ?? .map(counted: false, set: false)
                guard case .map(let counted, let set) = map else {
                    throw NotExpressible.because("a hash map get on another kind")
                }
                if get.has("value"), !set {
                    let keyText = try keyString(get.fields["value"])
                    if counted {
                        // the counted map exists only once something is put; the
                        // next part must be the value
                        guard let write = next() as? [String: Any], let data = write["write"], index == parts.endIndex
                        else { throw NotExpressible.because("a counted map used for more than one put") }
                        try put(data, inCountedMapAt: handle, key: keyText)
                        kind = nil
                        continue
                    }
                    handle = handle[keyText]
                    kind = nil
                } else if get.has("key"), set {
                    let keyText = try keyString(get.fields["key"])
                    guard let write = next() as? [String: Any], let data = write["write"] as? [String: Any],
                        try self.bytes(data["bytes"]) == Array(keyText.utf8), index == parts.endIndex
                    else { throw NotExpressible.because("a set entry that does not store its own key") }
                    if counted {
                        try handle.countedKeySet(String.self).insert(keyText)
                    } else {
                        try handle.keySet(String.self).insert(keyText)
                    }
                    kind = nil
                } else {
                    throw NotExpressible.because("a hash map get of a key or pair")
                }
            case "hash_map_remove":
                let keyText = try keyString(payload)
                let map = kind ?? .map(counted: false, set: false)
                guard case .map(let counted, let set) = map else {
                    throw NotExpressible.because("a remove on another kind")
                }
                switch (counted, set) {
                case (false, false): _ = try handle.map(String.self, UInt64.self).remove(keyText)
                case (true, false): _ = try handle.countedMap(String.self, UInt64.self).remove(keyText)
                case (false, true): _ = try handle.keySet(String.self).remove(keyText)
                case (true, true): _ = try handle.countedKeySet(String.self).remove(keyText)
                }
                kind = nil
            case "array_list_get":
                guard kind == nil || isList(kind) else { throw NotExpressible.because("an index into another kind") }
                handle = handle[index: try ScriptObject.signedInt(payload)]
                kind = nil
            case "linked_array_list_get":
                handle = handle[index: try ScriptObject.signedInt(payload)]
                kind = nil
            case "array_list_slice":
                let options = try ScriptObject(payload, "array_list_slice")
                try handle.list(UInt64.self).truncate(to: Int(try options.unsigned("size")))
                kind = nil
            case "linked_array_list_slice":
                let options = try ScriptObject(payload, "linked_array_list_slice")
                try handle.linkedList(UInt64.self).slice(
                    offset: Int(try options.unsigned("offset")), count: Int(try options.unsigned("size")))
                kind = nil
            case "linked_array_list_insert":
                let at = try ScriptObject.signedInt(payload)
                guard let write = next() as? [String: Any], let data = write["write"], index == parts.endIndex else {
                    throw NotExpressible.because("an insert without its value")
                }
                try insert(data, intoLinkedListAt: handle, at: at)
                kind = nil
            case "linked_array_list_remove":
                try handle.linkedList(UInt64.self).remove(at: try ScriptObject.signedInt(payload))
                kind = nil
            case "sorted_map_get":
                let get = try ScriptObject(payload, "sorted_map_get")
                guard case .sorted(let set)? = kind else {
                    throw NotExpressible.because("a sorted get without its init")
                }
                if get.has("value"), !set {
                    let keyBytes = try keyBytes(get.fields["value"])
                    guard let write = next() as? [String: Any], let data = write["write"], index == parts.endIndex
                    else {
                        throw NotExpressible.because("a sorted map get that is not a put")
                    }
                    try put(data, inSortedMapAt: handle, key: keyBytes)
                } else if get.has("key"), set {
                    // asking for a new key's slot stores the key on its own; a
                    // write of the same bytes after it changes nothing
                    let keyBytes = try keyBytes(get.fields["key"])
                    if index < parts.endIndex {
                        guard let write = next() as? [String: Any], let data = write["write"] as? [String: Any],
                            try self.bytes(data["bytes"]) == keyBytes, index == parts.endIndex
                        else { throw NotExpressible.because("a sorted set entry that does not store its own key") }
                    }
                    try handle.sortedSet([UInt8].self).insert(keyBytes)
                } else {
                    throw NotExpressible.because("a sorted get of a key or pair")
                }
                kind = nil
            case "sorted_map_remove":
                guard case .sorted(let set)? = kind else {
                    throw NotExpressible.because("a sorted remove without its init")
                }
                if set {
                    _ = try handle.sortedSet([UInt8].self).remove(try keyBytes(payload))
                } else {
                    _ = try handle.sortedMap([UInt8].self, UInt64.self).remove(try keyBytes(payload))
                }
                kind = nil
            case "write":
                guard index == parts.endIndex else { throw NotExpressible.because("a write in the middle of a path") }
                if let kind { throw NotExpressible.because("a value written where a collection was made: \(kind)") }
                try set(payload, at: handle)
            case "ctx":
                guard index == parts.endIndex else {
                    throw NotExpressible.because("a callback in the middle of a path")
                }
                let context = try ScriptObject(payload, "ctx")
                if let kind { try make(kind, at: handle) }
                if let bound = try context.optionalString("as") { names[bound] = handle }
                for op in try context.array("ops") {
                    try run(try ScriptObject(op, "an op"), inContext: true)
                }
                return
            default:
                throw NotExpressible.because("the path part \(key)")
            }
        }
        if let kind { try make(kind, at: handle) }
        if let bindAs { names[bindAs] = handle }
    }

    private func isList(_ kind: Kind?) -> Bool {
        if case .list? = kind { return true }
        return false
    }

    /// Makes an empty collection of a kind at a place, as an init part at
    /// the end of a path does: the store's collections are made on their
    /// first write, so the proof reaches the faithful wrappers through the
    /// handle's own resolution, which the store module exposes for testing.
    private func make(_ kind: Kind, at handle: Handle) throws {
        let cursor = try handle.write()
        switch kind {
        case .map(false, false): _ = try HashMap<ReadWrite>(cursor)
        case .map(true, false): _ = try CountedHashMap<ReadWrite>(cursor)
        case .map(false, true): _ = try HashSet<ReadWrite>(cursor)
        case .map(true, true): _ = try CountedHashSet<ReadWrite>(cursor)
        case .list: _ = try ArrayList<ReadWrite>(cursor)
        case .linkedList: _ = try LinkedArrayList<ReadWrite>(cursor)
        case .sorted(false): _ = try XitDB.SortedMap<ReadWrite>(cursor)
        case .sorted(true): _ = try XitDB.SortedSet<ReadWrite>(cursor)
        }
    }

    // MARK: Values

    private func keyString(_ value: Any?) throws -> String {
        let object = try ScriptObject(value, "a hash")
        guard let text = object.fields["sha1"] as? String, object.fields.count == 1 else {
            throw NotExpressible.because("a hash that is not the SHA-1 of a string")
        }
        return text
    }

    private func keyBytes(_ value: Any?) throws -> [UInt8] {
        try bytes(value)
    }

    private func bytes(_ value: Any?) throws -> [UInt8] {
        if let string = value as? String { return Array(string.utf8) }
        let object = try ScriptObject(value, "bytes")
        guard let digits = object.fields["hex"] as? String, object.fields.count == 1 else {
            throw NotExpressible.because("bytes that are neither a string nor hex")
        }
        return hex(digits)
    }

    /// The value a `write` part carries, as the store's type for it.
    private enum Stored {
        case uint(UInt64)
        case int(Int64)
        case double(Double)
        case bytes([UInt8])
    }

    private func stored(_ value: Any?) throws -> Stored {
        let object = try ScriptObject(value, "write data")
        guard object.fields.count == 1 else { throw NotExpressible.because("write data with several fields") }
        if object.has("uint") { return .uint(try object.unsigned("uint")) }
        if object.has("int") { return .int(try object.signed("int")) }
        if object.has("float") {
            guard let number = object.fields["float"] as? Double else {
                throw NotExpressible.because("a float that is not a number")
            }
            return .double(number)
        }
        if object.has("bytes") { return .bytes(try bytes(object.fields["bytes"])) }
        throw NotExpressible.because("a slot or tagged bytes as a value")
    }

    private func set(_ value: Any?, at handle: Handle) throws {
        switch try stored(value) {
        case .uint(let number): try handle.set(number)
        case .int(let number): try handle.set(number)
        case .double(let number): try handle.set(number)
        case .bytes(let array): try handle.set(array)
        }
    }

    private func put(_ value: Any?, inCountedMapAt handle: Handle, key: String) throws {
        switch try stored(value) {
        case .uint(let number): try handle.countedMap(String.self, UInt64.self).put(number, forKey: key)
        case .int(let number): try handle.countedMap(String.self, Int64.self).put(number, forKey: key)
        case .double(let number): try handle.countedMap(String.self, Double.self).put(number, forKey: key)
        case .bytes(let array): try handle.countedMap(String.self, [UInt8].self).put(array, forKey: key)
        }
    }

    private func put(_ value: Any?, inSortedMapAt handle: Handle, key: [UInt8]) throws {
        switch try stored(value) {
        case .uint(let number): try handle.sortedMap([UInt8].self, UInt64.self).put(number, forKey: key)
        case .int(let number): try handle.sortedMap([UInt8].self, Int64.self).put(number, forKey: key)
        case .double(let number): try handle.sortedMap([UInt8].self, Double.self).put(number, forKey: key)
        case .bytes(let array): try handle.sortedMap([UInt8].self, [UInt8].self).put(array, forKey: key)
        }
    }

    private func insert(_ value: Any?, intoLinkedListAt handle: Handle, at index: Int) throws {
        switch try stored(value) {
        case .uint(let number): try handle.linkedList(UInt64.self).insert(number, at: index)
        case .int(let number): try handle.linkedList(Int64.self).insert(number, at: index)
        case .double(let number): try handle.linkedList(Double.self).insert(number, at: index)
        case .bytes(let array): try handle.linkedList([UInt8].self).insert(array, at: index)
        }
    }
}

extension StoreScript.NotExpressible {
    static func because(_ reason: String) -> Self { Self(reason: reason) }
}

extension ScriptObject {
    /// A signed integer payload as an `Int`.
    static func signedInt(_ value: Any?) throws -> Int {
        guard let number = value as? Int else {
            throw StoreScript.NotExpressible.because("an index that is not an integer")
        }
        return number
    }
}
