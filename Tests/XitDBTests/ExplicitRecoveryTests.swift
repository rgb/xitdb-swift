import Foundation
import Testing

@testable import XitDB

/// Opening a database whose root header cannot be trusted, and the explicit
/// recovery that cuts the storage back to its last commit that verifies
/// (decision D19, as D22 item 4 settled it). Opening refuses, names that
/// commit, and writes nothing; `recover` is the one call that drops a
/// commit, and it leaves exactly the bytes that commit left.
///
/// Every test runs on a database of each format version: the committed
/// size, the first trailer and the smallest database are five bytes apart
/// in the two, and recovery writes the committed size alone in both.
@Suite struct ExplicitRecoveryTests {
    static let commitIDs: [UInt64] = [0x1111, 0x2222, 0x3333]

    /// The commit ID a recovered database draws for its next commit.
    static let nextCommitID: UInt64 = 0x4444

    /// A database of three commits on a storage of one kind, with the
    /// storage's bytes after each: `after[0]` is the new database, and
    /// `after[n]` what commit n left.
    struct Subject {
        let storage: StorageUnderTest
        /// The database's header, which says where its root header's
        /// committed size is and where its data starts.
        let header: DatabaseHeader
        let after: [[UInt8]]

        /// The committed size after commit n.
        func end(_ n: Int) -> UInt64 {
            UInt64(after[n].count)
        }

        /// The bytes in memory or on disk now.
        func stored() throws -> [UInt8] {
            try storage.storage.flush()
            return try storage.stored()
        }

        func write(_ bytes: [UInt8], at offset: UInt64) throws {
            try writeBytes(storage.storage, bytes, at: offset)
        }

        /// The byte at `offset`, for damaging it.
        func byte(at offset: UInt64) throws -> UInt8 {
            try #require(try readBytes(storage.storage, at: offset, count: 1).first)
        }

        func open() throws -> Database {
            try Database(opening: storage.storage, hashSize: 20, random: FixedRandom([nextCommitID]))
        }

        func recover() throws -> Database {
            try Database.recover(storage.storage, random: FixedRandom([nextCommitID]))
        }
    }

    static func makeSubject(_ kind: StorageKind, _ version: FormatVersion) throws -> Subject {
        let storage = try StorageUnderTest(kind)
        let database = try newDatabase(version, in: storage.storage, random: FixedRandom(commitIDs))
        try #require(database.header.version == version.rawValue)
        var after: [[UInt8]] = []
        try storage.storage.flush()
        after.append(try storage.stored())
        for n in 1...3 {
            try commit(database, UInt64(n))
            try storage.storage.flush()
            after.append(try storage.stored())
        }
        return Subject(storage: storage, header: database.header, after: after)
    }

    /// Commit n: a new moment holding n under "n".
    static func commit(_ database: Database, _ n: UInt64) throws {
        _ = try database.rootCursor.writePath([
            .arrayListInit, .arrayListAppend, .hashMapInit(), .hashMapGet(.value, sha1("n")), .write(.uint(n)),
        ])
    }

    /// A commit that adds a byte array of `count` bytes to a new moment.
    static func commitBytes(_ database: Database, count: Int) throws {
        _ = try database.rootCursor.writePath([
            .arrayListInit, .arrayListAppend, .hashMapInit(), .hashMapGet(.value, sha1("blob")),
            .write(.bytes([UInt8](repeating: 0xAB, count: count))),
        ])
    }

