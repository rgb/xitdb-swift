import Foundation
import Testing
import XitDBHashing

@testable import XitDB

/// What a creation that did not finish leaves of a version 2 database: its
/// header, and a root header that is still empty.
private func unfinishedCreation(of database: [UInt8]) -> [UInt8] {
    Array(database[0..<20]) + zeros(12)
}

/// The hasher a database is given (decision D35, item 1): the two
/// initialisers and the recovery that take one, what they check and when,
/// who carries the hasher on, and the header read before opening that a
/// program chooses the hasher by.
///
/// Nothing public hashes a key at this point of the work, so the tests ask
/// the engine for a key's hash directly; the keyed calls of the collections
/// are tested where they are built.
@Suite struct KeyHasherTests {
    /// Keys of several lengths, the empty one and one longer than a hash
    /// block among them.
    static let keys: [[UInt8]] = [
        [], utf8("a"), utf8("name"), utf8("fruits"), [0, 0, 0], [UInt8](repeating: 0xE9, count: 200),
    ]

    /// Checks that `database` hashes every key as `hashing` does.
    static func expectHashes<Hashing: KeyHashing>(
        _ database: Database, as hashing: Hashing.Type, _ comment: Comment? = nil
    ) throws {
        for key in keys {
            let hash = try database.keyHash(of: key)
            #expect(hash.bytes == Hashing.keyHash(of: key), comment)
            #expect(hash.bytes == [UInt8](capacity: Hashing.size) { Hashing.hash(key.span, into: &$0) }, comment)
            #expect(hash.count == Hashing.size, comment)
        }
    }

    /// Checks that `database` was given no hasher.
    static func expectNoHasher(_ database: Database, _ comment: Comment? = nil) {
        for key in keys {
            #expect(throws: XitDBError.noKeyHashing, comment) { try database.keyHash(of: key) }
        }
    }

    /// One commit: a moment that holds 1 under the hash of "n", of whatever
    /// size the database's hashes are.
    static func commit(_ database: Database) throws {
        let hash = KeyHash([UInt8](repeating: 0x5A, count: Int(database.header.hashSize)))
        _ = try database.rootCursor.writePath([
            .arrayListInit, .arrayListAppend, .hashMapInit(), .hashMapGet(.value, hash), .write(.uint(1)),
        ])
    }

    // MARK: Creating

    /// The hash size of a database created with a hasher is the hasher's,
    /// and the file is the one creating with that size writes, byte for
    /// byte: nothing of the hasher but its size reaches the file.
    @Test(arguments: StorageKind.allCases)
    func creatingWithAHasherWritesWhatCreatingWithItsSizeWrites(kind: StorageKind) throws {
        func check<Hashing: KeyHashing>(_ hashing: Hashing.Type, hashID: HashID?) throws {
            let bySize = try StorageUnderTest(kind)
            let byHasher = try StorageUnderTest(kind)
            _ = try Database(creating: bySize.storage, hashSize: Hashing.size, hashID: hashID, fileID: 0x10)
            let database = try Database(creating: byHasher.storage, hashing: hashing, hashID: hashID, fileID: 0x10)
            try bySize.storage.flush()
            try byHasher.storage.flush()
            #expect(try byHasher.stored() == bySize.stored(), "\(hashing)")
            #expect(Int(database.header.hashSize) == Hashing.size, "\(hashing)")
            #expect(database.header.hashID == hashID ?? HashID(rawValue: 0), "\(hashing)")
            try Self.expectHashes(database, as: hashing, "\(hashing)")
        }
        try check(SHA256.self, hashID: "sha2")
        try check(Insecure.SHA1.self, hashID: "sha1")
        try check(TinyHash.self, hashID: nil)
        try check(WideHash.self, hashID: nil)
    }

    /// Left out, the file ID is random, as when creating with a size.
    @Test func creatingWithAHasherDrawsAFileID() throws {
        let first = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let second = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        #expect(first.header.fileID != second.header.fileID)
        #expect(first.header.hashID == HashID(rawValue: 0))
    }

