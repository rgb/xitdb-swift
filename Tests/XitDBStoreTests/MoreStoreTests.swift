import Testing
import XitDB
import XitDBHashing
import XitDBStore

/// The pieces the other suites do not reach: the root handle, nested
/// handles by index, another hash, optionals through handles, and a
/// substring key.
@Suite("more of the store")
struct MoreStoreTests {
    @Test func theRootHandleIsTheMomentsMap() throws {
        let store = try Store(try Database(creating: MemoryStorage(), hashSize: 32), hashing: SHA256.self)
        try store.transaction { moment in
            let top = moment.root.map(String.self, UInt64.self)
            try top.put(1, forKey: "a")
            #expect(try moment["a"].value(UInt64.self) == 1)
            #expect(try top["a"] == 1)
            #expect(try moment.root.exists)
        }
    }

    @Test func nestedCollectionsByIndex() throws {
        let store = try Store(try Database(creating: MemoryStorage(), hashSize: 32), hashing: SHA256.self)
        try store.transaction { moment in
            let rows = moment["rows"].list(UInt64.self)
            try rows.append(0)
            let cells = try rows.append().list(String.self)
            try cells.append("x")
            try cells.append("y")
            #expect(try rows.count == 2)
            #expect(try rows[handleAt: 1].list(String.self).count == 2)
            #expect(try moment["rows"][index: 1][index: 0].value(String.self) == "x")
            #expect(try rows[0] == 0)
            #expect(throws: XitDBError.unexpectedTag) { try rows[1] }
            let linked = moment["linked"].linkedList(UInt64.self)
            try linked.append().map(String.self, UInt64.self).put(1, forKey: "a")
            #expect(try linked.count == 1)
            #expect(try linked[handleAt: 0].map(String.self, UInt64.self)["a"] == 1)
        }
    }

    @Test func anotherHash() throws {
        let store = try Store(try Database(creating: MemoryStorage(), hashSize: 16), hashing: SipHash128.self)
        try store.transaction { moment in
            try moment["n"].set(UInt64(5))
            try moment["m"].map(Int.self, String.self).put("five", forKey: 5)
        }
        let latest = try store.latest
        #expect(try latest["n"].value(UInt64.self) == 5)
        #expect(try latest["m"].map(Int.self, String.self)[5] == "five")
        let direct = try HashMap<ReadOnly>(try ArrayList<ReadOnly>(store.database.rootCursor).cursor(at: 0)!)
        #expect(
            try direct.cursor(forHash: SipHash128.hash(Array("n".utf8)))?.readUInt64() == 5,
            "the key is stored under the store's hash")
    }

    @Test func optionalsAndSubstringsThroughHandles() throws {
        let store = try Store(try Database(creating: MemoryStorage(), hashSize: 32), hashing: SHA256.self)
        try store.transaction { moment in
            let maybe = moment["maybe"].map(String.self, UInt64?.self)
            try maybe.put(nil, forKey: "none")
            try maybe.put(3, forKey: "some")
            #expect(try maybe["none"] == .some(nil))
            #expect(try maybe["some"] == 3)
            #expect(try maybe["absent"] == nil)
            #expect(try maybe.contains("none"))
            let text = "key-value"
            try moment[text.prefix(3)].set("k")
            #expect(try moment["key"].value(String.self) == "k")
        }
    }

    @Test func aStoreOverAnOpenedDatabase() throws {
        let storage = MemoryStorage()
        do {
            let store = try Store(try Database(creating: storage, hashSize: 32), hashing: SHA256.self)
            try store.transaction { moment in try moment["v"].set(UInt64(1)) }
        }
        let reopened = try Store(try Database(opening: storage), hashing: SHA256.self)
        #expect(try reopened.momentCount == 1)
        #expect(try reopened.latest["v"].value(UInt64.self) == 1)
        #expect(throws: XitDBError.hashSizeMismatch) {
            try Store(try Database(opening: storage), hashing: SipHash128.self)
        }
    }
}

