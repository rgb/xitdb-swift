import Testing
import XitDB

@Suite("Concurrency and snapshots") struct ConcurrencyExamples {
    @Test func readersOnOtherTasksWhileAWriterCommits() async throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }
        let path = scratch.path("main.db")
        do {
            let storage = try BufferedFileStorage(path: path, access: .create)
            let history = try ArrayList<ReadWrite>(Database(creating: storage, hashSize: 32).rootCursor)
            try history.append(.slot(nil)) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                try moment.put(.uint(0), forHash: sha256("first"))
                try moment.put(.uint(0), forHash: sha256("second"))
            }
        }
        let commits: UInt64 = 100

        let mismatches = try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                // The writer: a storage and a database of its own, and the lock.
                let storage = try BufferedFileStorage(
                    path: scratch.path("main.db"), access: .readWrite, durability: .none, lock: .exclusive)
                let database = try Database(opening: storage)
                let history = try ArrayList<ReadWrite>(database.rootCursor)
                for number in 1...commits {
                    try history.append(.slot(try history.slot(at: -1))) { cursor in
                        let moment = try HashMap<ReadWrite>(cursor)
                        try moment.put(.uint(number), forHash: sha256("first"))
                        try moment.put(.uint(number), forHash: sha256("second"))
                    }
                }
                return 0
            }
            for _ in 0..<2 {
                group.addTask {
                    // A reader: a storage opened read-only, and a database of its own.
                    let storage = try FileStorage(path: scratch.path("main.db"), access: .readOnly)
                    let database = try Database(opening: storage)
                    let history = try ArrayList<ReadOnly>(database.rootCursor)

                    var mismatches = 0
                    var latest: UInt64 = 0
                    while latest < commits {
                        // One moment, from one commit, whatever the writer does meanwhile.
                        let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
                        let first = try moment.cursor(forHash: sha256("first"))!.readUInt64()
                        let second = try moment.cursor(forHash: sha256("second"))!.readUInt64()
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
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            try HashMap<ReadWrite>(cursor).put(.uint(1), forHash: sha256("count"))
        }

        // The writer, on the main actor, hands the last commit to a reader.
        let snapshot = try database.snapshot()
        let reader = Task.detached {
            let history = try ArrayList<ReadOnly>(snapshot.rootCursor)
            let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
            return try moment.cursor(forHash: sha256("count"))!.readUInt64()
        }

        // The writer goes on, and the reader reads the commit it was given.
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            try HashMap<ReadWrite>(cursor).put(.uint(2), forHash: sha256("count"))
        }
        let count = try await reader.value
        #expect(count == 1)
        let latest = try HashMap<ReadOnly>(history.cursor(at: -1)!)
        #expect(try latest.cursor(forHash: sha256("count"))!.readUInt64() == 2)

        // A database of the snapshot reads the same commit.
        let reading = SnapshotDatabase(snapshot)
        #expect(try ArrayList<ReadOnly>(reading.rootCursor).count == 1)
    }

    @Test func aCursorFromAnEarlierCommitReadsThatCommit() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put(.uint(1), forHash: sha256("count"))

        // A cursor from that commit goes on reading it.
        let count = try map.cursor(forHash: sha256("count"))!
        try map.put(.uint(2), forHash: sha256("count"))
        #expect(try count.readUInt64() == 1)
        #expect(try map.cursor(forHash: sha256("count"))!.readUInt64() == 2)
    }

    @Test func aCursorFromATransactionThatDidNotCommit() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        struct NotNow: Error {}

        var unfinished: Cursor<ReadOnly>?
        var keptReader: ByteReader?
        var keptIterator: CollectionIterator?
        do {
            try database.withTransaction { cursor in
                let map = try HashMap<ReadWrite>(cursor)
                try map.put(.bytes(Array("a value long enough for a record".utf8)), forHash: sha256("note"))
                unfinished = try map.cursor(forHash: sha256("note"))
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
