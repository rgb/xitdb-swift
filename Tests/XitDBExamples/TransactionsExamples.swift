import Testing
import XitDB
import XitDBHashing

@Suite("Transactions") struct TransactionsExamples {
    @Test func aTransactionGroupsWrites() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)

        let total = try database.withTransaction { cursor in
            let map = try HashMap<ReadWrite>(cursor)
            try map.put(UInt64(3), forKey: "apples")
            try map.put(UInt64(4), forKey: "pears")
            return 3 + 4
        }
        #expect(total == 7)

        let map = try HashMap<ReadOnly>(database.rootCursor)
        #expect(try map.value(forKey: "pears", as: UInt64.self) == 4)
    }

    @Test func aWriteThroughTheRootCommitsAlone() throws {
        let separately = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let grouped = try Database(creating: MemoryStorage(), hashing: SHA256.self)

        // Three commits: making the map is one, and each write is another.
        let map = try HashMap<ReadWrite>(separately.rootCursor)
        try map.put(UInt64(3), forKey: "apples")
        try map.put(UInt64(4), forKey: "pears")

        // One commit.
        try grouped.withTransaction { cursor in
            let map = try HashMap<ReadWrite>(cursor)
            try map.put(UInt64(3), forKey: "apples")
            try map.put(UInt64(4), forKey: "pears")
        }

        // The numbers the article quotes.
        #expect(try separately.committedSize == 691)
        #expect(try grouped.committedSize == 335)
    }

    @Test func aThrowingBodyLeavesTheDatabaseAsItWas() throws {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashing: SHA256.self)
        try HashMap<ReadWrite>(database.rootCursor).put(UInt64(10), forKey: "stock")
        let before = try database.committedSize

        struct OutOfStock: Error {}

        #expect(throws: OutOfStock.self) {
            try database.withTransaction { cursor in
                let map = try HashMap<ReadWrite>(cursor)
                try map.put(UInt64(0), forKey: "stock")
                throw OutOfStock()
            }
        }

        // The error is the body's own. The value is what it was, and nothing
        // of the transaction is left in the file.
        let map = try HashMap<ReadOnly>(database.rootCursor)
        #expect(try map.value(forKey: "stock", as: UInt64.self) == 10)
        #expect(try database.committedSize == before)
        #expect(try storage.length == before)
    }

    @Test func theBodysCursorIsAtTheRootOfTheTransaction() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)

        try database.withTransaction { cursor in
            try cursor.write(.uint(42))
            #expect(try cursor.readUInt64() == 42)
        }

        #expect(try database.rootCursor.readUInt64() == 42)
    }

    @Test func theBodysCursorIsASnapshotLikeAnyOther() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)

        try database.withTransaction { cursor in
            // The map writes through the same position, but through its own
            // copy of the cursor, so this one does not notice.
            let map = try HashMap<ReadWrite>(cursor)
            try map.put(UInt64(1), forKey: "a")
            #expect(try cursor.slot.tag == .none)
            #expect(try map.value(forKey: "a", as: UInt64.self) == 1)
        }

        // What the slot holds when the body returns is the root, whichever
        // cursor wrote it.
        let other = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try other.withTransaction { cursor in
            var copy = cursor
            try copy.write(.uint(42))
            #expect(try cursor.slot.tag == .none)
        }
        #expect(try other.rootCursor.readUInt64() == 42)
    }

    /// The numbers the article's list of what a transaction appends rests on:
    /// a collection at the root is readied before the body runs, each kind as
    /// its init does. All with the 34 bytes of the root slot and the trailer.
    @Test func aTransactionReadiesARootCollection() throws {
        func costOfAnEmptyTransaction(makeRoot: (Database) throws -> Void) throws -> UInt64 {
            let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
            try makeRoot(database)
            let before = try database.committedSize
            try database.withTransaction { _ in }
            return try database.committedSize - before
        }

        #expect(try costOfAnEmptyTransaction { _ = try ArrayList<ReadWrite>($0.rootCursor) } == 194)
        #expect(try costOfAnEmptyTransaction { _ = try HashMap<ReadWrite>($0.rootCursor) } == 178)
        #expect(try costOfAnEmptyTransaction { _ = try HashSet<ReadWrite>($0.rootCursor) } == 178)
        #expect(try costOfAnEmptyTransaction { _ = try CountedHashMap<ReadWrite>($0.rootCursor) } == 186)
        #expect(try costOfAnEmptyTransaction { _ = try LinkedArrayList<ReadWrite>($0.rootCursor) } == 50)
        #expect(try costOfAnEmptyTransaction { _ = try SortedMap<ReadWrite>($0.rootCursor) } == 50)
        #expect(try costOfAnEmptyTransaction { _ in } == 34)
    }

    @Test func readsThroughTheRootSeeTheLastCommit() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let history = try ArrayList<ReadWrite>(database.rootCursor)

        try history.append(.slot(try history.slot(at: -1))) { cursor in
            // The list at the root has no new element yet: the root is read
            // from the last commit until this one is made.
            let committed = try history.count  // 0
            #expect(committed == 0)

            // A collection made from the body's cursor sees what the transaction
            // has written.
            let moment = try HashMap<ReadWrite>(cursor)
            try moment.put(UInt64(1), forKey: "seen")
            let seen = try moment.value(forKey: "seen", as: UInt64.self)  // 1
            #expect(seen == 1)
        }
        #expect(try history.count == 1)
    }

    @Test func writesNeedATransactionOfTheRightKind() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        var kept: Cursor<ReadWrite>?

        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            kept = try moment.putCursor(forKey: "kept")

            // The transaction has not ended, and the root belongs to it.
            #expect(throws: XitDBError.nestedTopLevelWrite) {
                try history.append(.uint(1))
            }
            #expect(throws: XitDBError.nestedTopLevelWrite) {
                try database.withTransaction { _ in }
            }
        }

        // The transaction has ended, and the cursor was below the root.
        #expect(throws: XitDBError.expectedTxStart) {
            try kept!.write(.uint(1))
        }
        // During a later one, the cursor is stale.
        try database.withTransaction { _ in
            #expect(throws: XitDBError.staleCursor) {
                try kept!.write(.uint(1))
            }
        }
        // A read through it reads the commit it came from.
        #expect(try kept!.slot.isEmpty)
    }

    @Test func aFailurePartwayPoisonsTheTransaction() throws {
        // Any other error, or none, and the checks after this fail.
        let small = try Database(creating: MemoryStorage(maxSize: 2_000), hashing: SHA256.self)
        do {
            try small.withTransaction { cursor in
                let map = try HashMap<ReadWrite>(cursor)
                try map.put(UInt64(1), forKey: "small")
                do {
                    // Too large for the storage, and only found out
                    // after the entry was written.
                    let large = [UInt8](repeating: 7, count: 3_000)
                    try map.put(large, forKey: "large")
                } catch XitDBError.maxSizeExceeded {
                    // Caught, but the transaction is poisoned:
                    // the next write, and the commit, fail.
                    #expect(throws: XitDBError.poisonedTransaction) { try map.put(UInt64(2), forKey: "x") }
                    #expect(try map.value(forKey: "small", as: UInt64.self) == 1)
                }
            }
        } catch XitDBError.poisonedTransaction {
            // Nothing of the transaction stays, the small value included.
        }
        #expect(try small.committedSize == 57)
        #expect(try small.rootCursor.slot.isEmpty)
    }

    @Test func aFailureBeforeWritingLeavesTheTransactionAsItWas() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { cursor in
            let map = try HashMap<ReadWrite>(cursor)
            let list = try ArrayList<ReadWrite>(map.putCursor(forKey: "list"))
            #expect(throws: XitDBError.indexOutOfRange) { try list.put(.uint(1), at: 5) }
            #expect(throws: XitDBError.unexpectedTag) { try ArrayList<ReadWrite>(cursor) }
            var iterator = try map.iterator()
            let entry = try iterator.next()!
            var copy = try map.putCursor(forKey: "copy")
            #expect(throws: XitDBError.structuralSlot) { try copy.write(.slot(try entry.slot)) }
            #expect(throws: XitDBError.structuralSlot) { try map.put(.slot(try entry.slot), forKey: "new") }
            #expect(throws: XitDBError.structuralSlot) { try list.append(.slot(try entry.slot)) }
            try list.append(.uint(1))
        }
        let map = try HashMap<ReadOnly>(database.rootCursor)
        #expect(try ArrayList<ReadOnly>(map.cursor(forKey: "list")!).count == 1)
    }

    @Test func anAppendWhoseBodyThrowsPoisons() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        struct Stop: Error {}
        #expect(throws: XitDBError.poisonedTransaction) {
            try database.withTransaction { cursor in
                let list = try ArrayList<ReadWrite>(HashMap<ReadWrite>(cursor).putCursor(forKey: "list"))
                #expect(throws: Stop.self) { try list.append(.uint(1)) { _ in throw Stop() } }
            }
        }
        #expect(try database.rootCursor.slot.isEmpty)
    }

    @Test func severalMomentsCanShareOneCommit() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try ArrayList<ReadWrite>(database.rootCursor).append(.slot(nil))
        let before = try database.replicaState

        try database.withTransaction { cursor in
            let history = try ArrayList<ReadWrite>(cursor)
            try history.append(.uint(1))
            try history.append(.uint(2))
        }

        let history = try ArrayList<ReadOnly>(database.rootCursor)
        #expect(try history.count == 3)
        #expect(try database.replicaState != before)
    }

    @Test func anUnfinishedTransactionIsIgnoredAndThenDiscarded() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }
        let path = scratch.path("main.db")

        var storage = try FileStorage(path: path, access: .create, durability: .none)
        var database = try Database(creating: storage, hashing: SHA256.self)
        try HashMap<ReadWrite>(database.rootCursor).put(UInt64(1), forKey: "kept")
        let committed = try database.committedSize

        // What a process that died in the middle of a transaction leaves.
        try storage.write([1, 2, 3, 4].span, at: committed)
        #expect(try storage.length == committed + 4)

        storage = try FileStorage(path: path, access: .readWrite, durability: .none)
        database = try Database(opening: storage, hashing: SHA256.self)
        #expect(try database.committedSize == committed)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        #expect(try map.value(forKey: "kept", as: UInt64.self) == 1)
        // Making the collection has already started on it.
        #expect(try storage.length == committed)
    }

    @Test func everyDurabilityLevelOpensAndCommits() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }

        let levels: [Durability] = [.none, .ordered, .full]
        for (number, level) in levels.enumerated() {
            let storage = try BufferedFileStorage(
                path: scratch.path("level-\(number).db"), access: .create, durability: level)
            let database = try Database(creating: storage, hashing: SHA256.self)
            try HashMap<ReadWrite>(database.rootCursor).put(UInt64(1), forKey: "a")
            #expect(try database.committedSize > 57)
        }

        let storage = try BufferedFileStorage(
            path: scratch.path("cache.db"), access: .create, durability: .none)
        _ = try Database(creating: storage, hashing: SHA256.self)
    }
}
