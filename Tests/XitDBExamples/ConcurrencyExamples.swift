import Testing
import XitDB
import XitDBHashing

@Suite("Concurrency and snapshots") struct ConcurrencyExamples {
    @Test func readersOnOtherTasksWhileAWriterCommits() async throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }
        let path = scratch.path("main.db")
        do {
            let storage = try BufferedFileStorage(path: path, access: .create)
            let history = try ArrayList<ReadWrite>(Database(creating: storage, hashing: SHA256.self).rootCursor)
            try history.append(.slot(nil)) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                try moment.put(UInt64(0), forKey: "first")
                try moment.put(UInt64(0), forKey: "second")
            }
        }
        let commits: UInt64 = 100

        let mismatches = try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                // The writer: a storage and a database of its own, and the lock.
                let storage = try BufferedFileStorage(
                    path: scratch.path("main.db"), access: .readWrite, durability: .none, lock: .exclusive)
                let database = try Database(opening: storage, hashing: SHA256.self)
                let history = try ArrayList<ReadWrite>(database.rootCursor)
                for number in 1...commits {
                    try history.append(.slot(try history.slot(at: -1))) { cursor in
                        let moment = try HashMap<ReadWrite>(cursor)
                        try moment.put(number, forKey: "first")
                        try moment.put(number, forKey: "second")
                    }
                }
                return 0
            }
            for _ in 0..<2 {
                group.addTask {
                    // A reader: a storage opened read-only, and a database of its own.
                    let storage = try FileStorage(path: scratch.path("main.db"), access: .readOnly)
                    let database = try Database(opening: storage, hashing: SHA256.self)
                    let history = try ArrayList<ReadOnly>(database.rootCursor)

                    var mismatches = 0
                    var latest: UInt64 = 0
                    while latest < commits {
                        // One moment, from one commit, whatever the writer does meanwhile.
                        let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
                        let first = try moment.value(forKey: "first", as: UInt64.self)!
                        let second = try moment.value(forKey: "second", as: UInt64.self)!
                        if first != second || first < latest {
                            mismatches += 1
                        }
                        latest = first
                    }
                    return mismatches
                }
            }
            return try await group.reduce(0, +)
        }
        #expect(mismatches == 0)
    }

    @Test @MainActor func aTaskReadsASnapshotWhileTheMainActorWrites() async throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            try HashMap<ReadWrite>(cursor).put(UInt64(1), forKey: "count")
        }

        // The writer, on the main actor, hands the last commit to a reader.
        let snapshot = try database.snapshot()
        let reader = Task.detached {
            let history = try ArrayList<ReadOnly>(snapshot.rootCursor)
            let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
            return try moment.value(forKey: "count", as: UInt64.self)
        }

        // The writer goes on, and the reader reads the commit it was given.
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            try HashMap<ReadWrite>(cursor).put(UInt64(2), forKey: "count")
        }
        let count = try await reader.value
        #expect(count == 1)
        let latest = try HashMap<ReadOnly>(history.cursor(at: -1)!)
        #expect(try latest.value(forKey: "count", as: UInt64.self) == 2)

        // A database of the snapshot reads the same commit.
        let reading = SnapshotDatabase(snapshot)
        #expect(try ArrayList<ReadOnly>(reading.rootCursor).count == 1)
    }

    @Test func aCursorFromAnEarlierCommitReadsThatCommit() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put(UInt64(1), forKey: "count")

        // A cursor from that commit goes on reading it.
        let count = try map.cursor(forKey: "count")!
        try map.put(UInt64(2), forKey: "count")
        #expect(try count.readUInt64() == 1)
        #expect(try map.value(forKey: "count", as: UInt64.self) == 2)
    }

    @Test func aCursorFromATransactionThatDidNotCommit() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        struct NotNow: Error {}

        var unfinished: Cursor<ReadOnly>?
        var keptReader: ByteReader?
        var keptIterator: CollectionIterator?
        do {
            try database.withTransaction { cursor in
                let map = try HashMap<ReadWrite>(cursor)
                try map.put("a value long enough for a record", forKey: "note")
                unfinished = try map.cursor(forKey: "note")
                keptReader = try unfinished!.reader()
                keptIterator = try map.iterator()
                throw NotNow()
            }
        } catch is NotNow {}

        // Its bytes were cut off, and the next transaction reuses their place.
        #expect(throws: XitDBError.staleCursor) { try unfinished!.readBytes() }
        #expect(throws: XitDBError.staleCursor) { try unfinished!.reader() }
        // So are an iterator and a byte reader made from it before the rollback.
        #expect(throws: XitDBError.staleCursor) { try keptIterator!.next() }
        #expect(throws: XitDBError.staleCursor) { try keptReader!.readRemaining() }
        // Its snapshot of the slot touches no bytes, and stays readable.
        #expect(try unfinished!.slot.tag == .bytes)
    }
}
