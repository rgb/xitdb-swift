import Foundation
import Testing

@testable import XitDB

/// The two versions of the file format (decision D31): a database is
/// created as version 2, a version 1 file is read and written as version 1
/// and stays one, and the two differ in the root header alone. Version 1
/// keeps a copy of the root slot after the database header and its committed
/// size at 29, so its data starts at 37; version 2 keeps the committed size
/// alone, at 24, and its data starts at 32. Nothing reads the copy of the
/// root slot, and since the original's `bdaa55e` nothing writes it.
///
/// Nothing creates version 1 any more. The version 1 databases here start
/// from files the original wrote at `6b93af1`: a new database from the
/// conformance fixtures, and `test.db`, which the other ports share.
@Suite struct FormatVersionTests {
    static let commitIDs: [UInt64] = (1...40).map { 0x1000 + UInt64($0) }

    /// One commit: a new moment that holds what the moment before it held,
    /// `n` under "n" and a value of its own.
    static func commit(_ database: Database, _ n: UInt64) throws {
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            try moment.put(.uint(n), forHash: sha1("n").bytes)
            try moment.put(.bytes(Array("the value of commit \(n)".utf8)), forHash: sha1("key-\(n)").bytes)
        }
    }

    /// The number under "n" in the last moment.
    static func lastN(_ database: Database) throws -> UInt64? {
        let history = try ArrayList<ReadOnly>(database.rootCursor.readOnly)
        guard let cursor = try history.cursor(at: -1) else { return nil }
        return try HashMap<ReadOnly>(cursor).cursor(forHash: sha1("n").bytes)?.readUInt64()
    }

    static func stored(_ subject: StorageUnderTest) throws -> [UInt8] {
        try subject.storage.flush()
        return try subject.stored()
    }

    static func walk(_ database: Database) throws -> String {
        try StructureWalk.describe(database.rootCursor.readOnly)
    }

    // MARK: What a commit writes

    /// A database of either version keeps its version through every commit.
    /// A commit appends, and rewrites the eight bytes of the committed size
    /// where the version keeps them; every byte before them, the copy of the
    /// root slot in a version 1 file among them, and every byte committed
    /// earlier is left as it was.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func aDatabaseKeepsItsVersionAndACommitRewritesTheSizeAlone(kind: StorageKind, version: FormatVersion) throws {
        let subject = try StorageUnderTest(kind)
        let database = try newDatabase(version, in: subject.storage, random: FixedRandom(Self.commitIDs))
        let size = version == .one ? 29 : 24
        let data = size + 8
        #expect(database.header.version == version.rawValue)
        #expect(database.header.fileSizePosition == UInt64(size))
        #expect(database.header.dataStart == UInt64(data))

        let new = try Self.stored(subject)
        #expect(new.count == data + 25)
        #expect(try database.committedSize == UInt64(new.count))
        #expect(Array(new[4..<6]) == [0, UInt8(version.rawValue)])
        // between the database header and the size: an empty copy of the
        // root slot in version 1, four bytes of padding in version 2
        #expect(Array(new[20..<size]) == zeros(size - 20))
        #expect(Array(new[size..<data]) == bigEndianBytes(UInt64(new.count)))

        var previous = new
        for n in 1...5 {
            try Self.commit(database, UInt64(n))
            let bytes = try Self.stored(subject)
            #expect(bytes.count > previous.count, "commit \(n)")
            #expect(Array(bytes[..<size]) == Array(new[..<size]), "commit \(n)")
            #expect(Array(bytes[size..<data]) == bigEndianBytes(UInt64(bytes.count)), "commit \(n)")
            #expect(Array(bytes[data..<previous.count]) == Array(previous[data...]), "commit \(n)")
            #expect(try database.committedSize == UInt64(bytes.count), "commit \(n)")
            #expect(database.header.version == version.rawValue, "commit \(n)")
            previous = bytes
        }

        let reopened = try Database(opening: subject.storage, hashSize: 20)
        #expect(reopened.header.version == version.rawValue)
        #expect(reopened.header == database.header)
        #expect(try Self.lastN(reopened) == 5)
        #expect(try ArrayList<ReadOnly>(reopened.rootCursor.readOnly).count == 5)
    }

    /// The same commits on a database of each version leave the same data,
    /// every commit ending five bytes lower in the version 2 file, with the
    /// same commit ID.
    @Test func theTwoVersionsHoldTheSameDataFiveBytesApart() throws {
        let one = MemoryStorage()
        let two = MemoryStorage()
        let first = try newDatabase(.one, in: one, random: FixedRandom(Self.commitIDs))
        let second = try newDatabase(.two, in: two, random: FixedRandom(Self.commitIDs))
        for n in 1...6 {
            try Self.commit(first, UInt64(n))
            try Self.commit(second, UInt64(n))
            #expect(one.bytes.count == two.bytes.count + 5, "commit \(n)")
            #expect(try Self.walk(first) == Self.walk(second), "commit \(n)")
        }
        #expect(Array(one.bytes[..<4]) == Array(two.bytes[..<4]))
        #expect(Array(one.bytes[6..<20]) == Array(two.bytes[6..<20]))

        // the new database, the list's init, and the six moments
        let commitsOne = try Database.verifiedCommits(in: one)
        let commitsTwo = try Database.verifiedCommits(in: two)
        #expect(commitsOne.count == 8)
        #expect(commitsOne.map(\.commitID) == commitsTwo.map(\.commitID))
        #expect(commitsOne.map(\.end) == commitsTwo.map { $0.end + 5 })
        #expect(commitsOne.first?.end == 62)
        #expect(commitsTwo.first?.end == 57)
        #expect(commitsOne.last?.end == UInt64(one.bytes.count))
        #expect(commitsTwo.last?.end == UInt64(two.bytes.count))
    }

    /// `test.db` was written when the original still kept the copy of the
    /// root slot up to date: its copy names the root of its last commit. A
    /// commit by this implementation leaves the copy as it is, so it names
    /// the root before; the root is read from the trailer the committed
    /// size ends at, and a copy that is plain garbage changes nothing.
    @Test func theCopyOfTheRootSlotInAVersionOneFileIsNeitherReadNorWritten() throws {
        let fixture = try FixtureTests.load()
        let rootBefore = Slot(value: 4847, tag: .arrayList)
        #expect(try Slot(decoding: fixture.span, at: 20) == rootBefore)

        let storage = MemoryStorage(bytes: fixture)
        let database = try Database(opening: storage, hashSize: 20, random: FixedRandom([7]))
        #expect(database.header.version == 1)
        #expect(try database.rootCursor.slot == rootBefore)
        let walkBefore = try Self.walk(database)

        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            try HashMap<ReadWrite>(cursor).put(.bytes(Array("changed".utf8)), forHash: sha1("foo").bytes)
        }
        // written: the committed size, and what the commit appended
        #expect(Array(storage.bytes[..<29]) == Array(fixture[..<29]))
        #expect(Array(storage.bytes[29..<37]) == bigEndianBytes(UInt64(storage.bytes.count)))
        #expect(Array(storage.bytes[37..<fixture.count]) == Array(fixture[37...]))
        #expect(storage.bytes.count > fixture.count)

        let root = try database.rootCursor.slot
        #expect(root.tag == .arrayList)
        #expect(root != rootBefore)
        #expect(try Slot(decoding: storage.bytes.span, at: 20) == rootBefore)

        let reopened = try Database(opening: storage)
        #expect(reopened.header.version == 1)
        #expect(try reopened.rootCursor.slot == root)
        #expect(try ArrayList<ReadOnly>(reopened.rootCursor.readOnly).count == 3)
        let walkAfter = try Self.walk(reopened)
        #expect(walkAfter != walkBefore)

        var garbled = storage.bytes
        garbled.replaceSubrange(20..<29, with: [UInt8](repeating: 0xFF, count: 9))
        let other = try Database(opening: MemoryStorage(bytes: garbled))
        #expect(try other.rootCursor.slot == root)
        #expect(try Self.walk(other) == walkAfter)
    }

    /// Inside a transaction a write is checked from the first byte of
    /// committed data on, which is where the first commit's trailer is: 37
    /// in a version 1 file, 32 in a version 2 file. A position in the
    /// headers before it is not frozen data but a damaged pointer, which is
    /// reported elsewhere.
    @Test(arguments: FormatVersion.allCases)
    func aWriteIsCheckedFromTheFirstByteOfData(version: FormatVersion) throws {
        let database = try newDatabase(version, in: MemoryStorage(), random: FixedRandom(Self.commitIDs))
        let dataStart: UInt64 = version == .one ? 37 : 32
        try database.withTransaction { _ in
            for position in UInt64(0)..<dataStart {
                try database.checkPosition(position)
            }
            #expect(throws: XitDBError.immutableBytes) { try database.checkPosition(dataStart) }
            #expect(throws: XitDBError.immutableBytes) { try database.checkPosition(dataStart + 24) }
        }
    }

    // MARK: Compaction

    /// A compaction makes its target as any new database is made: version
    /// 2, whatever the source is. The source is left as it was.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func compactionMakesAVersionTwoTargetWhateverTheSource(kind: StorageKind, version: FormatVersion) throws {
        let subject = try StorageUnderTest(kind)
        let source = try newDatabase(version, in: subject.storage, random: FixedRandom(Self.commitIDs))
        for n in 1...4 {
            try Self.commit(source, UInt64(n))
        }
        let before = try Self.stored(subject)

        let targetSubject = try StorageUnderTest(kind)
        var offsets = MemoryOffsetMap()
        let target = try source.compact(into: targetSubject.storage, fileID: 0x20, offsetMap: &offsets)
        #expect(target.header.version == 2)
        #expect(target.header.hashSize == source.header.hashSize)
        #expect(target.header.hashID == source.header.hashID)
        #expect(target.header.fileID == 0x20)

        let bytes = try Self.stored(targetSubject)
        #expect(Array(bytes[4..<6]) == [0, 2])
        #expect(Array(bytes[20..<24]) == zeros(4))
        #expect(Array(bytes[24..<32]) == bigEndianBytes(UInt64(bytes.count)))
        #expect(try target.committedSize == UInt64(bytes.count))

        // the source's last moment is the target's only one
        #expect(try ArrayList<ReadOnly>(target.rootCursor.readOnly).count == 1)
        #expect(try Self.lastN(target) == 4)
        let sourceMoment = try #require(try ArrayList<ReadOnly>(source.rootCursor.readOnly).cursor(at: -1))
        let targetMoment = try #require(try ArrayList<ReadOnly>(target.rootCursor.readOnly).cursor(at: -1))
        #expect(try StructureWalk.describe(targetMoment) == StructureWalk.describe(sourceMoment))

        #expect(try Self.stored(subject) == before)
        #expect(source.header.version == version.rawValue)
        #expect(try Database(opening: targetSubject.storage, hashSize: 20).header.version == 2)
    }

    /// The target does not depend on the source's version: the same data in
    /// a version 1 source and a version 2 source compacts to the same bytes.
    @Test func theTargetsOfAVersionOneAndAVersionTwoSourceAreTheSameBytes() throws {
        var targets: [[UInt8]] = []
        for version in FormatVersion.allCases {
            let source = try newDatabase(version, in: MemoryStorage(), random: FixedRandom(Self.commitIDs))
            for n in 1...4 {
                try Self.commit(source, UInt64(n))
            }
            let target = MemoryStorage()
            var offsets = MemoryOffsetMap()
            _ = try source.compact(into: target, fileID: 0x20, offsetMap: &offsets)
            targets.append(target.bytes)
        }
        #expect(firstDifference(targets[0], targets[1]) == nil)
        #expect(targets[0][5] == 2)
    }

    // MARK: Replication

    /// The bytes from 0 are a complete database of the source's version:
    /// the file's own bytes with the committed size, where the version
    /// keeps it, set to the end asked for. Both forms of the call give
    /// them. A start inside the root header is refused, and the first byte
    /// after it, 37 or 32, is the first a range can start at.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func readCommittedFromZeroSetsTheSizeWhereTheVersionKeepsIt(kind: StorageKind, version: FormatVersion) throws {
        let subject = try StorageUnderTest(kind)
        let source = try newDatabase(version, in: subject.storage, random: FixedRandom(Self.commitIDs))
        for n in 1...3 {
            try Self.commit(source, UInt64(n))
        }
        let size = version == .one ? 29 : 24
        let data = UInt64(size + 8)
        let committed = try source.committedSize
        let stored = try Self.stored(subject)
        #expect(stored.count == Int(committed))

        let ends = try Database.verifiedCommits(in: subject.storage).map(\.end)
        #expect(ends.count == 5)
        #expect(ends.last == committed)
        for end in ends {
            var expected = Array(stored[..<Int(end)])
            expected.replaceSubrange(size..<(size + 8), with: bigEndianBytes(end))
            #expect(firstDifference(try source.readCommitted(from: 0, to: end), expected) == nil, "to \(end)")
            var sink = ArrayByteSink()
            try source.readCommitted(from: 0, to: end, into: &sink)
            #expect(firstDifference(sink.bytes, expected) == nil, "to \(end), through a sink")
            // and those bytes open, as the version they say
            let copy = try Database(opening: MemoryStorage(bytes: expected), hashSize: 20)
            #expect(copy.header.version == version.rawValue)
            #expect(try copy.committedSize == end)
        }

        for start in 1..<data {
            #expect(throws: XitDBError.invalidRange, "from \(start)") {
                try source.readCommitted(from: start, to: committed)
            }
            var sink = ArrayByteSink()
            #expect(throws: XitDBError.invalidRange, "from \(start), through a sink") {
                try source.readCommitted(from: start, to: committed, into: &sink)
            }
        }
        #expect(try source.readCommitted(from: data, to: committed) == Array(stored[Int(data)...]))
    }

    /// A replica replaced from 0 becomes the database it was sent, version
    /// included, whatever version it had; the syncs after it append to it
    /// as that version, and it stays one when it is opened again.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func aReplicaReplacedFromZeroTakesItsSourcesVersion(kind: StorageKind, version: FormatVersion) throws {
        let sourceSubject = try StorageUnderTest(kind)
        let source = try newDatabase(version, in: sourceSubject.storage, random: FixedRandom(Self.commitIDs))
        try Self.commit(source, 1)
        try Self.commit(source, 2)

        // a replica of the other version, with a commit of its own
        let other: FormatVersion = version == .one ? .two : .one
        let replicaSubject = try StorageUnderTest(kind)
        let replica = try newDatabase(other, in: replicaSubject.storage, random: FixedRandom([0x9001, 0x9002, 0x9003]))
        try Self.commit(replica, 77)
        #expect(replica.header.version == other.rawValue)

        let first = try source.committedSize
        #expect(try source.replicationStart(for: try replica.replicaState) == 0)
        try replica.applyReplicated(at: 0, bytes: try source.readCommitted(from: 0, to: first))
        #expect(replica.header.version == version.rawValue)
        #expect(replica.header == source.header)
        #expect(try replica.committedSize == first)
        #expect(try replica.replicaState == (try source.replicaState))
        #expect(try Self.lastN(replica) == 2)

        // what follows goes after the committed size, through a source
        try Self.commit(source, 3)
        let start = try source.replicationStart(for: try replica.replicaState)
        #expect(start == first)
        let end = try source.committedSize
        var bytes = ArrayByteSource(try source.readCommitted(from: start, to: end))
        try replica.applyReplicated(at: start, from: &bytes, count: end - start)
        #expect(replica.header.version == version.rawValue)
        #expect(try replica.committedSize == end)
        #expect(try Self.lastN(replica) == 3)
        #expect(try Self.walk(replica) == Self.walk(source))

        // the replica's bytes are the source's, the committed size where
        // the source's version keeps it
        let replicaBytes = try Self.stored(replicaSubject)
        #expect(firstDifference(replicaBytes, try Self.stored(sourceSubject)) == nil)
        let size = version == .one ? 29 : 24
        #expect(Array(replicaBytes[size..<(size + 8)]) == bigEndianBytes(end))

        let reopened = try Database(opening: replicaSubject.storage, hashSize: 20)
        #expect(reopened.header.version == version.rawValue)
        #expect(try Self.lastN(reopened) == 3)
    }

    // MARK: Snapshots

    /// A snapshot of a database of either version reads its commit while
    /// the writer goes on committing, and serves that commit's bytes as the
    /// database itself would have.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func aSnapshotReadsItsCommitInEitherVersion(kind: StorageKind, version: FormatVersion) throws {
        let subject = try StorageUnderTest(kind)
        let database = try newDatabase(version, in: subject.storage, random: FixedRandom(Self.commitIDs))
        try Self.commit(database, 1)
        try Self.commit(database, 2)
        let snapshot = try database.snapshot()
        #expect(snapshot.header.version == version.rawValue)
        #expect(snapshot.header == database.header)
        let committed = snapshot.committedSize
        #expect(committed == (try database.committedSize))
        let walk = try StructureWalk.describe(snapshot.rootCursor)
        #expect(walk == (try Self.walk(database)))
        let bytes = try database.readCommitted(from: 0, to: committed)

        for n in 3...6 {
            try Self.commit(database, UInt64(n))
        }
        #expect(try StructureWalk.describe(snapshot.rootCursor) == walk)
        #expect(try Self.walk(database) != walk)

        let reading = SnapshotDatabase(snapshot)
        #expect(reading.header.version == version.rawValue)
        #expect(try reading.replicaState.committedSize == committed)
        #expect(firstDifference(try reading.readCommitted(from: 0, to: committed), bytes) == nil)
        let data = database.header.dataStart
        #expect(try reading.readCommitted(from: data, to: committed) == Array(bytes[Int(data)...]))
        #expect(throws: XitDBError.invalidRange) { try reading.readCommitted(from: data - 1, to: committed) }
    }

    /// On a file, what a snapshot is told of is a write to any byte it
    /// reads. The committed size is the one thing below its own size it
    /// never reads from the file, and the one thing a commit rewrites: a
    /// write of those eight bytes leaves it alone, and a write of the byte
    /// before them or of the byte after them does not, in either version.
    @Test(arguments: [StorageKind.file, .bufferedFile], FormatVersion.allCases)
    func onlyTheCommittedSizeIsRewrittenUnderASnapshot(kind: StorageKind, version: FormatVersion) throws {
        let subject = try StorageUnderTest(kind)
        let database = try newDatabase(version, in: subject.storage, random: FixedRandom(Self.commitIDs))
        try Self.commit(database, 1)
        let size = database.header.fileSizePosition

        var snapshot = try database.snapshot()
        let walk = try StructureWalk.describe(snapshot.rootCursor)
        // the size's own eight bytes, written back as they are
        try writeBytes(subject.storage, try readBytes(subject.storage, at: size, count: 8), at: size)
        try subject.storage.flush()
        #expect(try StructureWalk.describe(snapshot.rootCursor) == walk)

        // the byte before the size and the byte after it, each written back
        // as it is: the file holds the same database, and the snapshot was
        // told all the same
        for position in [size - 1, size + 8] {
            snapshot = try database.snapshot()
            #expect(try StructureWalk.describe(snapshot.rootCursor) == walk)
            try writeBytes(subject.storage, try readBytes(subject.storage, at: position, count: 1), at: position)
            try subject.storage.flush()
            #expect(throws: XitDBError.snapshotOverwritten, "a write at \(position)") {
                try StructureWalk.describe(snapshot.rootCursor)
            }
            #expect(try Self.lastN(database) == 1)
        }
    }
}