    /// A hasher whose size no database can have is refused as that size
    /// is, and the storage stays empty.
    @Test func aHasherOfASizeNoDatabaseHasIsRefused() throws {
        let storage = MemoryStorage()
        #expect(throws: XitDBError.invalidHashSize) { try Database(creating: storage, hashing: ZeroHash.self) }
        #expect(throws: XitDBError.invalidHashSize) { try Database(creating: storage, hashing: OversizedHash.self) }
        #expect(storage.bytes.isEmpty)
    }

    /// Creating with a hasher accepts and refuses the storages creating
    /// with its size does: bytes that are a database are refused and left,
    /// an unfinished creation of the same hash size is created over, one of
    /// another hash size is refused and left.
    @Test func creatingWithAHasherTakesTheStoragesCreatingWithASizeTakes() throws {
        let full = MemoryStorage()
        _ = try Database(creating: full, hashing: Insecure.SHA1.self, hashID: "sha1", fileID: 1)
        let fullBytes = full.bytes
        #expect(throws: XitDBError.storageNotEmpty) { try Database(creating: full, hashing: Insecure.SHA1.self) }
        #expect(full.bytes == fullBytes)

        // A creation that stopped before its first commit.
        let unfinished = unfinishedCreation(of: fullBytes)
        let same = MemoryStorage(bytes: unfinished)
        let database = try Database(creating: same, hashing: Insecure.SHA1.self, hashID: "sha1", fileID: 1)
        #expect(same.bytes == fullBytes)
        try Self.expectHashes(database, as: Insecure.SHA1.self)

        let other = MemoryStorage(bytes: unfinished)
        #expect(throws: XitDBError.invalidHashSize) { try Database(creating: other, hashing: SHA256.self) }
        #expect(other.bytes == unfinished)
    }

    // MARK: Opening

    /// Opening with the hasher the database was created with opens it, on
    /// every storage, and the database hashes with it.
    @Test(arguments: StorageKind.allCases)
    func openingWithTheHasherOpens(kind: StorageKind) throws {
        func check<Hashing: KeyHashing>(_ hashing: Hashing.Type) throws {
            let subject = try StorageUnderTest(kind)
            try Self.commit(try Database(creating: subject.storage, hashing: hashing))
            let database = try Database(opening: subject.storage, hashing: hashing)
            #expect(try database.rootCursor.count == 1, "\(hashing)")
            try Self.expectHashes(database, as: hashing, "\(hashing)")
        }
        try check(SHA256.self)
        try check(Insecure.SHA1.self)
        try check(TinyHash.self)
        try check(WideHash.self)
    }

    /// A hasher of another size is refused with `invalidHashSize`, the
    /// error of a size stated as a number that is not the file's, as in
    /// the original, and the storage is as it was.
    @Test(arguments: StorageKind.allCases)
    func openingWithAHasherOfAnotherSizeIsRefused(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        try Self.commit(try Database(creating: subject.storage, hashing: Insecure.SHA1.self, hashID: "sha1"))
        try subject.storage.flush()
        let before = try subject.stored()

        #expect(throws: XitDBError.invalidHashSize) { try Database(opening: subject.storage, hashing: SHA256.self) }
        #expect(throws: XitDBError.invalidHashSize) { try Database(opening: subject.storage, hashing: TinyHash.self) }
        #expect(throws: XitDBError.invalidHashSize) { try Database(opening: subject.storage, hashing: WideHash.self) }
        #expect(throws: XitDBError.invalidHashSize) { try Database(opening: subject.storage, hashSize: 32) }
        try subject.storage.flush()
        #expect(try subject.stored() == before)

        // Only the size is checked: a hasher of the same size opens,
        // whatever the header's hash ID says.
        let database = try Database(opening: subject.storage, hashing: ShortDigestHash.self)
        #expect(database.header.hashID == "sha1")
    }

