import Foundation
import Testing

@testable import XitDB

/// What is left when a transaction fails partway, or the process dies in
/// the middle of one: the database must be at its last commit, and the next
/// transaction must go on as if nothing had happened.
@Suite struct RecoveryTests {
    static let commitIDs: [UInt64] = [0x1111, 0x2222, 0x3333]

    /// Two commits to start from.
    static func populate(_ database: Database) throws {
        let root = database.rootCursor
        _ = try root.writePath([.arrayListInit, .arrayListAppend, .hashMapInit(), .ctx]) { cursor in
            _ = try cursor.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(1))])
            _ = try cursor.writePath([
                .hashMapGet(.value, sha1("b")), .write(.bytes(Array("a value of some length".utf8))),
            ])
            _ = try cursor.writePath([
                .hashMapGet(.value, sha1("list")), .arrayListInit, .arrayListAppend, .write(.uint(10)),
            ])
        }
        let last = try root.readPathSlot([.arrayListGet(-1)])
        _ = try root.writePath([.arrayListInit, .arrayListAppend, .write(.slot(last)), .hashMapInit(), .ctx]) {
            cursor in
            _ = try cursor.writePath([.hashMapGet(.value, sha1("c")), .write(.int(-3))])
        }
    }

    /// The transaction under test. It touches everything a transaction can:
    /// a new moment cloned from the last, new and changed entries, a removal,
    /// a long value, and a nested list.
    static func transaction(_ database: Database) throws {
        let root = database.rootCursor
        let last = try root.readPathSlot([.arrayListGet(-1)])
        _ = try root.writePath([.arrayListInit, .arrayListAppend, .write(.slot(last)), .hashMapInit(), .ctx]) {
            cursor in
            _ = try cursor.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(2))])
            _ = try cursor.writePath([
                .hashMapGet(.value, sha1("d")), .write(.bytes([UInt8](repeating: 0x5A, count: 100))),
            ])
            _ = try cursor.writePath([.hashMapRemove(sha1("b"))])
            _ = try cursor.writePath([
                .hashMapGet(.value, sha1("list")), .arrayListInit, .arrayListAppend, .write(.uint(11)),
            ])
            var text = try cursor.writePath([.hashMapGet(.value, sha1("text"))])
            try text.writeBytes(formatTag: "tx") { writer in
                try writer.write(Array("written in ".utf8))
                try writer.write(Array("pieces".utf8))
            }
        }
    }

    /// Checks that the database holds the two commits of `populate` and
    /// nothing of `transaction`.
    static func expectLastCommit(_ database: Database) throws {
        #expect(try database.rootCursor.count == 2)
        let moment = try #require(try database.rootCursor.readPath([.arrayListGet(-1)]))
        #expect(try #require(try moment.readPath([.hashMapGet(.value, sha1("a"))])).readUInt64() == 1)
        #expect(try #require(try moment.readPath([.hashMapGet(.value, sha1("c"))])).readInt64() == -3)
        #expect(try moment.readPath([.hashMapGet(.value, sha1("b"))]) != nil)
        #expect(try moment.readPath([.hashMapGet(.value, sha1("d"))]) == nil)
        #expect(try #require(try moment.readPath([.hashMapGet(.value, sha1("list"))])).count == 1)
    }

    static func expectTransaction(_ database: Database) throws {
        #expect(try database.rootCursor.count == 3)
        let moment = try #require(try database.rootCursor.readPath([.arrayListGet(-1)]))
        #expect(try #require(try moment.readPath([.hashMapGet(.value, sha1("a"))])).readUInt64() == 2)
        #expect(try moment.readPath([.hashMapGet(.value, sha1("b"))]) == nil)
        #expect(try #require(try moment.readPath([.hashMapGet(.value, sha1("list"))])).count == 2)
        let text = try #require(try moment.readPath([.hashMapGet(.value, sha1("text"))])).readBytesWithFormatTag()
        #expect(text == Bytes(Array("written in pieces".utf8), formatTag: "tx"))
    }

    static func open(_ storage: any WritableStorage, _ random: FixedRandom) throws -> Database {
        try Database(storage: storage, hashSize: 20, hashID: nil, fileID: 0xF11E, random: random)
    }

    /// What a run without faults leaves: the bytes after `populate`, the
    /// bytes after `transaction`, and how many writes the transaction makes.
    struct Golden {
        let base: [UInt8]
        let final: [UInt8]
        let writes: Int
        let syncs: Int
    }

    static let golden: Golden = {
        // Building this cannot fail; if it does, every test below fails on
        // the empty result.
        (try? makeGolden()) ?? Golden(base: [], final: [], writes: 0, syncs: 0)
    }()

    static func makeGolden() throws -> Golden {
        let memory = MemoryStorage()
        let counting = FaultInjectingStorage(memory)
        let database = try open(counting, FixedRandom(commitIDs))
        try populate(database)
        let base = memory.bytes
        let writesBefore = counting.writeCount
        let syncsBefore = counting.syncCount
        try transaction(database)
        return Golden(
            base: base,
            final: memory.bytes,
            writes: counting.writeCount - writesBefore,
            syncs: counting.syncCount - syncsBefore
        )
    }

    @Test func theTransactionWithoutFaults() throws {
        let golden = Self.golden
        #expect(golden.writes > 30)
        #expect(golden.syncs == 2)
        #expect(golden.final.count > golden.base.count)
        // committed bytes never change, except the root header
        #expect(Array(golden.final[37..<golden.base.count]) == Array(golden.base[37...]))
        #expect(Array(golden.final[..<20]) == Array(golden.base[..<20]))
        let database = try Self.open(MemoryStorage(bytes: golden.final), FixedRandom())
        try Self.expectTransaction(database)
    }

    /// A storage of each kind holding the two commits, behind a wrapper that
    /// can make its writes and syncs fail.
    private func populated(
        _ kind: StorageKind
    ) throws -> (subject: StorageUnderTest, faulty: FaultInjectingStorage, database: Database) {
        let subject = try StorageUnderTest(kind)
        let faulty = FaultInjectingStorage(subject.storage)
        // The third commit ID is there twice: a transaction that fails after
        // drawing it must get the same one when it is run again.
        let database = try Self.open(faulty, FixedRandom(Self.commitIDs + [Self.commitIDs[2]]))
        try Self.populate(database)
        return (subject, faulty, database)
    }

    private func stored(_ subject: StorageUnderTest) throws -> [UInt8] {
        try subject.storage.flush()
        return try subject.stored()
    }

    /// A write that fails, whichever one it is, leaves the storage exactly as
    /// it was after the last commit, and the same transaction then succeeds
    /// and leaves exactly what it would have left without the failure.
    @Test(arguments: StorageKind.allCases)
    func aFailureAtEachWriteLeavesTheLastCommit(kind: StorageKind) throws {
        let golden = Self.golden
        try #require(golden.writes > 0)
        for failing in 1...golden.writes {
            let (subject, faulty, database) = try populated(kind)
            faulty.faults = [.failWrite(faulty.writeCount + failing)]
            #expect(throws: FaultInjectingStorage.failure, "write \(failing)") { try Self.transaction(database) }

            #expect(try database.committedSize == UInt64(golden.base.count), "write \(failing)")
            #expect(try stored(subject) == golden.base, "write \(failing)")
            try Self.expectLastCommit(database)
            // another database on the same storage sees the same
            try Self.expectLastCommit(try Self.open(subject.storage, FixedRandom()))

            faulty.faults = []
            try Self.transaction(database)
            #expect(firstDifference(try stored(subject), golden.final) == nil, "after write \(failing)")
        }
    }

    /// The same with writes that are cut short, as a full disk or a crash
    /// cuts them: one byte arrives and then the write fails.
    ///
    /// The last write of a transaction is the root header's. Cut short after
    /// one byte it has changed the first byte of the root slot cached there,
    /// which nothing reads: the committed size after it is intact.
    @Test(arguments: StorageKind.allCases)
    func aWriteCutShortLeavesTheLastCommit(kind: StorageKind) throws {
        let golden = Self.golden
        try #require(golden.writes > 0)
        for failing in 1...golden.writes {
            let (subject, faulty, database) = try populated(kind)
            faulty.faults = [.cutWriteShort(faulty.writeCount + failing, keeping: 1)]
            #expect(throws: FaultInjectingStorage.failure, "write \(failing)") { try Self.transaction(database) }

            #expect(try database.committedSize == UInt64(golden.base.count), "write \(failing)")
            var bytes = try stored(subject)
            if failing == golden.writes {
                // the root header's cached slot
                bytes.replaceSubrange(20..<29, with: golden.base[20..<29])
            }
            #expect(bytes == golden.base, "write \(failing)")
            try Self.expectLastCommit(try Self.open(subject.storage, FixedRandom()))

            faulty.faults = []
            try Self.transaction(database)
            #expect(firstDifference(try stored(subject), golden.final) == nil, "after write \(failing)")
        }
    }

    /// The first sync of a commit comes before the root header is rewritten.
    /// If it fails, the transaction fails and nothing is committed.
    @Test(arguments: StorageKind.allCases)
    func aFailedSyncBeforeTheRootHeaderFailsTheTransaction(kind: StorageKind) throws {
        let golden = Self.golden
        let (subject, faulty, database) = try populated(kind)
        faulty.faults = [.failSync(faulty.syncCount + 1)]
        #expect(throws: FaultInjectingStorage.failure) { try Self.transaction(database) }

        #expect(try database.committedSize == UInt64(golden.base.count))
        #expect(try stored(subject) == golden.base)
        try Self.expectLastCommit(try Self.open(subject.storage, FixedRandom()))

        faulty.faults = []
        try Self.transaction(database)
        #expect(firstDifference(try stored(subject), golden.final) == nil)
    }

    /// The second sync comes after the root header is rewritten. If it
    /// fails, the failure is reported, but the commit is already in the
    /// storage: what is not known is whether it would survive a power loss.
    @Test(arguments: StorageKind.allCases)
    func aFailedSyncAfterTheRootHeaderIsReportedAndTheCommitStands(kind: StorageKind) throws {
        let golden = Self.golden
        let (subject, faulty, database) = try populated(kind)
        faulty.faults = [.failSync(faulty.syncCount + 2)]
        #expect(throws: FaultInjectingStorage.failure) { try Self.transaction(database) }

        #expect(try database.committedSize == UInt64(golden.final.count))
        try Self.expectTransaction(database)
        #expect(firstDifference(try stored(subject), golden.final) == nil)
        try Self.expectTransaction(try Self.open(subject.storage, FixedRandom()))
    }

    /// A process that dies in the middle of a transaction leaves its bytes
    /// after the committed size. Opening the file does not remove them, the
    /// database reads as of its last commit, and the next transaction
    /// discards them and goes on exactly as it would have without them.
    @Test func bytesLeftByAProcessThatDiedAreDiscardedByTheNextTransaction() throws {
        let golden = Self.golden
        let memory = MemoryStorage()
        let database = try Self.open(memory, FixedRandom(Self.commitIDs))
        try Self.populate(database)

        // the storage as it is in the middle of a transaction
        var midTransaction: [UInt8] = []
        struct Died: Error {}
        #expect(throws: Died.self) {
            try database.withTransaction { cursor in
                _ = try cursor.writePath([
                    .arrayListAppend, .hashMapInit(), .hashMapGet(.value, sha1("x")), .write(.uint(9)),
                ])
                midTransaction = memory.bytes
                throw Died()
            }
        }
        #expect(midTransaction.count > golden.base.count)
        #expect(Array(midTransaction[..<golden.base.count]) == golden.base)

        let storage = MemoryStorage(bytes: midTransaction)
        let reopened = try Self.open(storage, FixedRandom([Self.commitIDs[2]]))
        #expect(try reopened.committedSize == UInt64(golden.base.count))
        try Self.expectLastCommit(reopened)
        // opening and reading remove nothing
        #expect(storage.bytes == midTransaction)

        try Self.transaction(reopened)
        #expect(firstDifference(storage.bytes, golden.final) == nil)
    }

    /// The root header is the one place a database is rewritten, and a write
    /// to it that is torn inside its committed size can leave a size that is
    /// neither the old one nor the new one. The file format has no defence
    /// against that except that it is noticed: such a file does not open.
    /// Zig is the same. This test pins what happens, so that a change to it
    /// is deliberate.
    @Test func aRootHeaderTornInsideItsSizeIsNoticed() throws {
        let golden = Self.golden
        let memory = MemoryStorage()
        let faulty = FaultInjectingStorage(memory)
        let database = try Self.open(faulty, FixedRandom(Self.commitIDs))
        try Self.populate(database)

        // sixteen of the root header's seventeen bytes arrive
        faulty.faults = [.cutWriteShort(faulty.writeCount + golden.writes, keeping: 16)]
        #expect(throws: FaultInjectingStorage.failure) { try Self.transaction(database) }

        let oldSize = UInt64(golden.base.count)
        let newSize = UInt64(golden.final.count)
        let tornSize = (newSize & ~0xFF) | (oldSize & 0xFF)
        try #require(tornSize != oldSize && tornSize != newSize, "the two sizes must differ above their last byte")

        #expect(Array(memory.bytes[29..<37]) == bigEndianBytes(tornSize))
        #expect(throws: XitDBError.self) { try Self.open(memory, FixedRandom()) }
        #expect(throws: XitDBError.self) { try database.committedSize }
    }
}
