import Foundation
import Testing
import XitDB

@Suite("Recovery") struct RecoveryExamples {
    /// A history of three moments, with the bytes after each commit.
    private func threeMoments() throws -> (bytes: [UInt8], after: [[UInt8]]) {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashSize: 32)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        var after: [[UInt8]] = []
        for price: UInt64 in [10, 12, 15] {
            try history.append(.slot(try history.slot(at: -1))) { cursor in
                try HashMap<ReadWrite>(cursor).put(.uint(price), forHash: sha256("price"))
            }
            after.append(storage.bytes)
        }
        return (storage.bytes, after)
    }

    private func moments(_ database: Database) throws -> UInt64 {
        try ArrayList<ReadOnly>(database.rootCursor).count
    }

    /// The root header's committed size, written as the file stores it.
    private func withCommittedSize(_ size: UInt64, _ bytes: [UInt8]) -> [UInt8] {
        var bytes = bytes
        for index in 0..<8 {
            bytes[24 + index] = UInt8(truncatingIfNeeded: size >> (56 - 8 * UInt64(index)))
        }
        return bytes
    }

    @Test func whatOpeningDoesWithEachKindOfRootHeader() throws {
        let (good, after) = try threeMoments()
        // Before the moments: the new database, then the empty history.
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashSize: 32)
        #expect(storage.bytes.count == 57)
        _ = try ArrayList<ReadWrite>(database.rootCursor)
        #expect(storage.bytes.count == 251)
        // The commits end at 639, 1,027 and 1,415.
        #expect(after.map(\.count) == [639, 1027, 1415])

        // Sound: it opens.
        #expect(try moments(Database(opening: MemoryStorage(bytes: good))) == 3)

        // A size past the end of the file, or too small, or not at a trailer.
        for size: UInt64 in [1520, 10, 1032] {
            #expect(throws: XitDBError.untrustedRootHeader(lastVerified: 1415)) {
                try Database(opening: MemoryStorage(bytes: withCommittedSize(size, good)))
            }
        }

        // The file cut short, or its last trailer damaged: the last commit that
        // verifies is the one before.
        #expect(throws: XitDBError.untrustedRootHeader(lastVerified: 1027)) {
            try Database(opening: MemoryStorage(bytes: Array(good.dropLast())))
        }
        var damagedTrailer = good
        damagedTrailer[good.count - 3] ^= 1
        #expect(throws: XitDBError.untrustedRootHeader(lastVerified: 1027)) {
            try Database(opening: MemoryStorage(bytes: damagedTrailer))
        }

        // A root header torn inside its size: the new size's first bytes and the old one's last.
        var torn = good
        torn[31] = after[1][31]
        #expect(throws: XitDBError.untrustedRootHeader(lastVerified: 1415)) {
            try Database(opening: MemoryStorage(bytes: torn))
        }

        // An empty storage, and one too short for its headers.
        #expect(throws: XitDBError.invalidDatabase) { try Database(opening: MemoryStorage()) }
        #expect(throws: XitDBError.endOfStream) { try Database(opening: MemoryStorage(bytes: Array(good[..<30]))) }

        // Not a database, and no trailer that verifies.
        var notADatabase = good
        notADatabase[0] ^= 0xFF
        #expect(throws: XitDBError.invalidDatabase) {
            try Database(opening: MemoryStorage(bytes: notADatabase))
        }
        let noTrailer = withCommittedSize(1415, Array(good[..<32]) + [UInt8](repeating: 0, count: 100))
        #expect(throws: XitDBError.invalidDatabase) {
            try Database(opening: MemoryStorage(bytes: noTrailer))
        }
        // A damaged file ID: every trailer's checksum covers it.
        var otherFileID = good
        otherFileID[15] ^= 1
        #expect(throws: XitDBError.invalidDatabase) {
            try Database(opening: MemoryStorage(bytes: otherFileID))
        }
        #expect(throws: XitDBError.invalidDatabase) {
            try Database.recover(MemoryStorage(bytes: otherFileID))
        }
    }

    @Test func openingWritesNothing() throws {
        let (good, _) = try threeMoments()
        let storage = MemoryStorage(bytes: Array(good.dropLast()))
        #expect(throws: XitDBError.untrustedRootHeader(lastVerified: 1027)) {
            try Database(opening: storage)
        }
        #expect(storage.bytes == Array(good.dropLast()))
    }

    @Test func recovering() throws {
        let (good, _) = try threeMoments()
        let storage = MemoryStorage(bytes: Array(good.dropLast()))

        func openOrRecover(_ storage: any WritableStorage) throws(XitDBError) -> Database {
            do {
                return try Database(opening: storage)
            } catch .untrustedRootHeader(let lastVerified) {
                // Copy the file first if what lies past lastVerified might be wanted.
                print("cutting the file back to \(lastVerified) bytes")
                return try Database.recover(storage)
            }
        }

        let database = try openOrRecover(storage)
        // The third moment's commit is lost.
        #expect(try moments(database) == 2)
        #expect(storage.bytes.count == 1027)
        #expect(try database.committedSize == 1027)
        // And the database goes on from there.
        try ArrayList<ReadWrite>(database.rootCursor).append(.uint(1))
        #expect(try moments(Database(opening: storage)) == 3)
    }

    @Test func recoveringWhatCannotBeRecovered() throws {
        let (good, _) = try threeMoments()
        var notADatabase = good
        notADatabase[0] ^= 0xFF
        let storage = MemoryStorage(bytes: notADatabase)
        #expect(throws: XitDBError.invalidDatabase) {
            try Database.recover(storage)
        }
        #expect(storage.bytes == notADatabase)
    }

    @Test func recoveringOnASoundRootHeaderCommitsAnUnfinishedTransaction() throws {
        let (good, after) = try threeMoments()
        // A process that died after the third commit's trailer and before its root header.
        var died = good
        died.replaceSubrange(24..<32, with: after[1][24..<32])

        #expect(try moments(Database(opening: MemoryStorage(bytes: died))) == 2)
        #expect(try moments(Database.recover(MemoryStorage(bytes: died))) == 3)
    }

    @Test func recoveringAReadOnlyFile() throws {
        let (good, _) = try threeMoments()
        let scratch = ScratchDirectory()
        defer { scratch.remove() }
        let path = scratch.path("main.db")
        let writer = try FileStorage(path: path, access: .create)
        try writer.write(Array(good.dropLast()).span, at: 0)
        let reader = try FileStorage(path: path, access: .readOnly)
        do {
            _ = try Database.recover(reader)
            Issue.record("a read-only storage cannot be recovered")
        } catch {
            // `EBADF`, at the write of the root header.
            #expect(error == .storageFailure(errno: 9))
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data(good.dropLast()))
    }

    @Test func aReplicaAfterAFailedSyncAtZero() throws {
        let (good, _) = try threeMoments()
        let source = try Database(opening: MemoryStorage(bytes: good))

        struct ConnectionLost: Error {}
        struct DroppingSource: ByteSource {
            let bytes: [UInt8]
            let dropAt: Int
            var given = 0
            mutating func read(into buffer: inout MutableSpan<UInt8>) throws -> Int {
                guard given < dropAt else { throw ConnectionLost() }
                let count = min(buffer.count, dropAt - given)
                for index in 0..<count {
                    buffer[index] = bytes[given + index]
                }
                given += count
                return count
            }
        }

        let replicaStorage = MemoryStorage()
        var replica = try Database(creating: replicaStorage, hashSize: 32)
        var connection = DroppingSource(bytes: good, dropAt: 1100)
        #expect(throws: XitDBError.self) {
            try replica.applyReplicated(at: 0, from: &connection, count: UInt64(good.count))
        }
        // The replica has no first commit: its state is zero and zero, and
        // the source answers 0 to it.
        #expect(try replica.replicaState == ReplicaState(committedSize: 0, checksum: 0))
        #expect(try source.replicationStart(for: try replica.replicaState) == 0)

        // What arrived holds the source's earlier commits. Keep the last of them.
        replica = try Database.recover(replicaStorage)
        let start = try source.replicationStart(for: try replica.replicaState)
        #expect(start == 1027)
        let end = try source.committedSize
        let bytes = try source.readCommitted(from: start, to: end)
        try replica.applyReplicated(at: start, bytes: bytes)
        #expect(replicaStorage.bytes == good)

        // The source's first commit is its first 57 bytes: the new database.
        let first = MemoryStorage()
        var afterFirst = DroppingSource(bytes: good, dropAt: 70)
        #expect(throws: XitDBError.self) {
            try Database(creating: first, hashSize: 32)
                .applyReplicated(at: 0, from: &afterFirst, count: UInt64(good.count))
        }
        #expect(try Database.recover(first).committedSize == 57)
        let beforeFirst = MemoryStorage()
        var early40 = DroppingSource(bytes: good, dropAt: 40)
        #expect(throws: XitDBError.self) {
            try Database(creating: beforeFirst, hashSize: 32)
                .applyReplicated(at: 0, from: &early40, count: UInt64(good.count))
        }
        #expect(throws: XitDBError.invalidDatabase) { try Database.recover(beforeFirst) }

        // A sync that failed inside the source's header changed nothing: the
        // replica is the database it was.
        let untouched = MemoryStorage()
        let another = try Database(creating: untouched, hashSize: 32)
        let before = untouched.bytes
        var early = DroppingSource(bytes: good, dropAt: 10)
        #expect(throws: XitDBError.self) {
            try another.applyReplicated(at: 0, from: &early, count: UInt64(good.count))
        }
        #expect(untouched.bytes == before)
        #expect(try another.replicaState.committedSize == 57)
    }
}
