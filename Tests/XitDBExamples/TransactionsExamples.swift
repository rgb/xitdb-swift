import Testing
import XitDB

@Suite("Transactions") struct TransactionsExamples {
    @Test func aTransactionGroupsWrites() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)

        let total = try database.withTransaction { cursor in
            let map = try HashMap<ReadWrite>(cursor)
            try map.put(.uint(3), forHash: sha256("apples"))
            try map.put(.uint(4), forHash: sha256("pears"))
            return 3 + 4
        }
        #expect(total == 7)

        let map = try HashMap<ReadOnly>(database.rootCursor)
        #expect(try map.cursor(forHash: sha256("pears"))!.readUInt64() == 4)
    }

    @Test func aWriteThroughTheRootCommitsAlone() throws {
        let separately = try Database(creating: MemoryStorage(), hashSize: 32)
        let grouped = try Database(creating: MemoryStorage(), hashSize: 32)

        // Three commits: making the map is one, and each write is another.
        let map = try HashMap<ReadWrite>(separately.rootCursor)
        try map.put(.uint(3), forHash: sha256("apples"))
        try map.put(.uint(4), forHash: sha256("pears"))

        // One commit.
        try grouped.withTransaction { cursor in
            let map = try HashMap<ReadWrite>(cursor)
            try map.put(.uint(3), forHash: sha256("apples"))
            try map.put(.uint(4), forHash: sha256("pears"))
        }

        // The numbers the article quotes.
        #expect(try separately.committedSize == 696)
        #expect(try grouped.committedSize == 340)
    }

    @Test func aThrowingBodyLeavesTheDatabaseAsItWas() throws {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashSize: 32)
        try HashMap<ReadWrite>(database.rootCursor).put(.uint(10), forHash: sha256("stock"))
        let before = try database.committedSize

        struct OutOfStock: Error {}

        #expect(throws: OutOfStock.self) {
            try database.withTransaction { cursor in
                let map = try HashMap<ReadWrite>(cursor)
                try map.put(.uint(0), forHash: sha256("stock"))
                throw OutOfStock()
            }
        }

        // The error is the body's own. The value is what it was, and nothing
        // of the transaction is left in the file.
        let map = try HashMap<ReadOnly>(database.rootCursor)
        #expect(try map.cursor(forHash: sha256("stock"))!.readUInt64() == 10)
        #expect(try database.committedSize == before)
        #expect(try storage.length == before)
    }

    @Test func theBodysCursorIsAtTheRootOfTheTransaction() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)

        try database.withTransaction { cursor in
            try cursor.write(.uint(42))
            #expect(try cursor.readUInt64() == 42)
        }

        #expect(try database.rootCursor.readUInt64() == 42)
    }

    @Test func theBodysCursorIsASnapshotLikeAnyOther() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)

        try database.withTransaction { cursor in
            // The map writes through the same position, but through its own
            // copy of the cursor, so this one does not notice.
            let map = try HashMap<ReadWrite>(cursor)
            try map.put(.uint(1), forHash: sha256("a"))
            #expect(try cursor.slot.tag == .none)
            #expect(try map.cursor(forHash: sha256("a"))!.readUInt64() == 1)
        }

        // What the slot holds when the body returns is the root, whichever
        // cursor wrote it.
        let other = try Database(creating: MemoryStorage(), hashSize: 32)
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
            let database = try Database(creating: MemoryStorage(), hashSize: 32)
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
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let history = try ArrayList<ReadWrite>(database.rootCursor)

        try history.append(.slot(try history.slot(at: -1))) { cursor in
            // The list at the root has no new element yet: the root is read
            // from the last commit until this one is made.
            let committed = try history.count  // 0
            #expect(committed == 0)

            // A collection made from the body's cursor sees what the transaction
            // has written.
            let moment = try HashMap<ReadWrite>(cursor)
            try moment.put(.uint(1), forHash: sha256("seen"))
            let seen = try moment.cursor(forHash: sha256("seen"))!.readUInt64()  // 1
            #expect(seen == 1)
        }
        #expect(try history.count == 1)
    }

    @Test func writesNeedATransactionOfTheRightKind() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        var kept: Cursor<ReadWrite>?

        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            kept = try moment.putCursor(forHash: sha256("kept"))

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
        let small = try Database(creating: MemoryStorage(maxSize: 2_000), hashSize: 32)
        do {
            try small.withTransaction { cursor in
                let map = try HashMap<ReadWrite>(cursor)
                try map.put(.uint(1), forHash: sha256("small"))
                do {
                    // Too large for the storage, and only found out after the entry was written.
                    try map.put(.bytes([UInt8](repeating: 7, count: 3_000)), forHash: sha256("large"))
                } catch XitDBError.maxSizeExceeded {
                    // Caught, but the transaction is poisoned: the next write, and the commit, fail.
                    #expect(throws: XitDBError.poisonedTransaction) { try map.put(.uint(2), forHash: sha256("x")) }
                    #expect(try map.cursor(forHash: sha256("small"))!.readUInt64() == 1)
                }
            }
        } catch XitDBError.poisonedTransaction {
            // Nothing of the transaction stays, the small value included.
        }
        #expect(try small.committedSize == 62)
        #expect(try small.rootCursor.slot.isEmpty)
    }

    @Test func aFailureBeforeWritingLeavesTheTransactionAsItWas() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        try database.withTransaction { cursor in
            let map = try HashMap<ReadWrite>(cursor)
            let list = try ArrayList<ReadWrite>(map.putCursor(forHash: sha256("list")))
            #expect(throws: XitDBError.indexOutOfRange) { try list.put(.uint(1), at: 5) }
            #expect(throws: XitDBError.unexpectedTag) { try ArrayList<ReadWrite>(cursor) }
            var iterator = try map.iterator()
            let entry = try iterator.next()!
            var copy = try map.putCursor(forHash: sha256("copy"))
            #expect(throws: XitDBError.structuralSlot) { try copy.write(.slot(try entry.slot)) }
            #expect(throws: XitDBError.structuralSlot) { try map.put(.slot(try entry.slot), forHash: sha256("new")) }
            #expect(throws: XitDBError.structuralSlot) { try list.append(.slot(try entry.slot)) }
            try list.append(.uint(1))
        }
        let map = try HashMap<ReadOnly>(database.rootCursor)
        #expect(try ArrayList<ReadOnly>(map.cursor(forHash: sha256("list"))!).count == 1)
    }

    @Test func anAppendWhoseBodyThrowsPoisons() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        struct Stop: Error {}
        #expect(throws: XitDBError.poisonedTransaction) {
            try database.withTransaction { cursor in
                let list = try ArrayList<ReadWrite>(HashMap<ReadWrite>(cursor).putCursor(forHash: sha256("list")))
                #expect(throws: Stop.self) { try list.append(.uint(1)) { _ in throw Stop() } }
            }
        }
        #expect(try database.rootCursor.slot.isEmpty)
    }

    @Test func severalMomentsCanShareOneCommit() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
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
        var database = try Database(creating: storage, hashSize: 32)
        try HashMap<ReadWrite>(database.rootCursor).put(.uint(1), forHash: sha256("kept"))
        let committed = try database.committedSize

        // What a process that died in the middle of a transaction leaves.
        try storage.write([1, 2, 3, 4].span, at: committed)
        #expect(try storage.length == committed + 4)

        storage = try FileStorage(path: path, access: .readWrite, durability: .none)
        database = try Database(opening: storage)
        #expect(try database.committedSize == committed)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        #expect(try map.cursor(forHash: sha256("kept"))!.readUInt64() == 1)
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
            let database = try Database(creating: storage, hashSize: 32)
            try HashMap<ReadWrite>(database.rootCursor).put(.uint(1), forHash: sha256("a"))
            #expect(try database.committedSize > 62)
        }

        let storage = try BufferedFileStorage(path: scratch.path("cache.db"), access: .create, durability: .none)
        _ = try Database(creating: storage, hashSize: 32)
    }
}
