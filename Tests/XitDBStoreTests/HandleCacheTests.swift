import Testing
import XitDB
import XitDBHashing
import XitDBStore

/// Tries to break the writable moment: splits of the moment map's top node,
/// a join and a freeze inside the transaction, with handles made before
/// each written through after, and a handle carried across a transaction
/// boundary; every sequence is held byte for byte to the same writes
/// through the faithful calls in their canonical shape, the body's cursor
/// made into the moment's map and made again after a freeze.
@Suite("the writable moment")
struct HandleCacheTests {
    private func sha(_ key: String) -> [UInt8] { Array(SHA256.hash(data: Array(key.utf8))) }

    private func seeded(_ storage: MemoryStorage) throws -> Database {
        try Database(storage: storage, hashSize: 32, fileID: 7, random: SeededGenerator(seed: 5))
    }

    /// The canonical transaction, as the original's `appendContext` and the
    /// fixtures shape it: one path from the root that appends a clone of the
    /// last moment and runs the body with the cursor at it.
    private func canonical(_ database: Database, _ body: (inout Cursor<ReadWrite>) throws -> Void) throws {
        let history = try ArrayList<ReadOnly>(database.rootCursor)
        let previous = try history.count > 0 ? try history.slot(at: -1) : nil
        let path: [PathPart] = [.arrayListInit, .arrayListAppend, .write(.slot(previous)), .ctx]
        _ = try database.rootCursor.writePath(path.span, body)
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
        #expect(try store.latest["list"].linkedList(UInt64.self).count == 3)

        let throughCalls = MemoryStorage()
        let database = try seeded(throughCalls)
        try canonical(database) { cursor in
            var moment = try HashMap<ReadWrite>(cursor)
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
            // after the join's freeze, the map is made again from the body's cursor
            moment = try HashMap<ReadWrite>(cursor)
            try moment.put(.uint(1001), forHash: sha("k0"))
            try moment.put(.uint(7), forHash: sha("k7"))
            try database.freeze()
            moment = try HashMap<ReadWrite>(cursor)
            try moment.put(.uint(1002), forHash: sha("k0"))
            try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha("list"))).append(.uint(3))
        }
        #expect(
            throughStore.bytes == throughCalls.bytes,
            "lengths \(throughStore.bytes.count) and \(throughCalls.bytes.count)")
    }

    /// The review's case: a join, then writes through handles from before
    /// it, in a second moment, where the clone of the first gives the
    /// freeze something from before the transaction to copy.
    @Test func aJoinThenWritesInALaterMoment() throws {
        let throughStore = MemoryStorage()
        let store = try Store(try seeded(throughStore), hashing: SHA256.self)
        try store.transaction { moment in
            try moment["a"].set(UInt64(1))
            try moment["list"].linkedList(UInt64.self).append(1)
            try moment["other"].linkedList(UInt64.self).append(2)
            try moment["nested"]["deep"].set("x")
        }
        try store.transaction { moment in
            let a = moment["a"]
            let deep = moment["nested"]["deep"]
            let list = moment["list"].linkedList(UInt64.self)
            try list.join(moment["other"].linkedList(UInt64.self))
            try a.set(UInt64(2))
            try deep.set("y")
            try list.append(3)
            try moment["b"].set(UInt64(3))
            #expect(try list.count == 3)
            #expect(try a.value(UInt64.self) == 2)
        }
        #expect(try store.latest["list"].linkedList(UInt64.self).count == 3)
        #expect(try store.latest["nested"]["deep"].value(String.self) == "y")
        #expect(try store.moment(at: 0)["a"].value(UInt64.self) == 1)

        let throughCalls = MemoryStorage()
        let database = try seeded(throughCalls)
        try canonical(database) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            try moment.put(.uint(1), forHash: sha("a"))
            try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha("list"))).append(.uint(1))
            try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha("other"))).append(.uint(2))
            try HashMap<ReadWrite>(try moment.putCursor(forHash: sha("nested"))).put(
                .bytes(Array("x".utf8)), forHash: sha("deep"))
        }
        try canonical(database) { cursor in
            var moment = try HashMap<ReadWrite>(cursor)
            let other = try LinkedArrayList<ReadOnly>(try #require(try moment.readOnly.cursor(forHash: sha("other"))))
            try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha("list"))).append(contentsOf: other)
            moment = try HashMap<ReadWrite>(cursor)
            try moment.put(.uint(2), forHash: sha("a"))
            try HashMap<ReadWrite>(try moment.putCursor(forHash: sha("nested"))).put(
                .bytes(Array("y".utf8)), forHash: sha("deep"))
            try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha("list"))).append(.uint(3))
            try moment.put(.uint(3), forHash: sha("b"))
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
            // inside the transaction, the committed moments are the ones before it
            #expect(try store.momentCount == 1)
            #expect(try store.latest["a"].value(UInt64.self) == 1)
        }
        #expect(try previousHandle.value(UInt64.self) == 1)
        #expect(try store.latest["a"].value(UInt64.self) == 2)
        #expect(try store.momentCount == 2)
        // a handle kept past its transaction reads the moment as committed
        #expect(try kept?.value(UInt64.self) == 1)
        #expect(throws: XitDBError.expectedTxStart) { try kept?.set(UInt64(9)) }

        let throughCalls = MemoryStorage()
        let database = try seeded(throughCalls)
        try canonical(database) { cursor in
            try HashMap<ReadWrite>(cursor).put(.uint(1), forHash: sha("a"))
        }
        try canonical(database) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
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

    /// An empty body commits a plain clone, and a cleared root an empty
    /// moment, both as the canonical calls leave them.
    @Test func anEmptyBodyAndAClearedRoot() throws {
        let throughStore = MemoryStorage()
        let store = try Store(try seeded(throughStore), hashing: SHA256.self)
        try store.transaction { _ in }
        #expect(try store.momentCount == 1)
        #expect(try !store.latest.root.exists)
        #expect(try store.latest.root.map(String.self, UInt64.self)["a"] == nil)
        try store.transaction { moment in
            try moment["a"].set(UInt64(1))
        }
        try store.transaction { _ in }
        #expect(try store.latest["a"].value(UInt64.self) == 1)
        try store.transaction { moment in
            #expect(throws: XitDBError.unexpectedTag) { try moment.root.set(UInt64(5)) }
            try moment.root.clear()
            #expect(try !moment["a"].exists)
            try moment["b"].set(UInt64(2))
            #expect(try !moment["a"].exists)
            #expect(try moment["b"].value(UInt64.self) == 2)
        }
        #expect(try !store.latest["a"].exists)
        #expect(try store.latest["b"].value(UInt64.self) == 2)

        let throughCalls = MemoryStorage()
        let database = try seeded(throughCalls)
        try canonical(database) { _ in }
        try canonical(database) { cursor in try HashMap<ReadWrite>(cursor).put(.uint(1), forHash: sha("a")) }
        try canonical(database) { _ in }
        try canonical(database) { cursor in
            try cursor.write(.slot(nil))
            try HashMap<ReadWrite>(cursor).put(.uint(2), forHash: sha("b"))
        }
        #expect(
            throughStore.bytes == throughCalls.bytes,
            "lengths \(throughStore.bytes.count) and \(throughCalls.bytes.count)")
    }
}
