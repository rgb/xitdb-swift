import Foundation
import Testing

@testable import XitDB

/// A database without a first commit (decision D31 item 4, the original's
/// `92a926e`): a header that reads and a committed size of zero. No bigger
/// than a new database, it is what a creation that did not finish left;
/// bigger, it is a full copy that did not finish. What each call does with
/// each, and with the states beside them, is the table the director
/// accepted for brief package-28.
///
/// Version 1 databases start from a file the original wrote at `6b93af1`.
@Suite struct FirstCommitTests {
    /// The bytes of a new database of a version: file ID 0x10, hash size
    /// 20.
    static func newBytes(_ version: FormatVersion) throws -> [UInt8] {
        let storage = MemoryStorage()
        _ = try newDatabase(version, in: storage)
        return storage.bytes
    }

    /// Where the committed size is in a file of a version.
    static func sizePosition(_ version: FormatVersion) -> Int {
        version == .one ? 29 : 24
    }

    /// What a creation that did not finish can leave, by how far it got,
    /// with what opening such a storage throws. The committed size is zero,
    /// or not there, in all of them.
    static func unfinishedCreations(
        _ version: FormatVersion
    ) throws -> [(what: String, bytes: [UInt8], opening: XitDBError)] {
        var bytes = try newBytes(version)
        let size = sizePosition(version)
        bytes.replaceSubrange(size..<(size + 8), with: zeros(8))
        let data = size + 8
        return [
            ("the database header alone", Array(bytes[..<20]), .endOfStream),
            ("cut inside the root header", Array(bytes[..<(size + 3)]), .endOfStream),
            ("both headers", Array(bytes[..<data]), .invalidDatabase),
            ("both headers and part of the trailer", Array(bytes[..<(data + 10)]), .invalidDatabase),
            (
                "both headers and the whole trailer", bytes,
                .untrustedRootHeader(lastVerified: UInt64(bytes.count))
            ),
        ]
    }

    /// A source with three moments, of a version, in memory.
    static func makeSource(_ version: FormatVersion) throws -> (storage: MemoryStorage, database: Database) {
        let storage = MemoryStorage()
        let database = try newDatabase(version, in: storage, random: FixedRandom(FormatVersionTests.commitIDs))
        for n in 1...3 {
            try FormatVersionTests.commit(database, UInt64(n))
        }
        return (storage, database)
    }