    /// The hasher's size is checked once the header has been read and
    /// before the root header is: on a database whose root header cannot
    /// be trusted, a hasher of another size is what is reported, and the
    /// right one reports the root header.
    @Test(arguments: FormatVersion.allCases)
    func theHashersSizeIsCheckedBeforeTheRootHeader(version: FormatVersion) throws {
        let subject = try ExplicitRecoveryTests.makeSubject(.memory, version)
        try subject.write(bigEndianBytes(subject.end(3) + 1), at: subject.header.fileSizePosition)
        let storage = subject.storage.storage

        #expect(throws: XitDBError.invalidHashSize) { try Database(opening: storage, hashing: SHA256.self) }
        #expect(throws: XitDBError.untrustedRootHeader(lastVerified: subject.end(3))) {
            try Database(opening: storage, hashing: Insecure.SHA1.self)
        }
    }

    /// What opening with no stated size refuses, opening with a hasher
    /// refuses with the same error: no storage is opened for the hasher's
    /// sake.
    @Test func openingWithAHasherRefusesWhatOpeningRefuses() throws {
        #expect(throws: XitDBError.invalidDatabase) {
            try Database(opening: MemoryStorage(), hashing: SHA256.self)
        }
        #expect(throws: XitDBError.invalidDatabase) {
            try Database(opening: MemoryStorage(bytes: [UInt8](repeating: 0x41, count: 64)), hashing: SHA256.self)
        }
        let created = MemoryStorage()
        _ = try Database(creating: created, hashing: SHA256.self)
        var future = created.bytes
        future[5] = 3
        #expect(throws: XitDBError.invalidVersion) {
            try Database(opening: MemoryStorage(bytes: future), hashing: SHA256.self)
        }
        #expect(throws: XitDBError.invalidDatabase) {
            try Database(opening: MemoryStorage(bytes: unfinishedCreation(of: created.bytes)), hashing: SHA256.self)
        }
    }

    /// A version 1 database opens with a hasher as a version 2 one does.
    @Test func aVersionOneDatabaseOpensWithAHasher() throws {
        let storage = MemoryStorage(bytes: try fixtureFile("inputs/v1-history.db"))
        let database = try Database(opening: storage, hashing: Insecure.SHA1.self)
        #expect(database.header.version == 1)
        try Self.expectHashes(database, as: Insecure.SHA1.self)
        #expect(throws: XitDBError.invalidHashSize) { try Database(opening: storage, hashing: SHA256.self) }
    }

    // MARK: No hasher

    /// A database made with a hash size alone, or with none stated, was
    /// given no hasher, and neither were its snapshots, the databases over
    /// them, the target a compaction makes from it, or a database
    /// recovered without one.
    @Test func aDatabaseGivenNoHasherHashesNothing() throws {
        let storage = MemoryStorage()
        let created = try Database(creating: storage, hashSize: 20, hashID: "sha1")
        try Self.commit(created)
        Self.expectNoHasher(created, "created with a size")
        Self.expectNoHasher(try Database(opening: storage, hashSize: 20), "opened with a size")
        Self.expectNoHasher(try Database(opening: storage), "opened with no size")
        Self.expectNoHasher(try Database(storage: storage, hashSize: 20), "opened as the original opens")
        Self.expectNoHasher(try Database.recover(storage), "recovered")

        let snapshot = try created.snapshot()
        Self.expectNoHasher(SnapshotDatabase(snapshot).engine, "a snapshot's database")
        Self.expectNoHasher(snapshot.rootCursor.engine, "a snapshot's root cursor")

        var offsets = MemoryOffsetMap()
        Self.expectNoHasher(try created.compact(into: MemoryStorage(), offsetMap: &offsets), "a compaction's target")
    }

    #if os(macOS) || os(Linux)
        /// A hasher that appends more bytes than its size has a mistake no
        /// file can cause, and stops the program: in the database when the
        /// hasher returns, or at the append that does not fit where the hash
        /// is longer than the engine keeps inline, and by hand at the append.
        /// Each runs in a process of its own, which is not there on iOS.
        @Test func aHasherThatAppendsTooMuchStopsTheProgram() async {
            await #expect(processExitsWith: .failure) {
                let database = try Database(creating: MemoryStorage(), hashing: GreedyHash.self)
                _ = try database.keyHash(of: utf8("name"))
            }
            await #expect(processExitsWith: .failure) {
                let database = try Database(creating: MemoryStorage(), hashing: GreedyWideHash.self)
                _ = try database.keyHash(of: utf8("name"))
            }
            await #expect(processExitsWith: .failure) {
                _ = GreedyHash.keyHash(of: "name")
            }
            // The same calls with a hasher that keeps its word come back.
            await #expect(processExitsWith: .success) {
                let database = try Database(creating: MemoryStorage(), hashing: TinyHash.self)
                _ = try database.keyHash(of: utf8("name"))
                _ = TinyHash.keyHash(of: "name")
            }
        }
    #endif

    /// A hasher that gives fewer bytes than its size is not caught when it
    /// is given: the hash is what it gave, which the collection it goes to
    /// refuses as it refuses any hash of the wrong size.
    @Test func aHashersDigestIsTakenAsItComes() throws {
        let database = try Database(creating: MemoryStorage(), hashing: ShortDigestHash.self)
        #expect(database.header.hashSize == 20)
        let hash = try database.keyHash(of: utf8("name"))
        #expect(hash.bytes == ShortDigestHash.keyHash(of: utf8("name")))
        #expect(hash.bytes == mixedDigest(utf8("name"), count: 3))
        #expect(hash.count == 3)
    }

    /// The same where the hash is longer than the engine keeps inline:
    /// sixty-five bytes promised and three given make a hash of three, by
    /// the database and by hand, and a map refuses it.
    @Test func aLongHashThatComesShortIsTakenAsItComes() throws {
        let database = try Database(creating: MemoryStorage(), hashing: ShortWideHash.self)
        #expect(database.header.hashSize == 65)
        let hash = try database.keyHash(of: utf8("name"))
        #expect(hash.count == 3)
        #expect(hash.bytes == mixedDigest(utf8("name"), count: 3))
        #expect(ShortWideHash.keyHash(of: "name") == mixedDigest(utf8("name"), count: 3))
        // A wide hasher that keeps its word, beside it: all sixty-five.
        let wide = try Database(creating: MemoryStorage(), hashing: WideHash.self)
        #expect(try wide.keyHash(of: utf8("name")).count == 65)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        #expect(throws: XitDBError.invalidHashSize) { try map.put(.uint(1), forKey: "name") }
    }

    // MARK: Who carries the hasher on

    /// A snapshot carries the hasher: the database over it hashes as the
    /// one it was taken from, and so does every snapshot made from that
    /// one's cursors, of the root or of a collection inside it, and the
    /// database a read-only cursor makes again when its own has gone.
    @Test(arguments: StorageKind.allCases)
    func aSnapshotCarriesTheHasher(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(creating: subject.storage, hashing: SHA256.self, hashID: "sha2")
        try Self.commit(database)

        let snapshot = try database.snapshot()
        let reading = SnapshotDatabase(snapshot)
        try Self.expectHashes(reading.engine, as: SHA256.self, "a snapshot's database")
        try Self.expectHashes(snapshot.rootCursor.engine, as: SHA256.self, "a snapshot's root cursor")
        try Self.expectHashes(SnapshotDatabase(reading.snapshot()).engine, as: SHA256.self, "its own snapshot")

        // A collection inside the commit, found through the live database
        // and through the snapshot.
        let liveMoment = try #require(try Cursor<ReadOnly>(viewing: database.rootCursor).readPath([.arrayListGet(-1)]))
        try Self.expectHashes(
            try Snapshot(liveMoment).rootCursor.engine, as: SHA256.self, "a live cursor's collection")
        let pinnedMoment = try #require(try snapshot.rootCursor.readPath([.arrayListGet(-1)]))
        try Self.expectHashes(
            try Snapshot(pinnedMoment).rootCursor.engine, as: SHA256.self, "a snapshot cursor's collection")

        // A cursor read from a snapshot whose database was never kept:
        // the database it gives is made again from its engine.
        let orphan = try #require(try snapshot.rootCursor.readPath([.arrayListGet(-1)]))
        let remade = try #require(orphan.database as? SnapshotDatabase)
        try Self.expectHashes(remade.engine, as: SHA256.self, "a database made again from a cursor")
        try Self.expectHashes(remade.snapshot().rootCursor.engine, as: SHA256.self, "and its snapshot")
    }

    /// A snapshot crosses to another task with its hasher.
    @Test func aSnapshotsHasherCrossesTasks() async throws {
        let database = try Database(creating: MemoryStorage(), hashing: Insecure.SHA1.self)
        try Self.commit(database)
        let snapshot = try database.snapshot()
        let hashes = try await Task.detached {
            let reading = SnapshotDatabase(snapshot)
            return try Self.keys.map { try reading.engine.keyHash(of: $0).bytes }
        }.value
        #expect(hashes == Self.keys.map { Insecure.SHA1.keyHash(of: $0) })
    }

    /// The target a compaction makes holds its source's hasher, whether
    /// the source is the live database or a snapshot's. A target the
    /// caller opened keeps what it was opened with.
    @Test(arguments: FormatVersion.allCases)
    func aCompactionsTargetTakesItsSourcesHasher(version: FormatVersion) throws {
        let storage = MemoryStorage()
        _ = try newDatabase(version, in: storage)
        let source = try Database(opening: storage, hashing: Insecure.SHA1.self)
        try Self.commit(source)

        var offsets = MemoryOffsetMap()
        let target = try source.compact(into: MemoryStorage(), offsetMap: &offsets)
        try Self.expectHashes(target, as: Insecure.SHA1.self, "from the live database")
        #expect(try target.rootCursor.count == 1)

        let fromSnapshot = try SnapshotDatabase(try source.snapshot())
            .compact(into: MemoryStorage(), offsetMap: &offsets)
        try Self.expectHashes(fromSnapshot, as: Insecure.SHA1.self, "from a snapshot's database")

        // Over what a creation that did not finish left, the target is
        // created again, with the hasher.
        let unfinished = MemoryStorage(bytes: unfinishedCreation(of: try target.storageBytes()))
        let createdOver = try source.compact(into: unfinished, offsetMap: &offsets)
        try Self.expectHashes(createdOver, as: Insecure.SHA1.self, "created over an unfinished creation")

        // A database that exists and has an empty root is opened, with the
        // hasher.
        let existing = MemoryStorage()
        _ = try Database(creating: existing, hashSize: 20)
        let opened = try source.compact(into: existing, offsetMap: &offsets)
        try Self.expectHashes(opened, as: Insecure.SHA1.self, "an existing database with an empty root")

        let plain = try Database(creating: MemoryStorage(), hashSize: 20)
        try source.compact(into: plain, offsetMap: &offsets)
        Self.expectNoHasher(plain, "a target opened without a hasher")

        let own = try Database(creating: MemoryStorage(), hashing: ShortDigestHash.self)
        try source.compact(into: own, offsetMap: &offsets)
        #expect(try own.keyHash(of: utf8("name")).count == 3, "a target opened with a hasher of its own")
    }

    /// A replica replaced by a sync from 0 goes on hashing with the hasher
    /// it was opened with.
    @Test func aReplicaKeepsItsHasherThroughASyncFromZero() throws {
        let source = try Database(creating: MemoryStorage(), hashing: Insecure.SHA1.self, hashID: "sha1")
        try Self.commit(source)
        let replica = try Database(creating: MemoryStorage(), hashing: Insecure.SHA1.self)
        let bytes = try source.readCommitted(from: 0, to: try source.committedSize)
        try replica.applyReplicated(at: 0, bytes: bytes)
        #expect(replica.header == source.header)
        try Self.expectHashes(replica, as: Insecure.SHA1.self)
    }

    // MARK: Recovering

    /// Recovering with a hasher does what recovering does, to the byte,
    /// and the database it returns holds the hasher.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func recoveringWithAHasherRecoversAndKeepsIt(kind: StorageKind, version: FormatVersion) throws {
        let subject = try ExplicitRecoveryTests.makeSubject(kind, version)
        try subject.write(bigEndianBytes(subject.end(3) + 1), at: subject.header.fileSizePosition)

        let database = try Database.recover(subject.storage.storage, hashing: Insecure.SHA1.self)
        #expect(try subject.stored() == subject.after[3])
        try ExplicitRecoveryTests.expectCommit(database, 3)
        try Self.expectHashes(database, as: Insecure.SHA1.self)
    }

    /// Recovering with a hasher keeps to a root header that is sound, as
    /// recovering does, and goes by the trailers alone when it is asked to.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func recoveringWithAHasherKeepsToASoundRootHeaderUnlessAskedNotTo(kind: StorageKind, version: FormatVersion) throws
    {
        let kept = try ExplicitRecoveryTests.makeSubject(kind, version)
        try ExplicitRecoveryTests.setTheRootHeaderBack(kept, to: 2)
        let database = try Database.recover(kept.storage.storage, hashing: Insecure.SHA1.self)
        #expect(try kept.stored() == kept.after[2])
        try ExplicitRecoveryTests.expectCommit(database, 2)
        try Self.expectHashes(database, as: Insecure.SHA1.self)

        let asked = try ExplicitRecoveryTests.makeSubject(kind, version)
        try ExplicitRecoveryTests.setTheRootHeaderBack(asked, to: 2)
        let adopted = try Database.recover(
            asked.storage.storage, hashing: Insecure.SHA1.self, ignoringRootHeader: true)
        #expect(try asked.stored() == asked.after[3])
        try ExplicitRecoveryTests.expectCommit(adopted, 3)
        try Self.expectHashes(adopted, as: Insecure.SHA1.self)
    }

    /// A hasher of another size is refused before anything is cut: the
    /// damaged storage is as it was, bytes past the last commit included.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func recoveringWithAHasherOfAnotherSizeCutsNothing(kind: StorageKind, version: FormatVersion) throws {
        let subject = try ExplicitRecoveryTests.makeSubject(kind, version)
        // What a process that died left past the last commit, and a
        // committed size that names it.
        try subject.write([UInt8](repeating: 0xEE, count: 40), at: subject.end(3))
        try subject.write(bigEndianBytes(subject.end(3) + 40), at: subject.header.fileSizePosition)
        let damaged = try subject.stored()

        #expect(throws: XitDBError.invalidHashSize) {
            try Database.recover(subject.storage.storage, hashing: SHA256.self)
        }
        #expect(try subject.stored() == damaged)

        _ = try Database.recover(subject.storage.storage, hashing: Insecure.SHA1.self)
        #expect(try subject.stored() == subject.after[3])
    }

    /// Recovering with a hasher refuses what recovering refuses.
    @Test func recoveringWithAHasherRefusesWhatRecoveringRefuses() throws {
        #expect(throws: XitDBError.invalidDatabase) {
            try Database.recover(MemoryStorage(), hashing: SHA256.self)
        }
        // A header and no trailer that verifies.
        let created = MemoryStorage()
        _ = try Database(creating: created, hashing: SHA256.self)
        let headers = MemoryStorage(bytes: unfinishedCreation(of: created.bytes))
        #expect(throws: XitDBError.invalidDatabase) { try Database.recover(headers, hashing: SHA256.self) }
        #expect(headers.bytes == unfinishedCreation(of: created.bytes))
    }

    // MARK: The engine's own doors

    /// Every way into a database that takes a hasher holds it to the hash
    /// size: the initialisers the public ones and the compaction go
    /// through refuse a hasher of another size before they write.
    @Test func noDoorLetsAHasherOfAnotherSizeIn() throws {
        let sha256 = KeyHasher(SHA256.self)
        func random() -> RandomSource { RandomSource(FixedRandom([1, 2, 3])) }

        let empty = MemoryStorage()
        #expect(throws: XitDBError.invalidHashSize) {
            try Database(creating: empty, hashSize: 20, hashID: nil, fileID: nil, random: random(), hasher: sha256)
        }
        #expect(throws: XitDBError.invalidHashSize) {
            try Database(storage: empty, hashSize: 20, random: random(), hasher: sha256)
        }
        #expect(empty.bytes.isEmpty)

        // What a creation that did not finish left is not cut for a hasher
        // that is then refused.
        let created = MemoryStorage()
        _ = try Database(creating: created, hashSize: 20)
        let left = unfinishedCreation(of: created.bytes)
        let unfinished = MemoryStorage(bytes: left)
        #expect(throws: XitDBError.invalidHashSize) {
            try Database(storage: unfinished, hashSize: 20, random: random(), hasher: sha256)
        }
        #expect(throws: XitDBError.invalidHashSize) {
            try Database(creating: unfinished, hashSize: 20, hashID: nil, fileID: nil, random: random(), hasher: sha256)
        }
        #expect(unfinished.bytes == left)

        let existing = MemoryStorage()
        _ = try Database(creating: existing, hashSize: 20)
        let before = existing.bytes
        #expect(throws: XitDBError.invalidHashSize) {
            try Database(opening: existing, hashSize: nil, random: random(), hasher: sha256)
        }
        #expect(throws: XitDBError.invalidHashSize) {
            try Database(opening: existing, hashSize: 20, random: random(), hasher: sha256)
        }
        #expect(throws: XitDBError.invalidHashSize) {
            try Database(storage: existing, hashSize: nil, random: random(), hasher: sha256)
        }
        #expect(throws: XitDBError.invalidHashSize) {
            try Database(storage: existing, hashSize: 20, random: random(), hasher: sha256)
        }
        #expect(throws: XitDBError.invalidHashSize) {
            try Database.recover(existing, random: random(), hasher: sha256)
        }
        #expect(existing.bytes == before)

        let sha1 = KeyHasher(Insecure.SHA1.self)
        try Self.expectHashes(
            try Database(storage: existing, hashSize: nil, random: random(), hasher: sha1), as: Insecure.SHA1.self)
        try Self.expectHashes(
            try Database(storage: MemoryStorage(), hashSize: 20, random: random(), hasher: sha1),
            as: Insecure.SHA1.self)
    }
}

