import Testing
import XitDB
import XitDBHashing
import XitDBStore

/// Tries to break the cache of a writable moment's two top-level cursors:
/// splits of the moment map's top node, a join and a freeze inside the
/// transaction, with handles made before each written through after, and a
/// handle carried across a transaction boundary; every sequence is held
/// byte for byte to the same writes through the faithful calls.
@Suite("the writable moment's cache")
struct HandleCacheTests {
    private func sha(_ key: String) -> [UInt8] { Array(SHA256.hash(data: Array(key.utf8))) }

    private func seeded(_ storage: MemoryStorage) throws -> Database {
        try Database(storage: storage, hashSize: 32, fileID: 7, random: SeededGenerator(seed: 5))
    }

    /// The faithful twin of the store's moment: the element at `index` as a
    /// map, resolved from the transaction's cursor as the store does.
    private func faithfulMoment(_ root: Cursor<ReadWrite>, _ index: Int) throws -> HashMap<ReadWrite> {
        try HashMap<ReadWrite>(try ArrayList<ReadWrite>(root).putCursor(at: index))
    }

    @Test func splitsJoinAndFreezeWithinOneTransaction() throws {
        let throughStore = MemoryStorage()
        let store = try Store(try seeded(throughStore), hashing: SHA256.self)
        try store.transaction { moment in
            let early = moment["k0"]
            let earlyList = moment["list"].linkedList(UInt64.self)
            try early.set(UInt64(0))
            // puts that split the top node several times over
            let map = moment.root.map(String.self, UInt64.self)
            for index in 1..<300 {
                try map.put(UInt64(index), forKey: "k\(index)")
            }
            #expect(try early.value(UInt64.self) == 0)
            try early.set(UInt64(1000))
            #expect(try map["k0"] == 1000)
            // a join on a list in the moment freezes the transaction
            try earlyList.append(1)
            let other = moment["other"].linkedList(UInt64.self)
            try other.append(2)
            try earlyList.join(other)
            #expect(try earlyList.count == 2)
            // a handle from before the join writes after it
            try early.set(UInt64(1001))
            try map.put(7, forKey: "k7")
            // a freeze from the database itself
            try store.database.freeze()
            try early.set(UInt64(1002))
            try earlyList.append(3)
            #expect(try earlyList.count == 3)
            #expect(try map["k7"] == 7)
            #expect(try map["k299"] == 299)
        }
        #expect(try store.latest["k0"].value(UInt64.self) == 1002)

        let throughCalls = MemoryStorage()
        let database = try seeded(throughCalls)
        try database.withTransaction { root in
            let history = try ArrayList<ReadWrite>(root)
            try history.append(.slot(nil)) { _ in }
            var moment = try faithfulMoment(root, 0)
            try moment.put(.uint(0), forHash: sha("k0"))
            for index in 1..<300 {
                try moment.put(.uint(UInt64(index)), forHash: sha("k\(index)"))
            }
            try moment.put(.uint(1000), forHash: sha("k0"))
            let list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha("list")))
            try list.append(.uint(1))
            let other = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha("other")))
            try other.append(.uint(2))
            try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha("list"))).append(
                contentsOf: other.readOnly)
            moment = try faithfulMoment(root, 0)
            try moment.put(.uint(1001), forHash: sha("k0"))
            try moment.put(.uint(7), forHash: sha("k7"))
            try database.freeze()
            moment = try faithfulMoment(root, 0)
            try moment.put(.uint(1002), forHash: sha("k0"))
            try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha("list"))).append(.uint(3))
        }
        #expect(
            throughStore.bytes == throughCalls.bytes,
            "lengths \(throughStore.bytes.count) and \(throughCalls.bytes.count)")
    }

    @Test func aHandleAcrossATransactionBoundary() throws {
        let throughStore = MemoryStorage()
        let store = try Store(try seeded(throughStore), hashing: SHA256.self)
        var kept: Handle?
        var keptMap: Map<String, UInt64>?
        try store.transaction { moment in
            try moment["a"].set(UInt64(1))
            kept = moment["a"]
            keptMap = moment.root.map(String.self, UInt64.self)
        }
        let previous = try store.latest
        let previousHandle = previous["a"]
        #expect(try previousHandle.value(UInt64.self) == 1)
        try store.transaction { moment in
            // the kept handles belong to the committed transaction and refuse
            let handle = try #require(kept)
            #expect(throws: XitDBError.staleCursor) { try handle.set(UInt64(9)) }
            #expect(throws: XitDBError.staleCursor) { try keptMap?.put(9, forKey: "a") }
            // the previous moment's read-only handle still reads its moment
            try moment["a"].set(UInt64(2))
            #expect(try previousHandle.value(UInt64.self) == 1)
            #expect(try moment["a"].value(UInt64.self) == 2)
            for index in 0..<100 {
                try moment["m"].map(String.self, UInt64.self).put(UInt64(index), forKey: "k\(index)")
            }
            #expect(try previousHandle.value(UInt64.self) == 1)
        }
        #expect(try previousHandle.value(UInt64.self) == 1)
        #expect(try store.latest["a"].value(UInt64.self) == 2)

        let throughCalls = MemoryStorage()
        let database = try seeded(throughCalls)
        try database.withTransaction { root in
            try ArrayList<ReadWrite>(root).append(.slot(nil)) { _ in }
            try faithfulMoment(root, 0).put(.uint(1), forHash: sha("a"))
        }
        try database.withTransaction { root in
            let history = try ArrayList<ReadWrite>(root)
            try history.append(.slot(try history.slot(at: -1))) { _ in }
            let moment = try faithfulMoment(root, 1)
            try moment.put(.uint(2), forHash: sha("a"))
            for index in 0..<100 {
                try HashMap<ReadWrite>(try moment.putCursor(forHash: sha("m"))).put(
                    .uint(UInt64(index)), forHash: sha("k\(index)"))
            }
        }
        #expect(
            throughStore.bytes == throughCalls.bytes,
            "lengths \(throughStore.bytes.count) and \(throughCalls.bytes.count)")
    }
}