    /// Checks that the database reads as of commit n: n moments, the last
    /// holding n.
    static func expectCommit(_ database: Database, _ n: Int, _ comment: Comment? = nil) throws {
        if n == 0 {
            #expect(try database.rootCursor.slot.tag == .none, comment)
            return
        }
        #expect(try database.rootCursor.count == UInt64(n), comment)
        let value = try #require(
            try database.rootCursor.readPath([.arrayListGet(-1), .hashMapGet(.value, sha1("n"))]), comment)
        #expect(try value.readUInt64() == UInt64(n), comment)
    }

    /// A committed size past the end of the storage, below what a database
    /// can be, or inside the storage but not at a trailer: opening refuses
    /// with the end of the last commit, and writes nothing. A size that
    /// ends at an earlier commit's trailer is trusted, and names that
    /// commit.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func aCommittedSizeThatCannotBeRightIsUntrusted(kind: StorageKind, version: FormatVersion) throws {
        let subject = try Self.makeSubject(kind, version)
        let end = subject.end(3)
        let sizes: [(UInt64, String)] = [
            (end + 1, "past the end"), (UInt64.max, "far past the end"), (10, "below a new database"),
            (subject.header.minimumFileSize - 1, "a byte below a new database"), (end - 1, "not at a trailer"),
            (subject.end(1) + 1, "inside an earlier commit"),
        ]
        for (size, what) in sizes {
            try subject.write(bigEndianBytes(size), at: subject.header.fileSizePosition)
            let damaged = try subject.stored()
            #expect(throws: XitDBError.untrustedRootHeader(lastVerified: end), "\(what)") { try subject.open() }
            #expect(try subject.stored() == damaged, "\(what)")
        }

        try subject.write(bigEndianBytes(subject.end(2)), at: subject.header.fileSizePosition)
        let earlier = try subject.open()
        #expect(try earlier.committedSize == subject.end(2))
        try Self.expectCommit(earlier, 2)
    }

    /// Bytes past the committed size, as a process that died leaves them,
    /// are passed over by the scan, which starts from the end of the
    /// storage; recovery drops them, and leaves the last commit exactly,
    /// with one write for the root header and one sync.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func whatACrashLeftPastTheEndIsDroppedByRecovery(kind: StorageKind, version: FormatVersion) throws {
        let subject = try Self.makeSubject(kind, version)
        let end = subject.end(3)
        try subject.write(Array("what a crash left".utf8), at: end)
        // a sound root header opens over the leftovers, and drops nothing
        #expect(try subject.open().committedSize == end)
        #expect(try subject.stored().count == Int(end) + 17)

        try subject.write(bigEndianBytes(10), at: subject.header.fileSizePosition)
        #expect(throws: XitDBError.untrustedRootHeader(lastVerified: end)) { try subject.open() }
        #expect(try subject.stored().count == Int(end) + 17)

        let faulty = FaultInjectingStorage(subject.storage.storage)
        let recovered = try Database.recover(faulty, random: FixedRandom([Self.nextCommitID]))
        #expect(faulty.writeCount == 1)
        #expect(faulty.syncCount == 1)
        #expect(try faulty.length == end)
        #expect(firstDifference(try subject.stored(), subject.after[3]) == nil)
        try Self.expectCommit(recovered, 3)
    }

    /// A last trailer that does not verify, because its checksum or its
    /// root slot was changed: opening names the commit before it and drops
    /// nothing; recovery leaves exactly the bytes that commit left, reads
    /// as of it, and takes the next commit exactly as the database would
    /// have after that commit.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func aDamagedLastTrailerLosesThatCommitOnlyThroughRecovery(kind: StorageKind, version: FormatVersion) throws {
        let subject = try Self.makeSubject(kind, version)
        let end = subject.end(3)
        let previous = subject.end(2)
        let trailerStart = end - RootTrailer.byteCount

        // the checksum's last byte
        let checksumByte = try subject.byte(at: end - 1)
        try subject.write([~checksumByte], at: end - 1)
        #expect(throws: XitDBError.untrustedRootHeader(lastVerified: previous)) { try subject.open() }
        try subject.write([checksumByte], at: end - 1)
        // the root slot's tag
        let tagByte = try subject.byte(at: trailerStart)
        try subject.write([~tagByte], at: trailerStart)
        #expect(throws: XitDBError.untrustedRootHeader(lastVerified: previous)) { try subject.open() }
        var damaged = subject.after[3]
        damaged[Int(trailerStart)] = ~tagByte
        #expect(try subject.stored() == damaged)

        let faulty = FaultInjectingStorage(subject.storage.storage)
        let recovered = try Database.recover(faulty, random: FixedRandom([Self.nextCommitID]))
        #expect(faulty.writeCount == 1)
        #expect(faulty.syncCount == 1)
        #expect(try faulty.length == previous)
        #expect(try recovered.committedSize == previous)
        #expect(firstDifference(try subject.stored(), subject.after[2]) == nil)
        try Self.expectCommit(recovered, 2)

        // it goes on from there, as a database left at commit 2 would
        try Self.commit(recovered, 3)
        try Self.expectCommit(recovered, 3)
        let golden = MemoryStorage(bytes: subject.after[2])
        let left = try Database(opening: golden, hashSize: 20, random: FixedRandom([Self.nextCommitID]))
        try Self.commit(left, 3)
        #expect(firstDifference(try subject.stored(), golden.bytes) == nil)
        #expect(recovered.header.version == version.rawValue)
    }

    /// A bad magic number is not a database, and a version this
    /// implementation does not read (0, or 3 and above) is not one it can
    /// recover: opening and recovery report them as they always did and
    /// change nothing. The header is checked before the root header, in the
    /// order magic, version, hash size; recovery takes no hash size.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func aStorageThatIsNotADatabaseIsNotRecovered(kind: StorageKind, version: FormatVersion) throws {
        let subject = try Self.makeSubject(kind, version)
        // a root header that cannot be trusted, behind each fault of the header
        let sizePosition = subject.header.fileSizePosition
        try subject.write(bigEndianBytes(subject.end(3) + 1), at: sizePosition)
        var damaged = subject.after[3]
        damaged.replaceSubrange(Int(sizePosition)..<Int(sizePosition + 8), with: bigEndianBytes(subject.end(3) + 1))

        try subject.write([UInt8(ascii: "g")], at: 0)
        #expect(throws: XitDBError.invalidDatabase) { try subject.open() }
        #expect(throws: XitDBError.invalidDatabase) { try subject.recover() }
        var withBadMagic = damaged
        withBadMagic[0] = UInt8(ascii: "g")
        #expect(try subject.stored() == withBadMagic)
        try subject.write([UInt8(ascii: "x")], at: 0)

        for unread in [UInt8(0), 3] {
            try subject.write([0, unread], at: 4)
            #expect(throws: XitDBError.invalidVersion) { try subject.open() }
            #expect(throws: XitDBError.invalidVersion) { try subject.recover() }
        }
        try subject.write([0, UInt8(version.rawValue)], at: 4)

        #expect(throws: XitDBError.invalidHashSize) { try Database(opening: subject.storage.storage, hashSize: 8) }
        #expect(throws: XitDBError.untrustedRootHeader(lastVerified: subject.end(3))) { try subject.open() }
        #expect(try subject.stored() == damaged)

        _ = try subject.recover()
        #expect(firstDifference(try subject.stored(), subject.after[3]) == nil)
    }

    /// A storage in which no trailer verifies holds no commit to recover
    /// to: one whose header carries another file ID, so that no trailer's
    /// checksum is for it; one cut shorter than a database can be; and a
    /// new database whose one trailer is damaged. Opening and recovery
    /// report that it holds no database, and leave it as it is.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func aStorageWithNoVerifyingTrailerCannotBeRecovered(kind: StorageKind, version: FormatVersion) throws {
        let subject = try Self.makeSubject(kind, version)

        try subject.write(bigEndianBytes(subject.header.fileID + 1), at: 12)
        var otherFile = subject.after[3]
        otherFile.replaceSubrange(12..<20, with: bigEndianBytes(subject.header.fileID + 1))
        #expect(throws: XitDBError.invalidDatabase) { try subject.open() }
        #expect(throws: XitDBError.invalidDatabase) { try subject.recover() }
        #expect(try subject.stored() == otherFile)
        try subject.write(bigEndianBytes(subject.header.fileID), at: 12)

        let smallest = subject.header.minimumFileSize
        #expect(smallest == (version == .one ? 62 : 57))
        try subject.storage.storage.truncate(to: smallest - 1)
        #expect(throws: XitDBError.invalidDatabase) { try subject.open() }
        #expect(throws: XitDBError.invalidDatabase) { try subject.recover() }
        #expect(try subject.stored() == Array(subject.after[3][..<Int(smallest - 1)]))

        let fresh = try StorageUnderTest(kind)
        _ = try newDatabase(version, in: fresh.storage)
        let end = smallest - 1
        let last = try #require(try readBytes(fresh.storage, at: end, count: 1).first)
        try writeBytes(fresh.storage, [~last], at: end)
        #expect(throws: XitDBError.invalidDatabase) { try Database(opening: fresh.storage) }
        #expect(throws: XitDBError.invalidDatabase) { try Database.recover(fresh.storage) }
        try fresh.storage.flush()
        #expect(try fresh.stored().count == Int(smallest))
        #expect(try fresh.stored()[Int(end)] == ~last)
    }

    /// The scan reads the storage in windows from the end back. A last
    /// commit of about a window, or of several, with its trailer damaged,
    /// is passed over to the commit before it, whether that commit's
    /// trailer lies whole in the first window, whole in a later one, or
    /// across the edge of two.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func theScanCrossesItsWindows(kind: StorageKind, version: FormatVersion) throws {
        let window = DatabaseReader.scanWindow
        // what a commit of a byte array adds to the storage beyond the array
        let overhead: Int = try {
            let memory = MemoryStorage()
            let database = try newDatabase(version, in: memory, random: FixedRandom([1, 2]))
            try Self.commit(database, 1)
            let before = memory.bytes.count
            try Self.commitBytes(database, count: 1000)
            return memory.bytes.count - before - 1000
        }()

        // the last commit's size, so that the trailer before it ends: at the
        // first window's start, a byte above it, inside the overlap, at the
        // second window's end, and three windows back
        for added in [window - 25, window - 24, window - 1, window, 3 * window + 7] {
            let storage = try StorageUnderTest(kind)
            let database = try newDatabase(version, in: storage.storage, random: FixedRandom([1, 2]))
            try Self.commit(database, 1)
            let before = try database.committedSize
            try Self.commitBytes(database, count: added - overhead)
            let length = try database.committedSize
            try #require(length - before == UInt64(added), "\(added)")

            let last = try #require(try readBytes(storage.storage, at: length - 1, count: 1).first)
            try writeBytes(storage.storage, [~last], at: length - 1)
            #expect(throws: XitDBError.untrustedRootHeader(lastVerified: before), "\(added)") {
                try Database(opening: storage.storage, hashSize: 20)
            }
            let recovered = try Database.recover(storage.storage)
            #expect(try recovered.committedSize == before, "\(added)")
            #expect(try storage.storage.length == before, "\(added)")
            try Self.expectCommit(recovered, 1, "\(added)")
        }
    }

    /// Recovery goes by the trailers alone, not by the root header. On a
    /// database whose root header is sound it rewrites only the root
    /// header, for the commit it already names. A transaction whose trailer
    /// reached the storage and whose root header did not, as a process
    /// that died between the two leaves it, lies past the committed size
    /// with a trailer that verifies: opening reads as of the root header,
    /// and recovery commits the transaction.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func recoveryGoesByTheTrailersAlone(kind: StorageKind, version: FormatVersion) throws {
        let subject = try Self.makeSubject(kind, version)
        let faulty = FaultInjectingStorage(subject.storage.storage)
        let recovered = try Database.recover(faulty, random: FixedRandom([Self.nextCommitID]))
        #expect(faulty.writeCount == 1)
        #expect(faulty.syncCount == 1)
        #expect(firstDifference(try subject.stored(), subject.after[3]) == nil)
        try Self.expectCommit(recovered, 3)

        // commit 2's root header, with commit 3's bytes after it
        let sizePosition = Int(subject.header.fileSizePosition)
        try subject.write(Array(subject.after[2][sizePosition..<(sizePosition + 8)]), at: UInt64(sizePosition))
        let opened = try subject.open()
        #expect(try opened.committedSize == subject.end(2))
        try Self.expectCommit(opened, 2)
        let adopted = try subject.recover()
        #expect(try adopted.committedSize == subject.end(3))
        #expect(firstDifference(try subject.stored(), subject.after[3]) == nil)
        try Self.expectCommit(adopted, 3)
    }
}
