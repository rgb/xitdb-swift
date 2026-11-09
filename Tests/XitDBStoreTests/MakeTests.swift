import Testing
import XitDB
import XitDBHashing
import XitDBStore

/// `Handle.make(_:)`: every kind made empty, an existing collection kept,
/// another kind refused, the root a map only, and the bytes the format's
/// own init writes.
@Suite("making empty collections")
struct MakeTests {
    private func sha(_ key: String) -> [UInt8] { Array(SHA256.hash(data: Array(key.utf8))) }

    private func seeded(_ storage: MemoryStorage) throws -> Database {
        try Database(storage: storage, hashSize: 32, fileID: 7, random: SeededGenerator(seed: 5))
    }

    @Test func everyKindIsMadeEmptyAndUsable() throws {
        let store = try Store(try Database(creating: MemoryStorage(), hashSize: 32), hashing: SHA256.self)
        try store.transaction { moment in
            try moment["map"].make(.map)
            try moment["countedMap"].make(.countedMap)
            try moment["keySet"].make(.keySet)
            try moment["countedKeySet"].make(.countedKeySet)
            try moment["list"].make(.list)
            try moment["linkedList"].make(.linkedList)
            try moment["sortedMap"].make(.sortedMap)
            try moment["sortedSet"].make(.sortedSet)
            for name in [
                "map", "countedMap", "keySet", "countedKeySet", "list", "linkedList", "sortedMap", "sortedSet",
            ] {
                #expect(try moment[name].exists, Comment(rawValue: name))
            }
            #expect(try moment["map"].map(String.self, UInt64.self)["x"] == nil)
            #expect(try moment["countedMap"].countedMap(String.self, UInt64.self).count == 0)
            #expect(try !moment["keySet"].keySet(String.self).contains("x"))
            #expect(try moment["countedKeySet"].countedKeySet(String.self).count == 0)
            #expect(try moment["list"].list(UInt64.self).count == 0)
            #expect(try moment["linkedList"].linkedList(UInt64.self).count == 0)
            #expect(try moment["sortedMap"].sortedMap(String.self, UInt64.self).count == 0)
            #expect(try moment["sortedSet"].sortedSet(String.self).count == 0)
            // and they take entries afterwards
            try moment["map"].map(String.self, UInt64.self).put(1, forKey: "x")
            try moment["countedMap"].countedMap(String.self, UInt64.self).put(1, forKey: "x")
            try moment["keySet"].keySet(String.self).insert("x")
            try moment["countedKeySet"].countedKeySet(String.self).insert("x")
            try moment["list"].list(UInt64.self).append(1)
            try moment["linkedList"].linkedList(UInt64.self).append(1)
            try moment["sortedMap"].sortedMap(String.self, UInt64.self).put(1, forKey: "x")
            try moment["sortedSet"].sortedSet(String.self).insert("x")
        }
        let latest = try store.latest
        #expect(try latest["map"].map(String.self, UInt64.self)["x"] == 1)
        #expect(try latest["countedMap"].countedMap(String.self, UInt64.self).count == 1)
        #expect(try latest["keySet"].keySet(String.self).contains("x"))
        #expect(try latest["countedKeySet"].countedKeySet(String.self).count == 1)
        #expect(try latest["list"].list(UInt64.self).count == 1)
        #expect(try latest["linkedList"].linkedList(UInt64.self).count == 1)
        #expect(try latest["sortedMap"].sortedMap(String.self, UInt64.self).count == 1)
        #expect(try latest["sortedSet"].sortedSet(String.self).count == 1)
    }

    @Test func anExistingCollectionIsKeptAndAnotherKindRefused() throws {
        let store = try Store(try Database(creating: MemoryStorage(), hashSize: 32), hashing: SHA256.self)
        try store.transaction { moment in
            let list = moment["list"].list(UInt64.self)
            try list.append(1)
            try list.append(2)
            try moment["list"].make(.list)
            #expect(try list.count == 2)
            try moment["map"].map(String.self, UInt64.self).put(1, forKey: "x")
            try moment["map"].make(.map)
            #expect(try moment["map"].map(String.self, UInt64.self)["x"] == 1)
            #expect(throws: XitDBError.unexpectedTag) { try moment["list"].make(.map) }
            #expect(throws: XitDBError.unexpectedTag) { try moment["map"].make(.list) }
            #expect(throws: XitDBError.unexpectedTag) { try moment["map"].make(.countedMap) }
            #expect(throws: XitDBError.unexpectedTag) { try moment["list"].make(.linkedList) }
            try moment["n"].set(UInt64(1))
            #expect(throws: XitDBError.unexpectedTag) { try moment["n"].make(.map) }
            #expect(try list.count == 2)
            #expect(try moment["n"].value(UInt64.self) == 1)
        }
        #expect(throws: XitDBError.expectedTxStart) { try store.latest["new"].make(.list) }
    }

    @Test func theRootIsAMapOnly() throws {
        let store = try Store(try Database(creating: MemoryStorage(), hashSize: 32), hashing: SHA256.self)
        try store.transaction { moment in
            #expect(throws: XitDBError.unexpectedTag) { try moment.root.make(.list) }
            #expect(throws: XitDBError.unexpectedTag) { try moment.root.make(.countedMap) }
            #expect(try !moment.root.exists)
            try moment.root.make(.map)
            #expect(try moment.root.exists)
        }
        #expect(try store.latest.root.exists)
        #expect(try store.latest["x"].value(UInt64.self) == nil)
    }

    @Test func theBytesAreTheFormatsInit() throws {
        let throughStore = MemoryStorage()
        let store = try Store(try seeded(throughStore), hashing: SHA256.self)
        try store.transaction { moment in
            try moment["a"].make(.linkedList)
            try moment["b"].make(.sortedMap)
            try moment["c"].make(.countedKeySet)
            try moment["d"]["e"].make(.list)
            try moment["a"].make(.linkedList)
            try moment["a"].linkedList(UInt64.self).append(1)
        }

        let throughCalls = MemoryStorage()
        let database = try seeded(throughCalls)
        let history = try ArrayList<ReadOnly>(database.rootCursor)
        let previous = try history.count > 0 ? try history.slot(at: -1) : nil
        let path: [PathPart] = [.arrayListInit, .arrayListAppend, .write(.slot(previous)), .ctx]
        _ = try database.rootCursor.writePath(path.span) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            _ = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha("a")))
            _ = try XitDB.SortedMap<ReadWrite>(try moment.putCursor(forHash: sha("b")))
            _ = try CountedHashSet<ReadWrite>(try moment.putCursor(forHash: sha("c")))
            _ = try ArrayList<ReadWrite>(
                try HashMap<ReadWrite>(try moment.putCursor(forHash: sha("d"))).putCursor(forHash: sha("e")))
            _ = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha("a")))
            try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha("a"))).append(.uint(1))
        }
        #expect(
            throughStore.bytes == throughCalls.bytes,
            "lengths \(throughStore.bytes.count) and \(throughCalls.bytes.count)")
    }
}
