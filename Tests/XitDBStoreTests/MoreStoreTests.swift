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
