import Foundation
import Testing

@testable import XitDB

/// What is left when a transaction fails partway, or the process dies in
/// the middle of one: the database must be at its last commit, and the next
/// transaction must go on as if nothing had happened.
///
/// Every test runs on a database of each format version. A commit's last
/// write is the root header's committed size, eight bytes, at 29 in a
/// version 1 file and at 24 in a version 2 file; nothing else of a root
/// header is written by a commit in either.
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

    /// Opens the database in a storage, or makes a new one of `version` in
    /// an empty storage.
    static func open(_ storage: any WritableStorage, _ random: FixedRandom, _ version: FormatVersion) throws
        -> Database
    {
        if try storage.length == 0 {
            return try newDatabase(version, in: storage, random: random)
        }
        let database = try Database(opening: storage, hashSize: 20, random: random)
        try #require(database.header.version == version.rawValue)
        return database
    }

    /// What a run without faults leaves: the bytes after `populate`, the
    /// bytes after `transaction`, and how many writes the transaction makes.
    struct Golden {
        let base: [UInt8]
        let final: [UInt8]
        let writes: Int
        let syncs: Int
    }

    // Building these cannot fail; if it does, every test below fails on the
    // empty result.
    private static let goldenOne = (try? makeGolden(.one)) ?? Golden(base: [], final: [], writes: 0, syncs: 0)
    private static let goldenTwo = (try? makeGolden(.two)) ?? Golden(base: [], final: [], writes: 0, syncs: 0)

    static func golden(_ version: FormatVersion) -> Golden {
        version == .one ? goldenOne : goldenTwo
    }

    static func makeGolden(_ version: FormatVersion) throws -> Golden {
        let memory = MemoryStorage()
        let counting = FaultInjectingStorage(memory)
        let database = try open(counting, FixedRandom(commitIDs), version)
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

    @Test(arguments: FormatVersion.allCases)
    func theTransactionWithoutFaults(version: FormatVersion) throws {
        let golden = Self.golden(version)
        #expect(golden.writes > 30)
        #expect(golden.syncs == 2)
        #expect(golden.final.count > golden.base.count)
        // committed bytes never change, except the root header's committed
        // size: eight bytes, at 29 in version 1 and at 24 in version 2
        let size = version == .one ? 29 : 24
        #expect(Array(golden.final[(size + 8)..<golden.base.count]) == Array(golden.base[(size + 8)...]))
        #expect(Array(golden.final[..<size]) == Array(golden.base[..<size]))
        #expect(Array(golden.base[size..<(size + 8)]) == bigEndianBytes(UInt64(golden.base.count)))
        #expect(Array(golden.final[size..<(size + 8)]) == bigEndianBytes(UInt64(golden.final.count)))
        #expect(golden.final[5] == UInt8(version.rawValue))
        let database = try Self.open(MemoryStorage(bytes: golden.final), FixedRandom(), version)
        try Self.expectTransaction(database)
    }

    /// The same transactions leave the same bytes in the two versions, five
    /// bytes apart: the data of a version 2 file starts at 32, of a version
    /// 1 file at 37.
    @Test func theTwoVersionsDifferByFiveBytes() {
        let one = Self.golden(.one)
        let two = Self.golden(.two)
        #expect(one.base.count == two.base.count + 5)
        #expect(one.final.count == two.final.count + 5)
        #expect(one.writes == two.writes)
        #expect(one.syncs == two.syncs)
    }

    /// A storage of each kind holding the two commits, behind a wrapper that
    /// can make its writes and syncs fail.
    private func populated(
        _ kind: StorageKind, _ version: FormatVersion
    ) throws -> (subject: StorageUnderTest, faulty: FaultInjectingStorage, database: Database) {
        let subject = try StorageUnderTest(kind)
        let faulty = FaultInjectingStorage(subject.storage)
        // The third commit ID is there twice: a transaction that fails after
        // drawing it must get the same one when it is run again.
        let database = try Self.open(faulty, FixedRandom(Self.commitIDs + [Self.commitIDs[2]]), version)
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
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func aFailureAtEachWriteLeavesTheLastCommit(kind: StorageKind, version: FormatVersion) throws {
        let golden = Self.golden(version)
        try #require(golden.writes > 0)
        for failing in 1...golden.writes {
            let (subject, faulty, database) = try populated(kind, version)
            faulty.faults = [.failWrite(faulty.writeCount + failing)]
            #expect(throws: FaultInjectingStorage.failure, "write \(failing)") { try Self.transaction(database) }

            #expect(try database.committedSize == UInt64(golden.base.count), "write \(failing)")
            #expect(try stored(subject) == golden.base, "write \(failing)")
            try Self.expectLastCommit(database)
            // another database on the same storage sees the same
            try Self.expectLastCommit(try Self.open(subject.storage, FixedRandom(), version))

            faulty.faults = []
            try Self.transaction(database)
            #expect(firstDifference(try stored(subject), golden.final) == nil, "after write \(failing)")
        }
    }

    /// The same with writes that are cut short, as a full disk or a crash
    /// cuts them: one byte arrives and then the write fails.
    ///
    /// The last write of a transaction is the root header's committed size.
    /// Cut short after one byte it has written the size's first byte, the
    /// most significant, which is zero in the old size and the new: the
    /// size is intact, and so is every other byte.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func aWriteCutShortLeavesTheLastCommit(kind: StorageKind, version: FormatVersion) throws {
        let golden = Self.golden(version)
        try #require(golden.writes > 0)
        for failing in 1...golden.writes {
            let (subject, faulty, database) = try populated(kind, version)
            faulty.faults = [.cutWriteShort(faulty.writeCount + failing, keeping: 1)]
            #expect(throws: FaultInjectingStorage.failure, "write \(failing)") { try Self.transaction(database) }

            #expect(try database.committedSize == UInt64(golden.base.count), "write \(failing)")
            #expect(try stored(subject) == golden.base, "write \(failing)")
            try Self.expectLastCommit(try Self.open(subject.storage, FixedRandom(), version))

            faulty.faults = []
            try Self.transaction(database)
            #expect(firstDifference(try stored(subject), golden.final) == nil, "after write \(failing)")
        }
    }

    /// The first sync of a commit comes before the root header is rewritten.
    /// If it fails, the transaction fails and nothing is committed.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func aFailedSyncBeforeTheRootHeaderFailsTheTransaction(kind: StorageKind, version: FormatVersion) throws {
        let golden = Self.golden(version)
        let (subject, faulty, database) = try populated(kind, version)
        faulty.faults = [.failSync(faulty.syncCount + 1)]
        #expect(throws: FaultInjectingStorage.failure) { try Self.transaction(database) }

        #expect(try database.committedSize == UInt64(golden.base.count))
        #expect(try stored(subject) == golden.base)
        try Self.expectLastCommit(try Self.open(subject.storage, FixedRandom(), version))

        faulty.faults = []
        try Self.transaction(database)
        #expect(firstDifference(try stored(subject), golden.final) == nil)
    }

    /// The second sync comes after the root header is rewritten. If it
    /// fails, the failure is reported, but the commit is already in the
    /// storage: what is not known is whether it would survive a power loss.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func aFailedSyncAfterTheRootHeaderIsReportedAndTheCommitStands(kind: StorageKind, version: FormatVersion) throws {
        let golden = Self.golden(version)
        let (subject, faulty, database) = try populated(kind, version)
        faulty.faults = [.failSync(faulty.syncCount + 2)]
        #expect(throws: FaultInjectingStorage.failure) { try Self.transaction(database) }

        #expect(try database.committedSize == UInt64(golden.final.count))
        try Self.expectTransaction(database)
        #expect(firstDifference(try stored(subject), golden.final) == nil)
        try Self.expectTransaction(try Self.open(subject.storage, FixedRandom(), version))
    }

    /// A process that dies in the middle of a transaction leaves its bytes
    /// after the committed size. Opening the file does not remove them, the
    /// database reads as of its last commit, and the next transaction
    /// discards them and goes on exactly as it would have without them.
    @Test(arguments: FormatVersion.allCases)
    func bytesLeftByAProcessThatDiedAreDiscardedByTheNextTransaction(version: FormatVersion) throws {
        let golden = Self.golden(version)
        let memory = MemoryStorage()
        let database = try Self.open(memory, FixedRandom(Self.commitIDs), version)
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
        let reopened = try Self.open(storage, FixedRandom([Self.commitIDs[2]]), version)
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
    /// against that except that it is noticed: such a file does not open,
    /// and the error names the transaction's own trailer, which is whole at
    /// the end of the file. Recovery commits it, and leaves exactly what the
    /// transaction would have left. (Zig refuses the file and offers no
    /// recovery.) The database that made the torn write keeps reporting
    /// its root header as it is.
    @Test(arguments: FormatVersion.allCases)
    func aRootHeaderTornInsideItsSizeIsNoticed(version: FormatVersion) throws {
        let golden = Self.golden(version)
        let memory = MemoryStorage()
        let faulty = FaultInjectingStorage(memory)
        let database = try Self.open(faulty, FixedRandom(Self.commitIDs), version)
        try Self.populate(database)

        // seven of the committed size's eight bytes arrive
        faulty.faults = [.cutWriteShort(faulty.writeCount + golden.writes, keeping: 7)]
        #expect(throws: FaultInjectingStorage.failure) { try Self.transaction(database) }

        let oldSize = UInt64(golden.base.count)
        let newSize = UInt64(golden.final.count)
        let tornSize = (newSize & ~0xFF) | (oldSize & 0xFF)
        try #require(tornSize != oldSize && tornSize != newSize, "the two sizes must differ above their last byte")

        let sizePosition = Int(database.header.fileSizePosition)
        #expect(sizePosition == (version == .one ? 29 : 24))
        #expect(Array(memory.bytes[sizePosition..<(sizePosition + 8)]) == bigEndianBytes(tornSize))
        #expect(throws: XitDBError.untrustedRootHeader(lastVerified: newSize)) {
            try Database(opening: memory, hashSize: 20)
        }
        #expect(throws: tornSize > newSize ? XitDBError.truncatedDatabase : .invalidDatabase) {
            try database.committedSize
        }

        let recovered = try Database.recover(memory, random: FixedRandom())
        #expect(firstDifference(memory.bytes, golden.final) == nil)
        try Self.expectTransaction(recovered)
    }
}
