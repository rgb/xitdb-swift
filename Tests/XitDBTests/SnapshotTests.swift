import Foundation
import Testing

@testable import XitDB

/// A storage of the caller's own: a memory storage behind the protocol, so
/// that the engine sees no built-in class and takes the copying fallback.
final class WrappedStorage: WritableStorage {
    let inner = MemoryStorage()

    func read(into buffer: inout MutableSpan<UInt8>, range: Range<Int>, at offset: UInt64) throws(XitDBError) -> Int {
        try inner.read(into: &buffer, range: range, at: offset)
    }
    var length: UInt64 { get throws(XitDBError) { try inner.length } }
    func write(_ bytes: Span<UInt8>, at offset: UInt64) throws(XitDBError) { try inner.write(bytes, at: offset) }
    func truncate(to length: UInt64) throws(XitDBError) { try inner.truncate(to: length) }
    func flush() throws(XitDBError) {}
    func sync(_ point: SyncPoint) throws(XitDBError) {}
}

/// The snapshot of one commit (D25): what it reads, what it costs the
/// writer, what it refuses, and when a file rewritten under it says so.
@Suite struct SnapshotTests {
    static let storageKinds = StorageKind.allCases

    /// A database with a hash map at its root, on a storage of one kind.
    private struct Fixture {
        let subject: StorageUnderTest
        let database: Database

        init(_ kind: StorageKind) throws {
            subject = try StorageUnderTest(kind)
            database = try Database(
                storage: subject.storage, hashSize: 20, hashID: nil, fileID: 7,
                random: FixedRandom((1...400).map { UInt64($0) }))
            _ = try database.rootCursor.writePath([.hashMapInit()])
        }

        /// Writes `value` under `key` in the root map, one transaction.
        func put(_ key: String, _ value: UInt64) throws {
            try HashMap<ReadWrite>(database.rootCursor).put(.uint(value), forHash: sha1(key).bytes)
        }

        /// The number under `key` in the last commit, or nil.
        func value(_ key: String) throws -> UInt64? {
            try HashMap<ReadOnly>(database.rootCursor).cursor(forHash: sha1(key).bytes)?.readUInt64()
        }
    }

    /// The number under `key` in a snapshot's root map, or nil.
    private static func value(_ key: String, in snapshot: Snapshot) throws -> UInt64? {
        try HashMap<ReadOnly>(snapshot.rootCursor).cursor(forHash: sha1(key).bytes)?.readUInt64()
    }

    /// Opens a database of its own over the snapshot and reads the value.
    private static func value(_ key: String, readingFresh snapshot: Snapshot) throws -> UInt64? {
        try HashMap<ReadOnly>(Database(reading: snapshot).rootCursor).cursor(forHash: sha1(key).bytes)?.readUInt64()
    }

    func requireSendable<T: Sendable>(_: T.Type) {}

    // MARK: What a snapshot reads

    @Test(arguments: storageKinds)
    func aSnapshotReadsTheCommitItWasTakenAtWhateverTheWriterDoesNext(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        try fixture.put("a", 1)
        try fixture.put("b", 2)
        let size = try fixture.database.committedSize

        let snapshot = try fixture.database.snapshot()
        requireSendable(Snapshot.self)
        #expect(snapshot.committedSize == size)
        #expect(snapshot.header == fixture.database.header)

        // The writer goes on: new keys, a changed key, and enough commits
        // to grow the storage well past the snapshot's size.
        try fixture.put("a", 10)
        try fixture.put("c", 3)
        for round in 0..<40 {
            try fixture.put("round", UInt64(round))
        }
        #expect(try fixture.value("a") == 10)
        #expect(try fixture.database.committedSize > size)

        #expect(try Self.value("a", in: snapshot) == 1)
        #expect(try Self.value("b", in: snapshot) == 2)
        #expect(try Self.value("c", in: snapshot) == nil)
        #expect(try Self.value("round", in: snapshot) == nil)
        #expect(try Self.value("a", readingFresh: snapshot) == 1)
        #expect(snapshot.committedSize == size)

        // Its database has the pinned size and says so without reading.
        let reading = Database(reading: snapshot)
        #expect(try reading.committedSize == size)
        #expect(try reading.snapshot().committedSize == size)
        #expect(try Self.value("b", in: try reading.snapshot()) == 2)
    }