/// The review's findings on the collections: a counted map made through a
/// handle, negative arguments, and a join with nothing to add.
@Suite("the collections' edges")
struct CollectionEdgeTests {
    private func makeStore() throws -> Store {
        try Store(try Database(creating: MemoryStorage(), hashSize: 32), hashing: SHA256.self)
    }

    @Test func aCountedMapIsMadeThroughItsHandle() throws {
        let store = try makeStore()
        try store.transaction { moment in
            let counted = moment["counted"].countedMap(String.self, UInt64.self)
            try counted.put(1, forKey: "a")
            let nested = counted[handleFor: "inner"].countedMap(String.self, UInt64.self)
            try nested.put(2, forKey: "b")
            try nested.put(3, forKey: "c")
            #expect(try nested.count == 2)
            #expect(try counted.count == 2)
            // through the plain subscript the nested place is a plain map
            let plain = moment["plain"].map(String.self, UInt64.self)
            try plain[handleFor: "inner"].map(String.self, UInt64.self).put(1, forKey: "x")
            #expect(throws: XitDBError.unexpectedTag) {
                try moment["plain"]["inner"].countedMap(String.self, UInt64.self).count
            }
        }
        #expect(try store.latest["counted"]["inner"].countedMap(String.self, UInt64.self).count == 2)
    }

    @Test func negativeArgumentsAreRefused() throws {
        let store = try makeStore()
        try store.transaction { moment in
            let list = moment["list"].list(UInt64.self)
            try list.append(1)
            try list.append(2)
            #expect(throws: XitDBError.indexOutOfRange) { try list.truncate(to: -1) }
            let linked = moment["linked"].linkedList(UInt64.self)
            try linked.append(1)
            try linked.append(2)
            #expect(throws: XitDBError.indexOutOfRange) { try linked.slice(offset: -1, count: 1) }
            #expect(throws: XitDBError.indexOutOfRange) { try linked.slice(offset: 0, count: -1) }
            #expect(try list.count == 2)
            #expect(try linked.count == 2)
            try list.truncate(to: 0)
            try linked.slice(offset: 1, count: 1)
            #expect(try list.count == 0)
            #expect(try linked.count == 1)
            #expect(try linked[0] == 2)
        }
    }

    @Test func aJoinWithNothingToAddWritesNothing() throws {
        let storage = MemoryStorage()
        let store = try Store(
            try Database(storage: storage, hashSize: 32, fileID: 1, random: SeededGenerator(seed: 1)),
            hashing: SHA256.self)
        try store.transaction { moment in
            try moment["list"].linkedList(UInt64.self).append(1)
            try moment["empty"].linkedList(UInt64.self).append(1)
            try moment["empty"].linkedList(UInt64.self).slice(offset: 0, count: 0)
        }
        let before = storage.bytes
        try store.transaction { moment in
            let list = moment["list"].linkedList(UInt64.self)
            try list.join(moment["missing"].linkedList(UInt64.self))
            try list.join(moment["empty"].linkedList(UInt64.self))
            #expect(try list.count == 1)
            #expect(throws: XitDBError.unexpectedTag) {
                try list.join(moment["list"][index: 0].linkedList(UInt64.self))
            }
        }
        // the moment is a clone; the joins added nothing and froze nothing
        let afterClone = MemoryStorage()
        let twin = try Store(
            try Database(storage: afterClone, hashSize: 32, fileID: 1, random: SeededGenerator(seed: 1)),
            hashing: SHA256.self)
        try twin.transaction { moment in
            try moment["list"].linkedList(UInt64.self).append(1)
            try moment["empty"].linkedList(UInt64.self).append(1)
            try moment["empty"].linkedList(UInt64.self).slice(offset: 0, count: 0)
        }
        try twin.transaction { _ in }
        #expect(storage.bytes == afterClone.bytes)
        #expect(storage.bytes.count > before.count)
    }
}