    /// A source with three moments of some three thousand bytes each, of
    /// a version, in memory: about ten thousand bytes, so that its commits
    /// lie across three of the 4096-byte blocks a sync writes its data in.
    static func makeLargeSource(_ version: FormatVersion) throws -> (storage: MemoryStorage, database: Database) {
        let storage = MemoryStorage()
        let database = try newDatabase(version, in: storage, random: FixedRandom(FormatVersionTests.commitIDs))
        for n in 1...3 {
            let history = try ArrayList<ReadWrite>(database.rootCursor)
            try history.append(.slot(try history.slot(at: -1))) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                try moment.put(.uint(UInt64(n)), forHash: sha1("n").bytes)
                try moment.put(.bytes([UInt8](repeating: UInt8(n), count: 3000)), forHash: sha1("large-\(n)").bytes)
            }
        }
        return (storage, database)
    }

    /// A replica with a commit of its own: file ID 77, the last moment
    /// holding 5.
    static func makeReplica(_ storage: any WritableStorage) throws -> Database {
        let replica = try Database(
            creating: storage, hashSize: 20, hashID: nil, fileID: 77, random: FixedRandom([0x7001, 0x7002, 0x7003]))
        try FormatVersionTests.commit(replica, 5)
        return replica
    }

    private struct Refused: Error, CustomStringConvertible {
        var description: String { "refused by the test" }
    }

    /// A source that throws on every read.
    private struct ThrowingSource: ByteSource {
        mutating func read(into buffer: inout MutableSpan<UInt8>) throws -> Int {
            throw Refused()
        }
    }

    /// A source that gives at most `piece` bytes per read: one, as a slow
    /// socket might, unless told otherwise.
    private struct PiecewiseSource: ByteSource {
        let bytes: [UInt8]
        var piece = 1
        var position = 0

        mutating func read(into buffer: inout MutableSpan<UInt8>) -> Int {
            let count = min(piece, bytes.count - position, buffer.count)
            for index in 0..<count {
                buffer[index] = bytes[position + index]
            }
            position += count
            return count
        }
    }

    static let noFirstCommit = ReplicaState(committedSize: 0, checksum: 0)

    // MARK: Creating

    /// Creating accepts what a creation that did not finish left, of either
    /// version and however far it got, and creates over it: the storage
    /// then holds exactly what creating in an empty storage leaves, a
    /// version 2 database with the file ID given.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func creatingCreatesOverACreationThatDidNotFinish(kind: StorageKind, version: FormatVersion) throws {
        let fresh = MemoryStorage()
        _ = try Database(creating: fresh, hashSize: 20, hashID: "sha2", fileID: 9)
        #expect(fresh.bytes.count == 57)

        for (what, bytes, _) in try Self.unfinishedCreations(version) {
            let subject = try StorageUnderTest(kind)
            try writeBytes(subject.storage, bytes, at: 0)
            let database = try Database(creating: subject.storage, hashSize: 20, hashID: "sha2", fileID: 9)
            #expect(database.header.version == 2, "\(what)")
            #expect(database.header.fileID == 9, "\(what)")
            #expect(database.header.hashID == "sha2", "\(what)")
            #expect(firstDifference(try FormatVersionTests.stored(subject), fresh.bytes) == nil, "\(what)")

            try FormatVersionTests.commit(database, 1)
            #expect(try FormatVersionTests.lastN(Database(opening: subject.storage)) == 1, "\(what)")
        }
    }

    /// Created over, the database has a new file ID unless one is given:
    /// the one the unfinished creation had is not kept.
    @Test(arguments: FormatVersion.allCases)
    func creatingOverDrawsANewFileID(version: FormatVersion) throws {
        for (what, bytes, _) in try Self.unfinishedCreations(version) {
            let random = FixedRandom([0xABCD, 0x1234])
            let database = try Database(
                creating: MemoryStorage(bytes: bytes), hashSize: 20, hashID: nil, fileID: nil, random: random)
            #expect(database.header.fileID == 0xABCD, "\(what)")
            #expect(random.remaining == 1, "\(what)")
            #expect(try Database(creating: MemoryStorage(bytes: bytes), hashSize: 20).header.fileID != 0x10, "\(what)")
        }
    }

    /// Creating refuses every other storage that holds bytes, and writes
    /// nothing: one cut inside the database header, a database with a
    /// commit, a full copy that did not finish, a database whose committed
    /// size fails its checks, and bytes that are no database.
    @Test(arguments: FormatVersion.allCases)
    func creatingRefusesEverythingElseAndWritesNothing(version: FormatVersion) throws {
        let new = try Self.newBytes(version)
        let size = Self.sizePosition(version)
        var zeroed = new
        zeroed.replaceSubrange(size..<(size + 8), with: zeros(8))
        var tooSmall = new
        tooSmall.replaceSubrange(size..<(size + 8), with: bigEndianBytes(10))
        var pastTheEnd = new
        pastTheEnd.replaceSubrange(size..<(size + 8), with: bigEndianBytes(UInt64(new.count + 1)))
        var damagedTrailer = new
        damagedTrailer[new.count - 1] ^= 1
        var wrongMagic = zeroed
        wrongMagic[0] ^= 0xFF
        var laterVersion = zeroed
        laterVersion[5] = 3
        let withCommits = try Self.makeSource(version).storage.bytes

        let refused: [(String, [UInt8])] = [
            ("one byte", [0x78]),
            ("cut inside the database header", Array(new[..<10])),
            ("a byte short of a database header", Array(new[..<19])),
            ("a new database", new),
            ("a database with commits", withCommits),
            ("no first commit, a byte longer than a new database", zeroed + [0]),
            ("no first commit, and longer", zeroed + [UInt8](repeating: 0xAA, count: 100)),
            ("a size below a new database's", tooSmall),
            ("a size past the end", pastTheEnd),
            ("a trailer that does not verify", damagedTrailer),
            ("zeros", zeros(100)),
            ("an unfinished creation with the wrong magic", wrongMagic),
            ("an unfinished creation of a later version", laterVersion),
        ]
        for (what, bytes) in refused {
            let storage = MemoryStorage(bytes: bytes)
            #expect(throws: XitDBError.storageNotEmpty, "\(what)") { try Database(creating: storage, hashSize: 20) }
            #expect(storage.bytes == bytes, "\(what)")
        }
    }

    /// An unfinished creation of a database with another hash size is not
    /// created over, as the original's `init` refuses it: the hash size is
    /// the error, and nothing is written. A hash size no header can hold is
    /// refused before the storage is touched, too.
    @Test(arguments: FormatVersion.allCases)
    func creatingOverAnotherHashSizeIsRefused(version: FormatVersion) throws {
        for (what, bytes, _) in try Self.unfinishedCreations(version) {
            for hashSize in [32, 8, 0, 65536, -1] {
                let storage = MemoryStorage(bytes: bytes)
                #expect(throws: XitDBError.invalidHashSize, "\(what), \(hashSize)") {
                    try Database(creating: storage, hashSize: hashSize)
                }
                #expect(storage.bytes == bytes, "\(what), \(hashSize)")
            }
        }
    }

    // MARK: Opening

    /// Opening never writes, so it does not create over an unfinished
    /// creation: it throws what it throws for such bytes, by how far the
    /// creation got, and leaves them. Where the first trailer is whole the
    /// error names it, and `recover` finishes the creation with the file ID
    /// the storage has.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func openingRefusesACreationThatDidNotFinish(kind: StorageKind, version: FormatVersion) throws {
        let new = try Self.newBytes(version)
        for (what, bytes, error) in try Self.unfinishedCreations(version) {
            let subject = try StorageUnderTest(kind)
            try writeBytes(subject.storage, bytes, at: 0)
            #expect(throws: error, "\(what)") { try Database(opening: subject.storage) }
            #expect(throws: error, "\(what)") { try Database(opening: subject.storage, hashSize: 20) }
            #expect(throws: XitDBError.invalidHashSize, "\(what)") {
                try Database(opening: subject.storage, hashSize: 32)
            }
            #expect(try FormatVersionTests.stored(subject) == bytes, "\(what)")

            if case .untrustedRootHeader = error {
                let recovered = try Database.recover(subject.storage)
                #expect(recovered.header.version == version.rawValue)
                #expect(recovered.header.fileID == newDatabaseFileID)
                #expect(try recovered.committedSize == UInt64(new.count))
                #expect(firstDifference(try FormatVersionTests.stored(subject), new) == nil)
            } else {
                // no trailer that verifies: no commit to recover to
                #expect(throws: XitDBError.invalidDatabase, "\(what)") { try Database.recover(subject.storage) }
                #expect(try FormatVersionTests.stored(subject) == bytes, "\(what)")
            }
        }

        // the whole trailer, damaged: no commit at all
        var damaged = new
        let size = Self.sizePosition(version)
        damaged.replaceSubrange(size..<(size + 8), with: zeros(8))
        damaged[damaged.count - 1] ^= 1
        #expect(throws: XitDBError.invalidDatabase) { try Database(opening: MemoryStorage(bytes: damaged)) }
        #expect(throws: XitDBError.invalidDatabase) { try Database.recover(MemoryStorage(bytes: damaged)) }
    }

    /// On a file opened read-only, opening throws as it does read-write, and
    /// creating fails at its first write, the file left as it was. The
    /// Zig-shaped init does what the original's does there: the file cannot
    /// be emptied, which cutting a read-only file does not report, so it
    /// comes back as a database without a first commit.
    @Test(arguments: FormatVersion.allCases)
    func onAReadOnlyFileAnUnfinishedCreationStays(version: FormatVersion) throws {
        for (what, bytes, error) in try Self.unfinishedCreations(version) {
            let directory = try TemporaryDirectory()
            let writer = try FileStorage(path: directory.path(), access: .create, durability: .none)
            try writeBytes(writer, bytes, at: 0)

            let plain = try FileStorage(path: directory.path(), access: .readOnly)
            let buffered = try BufferedFileStorage(path: directory.path(), access: .readOnly)
            for storage in [plain, buffered] as [any WritableStorage] {
                #expect(throws: error, "\(what)") { try Database(opening: storage) }
                #expect(throws: XitDBError.storageFailure(errno: EBADF), "\(what)") {
                    try Database(creating: storage, hashSize: 20)
                }
                #expect(try directory.contents() == bytes, "\(what)")

                let left = try Database(storage: storage, hashSize: 20)
                #expect(left.header.version == version.rawValue, "\(what)")
                #expect(left.header.fileID == newDatabaseFileID, "\(what)")
                #expect(try left.replicaState == Self.noFirstCommit, "\(what)")
                #expect(throws: XitDBError.self, "\(what)") { try left.committedSize }
                #expect(throws: XitDBError.self, "\(what)") { try left.rootCursor.slot }
                #expect(try directory.contents() == bytes, "\(what)")
            }
        }
    }

    /// The Zig-shaped init, which a compaction opens its target with,
    /// creates over an unfinished creation as the original's `init` does:
    /// version 2, the file ID given or one drawn. A hash size that is not
    /// the header's is refused first, and nothing is cut.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func theZigShapedInitCreatesOverACreationThatDidNotFinish(kind: StorageKind, version: FormatVersion) throws {
        let fresh = MemoryStorage()
        _ = try Database(storage: fresh, hashSize: 20, hashID: nil, fileID: 9, random: FixedRandom())
        for (what, bytes, _) in try Self.unfinishedCreations(version) {
            let subject = try StorageUnderTest(kind)
            try writeBytes(subject.storage, bytes, at: 0)
            #expect(throws: XitDBError.invalidHashSize, "\(what)") {
                try Database(storage: subject.storage, hashSize: 32, hashID: nil, fileID: 9, random: FixedRandom())
            }
            #expect(try FormatVersionTests.stored(subject) == bytes, "\(what)")

            let database = try Database(
                storage: subject.storage, hashSize: 20, hashID: nil, fileID: 9, random: FixedRandom())
            #expect(database.header.version == 2, "\(what)")
            #expect(firstDifference(try FormatVersionTests.stored(subject), fresh.bytes) == nil, "\(what)")

            let drawn = try Database(
                storage: MemoryStorage(bytes: bytes), hashSize: 20, hashID: nil, fileID: nil,
                random: FixedRandom([0xABCD]))
            #expect(drawn.header.fileID == 0xABCD, "\(what)")
        }
    }

    // MARK: A full copy that did not finish

    /// A sync from 0 whose source ends early leaves a database without a
    /// first commit: the source's header, a committed size of zero and the
    /// blocks of data that arrived whole. In the process that made it and
    /// opened again, its state is zero and zero, to which the source
    /// answers 0; everything else is `invalidDatabase`; the next sync from
    /// 0 replaces it. `recover`, on a copy of the same bytes, cuts back to
    /// the last commit of the source that those blocks hold whole, and the
    /// replica goes on from there.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func aFullCopyThatDidNotFinishOpensAndIsReplaced(kind: StorageKind, version: FormatVersion) throws {
        let (sourceStorage, source) = try Self.makeLargeSource(version)
        let committed = try source.committedSize
        let whole = try source.readCommitted(from: 0, to: committed)
        let ends = try Database.verifiedCommits(in: sourceStorage).map(\.end)
        try #require(ends.count == 5)
        let data = Int(source.header.dataStart)

        let subject = try StorageUnderTest(kind)
        let replica = try Self.makeReplica(subject.storage)
        // the connection ends seven bytes into the source's last commit,
        // inside the second block of the data: the first block arrived
        // whole, and holds the source's commits up to the first moment
        let arrived = Int(ends[3]) + 7
        let kept = data + 4096
        try #require(arrived > kept && arrived < kept + 4096)
        try #require(Int(ends[2]) < kept && Int(ends[3]) > kept)
        var short = ArrayByteSource(Array(whole[..<arrived]))
        #expect(throws: XitDBError.endOfStream) {
            try replica.applyReplicated(at: 0, from: &short, count: committed)
        }

        // what is left: the source's header, zeros up to the data, and the
        // one block of data that arrived whole
        let left = try FormatVersionTests.stored(subject)
        #expect(left.count == kept)
        #expect(Array(left[..<20]) == Array(whole[..<20]))
        #expect(Array(left[20..<data]) == zeros(data - 20))
        #expect(Array(left[data...]) == Array(whole[data..<kept]))

        func expectNoFirstCommit(_ database: Database, _ comment: Comment) throws {
            #expect(database.header == source.header, comment)
            #expect(try database.replicaState == Self.noFirstCommit, comment)
            #expect(try source.replicationStart(for: try database.replicaState) == 0, comment)
            #expect(throws: XitDBError.invalidDatabase, comment) { try database.committedSize }
            #expect(throws: XitDBError.invalidDatabase, comment) { try database.rootCursor.slot }
            #expect(throws: XitDBError.invalidDatabase, comment) {
                try ArrayList<ReadOnly>(database.rootCursor.readOnly).count
            }
            #expect(throws: XitDBError.invalidDatabase, comment) { try FormatVersionTests.lastN(database) }
            #expect(throws: XitDBError.invalidDatabase, comment) { try FormatVersionTests.commit(database, 9) }
            #expect(throws: XitDBError.invalidDatabase, comment) { try database.withTransaction { _ in } }
            #expect(throws: XitDBError.invalidDatabase, comment) { try database.snapshot() }
            #expect(throws: XitDBError.invalidDatabase, comment) {
                try database.replicationStart(for: try source.replicaState)
            }
            #expect(throws: XitDBError.invalidDatabase, comment) { try database.readCommitted(from: 0, to: ends[0]) }
            #expect(throws: XitDBError.invalidRange, comment) { try database.readCommitted(from: 5, to: 3) }
            #expect(throws: XitDBError.invalidDatabase, comment) {
                try database.applyReplicated(at: ends[3], bytes: Array(whole[Int(ends[3])...]))
            }
            let target = MemoryStorage()
            var offsets = MemoryOffsetMap()
            #expect(throws: XitDBError.invalidDatabase, comment) {
                try database.compact(into: target, offsetMap: &offsets)
            }
            #expect(target.bytes.isEmpty, comment)
            #expect(try FormatVersionTests.stored(subject) == left, comment)
        }
        try expectNoFirstCommit(replica, "in the process of the failed sync")

        let reopened = try Database(opening: subject.storage, hashSize: 20)
        try expectNoFirstCommit(reopened, "opened again")
        #expect(throws: XitDBError.invalidHashSize) { try Database(opening: subject.storage, hashSize: 32) }
        #expect(throws: XitDBError.storageNotEmpty) { try Database(creating: subject.storage, hashSize: 20) }
        try expectNoFirstCommit(
            try Database(storage: subject.storage, hashSize: 20), "opened by the Zig-shaped init")

        // recovering instead: the last commit of the source that the block
        // holds whole
        let copy = MemoryStorage(bytes: left)
        let recovered = try Database.recover(copy)
        #expect(try recovered.committedSize == ends[2])
        #expect(try FormatVersionTests.lastN(recovered) == 1)
        let next = try source.replicationStart(for: try recovered.replicaState)
        #expect(next == ends[2])
        try recovered.applyReplicated(at: next, bytes: try source.readCommitted(from: next, to: committed))
        #expect(firstDifference(copy.bytes, sourceStorage.bytes) == nil)

        // the next sync from 0 replaces it
        try reopened.applyReplicated(at: 0, bytes: whole)
        #expect(try reopened.committedSize == committed)
        #expect(try reopened.replicaState == (try source.replicaState))
        #expect(try FormatVersionTests.lastN(reopened) == 3)
        #expect(firstDifference(try FormatVersionTests.stored(subject), sourceStorage.bytes) == nil)
        #expect(try FormatVersionTests.lastN(Database(opening: subject.storage)) == 3)
    }

    /// A copy that stops inside its first block of data leaves the headers
    /// and nothing of the data, however much of the block had arrived, as
    /// the original does. That is what an unfinished creation leaves: the
    /// process that made it still has its state of zero and zero and can
    /// sync again, while opening the storage refuses it, and creating
    /// creates over it.
    @Test(arguments: FormatVersion.allCases, [1, 10, 4095])
    func aCopyThatStopsInItsFirstBlockLeavesWhatAnUnfinishedCreationLeaves(version: FormatVersion, arriving: Int)
        throws
    {
        let (sourceStorage, source) = try Self.makeLargeSource(version)
        let committed = try source.committedSize
        let whole = try source.readCommitted(from: 0, to: committed)
        let data = Int(source.header.dataStart)

        let storage = MemoryStorage()
        let replica = try Self.makeReplica(storage)
        var short = ArrayByteSource(Array(whole[..<(data + arriving)]))
        #expect(throws: XitDBError.endOfStream) {
            try replica.applyReplicated(at: 0, from: &short, count: committed)
        }
        #expect(storage.bytes == Array(whole[..<20]) + zeros(data - 20))
        #expect(replica.header == source.header)
        #expect(try replica.replicaState == Self.noFirstCommit)
        #expect(throws: XitDBError.invalidDatabase) { try replica.committedSize }

        #expect(throws: XitDBError.invalidDatabase) { try Database(opening: MemoryStorage(bytes: storage.bytes)) }
        let created = try Database(creating: MemoryStorage(bytes: storage.bytes), hashSize: 20, fileID: 3)
        #expect(created.header.version == 2)
        #expect(try created.committedSize == 57)

        try replica.applyReplicated(at: 0, bytes: whole)
        #expect(firstDifference(storage.bytes, sourceStorage.bytes) == nil)
    }

    /// The data of a copy reaches the storage in blocks of 4096 bytes,
    /// counted from where the data starts, each once all of it has arrived,
    /// as the original writes it. So a source that stops leaves the blocks
    /// before the one it stopped in and nothing of that one, whether it
    /// gave its bytes whole, one at a time, or in pieces that do not fit
    /// the blocks; and the last block, which is as long as what remains,
    /// is written when the last byte comes.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func aCopyKeepsTheBlocksThatArrivedWhole(kind: StorageKind, version: FormatVersion) throws {
        let (sourceStorage, source) = try Self.makeLargeSource(version)
        let committed = try source.committedSize
        let whole = try source.readCommitted(from: 0, to: committed)
        let data = Int(source.header.dataStart)
        // two whole blocks and a third that is shorter
        try #require(whole.count - data > 2 * 4096 + 1 && whole.count - data < 3 * 4096)

        // how much of the data arrives, and how many blocks of it are kept
        let stops: [(arriving: Int, blocks: Int)] = [
            (0, 0), (1, 0), (4095, 0), (4096, 1), (4097, 1), (8191, 1), (8192, 2), (8193, 2),
            (whole.count - data - 1, 2),
        ]
        for (arriving, blocks) in stops {
            for piece in [Int.max, 1, 1000] {
                let comment: Comment = "\(arriving) bytes of data, at most \(piece) at a time"
                let subject = try StorageUnderTest(kind)
                let replica = try Self.makeReplica(subject.storage)
                var short = PiecewiseSource(bytes: Array(whole[..<(data + arriving)]), piece: piece)
                #expect(throws: XitDBError.endOfStream, comment) {
                    try replica.applyReplicated(at: 0, from: &short, count: committed)
                }
                let left = try FormatVersionTests.stored(subject)
                let kept = data + blocks * 4096
                #expect(left.count == kept, comment)
                #expect(left == Array(whole[..<20]) + zeros(data - 20) + Array(whole[data..<kept]), comment)
                #expect(try replica.replicaState == Self.noFirstCommit, comment)

                var all = PiecewiseSource(bytes: whole, piece: piece)
                try replica.applyReplicated(at: 0, from: &all, count: committed)
                #expect(try replica.committedSize == committed, comment)
                #expect(firstDifference(try FormatVersionTests.stored(subject), sourceStorage.bytes) == nil, comment)
            }
        }
    }

    /// The same at the committed size: the blocks count from where the
    /// bytes start, the ones that arrived whole stay past the committed
    /// size, which does not move, and the next sync discards them.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func anAppendKeepsTheBlocksThatArrivedWhole(kind: StorageKind, version: FormatVersion) throws {
        let (sourceStorage, source) = try Self.makeLargeSource(version)
        let committed = try source.committedSize
        let ends = try Database.verifiedCommits(in: sourceStorage).map(\.end)
        // the replica has the source up to its empty history
        let from = ends[1]
        let tail = try source.readCommitted(from: from, to: committed)
        try #require(tail.count > 2 * 4096 + 1 && tail.count < 3 * 4096)

        let subject = try StorageUnderTest(kind)
        let replica = try Self.makeReplica(subject.storage)
        try replica.applyReplicated(at: 0, bytes: try source.readCommitted(from: 0, to: from))
        let before = try FormatVersionTests.stored(subject)
        #expect(before.count == Int(from))

        let stops: [(arriving: Int, blocks: Int)] = [
            (0, 0), (1, 0), (4095, 0), (4096, 1), (4097, 1), (8191, 1), (8192, 2), (tail.count - 1, 2),
        ]
        for (arriving, blocks) in stops {
            for piece in [Int.max, 1, 1000] {
                let comment: Comment = "\(arriving) bytes, at most \(piece) at a time"
                var short = PiecewiseSource(bytes: Array(tail[..<arriving]), piece: piece)
                #expect(throws: XitDBError.endOfStream, comment) {
                    try replica.applyReplicated(at: from, from: &short, count: UInt64(tail.count))
                }
                #expect(try replica.committedSize == from, comment)
                let left = try FormatVersionTests.stored(subject)
                #expect(left == before + Array(tail[..<(blocks * 4096)]), comment)
            }
        }

        var all = PiecewiseSource(bytes: tail, piece: 1000)
        try replica.applyReplicated(at: from, from: &all, count: UInt64(tail.count))
        #expect(try replica.committedSize == committed)
        #expect(firstDifference(try FormatVersionTests.stored(subject), sourceStorage.bytes) == nil)
    }

    /// The source's header is read and checked before the replica is
    /// touched: a count too small for a header, a source that ends or
    /// throws inside it, bytes that are no database or one of another hash
    /// size, and a count too small for the headers of the version the
    /// incoming header names each leave the replica exactly as it was.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func bytesThatAreNoDatabaseLeaveTheReplicaAsItWas(kind: StorageKind, version: FormatVersion) throws {
        let (_, source) = try Self.makeSource(version)
        let committed = try source.committedSize
        let whole = try source.readCommitted(from: 0, to: committed)
        let data = Int(source.header.dataStart)

        let subject = try StorageUnderTest(kind)
        let replica = try Self.makeReplica(subject.storage)
        let before = try FormatVersionTests.stored(subject)
        let headerBefore = replica.header
        let stateBefore = try replica.replicaState

        var wrongMagic = whole
        wrongMagic[1] ^= 0xFF
        var laterVersion = whole
        laterVersion[5] = 3
        var noVersion = whole
        noVersion[5] = 0
        let other = try Database(creating: MemoryStorage(), hashSize: 8)
        let otherHashSize = try other.readCommitted(from: 0, to: try other.committedSize)

        let fromArrays: [(String, [UInt8], XitDBError)] = [
            ("no bytes", [], .invalidRange),
            ("nineteen bytes", Array(whole[..<19]), .invalidRange),
            ("the wrong magic", wrongMagic, .invalidDatabase),
            ("a later version", laterVersion, .invalidVersion),
            ("version 0", noVersion, .invalidVersion),
            ("another hash size", otherHashSize, .invalidHashSize),
            ("the database header alone", Array(whole[..<20]), .invalidRange),
            ("a byte short of the headers", Array(whole[..<(data - 1)]), .invalidRange),
        ]
        func expectUntouched(_ comment: Comment) throws {
            #expect(try FormatVersionTests.stored(subject) == before, comment)
            #expect(replica.header == headerBefore, comment)
            #expect(try replica.replicaState == stateBefore, comment)
            #expect(try FormatVersionTests.lastN(replica) == 5, comment)
        }
        for (what, bytes, error) in fromArrays {
            #expect(throws: error, "\(what), from an array") { try replica.applyReplicated(at: 0, bytes: bytes) }
            try expectUntouched("\(what), from an array")
            var all = ArrayByteSource(bytes)
            #expect(throws: error, "\(what), from a source") {
                try replica.applyReplicated(at: 0, from: &all, count: UInt64(bytes.count))
            }
            try expectUntouched("\(what), from a source")
            var slow = PiecewiseSource(bytes: bytes)
            #expect(throws: error, "\(what), a byte at a time") {
                try replica.applyReplicated(at: 0, from: &slow, count: UInt64(bytes.count))
            }
            try expectUntouched("\(what), a byte at a time")
        }

        // a source that ends, or throws, inside the header it promised
        var ending = ArrayByteSource(Array(whole[..<10]))
        #expect(throws: XitDBError.endOfStream) { try replica.applyReplicated(at: 0, from: &ending, count: committed) }
        try expectUntouched("a source that ends inside the header")
        var refusing = ThrowingSource()
        #expect(throws: XitDBError.callerError(Refused())) {
            try replica.applyReplicated(at: 0, from: &refusing, count: committed)
        }
        try expectUntouched("a source that throws")

        // and the whole bytes replace it
        try replica.applyReplicated(at: 0, bytes: whole)
        #expect(replica.header == source.header)
        #expect(try FormatVersionTests.lastN(replica) == 3)
    }

    /// Past the header the replica is being replaced, so whatever stops
    /// the copy leaves a database without a first commit: a source that
    /// ends or throws inside the root header or the data, and bytes that
    /// do not end with a trailer, or end with a trailer of another file.
    /// The incoming root header's size is not read: bytes that stop short
    /// of it are told by their missing trailer.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func aCopyThatFailsPastTheHeaderLeavesNoFirstCommit(kind: StorageKind, version: FormatVersion) throws {
        let (_, source) = try Self.makeSource(version)
        let committed = try source.committedSize
        let whole = try source.readCommitted(from: 0, to: committed)
        let data = Int(source.header.dataStart)
        var otherFile = whole
        otherFile[19] ^= 1

        typealias Apply = (Database) throws -> Void
        let failures: [(String, XitDBError, Int, Apply)] = [
            (
                "a source that ends inside the root header", .endOfStream, data,
                { replica in
                    var source = ArrayByteSource(Array(whole[..<(data - 3)]))
                    try replica.applyReplicated(at: 0, from: &source, count: committed)
                }
            ),
            (
                "a source that ends inside the first block of the data", .endOfStream, data,
                { replica in
                    var source = PiecewiseSource(bytes: Array(whole[..<(data + 40)]))
                    try replica.applyReplicated(at: 0, from: &source, count: committed)
                }
            ),
            (
                "bytes a byte short, from an array", .invalidDatabase, whole.count - 1,
                { replica in try replica.applyReplicated(at: 0, bytes: Array(whole.dropLast())) }
            ),
            (
                "bytes a byte short, from a source", .invalidDatabase, whole.count - 1,
                { replica in
                    var source = ArrayByteSource(Array(whole.dropLast()))
                    try replica.applyReplicated(at: 0, from: &source, count: committed - 1)
                }
            ),
            (
                "the headers and nothing else", .invalidDatabase, data,
                { replica in try replica.applyReplicated(at: 0, bytes: Array(whole[..<data])) }
            ),
            (
                "a trailer of another file", .invalidDatabase, whole.count,
                { replica in try replica.applyReplicated(at: 0, bytes: otherFile) }
            ),
        ]
        for (what, error, length, apply) in failures {
            let subject = try StorageUnderTest(kind)
            let replica = try Self.makeReplica(subject.storage)
            #expect(throws: error, "\(what)") { try apply(replica) }
            let left = try FormatVersionTests.stored(subject)
            #expect(left.count == length, "\(what)")
            #expect(Array(left[20..<data]) == zeros(data - 20), "\(what)")
            #expect(replica.header.version == version.rawValue, "\(what)")
            #expect(replica.header.hashSize == 20, "\(what)")
            #expect(try replica.replicaState == Self.noFirstCommit, "\(what)")
            #expect(throws: XitDBError.invalidDatabase, "\(what)") { try replica.committedSize }

            try replica.applyReplicated(at: 0, bytes: whole)
            #expect(try FormatVersionTests.lastN(replica) == 3, "\(what)")
        }
    }

    /// A sync from 0 that fails before it has changed the storage leaves
    /// the database object as it was. On a storage opened read-only,
    /// cutting does nothing and the header's write is refused: the call
    /// throws the storage's error, and `header`, `replicaState` and a read
    /// through `rootCursor` are afterwards what they were before, though
    /// the bytes offered were a sound database of another file ID and, for
    /// one of them, another version. (The original takes the incoming
    /// header before it writes it.)
    @Test(arguments: FormatVersion.allCases)
    func aSyncFromZeroOntoAReadOnlyStorageLeavesTheDatabaseAsItWas(version: FormatVersion) throws {
        let (_, source) = try Self.makeSource(version)
        let committed = try source.committedSize
        let whole = try source.readCommitted(from: 0, to: committed)

        let directory = try TemporaryDirectory()
        let writer = try FileStorage(path: directory.path(), access: .create, durability: .none)
        _ = try Self.makeReplica(writer)
        let before = try directory.contents()

        let plain = try FileStorage(path: directory.path(), access: .readOnly)
        let buffered = try BufferedFileStorage(path: directory.path(), access: .readOnly)
        for storage in [plain, buffered] as [any WritableStorage] {
            let replica = try Database(opening: storage, hashSize: 20)
            let header = replica.header
            let state = try replica.replicaState
            #expect(header.fileID == 77)
            #expect(header.version == 2)
            #expect(try FormatVersionTests.lastN(replica) == 5)

            #expect(throws: XitDBError.storageFailure(errno: EBADF)) {
                try replica.applyReplicated(at: 0, bytes: whole)
            }
            var stream = ArrayByteSource(whole)
            #expect(throws: XitDBError.storageFailure(errno: EBADF)) {
                try replica.applyReplicated(at: 0, from: &stream, count: committed)
            }
            #expect(replica.header == header)
            #expect(try replica.replicaState == state)
            #expect(try replica.committedSize == state.committedSize)
            #expect(try FormatVersionTests.lastN(replica) == 5)
            #expect(try directory.contents() == before)
        }
    }

    /// A full copy does not take the source's bytes between the database
    /// header and the committed size: the replica has zeros there, whatever
    /// the source had. In version 1 that is the copy of the root slot,
    /// which `test.db` still has from the original that wrote it; in
    /// version 2 it is padding. Every other byte is the source's.
    @Test(arguments: StorageKind.allCases)
    func aFullCopyLeavesZerosBetweenTheHeaderAndTheSize(kind: StorageKind) throws {
        let fixture = try FixtureTests.load()
        #expect(Array(fixture[20..<29]) != zeros(9))
        var padded = try Self.makeSource(.two).storage.bytes
        padded.replaceSubrange(20..<24, with: [0xDE, 0xAD, 0xBE, 0xEF])

        for (bytes, size) in [(fixture, 29), (padded, 24)] {
            let source = try Database(opening: MemoryStorage(bytes: bytes), hashSize: 20)
            let committed = try source.committedSize
            let sent = try source.readCommitted(from: 0, to: committed)
            // what is sent is the file as it is
            #expect(sent == bytes)

            let subject = try StorageUnderTest(kind)
            let replica = try Self.makeReplica(subject.storage)
            var stream = ArrayByteSource(sent)
            try replica.applyReplicated(at: 0, from: &stream, count: committed)
            var expected = bytes
            expected.replaceSubrange(20..<size, with: zeros(size - 20))
            #expect(firstDifference(try FormatVersionTests.stored(subject), expected) == nil)
            #expect(try replica.readCommitted(from: 0, to: committed) == expected)
            #expect(try replica.replicaState == (try source.replicaState))
            #expect(replica.header == source.header)
            #expect(
                try StructureWalk.describe(replica.rootCursor.readOnly)
                    == StructureWalk.describe(source.rootCursor.readOnly))

            let again = try StorageUnderTest(kind)
            let fromArray = try Self.makeReplica(again.storage)
            try fromArray.applyReplicated(at: 0, bytes: sent)
            #expect(firstDifference(try FormatVersionTests.stored(again), expected) == nil)
        }
    }

    // MARK: Compaction

    /// A compaction opens its target as the original's does: what an
    /// unfinished creation left is created again and compacted into; a
    /// full copy that did not finish is no target, and is left as it is.
    @Test(arguments: FormatVersion.allCases)
    func compactionIntoAStorageWithoutAFirstCommit(version: FormatVersion) throws {
        let (_, source) = try Self.makeSource(.two)
        let expected = MemoryStorage()
        var offsets = MemoryOffsetMap()
        let first = try Self.makeSource(.two).database
        _ = try first.compact(into: expected, fileID: 0x20, offsetMap: &offsets)

        for (what, bytes, _) in try Self.unfinishedCreations(version) {
            let twin = try Self.makeSource(.two).database
            let target = MemoryStorage(bytes: bytes)
            let compacted = try twin.compact(into: target, fileID: 0x20, offsetMap: &offsets)
            #expect(compacted.header.version == 2, "\(what)")
            #expect(firstDifference(target.bytes, expected.bytes) == nil, "\(what)")
        }

        var zeroed = try Self.newBytes(version)
        let size = Self.sizePosition(version)
        zeroed.replaceSubrange(size..<(size + 8), with: zeros(8))
        let unfinishedCopy = zeroed + [UInt8](repeating: 0, count: 50)
        let target = MemoryStorage(bytes: unfinishedCopy)
        #expect(throws: XitDBError.invalidDatabase) {
            try source.compact(into: target, fileID: 0x20, offsetMap: &offsets)
        }
        #expect(target.bytes == unfinishedCopy)
    }
}