    @Test(arguments: storageKinds)
    func aSnapshotInsideATransactionPinsTheLastCommit(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        try fixture.put("a", 1)
        let size = try fixture.database.committedSize
        var taken: Snapshot?

        func body(_ cursor: inout Cursor<ReadWrite>) throws {
            let map = try HashMap<ReadWrite>(cursor)
            try map.put(.uint(2), forHash: sha1("a").bytes)
            try map.put(.uint(3), forHash: sha1("inside").bytes)
            taken = try fixture.database.snapshot()
            // It does not see the transaction's own work.
            #expect(try Self.value("a", in: taken!) == 1)
            #expect(try Self.value("inside", in: taken!) == nil)
        }
        try fixture.database.withTransaction(body)

        let snapshot = try #require(taken)
        #expect(snapshot.committedSize == size)
        #expect(try Self.value("a", in: snapshot) == 1)
        #expect(try fixture.value("a") == 2)
    }

    @Test(arguments: storageKinds)
    func iteratorsAndByteReadersReadThroughASnapshot(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let text = Array("a value long enough to be a record of its own, well past the short slot".utf8)
        try HashMap<ReadWrite>(fixture.database.rootCursor).put(.bytes(text), forHash: sha1("text").bytes)
        try fixture.put("n", 5)
        let snapshot = try fixture.database.snapshot()
        try fixture.put("n", 6)
        try HashMap<ReadWrite>(fixture.database.rootCursor).put(.bytes([1, 2, 3]), forHash: sha1("text").bytes)

        let map = try HashMap<ReadOnly>(snapshot.rootCursor)
        let textCursor = try #require(try map.cursor(forHash: sha1("text").bytes))
        #expect(try textCursor.readBytes() == text)
        var reader = try textCursor.reader()
        #expect(try reader.readRemaining() == text)

        var iterator = try map.iterator()
        var count = 0
        while let entry = try iterator.next() {
            count += 1
            _ = try entry.readEntry()
        }
        #expect(count == 2)
    }

    // MARK: What it refuses