/// The header read before a database is opened, which a program picks the
/// hasher by.
@Suite struct HeaderReadingTests {
    /// The header read from a storage is the one the open database has, on
    /// every storage and for both format versions, and reading it writes
    /// nothing.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func theHeaderReadIsTheDatabases(kind: StorageKind, version: FormatVersion) throws {
        let subject = try StorageUnderTest(kind)
        let database = try newDatabase(version, in: subject.storage)
        try KeyHasherTests.commit(database)
        try subject.storage.flush()
        let before = try subject.stored()

        let header = try DatabaseHeader(reading: subject.storage)
        #expect(header == database.header)
        #expect(header.version == version.rawValue)
        #expect(header.hashSize == 20)
        #expect(header.hashID == "sha1")
        #expect(header.fileID == newDatabaseFileID)
        try subject.storage.flush()
        #expect(try subject.stored() == before)
    }

    /// The use it is for: the hasher is chosen by the file's hash size,
    /// held as a value, and passed as it is.
    @Test func aHasherChosenByTheHeaderOpensTheDatabase() throws {
        func make<Hashing: KeyHashing>(_ hashing: Hashing.Type) throws -> MemoryStorage {
            let storage = MemoryStorage()
            try KeyHasherTests.commit(try Database(creating: storage, hashing: hashing))
            return storage
        }
        for (storage, size) in [(try make(Insecure.SHA1.self), 20), (try make(SHA256.self), 32)] {
            let header = try DatabaseHeader(reading: storage)
            #expect(Int(header.hashSize) == size)
            let hashing: any KeyHashing.Type = header.hashSize == 20 ? Insecure.SHA1.self : SHA256.self
            let database = try Database(opening: storage, hashing: hashing)
            let hash = try database.keyHash(of: utf8("name")).bytes
            if size == 20 {
                #expect(hash == Insecure.SHA1.keyHash(of: "name"))
            } else {
                #expect(hash == SHA256.keyHash(of: "name"))
            }
            let recovered = try Database.recover(storage, hashing: hashing)
            #expect(try recovered.keyHash(of: utf8("name")).bytes == hash)
            let created = try Database(creating: MemoryStorage(), hashing: hashing)
            #expect(Int(created.header.hashSize) == size)
        }
    }

    /// The header reads from a file opened for reading only, and from a
    /// storage that holds no more than a header: nothing past the twenty
    /// bytes is looked at, so a header that reads says nothing about
    /// whether the database opens.
    @Test func onlyTheHeaderIsRead() throws {
        let directory = try TemporaryDirectory()
        let writable = try FileStorage(path: directory.path(), access: .create, durability: .none)
        let database = try Database(creating: writable, hashing: SHA256.self, hashID: "sha2", fileID: 9)
        let readOnly = try FileStorage(path: directory.path(), access: .readOnly, durability: .none)
        #expect(try DatabaseHeader(reading: readOnly) == database.header)

        let whole = try directory.contents()
        let headerAlone = MemoryStorage(bytes: Array(whole[0..<20]))
        #expect(try DatabaseHeader(reading: headerAlone) == database.header)
        #expect(throws: XitDBError.endOfStream) { try Database(opening: headerAlone) }

        // Damage past the header does not show.
        var damaged = whole
        for index in 20..<damaged.count { damaged[index] = 0xFF }
        #expect(try DatabaseHeader(reading: MemoryStorage(bytes: damaged)) == database.header)

        // One read of the storage, at its start.
        let counting = FaultInjectingStorage(MemoryStorage(bytes: whole))
        _ = try DatabaseHeader(reading: counting)
        #expect(counting.readCount == 1)
        #expect(counting.writeCount == 0)
    }

    /// What is no header is refused as opening refuses it.
    @Test func whatIsNoHeaderIsRefused() throws {
        let created = MemoryStorage()
        _ = try Database(creating: created, hashSize: 20, hashID: "sha1", fileID: 1)
        let good = Array(created.bytes[0..<20])

        #expect(throws: XitDBError.invalidDatabase) { try DatabaseHeader(reading: MemoryStorage()) }
        for count in [1, 3, 19] {
            #expect(throws: XitDBError.endOfStream, "\(count) bytes") {
                try DatabaseHeader(reading: MemoryStorage(bytes: Array(good[0..<count])))
            }
        }
        for index in 0..<3 {
            var bytes = good
            bytes[index] ^= 0x20
            #expect(throws: XitDBError.invalidDatabase, "magic byte \(index)") {
                try DatabaseHeader(reading: MemoryStorage(bytes: bytes))
            }
        }
        for version: UInt8 in [0, 3, 0xFF] {
            var bytes = good
            bytes[5] = version
            #expect(throws: XitDBError.invalidVersion, "version \(version)") {
                try DatabaseHeader(reading: MemoryStorage(bytes: bytes))
            }
        }
        // A storage that says it holds bytes and reads none.
        let silent = FaultInjectingStorage(MemoryStorage(bytes: good), faults: [.readNothing(0..<20)])
        #expect(throws: XitDBError.invalidDatabase) { try DatabaseHeader(reading: silent) }
    }

    /// A storage's own failure is passed on.
    @Test func aStoragesFailureIsPassedOn() throws {
        #expect(throws: XitDBError.storageFailure(errno: EIO)) { try DatabaseHeader(reading: FailingStorage()) }
    }
}

/// A storage whose every read fails.
private struct FailingStorage: ReadableStorage {
    func read(into buffer: inout MutableSpan<UInt8>, range: Range<Int>, at offset: UInt64) throws(XitDBError) -> Int {
        throw .storageFailure(errno: EIO)
    }

    var length: UInt64 {
        get throws(XitDBError) { 100 }
    }
}

extension Database {
    /// The bytes of a database in memory, for a test that starts another
    /// storage from them.
    fileprivate func storageBytes() throws -> [UInt8] {
        try readCommitted(from: 0, to: try committedSize)
    }
}