    @Test(arguments: storageKinds)
    func everyWriteThroughASnapshotsDatabaseIsRefusedBeforeAnythingIsDone(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        try fixture.put("a", 1)
        let snapshot = try fixture.database.snapshot()
        let before = try wholeStorage(fixture.subject.storage)
        let reading = Database(reading: snapshot)

        func transaction(_ cursor: inout Cursor<ReadWrite>) throws {
            _ = try cursor.writePath([.hashMapInit()])
        }
        #expect(throws: XitDBError.cursorNotWritable) { try reading.withTransaction(transaction) }
        #expect(throws: XitDBError.cursorNotWritable) { try reading.rootCursor.writePath([.hashMapInit()]) }
        #expect(throws: XitDBError.cursorNotWritable) { try HashMap<ReadWrite>(reading.rootCursor) }
        #expect(throws: XitDBError.cursorNotWritable) { try ArrayList<ReadWrite>(reading.rootCursor) }
        #expect(throws: XitDBError.cursorNotWritable) {
            var root = reading.rootCursor
            try root.writeBytes { writer in try writer.write([1, 2, 3]) }
        }
        #expect(throws: XitDBError.cursorNotWritable) { try reading.applyReplicated(at: 0, bytes: [1, 2, 3]) }
        #expect(throws: XitDBError.cursorNotWritable) {
            try reading.applyReplicated(at: try reading.committedSize, bytes: [1, 2, 3])
        }
        #expect(throws: XitDBError.cursorNotWritable) { try reading.freeze() }

        // The write-mode collections can be wrapped around a read cursor
        // and refuse at their first write too.
        let value = try #require(try HashMap<ReadOnly>(snapshot.rootCursor).cursor(forHash: sha1("a").bytes))
        #expect(throws: XitDBError.cursorNotWritable) {
            try Cursor<ReadWrite>(viewing: value).writePath([.write(.uint(2))])
        }

        #expect(try wholeStorage(fixture.subject.storage) == before)
        #expect(try Self.value("a", in: snapshot) == 1)
        #expect(try fixture.value("a") == 1)
    }

    // MARK: Sub-collections

    @Test(arguments: storageKinds)
    func aCursorReadFromASnapshotBecomesASnapshotOfThatCollection(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(
            storage: subject.storage, hashSize: 20, hashID: nil, fileID: 7,
            random: FixedRandom((1...400).map { UInt64($0) }))
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        for moment in 1...3 {
            func body(_ cursor: inout Cursor<ReadWrite>) throws {
                let map = try HashMap<ReadWrite>(cursor)
                try map.put(.uint(UInt64(moment)), forHash: sha1("value").bytes)
            }
            try history.append(.slot(nil), body)
        }

        let snapshot = try database.snapshot()
        let moments = try ArrayList<ReadOnly>(snapshot.rootCursor)
        let second = try Snapshot(try #require(try moments.cursor(at: 1)))
        #expect(second.committedSize == snapshot.committedSize)
        #expect(try Self.value("value", in: second) == 2)
        // Reading nothing, it cannot fail; a snapshot of it is itself.
        #expect(try Database(reading: second).snapshot().committedSize == second.committedSize)

        // The writer goes on; the sub-collection snapshot does not move.
        func body(_ cursor: inout Cursor<ReadWrite>) throws {
            try HashMap<ReadWrite>(cursor).put(.uint(99), forHash: sha1("value").bytes)
        }
        try history.append(.slot(nil), body)
        #expect(try Self.value("value", in: second) == 2)

        // A cursor of the live database, made outside a transaction, works
        // the same way: its data is committed.
        let live = try Snapshot(try #require(try history.cursor(at: 3)))
        #expect(try Self.value("value", in: live) == 99)
        #expect(live.committedSize == (try database.committedSize))

        // A cursor pointing at the transaction's own work is refused: that
        // data is in no commit yet. A cursor at committed data, read in the
        // same body, is not, and a slot that holds its value passes.
        func running(_ cursor: inout Cursor<ReadWrite>) throws {
            let map = try HashMap<ReadWrite>(cursor)
            try map.put(.uint(7), forHash: sha1("value").bytes)
            try map.put(.bytes(Array(repeating: 9, count: 40)), forHash: sha1("blob").bytes)
            guard let blob = try map.cursor(forHash: sha1("blob").bytes),
                let inside = try map.cursor(forHash: sha1("value").bytes)
            else {
                Issue.record("the values written in the transaction are not there")
                return
            }
            #expect(throws: XitDBError.staleCursor) { try Snapshot(blob) }
            // The map's own cursor points at the block the init wrote here;
            // the body's cursor variable still holds the slot set to nothing
            // it was handed, which passes as a value.
            #expect(throws: XitDBError.staleCursor) { try Snapshot(map.cursor.readOnly) }
            #expect(try Snapshot(cursor.readOnly).root.tag == .none)
            #expect(try Snapshot(inside).rootCursor.readUInt64() == 7)
            let earlier = try Snapshot(try #require(try history.cursor(at: 3)))
            #expect(try Self.value("value", in: earlier) == 99)
        }
        try history.append(.slot(nil), running)
        #expect(try Self.value("value", in: try Snapshot(try #require(try history.cursor(at: 4)))) == 7)

        // A cursor from a transaction that did not commit is refused.
        struct NotNow: Error {}
        var unfinished: Cursor<ReadOnly>?
        func failing(_ cursor: inout Cursor<ReadWrite>) throws {
            let map = try HashMap<ReadWrite>(cursor)
            try map.put(.uint(5), forHash: sha1("value").bytes)
            unfinished = try map.cursor(forHash: sha1("value").bytes)
            throw NotNow()
        }
        #expect(throws: NotNow.self) { try history.append(.slot(nil), failing) }
        #expect(throws: XitDBError.staleCursor) { try Snapshot(try #require(unfinished)) }
    }

    // MARK: Maintenance served from a snapshot

    @Test(arguments: storageKinds)
    func compactionAndReplicationAreServedFromASnapshotDatabase(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(
            storage: subject.storage, hashSize: 20, hashID: nil, fileID: 7,
            random: FixedRandom((1...400).map { UInt64($0) }))
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        for moment in 1...3 {
            func body(_ cursor: inout Cursor<ReadWrite>) throws {
                let map = try HashMap<ReadWrite>(cursor)
                try map.put(.uint(UInt64(moment)), forHash: sha1("value").bytes)
                try map.put(.bytes(Array(repeating: UInt8(moment), count: 40)), forHash: sha1("blob").bytes)
            }
            try history.append(.slot(nil), body)
        }
        let snapshot = try database.snapshot()
        let committed = try database.readCommitted(from: 0, to: try database.committedSize)
        let state = try database.replicaState
        // The writer goes on; the snapshot's database still serves the commit.
        func body(_ cursor: inout Cursor<ReadWrite>) throws {
            try HashMap<ReadWrite>(cursor).put(.uint(99), forHash: sha1("value").bytes)
        }
        try history.append(.slot(nil), body)

        let reading = Database(reading: snapshot)
        #expect(try reading.readCommitted(from: 0, to: snapshot.committedSize) == committed)
        #expect(try reading.replicaState == state)

        // Compaction from the snapshot's database: the last moment of the
        // commit, as compacting the live database at that commit would give.
        var offsets = MemoryOffsetMap()
        let compacted = try reading.compact(into: MemoryStorage(), offsetMap: &offsets)
        let compactedWalk = try StructureWalk.describe(compacted.rootCursor.readOnly)
        #expect(compactedWalk.contains("uint(3)"))
        #expect(!compactedWalk.contains("uint(99)"))

        // A compaction into a snapshot's database is refused first.
        var more = MemoryOffsetMap()
        #expect(throws: XitDBError.cursorNotWritable) { try database.compact(into: reading, offsetMap: &more) }

        // A sub-collection snapshot serves the commit's bytes to replication
        // and refuses compaction.
        let moments = try ArrayList<ReadOnly>(snapshot.rootCursor)
        let second = try Snapshot(try #require(try moments.cursor(at: 1)))
        let partial = Database(reading: second)
        #expect(try partial.readCommitted(from: 0, to: second.committedSize) == committed)
        #expect(try partial.replicaState == state)
        var third = MemoryOffsetMap()
        #expect(throws: XitDBError.subCollectionSnapshot) {
            try partial.compact(into: MemoryStorage(), offsetMap: &third)
        }
        #expect(throws: XitDBError.cursorNotWritable) { try partial.freeze() }
        #expect(throws: XitDBError.cursorNotWritable) {
            var root = partial.rootCursor
            try root.writeIfEmpty(.uint(1))
        }
    }

    @Test(arguments: [StorageKind.file, .bufferedFile])
    func aSnapshotReadsOnAfterAnotherFileIsRenamedOverIts(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        try fixture.put("a", 1)
        let path = try #require(fixture.subject.path)
        let snapshot = try fixture.database.snapshot()

        // Another database, written to a file beside it, renamed over the path.
        let directory = (path as NSString).deletingLastPathComponent
        let otherPath = (directory as NSString).appendingPathComponent("other.db")
        do {
            let other = try Database(
                creating: try FileStorage(path: otherPath, access: .create, durability: .none), hashSize: 20)
            try HashMap<ReadWrite>(other.rootCursor).put(.uint(2), forHash: sha1("a").bytes)
        }
        #expect(rename(otherPath, path) == 0)

        // The snapshot holds the old file through its descriptor; a storage
        // opened on the path now reads the other database.
        #expect(try Self.value("a", in: snapshot) == 1)
        let reopened = try Database(opening: try FileStorage(path: path, access: .readOnly))
        #expect(try HashMap<ReadOnly>(reopened.rootCursor).cursor(forHash: sha1("a").bytes)?.readUInt64() == 2)
    }

    // MARK: Memory and custom storages

    @Test func inMemoryTheWriterCopiesOnceAndTheSnapshotKeepsItsBytes() throws {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashSize: 20)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put(.uint(1), forHash: sha1("a").bytes)
        let snapshot = try database.snapshot()
        let frozen = Array(storage.bytes[..<Int(snapshot.committedSize)])

        try map.put(.uint(2), forHash: sha1("a").bytes)
        try database.applyReplicated(at: 0, bytes: frozen)  // a sync from zero, back to the same bytes
        try map.put(.uint(3), forHash: sha1("a").bytes)

        #expect(try Self.value("a", in: snapshot) == 1)
        #expect(try HashMap<ReadOnly>(database.rootCursor).cursor(forHash: sha1("a").bytes)?.readUInt64() == 3)
        // The snapshot's bytes are the commit's, whatever the storage holds now.
        #expect(try readBytes(snapshot.storage, at: 0, count: Int(snapshot.committedSize)) == frozen)
        #expect(try readBytes(snapshot.storage, at: snapshot.committedSize, count: 10) == [])
    }

    @Test func aStorageOfTheCallersOwnIsCopied() throws {
        let storage = WrappedStorage()
        let database = try Database(creating: storage, hashSize: 20)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put(.uint(1), forHash: sha1("a").bytes)
        let snapshot = try database.snapshot()
        guard case .bytes(let copy) = snapshot.storage.source else {
            Issue.record("a custom storage's snapshot is not a copy")
            return
        }
        #expect(UInt64(copy.count) == snapshot.committedSize)

        try map.put(.uint(2), forHash: sha1("a").bytes)
        #expect(try Self.value("a", in: snapshot) == 1)
    }

    // MARK: Files

    @Test(arguments: [StorageKind.file, .bufferedFile, .bufferedFileSmallWindow])
    func aSyncFromZeroOnAFileInvalidatesTheSnapshotsTakenBefore(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        try fixture.put("a", 1)
        let snapshot = try fixture.database.snapshot()
        let map = try HashMap<ReadOnly>(snapshot.rootCursor)
        #expect(try map.cursor(forHash: sha1("a").bytes)?.readUInt64() == 1)

        // Another database's bytes, replicated from zero over this one.
        let other = try Database(creating: MemoryStorage(), hashSize: 20)
        try HashMap<ReadWrite>(other.rootCursor).put(.uint(7), forHash: sha1("b").bytes)
        let replica = try other.readCommitted(from: 0, to: try other.committedSize)
        try fixture.database.applyReplicated(at: 0, bytes: replica)
        #expect(try fixture.value("b") == 7)

        // Every read through the old snapshot now refuses, a held collection's too.
        #expect(throws: XitDBError.snapshotOverwritten) { try Self.value("a", in: snapshot) }
        #expect(throws: XitDBError.snapshotOverwritten) { try map.cursor(forHash: sha1("a").bytes) }
        #expect(throws: XitDBError.snapshotOverwritten) {
            try readBytes(snapshot.storage, at: 0, count: 8)
        }

        // A snapshot taken after the sync reads the new database, and a
        // further sync invalidates it in turn and not the first one twice.
        let after = try fixture.database.snapshot()
        #expect(try Self.value("b", in: after) == 7)
        try fixture.database.applyReplicated(at: 0, bytes: replica)
        #expect(throws: XitDBError.snapshotOverwritten) { try Self.value("b", in: after) }
    }

    @Test(arguments: [StorageKind.file, .bufferedFile])
    func aWriteBelowTheCommittedSizeThroughTheStorageInvalidatesToo(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        try fixture.put("a", 1)
        let snapshot = try fixture.database.snapshot()

        // The commit's own root header rewrite is not an overwrite: the
        // snapshot reads on after further commits.
        try fixture.put("a", 2)
        #expect(try Self.value("a", in: snapshot) == 1)

        // A caller's own write into committed bytes is, once it reaches the
        // file: a buffered storage holds it in its window until it flushes.
        try writeBytes(fixture.subject.storage, [0xFF], at: 40)
        try fixture.subject.storage.flush()
        #expect(throws: XitDBError.snapshotOverwritten) { try Self.value("a", in: snapshot) }
    }

    // MARK: Across tasks

    @Test(arguments: storageKinds)
    func tasksReadOneSnapshotWhileTheWriterCommits(kind: StorageKind) async throws {
        let fixture = try Fixture(kind)
        try fixture.put("a", 1)
        try fixture.put("b", 1)
        let snapshot = try fixture.database.snapshot()

        let mismatches = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    var mismatches = 0
                    for _ in 0..<200 {
                        let map = try HashMap<ReadOnly>(snapshot.rootCursor)
                        let a = try map.cursor(forHash: sha1("a").bytes)?.readUInt64()
                        let b = try map.cursor(forHash: sha1("b").bytes)?.readUInt64()
                        if a != 1 || b != 1 { mismatches += 1 }
                    }
                    return mismatches
                }
            }
            // The writer, on this task, meanwhile.
            for round in 2...60 {
                try fixture.put("a", UInt64(round))
                try fixture.put("b", UInt64(round))
            }
            return try await group.reduce(0, +)
        }
        #expect(mismatches == 0)
        #expect(try fixture.value("a") == 60)
    }
}
