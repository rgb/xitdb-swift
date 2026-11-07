import Testing

@testable import XitDB

// A port of Zig's test "replication" (`src/test.zig`, lines 3757 to 3835) with the functions it calls:
// `testReplication` (lines 3966 to 4111), `testRoots` (lines 4113 to 4366) and `testReplicaOfOtherFile` (lines
// 3837 to 3915), and their helpers `readCommittedBytes`, `replicate`, `expectAppendOnlyAndReplicate` and
// `expectSameCommittedBytes` (lines 3917 to 3964), through the public API.
//
// Zig runs `testReplication` and `testRoots` for a memory source and replica, a file source and replica, and a
// buffered-file source and replica (lines 3761 to 3832), and `testReplicaOfOtherFile` once, over memory databases.
// Here the first two take the storage kind as the test's argument and run for every kind the storages under test
// come in, with the source and the replica of the same kind as Zig has them; the compacted databases inside them
// are over memory, as Zig's are whatever the kind. `testReplicaOfOtherFile` is over memory storages, as Zig has it.
//
// The comments inside the tests are Zig's. Zig's `clearStorage` of the source and the replica at the start of a
// block is a new storage of each kind here, and reopening a database (`DB.init(replica_opts)` over the same file)
// is a new `Database` over the same storage. Zig's `std.Io.Writer.Allocating` as the sink of `readCommitted` is
// `CollectingSink` here (the streaming path, as Zig's; the array convenience is the edge tests' and the conformance
// runner's) and its `std.Io.Reader.fixed` over the written bytes an `ArrayByteSource`; `std.Io.Writer.Discarding` is
// `DiscardingSink` below. Zig's `Ctx.run` methods are the private methods `writeMoment` and `writeBatch` below,
// and its `error.Fail` is `Fail`. Zig's `history.append(.{ .slot = ... }, Ctx{})` is
// `history.append(.slot(...)) { cursor in ... }`, and `map.cursor.writePath(Ctx, &.{ ..., .{ .ctx = Ctx{} } })`
// is `map.cursor.writePath([..., .ctx]) { cursor in ... }`. Zig's `readBytes(&buffer)` into a fixed buffer is
// `readBytes(maxCount:)` with the buffer's size. Zig's `xitdb.VERSION` is `DatabaseHeader.currentVersion`, and
// `@bitSizeOf(xitdb.DatabaseHeader) / 8` is `DatabaseHeader.byteCount`. Zig's `takeInt(u8)` through the core's
// reader and `writeByte` through its writer, which damage the replica's file directly, are `readBytes` and
// `writeBytes` on the replica's storage. Zig's `expect` aborts the test, so where a failure would make a later line
// trap (a byte count that a slice depends on) it is `#require`; everywhere else it is `#expect`.
//
// Every assertion Zig makes in those lines is here. Left out:
// - Zig's set-up of its storages (lines 3761 to 3832): the files `main.db` and `replica.db` it creates and deletes,
//   its buffers, `max_size = 50_000_000` and `.fsync = false`. The storages under test have no size limit and no
//   durability.
// - `replica.core.flush()` (line 4108), which puts the damaged byte on the file for the reopen that follows. Here
//   the reopen reads through the same storage the byte was written through, so there is nothing to flush.
// - Zig's allocator arguments, `defer ... deinit()` and `allocator.free` lines, which have no counterpart.

/// Zig's replication tests: a replica is brought up to date by the bytes it lacks, replaced when it is a replica
/// of another file or has diverged, and the root can be of any type.
@Suite struct ReplicationTests {
    /// Zig's `error.Fail`.
    private struct Fail: Error {}

    /// Zig's `std.Io.Writer.Discarding`: a sink that drops what it is given.
    private struct DiscardingSink: ByteSink {
        mutating func write(_ bytes: Span<UInt8>) {}
    }

    // MARK: Zig's helpers

    /// Zig's `std.Io.Writer.Allocating`: the committed bytes from `start` to `end`, through a sink.
    private func readCommitted(_ database: Database, from start: UInt64, to end: UInt64) throws -> [UInt8] {
        var sink = CollectingSink()
        try database.readCommitted(from: start, to: end, into: &sink)
        return sink.bytes
    }

    /// test.zig 3917-3922: `readCommittedBytes`, the committed bytes from `start` to the committed size.
    private func readCommittedBytes(_ database: Database, from start: UInt64) throws -> [UInt8] {
        try readCommitted(database, from: start, to: try database.committedSize)
    }

    /// test.zig 3924-3934: `replicate`.
    private func replicate(_ source: Database, _ replica: Database) throws {
        // the replica sends its state, and the source sends back the bytes it doesn't
        // have yet (or all of them, if it isn't a replica of this source)
        let start = try source.replicationStart(for: try replica.replicaState)
        let end = try source.committedSize
        let bytes = try readCommitted(source, from: start, to: end)
        var reader = ArrayByteSource(bytes)
        try replica.applyReplicated(at: start, from: &reader, count: end - start)
    }

    /// test.zig 3936-3956: `expectAppendOnlyAndReplicate`.
    private func expectAppendOnlyAndReplicate(_ source: Database, _ replica: Database, committed: inout [UInt8])
        throws
    {
        // checks that no committed byte has changed since `committed` was read,
        // except the root header (the root slot and file size after the database
        // header). then replicates and checks that the replica is identical.
        let rootHeaderStart = Int(DatabaseHeader.byteCount)
        let rootHeaderEnd = rootHeaderStart + 17
        do {
            let current = try readCommittedBytes(source, from: 0)
            try #require(current.count >= committed.count)
            #expect(committed[0..<rootHeaderStart] == current[0..<rootHeaderStart])
            #expect(committed[rootHeaderEnd...] == current[rootHeaderEnd..<committed.count])
            committed = current
        }

        try replicate(source, replica)
        let replicaBytes = try readCommittedBytes(replica, from: 0)
        #expect(committed == replicaBytes)
    }

    /// test.zig 3958-3964: `expectSameCommittedBytes`.
    private func expectSameCommittedBytes(_ source: Database, _ replica: Database) throws {
        let sourceBytes = try readCommittedBytes(source, from: 0)
        let replicaBytes = try readCommittedBytes(replica, from: 0)
        #expect(sourceBytes == replicaBytes)
    }

    // MARK: testReplication

    /// test.zig 3977-3985: `Ctx.run` of `testReplication`, which writes moment `i` into the cursor's hash map and
    /// fails after writing if asked to.
    private func writeMoment(_ cursor: Cursor<ReadWrite>, i: Int, fail: Bool = false) throws {
        let moment = try HashMap<ReadWrite>(cursor)
        try moment.put(.uint(UInt64(i)), forHash: hashInt("key-\(i)"))
        let list = try ArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
        try list.append(.uint(UInt64(i)))
        if fail { throw Fail() }
    }

    /// test.zig 3966-4111: `testReplication`. A history of three hundred moments, with failed transactions and a
    /// rollback among them, replicated after each; a short append; the replica reopened; a compacted copy
    /// replicated from byte 0; and a damaged replica that no longer opens.
    @Test(arguments: StorageKind.allCases)
    func replication(kind: StorageKind) throws {
        let sourceSubject = try StorageUnderTest(kind)
        let replicaSubject = try StorageUnderTest(kind)

        // a fixed file ID, so the bytes of the new database are known
        let source = try Database(storage: sourceSubject.storage, hashSize: 20, fileID: 0x0102_0304_0506_0708)
        var replica = try Database(storage: replicaSubject.storage, hashSize: 20)

        // a new database is its header (which ends with its file ID), its root
        // header, and the trailer for its empty root: the slot (9 zero bytes), the commit ID (0 for
        // the first commit), then the CRC-64/XZ of the file ID, the trailer's position
        // (37), the slot, and the commit ID
        do {
            let bytes = try readCommittedBytes(source, from: 0)
            try #require(bytes.count == 62)
            #expect(Array(bytes[12..<20]) == [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
            #expect(
                Array(bytes[37...]) == [
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0xd6, 0x18, 0x4e, 0x46, 0xb4, 0x7d, 0x29,
                    0x26,
                ])
        }

        // new databases have their own random file IDs, so the
        // first sync replaces the replica with a copy of the source
        #expect(try source.replicationStart(for: try replica.replicaState) == 0)
        try replicate(source, replica)
        try expectSameCommittedBytes(source, replica)

        #expect(source.header.version == DatabaseHeader.currentVersion)

        let history = try ArrayList<ReadWrite>(source.rootCursor)

        var committed = try readCommittedBytes(source, from: 0)

        // enough moments for the top-level array list to grow to three levels
        for i in 0..<300 {
            if i == 200 {
                // roll back the history
                try history.truncate(to: 150)
            } else if i % 50 == 25 {
                // a failed transaction
                #expect(throws: Fail.self) {
                    try history.append(.slot(try history.slot(at: -1))) { cursor in
                        try writeMoment(cursor, i: i, fail: true)
                    }
                }
            } else {
                try history.append(.slot(try history.slot(at: -1))) { cursor in
                    try writeMoment(cursor, i: i)
                }
            }

            try expectAppendOnlyAndReplicate(source, replica, committed: &committed)
        }

        // `applyReplicated` must be given exactly the bytes up to a trailer.
        // a short append fails and is overwritten by the next one.
        let endBeforeLastMoment: UInt64
        do {
            try history.append(.slot(try history.slot(at: -1))) { cursor in
                try writeMoment(cursor, i: 300)
            }
            let start = try replica.committedSize
            endBeforeLastMoment = start
            let end = try source.committedSize
            let bytes = try readCommittedBytes(source, from: start)
            #expect(throws: XitDBError.invalidDatabase) {
                try replica.applyReplicated(at: start, bytes: Array(bytes[0..<(bytes.count - 1)]))
            }
            #expect(try replica.committedSize == start)
            // and only committed bytes can be read, starting at 0 or after the root header
            var discarding = DiscardingSink()
            #expect(throws: XitDBError.invalidRange) {
                try source.readCommitted(from: start, to: end + 1, into: &discarding)
            }
            #expect(throws: XitDBError.invalidRange) {
                try source.readCommitted(from: 20, to: end, into: &discarding)
            }
            try replicate(source, replica)
            try expectSameCommittedBytes(source, replica)
        }

        // the replica can be reopened and read
        replica = try Database(storage: replicaSubject.storage, hashSize: 20)
        let sourceHistory = try ArrayList<ReadOnly>(source.rootCursor.readOnly)
        let replicaHistory = try ArrayList<ReadOnly>(replica.rootCursor.readOnly)
        #expect(try sourceHistory.count == replicaHistory.count)
        let momentCursor = try #require(try replicaHistory.cursor(at: -1))
        let moment = try HashMap<ReadOnly>(momentCursor)
        let key299 = try #require(try moment.cursor(forHash: hashInt("key-299")))
        #expect(try key299.readUInt64() == 299)
        // removed by the slice
        #expect(try moment.cursor(forHash: hashInt("key-180")) == nil)
        let key149 = try #require(try moment.cursor(forHash: hashInt("key-149")))
        #expect(try key149.readUInt64() == 149)

        // a compacted database is a new file, so a replica of it is seeded from byte 0
        do {
            var offsetMap = MemoryOffsetMap()

            let target = try source.compact(into: MemoryStorage(), offsetMap: &offsetMap)
            let compactedReplica = try Database(storage: MemoryStorage(), hashSize: 20)
            try replicate(target, compactedReplica)
            try expectSameCommittedBytes(target, compactedReplica)

            // and it can keep receiving transactions
            let targetHistory = try ArrayList<ReadWrite>(target.rootCursor)
            try targetHistory.append(.slot(try targetHistory.slot(at: -1)))
            try replicate(target, compactedReplica)
            try expectSameCommittedBytes(target, compactedReplica)

            let compactedHistory = try ArrayList<ReadOnly>(compactedReplica.rootCursor.readOnly)
            #expect(try compactedHistory.count == 2)
            let compactedMomentCursor = try #require(try compactedHistory.cursor(at: -1))
            let compactedMoment = try HashMap<ReadOnly>(compactedMomentCursor)
            let compactedKey299 = try #require(try compactedMoment.cursor(forHash: hashInt("key-299")))
            #expect(try compactedKey299.readUInt64() == 299)
        }

        // a database whose trailer doesn't match its header cannot be
        // trusted: the port names the commit before it, where Zig says the
        // file is invalid (decision D19)
        do {
            let position = try replica.committedSize - 1
            let byte = try #require(try readBytes(replicaSubject.storage, at: position, count: 1).first)
            try writeBytes(replicaSubject.storage, [~byte], at: position)
            #expect(throws: XitDBError.untrustedRootHeader(lastVerified: endBeforeLastMoment)) {
                _ = try Database(storage: replicaSubject.storage, hashSize: 20)
            }
        }
    }

    // MARK: testReplicaOfOtherFile

    /// test.zig 3837-3915: `testReplicaOfOtherFile`, over memory storages as Zig has it.
    @Test func replicaOfOtherFile() throws {
        // a replica is never extended with bytes from a file it isn't a replica of
        let source = try Database(storage: MemoryStorage(), hashSize: 20, fileID: 1)
        let other = try Database(storage: MemoryStorage(), hashSize: 20, fileID: 2)
        let replica = try Database(storage: MemoryStorage(), hashSize: 20)

        // the same writes give both files the same layout
        var sourceRoot = source.rootCursor
        try sourceRoot.write(.uint(1))
        var otherRoot = other.rootCursor
        try otherRoot.write(.uint(1))
        try replicate(source, replica)

        // the other file has a trailer where the replica's committed bytes end,
        // but its checksum covers a different file ID, so the replica is replaced
        try otherRoot.write(.uint(2))
        #expect(try other.replicationStart(for: try replica.replicaState) == 0)

        // and if its bytes are appended anyway, they are rejected
        do {
            let start = try replica.committedSize
            let end = try other.committedSize
            let bytes = try readCommitted(other, from: start, to: end)
            var reader = ArrayByteSource(bytes)
            #expect(throws: XitDBError.invalidDatabase) {
                try replica.applyReplicated(at: start, from: &reader, count: end - start)
            }
            #expect(try replica.committedSize == start)
        }

        // a source restored from an older copy keeps its file ID, but
        // its history diverges, so the replica is replaced too
        let restored = try Database(storage: MemoryStorage(), hashSize: 20, fileID: 1)
        var restoredRoot = restored.rootCursor
        try restoredRoot.write(.uint(3))
        #expect(try restored.replicationStart(for: try replica.replicaState) == 0)

        // copies of one file that write different data of the same size have the
        // same layout, but every commit has a random ID, so their histories differ
        do {
            let copyA = try Database(storage: MemoryStorage(), hashSize: 20, fileID: 3)
            let copyB = try Database(storage: MemoryStorage(), hashSize: 20, fileID: 3)
            let copyReplica = try Database(storage: MemoryStorage(), hashSize: 20)
            var copyARoot = copyA.rootCursor
            try copyARoot.write(.bytes(utf8("aaaaaaaaaaaa")))
            var copyBRoot = copyB.rootCursor
            try copyBRoot.write(.bytes(utf8("bbbbbbbbbbbb")))

            try replicate(copyA, copyReplica)
            #expect(try copyA.committedSize == copyB.committedSize)
            #expect(try copyB.replicationStart(for: try copyReplica.replicaState) == 0)
            try replicate(copyB, copyReplica)
            #expect(try copyReplica.rootCursor.readBytes(maxCount: 16) == utf8("bbbbbbbbbbbb"))
        }

        // while the real source only sends the new bytes
        try sourceRoot.write(.uint(2))
        #expect(try source.replicationStart(for: try replica.replicaState) == replica.committedSize)
        try replicate(source, replica)
        try expectSameCommittedBytes(source, replica)
    }

    // MARK: testRoots

    /// test.zig 4113-4366: `testRoots`. Each block starts from new storages, so the blocks are the methods below,
    /// in Zig's order.
    @Test(arguments: StorageKind.allCases)
    func roots(kind: StorageKind) throws {
        // the root can be any type, not just an array list
        try hashMapRoot(kind)
        try arrayListRootHeldByWrapper(kind)
        try scalarRoot(kind)
        try hashSetRoot(kind)
        try sortedMapRoot(kind)
        try linkedArrayListRoot(kind)
    }

    /// test.zig 4185-4196: `Batch.run` of `testRoots`, which puts a hundred keys into the cursor's hash map and
    /// fails after writing if asked to.
    private func writeBatch(_ cursor: Cursor<ReadWrite>, fail: Bool) throws {
        let root = try HashMap<ReadWrite>(cursor)
        for i in 0..<100 {
            try root.put(.uint(UInt64(i)), forHash: hashInt("batch-\(i)"))
        }
        if fail { throw Fail() }
    }

    /// test.zig 4122-4257: "a hash map root": a hundred keys put one transaction at a time and replicated after
    /// each, a key written, nested collections in one transaction, a batch under `withTransaction`, a late cursor, the
    /// replica reopened, and compacted.
    private func hashMapRoot(_ kind: StorageKind) throws {
        // a hash map root
        let sourceSubject = try StorageUnderTest(kind)
        let replicaSubject = try StorageUnderTest(kind)

        let source = try Database(storage: sourceSubject.storage, hashSize: 20)
        var replica = try Database(storage: replicaSubject.storage, hashSize: 20)

        let map = try HashMap<ReadWrite>(source.rootCursor)

        // initializing an initialized root doesn't start a transaction
        let sizeAfterInit = try source.committedSize
        _ = try HashMap<ReadWrite>(source.rootCursor)
        #expect(try source.committedSize == sizeAfterInit)

        // nor can the root be initialized as another type
        #expect(throws: XitDBError.unexpectedTag) { _ = try ArrayList<ReadWrite>(source.rootCursor) }
        #expect(try source.committedSize == sizeAfterInit)

        var committed = try readCommittedBytes(source, from: 0)

        for i in 0..<100 {
            try map.put(.uint(UInt64(i)), forHash: hashInt("key-\(i)"))
            if i == 50 {
                #expect(try map.remove(forHash: hashInt("key-25")))
            }

            try expectAppendOnlyAndReplicate(source, replica, committed: &committed)
        }

        // a key is written in the same transaction as the lookup, so it works on a root map
        try map.putKey(.bytes(utf8("key-1")), forHash: hashInt("key-1"))
        do {
            let kv = try #require(try map.entry(forHash: hashInt("key-1")))
            #expect(try kv.key.readBytes(maxCount: 8) == utf8("key-1"))
            #expect(try kv.value.readUInt64() == 1)
        }

        // nested collections are written inside one transaction
        _ = try map.cursor.writePath([.hashMapGet(.value, sha1("inner")), .ctx]) { cursor in
            let inner = try HashMap<ReadWrite>(cursor)
            try inner.put(.bytes(utf8("foo")), forHash: hashInt("foo"))
            let list = try ArrayList<ReadWrite>(try inner.putCursor(forHash: hashInt("list")))
            try list.append(.uint(1))
            try list.append(.uint(2))
        }
        try replicate(source, replica)
        try expectSameCommittedBytes(source, replica)

        // `withTransaction` groups many writes into one transaction
        do {
            let sizeBefore = try source.committedSize

            // a failed transaction leaves nothing behind
            #expect(throws: Fail.self) {
                try source.withTransaction { cursor in try writeBatch(cursor, fail: true) }
            }
            #expect(try source.committedSize == sizeBefore)
            #expect(try map.cursor(forHash: hashInt("batch-0")) == nil)

            // a successful one commits everything at once
            try source.withTransaction { cursor in try writeBatch(cursor, fail: false) }
            #expect(try source.committedSize > sizeBefore)
            let batch0 = try #require(try map.cursor(forHash: hashInt("batch-0")))
            #expect(try batch0.readUInt64() == 0)
            let batch99 = try #require(try map.cursor(forHash: hashInt("batch-99")))
            #expect(try batch99.readUInt64() == 99)
            try replicate(source, replica)
            try expectSameCommittedBytes(source, replica)
        }

        // a nested write cursor can't be written to after its transaction
        var lateCursor = try map.putCursor(forHash: hashInt("late"))
        #expect(throws: XitDBError.expectedTxStart) { try lateCursor.write(.uint(1)) }
        #expect(throws: XitDBError.expectedTxStart) { _ = try HashMap<ReadWrite>(lateCursor) }
        try replicate(source, replica)
        try expectSameCommittedBytes(source, replica)

        // the replica can be reopened and read
        replica = try Database(storage: replicaSubject.storage, hashSize: 20)
        do {
            let replicaMap = try HashMap<ReadOnly>(replica.rootCursor.readOnly)
            let key99 = try #require(try replicaMap.cursor(forHash: hashInt("key-99")))
            #expect(try key99.readUInt64() == 99)
            #expect(try replicaMap.cursor(forHash: hashInt("key-25")) == nil)
            let innerCursor = try #require(try replicaMap.cursor(forHash: hashInt("inner")))
            let inner = try HashMap<ReadOnly>(innerCursor)
            let listCursor = try #require(try inner.cursor(forHash: hashInt("list")))
            let list = try ArrayList<ReadOnly>(listCursor)
            #expect(try list.count == 2)
            let last = try #require(try list.cursor(at: -1))
            #expect(try last.readUInt64() == 2)
        }

        // it can be compacted
        do {
            var offsetMap = MemoryOffsetMap()

            let target = try replica.compact(into: MemoryStorage(), offsetMap: &offsetMap)
            #expect(try target.committedSize < replica.committedSize)

            let targetMap = try HashMap<ReadOnly>(target.rootCursor.readOnly)
            let key99 = try #require(try targetMap.cursor(forHash: hashInt("key-99")))
            #expect(try key99.readUInt64() == 99)
            #expect(try targetMap.cursor(forHash: hashInt("key-25")) == nil)
            let innerCursor = try #require(try targetMap.cursor(forHash: hashInt("inner")))
            let inner = try HashMap<ReadOnly>(innerCursor)
            let listCursor = try #require(try inner.cursor(forHash: hashInt("list")))
            let list = try ArrayList<ReadOnly>(listCursor)
            #expect(try list.count == 2)

            // a compacted database is a new file, so a replica of it is seeded from byte 0
            let compactedReplica = try Database(storage: MemoryStorage(), hashSize: 20)
            try replicate(target, compactedReplica)
            try expectSameCommittedBytes(target, compactedReplica)
        }
    }

    /// test.zig 4259-4277: "an array list root held by a wrapper stays current".
    private func arrayListRootHeldByWrapper(_ kind: StorageKind) throws {
        // an array list root held by a wrapper stays current
        let subject = try StorageUnderTest(kind)
        let db = try Database(storage: subject.storage, hashSize: 20)

        let history = try ArrayList<ReadWrite>(db.rootCursor)
        try history.append(.uint(1))
        try history.append(.uint(2))
        #expect(try history.count == 2)
        var iter = try history.iterator()
        var iterCount = 0
        while try iter.next() != nil { iterCount += 1 }
        #expect(iterCount == 2)

        // initializing an initialized root doesn't start a transaction
        let size = try db.committedSize
        _ = try ArrayList<ReadWrite>(db.rootCursor)
        #expect(try db.committedSize == size)
    }

    /// test.zig 4279-4313: "a scalar root".
    private func scalarRoot(_ kind: StorageKind) throws {
        // a scalar root
        let subject = try StorageUnderTest(kind)
        let db = try Database(storage: subject.storage, hashSize: 20)

        let retained = db.rootCursor
        var root = db.rootCursor
        try root.write(.uint(42))
        #expect(try root.readUInt64() == 42)
        #expect(try db.rootCursor.readUInt64() == 42)

        // a root cursor kept from before the write sees the new root
        // everywhere it reads its slot, not just in typed reads
        #expect(try retained.readUInt64() == 42)
        #expect(try retained.slot.value == 42)
        let retainedPathSlot = try #require(try retained.readPathSlot([]))
        #expect(retainedPathSlot.value == 42)
        let retainedPath = try #require(try retained.readPath([]))
        #expect(try retainedPath.readUInt64() == 42)

        // the cursor stays a root cursor, so it can keep writing
        try root.write(.bytes(utf8("this is too long to fit in a slot")))
        #expect(try db.rootCursor.readBytes(maxCount: 64) == utf8("this is too long to fit in a slot"))

        // bytes can't be streamed into the root
        #expect(throws: XitDBError.cursorNotWritable) { try root.writeBytes { _ in } }

        // a scalar root can't be initialized as a collection
        #expect(throws: XitDBError.unexpectedTag) { _ = try HashMap<ReadWrite>(db.rootCursor) }

        // but once it is cleared, it can
        try root.write(.slot(nil))
        let map = try HashMap<ReadWrite>(db.rootCursor)
        try map.put(.uint(1), forHash: hashInt("foo"))
        let foo = try #require(try map.cursor(forHash: hashInt("foo")))
        #expect(try foo.readUInt64() == 1)
    }

    /// test.zig 4315-4327: "a hash set root".
    private func hashSetRoot(_ kind: StorageKind) throws {
        // a hash set root
        let subject = try StorageUnderTest(kind)
        let db = try Database(storage: subject.storage, hashSize: 20)

        let set = try HashSet<ReadWrite>(db.rootCursor)
        try set.insert(.bytes(utf8("a")), forHash: hashInt("a"))
        try set.insert(.bytes(utf8("a")), forHash: hashInt("a"))
        try set.insert(.bytes(utf8("b")), forHash: hashInt("b"))
        let a = try #require(try set.cursor(forHash: hashInt("a")))
        #expect(try a.readBytes(maxCount: 8) == utf8("a"))
        let b = try #require(try set.cursor(forHash: hashInt("b")))
        #expect(try b.readBytes(maxCount: 8) == utf8("b"))
    }

    /// test.zig 4329-4346: "a sorted map root".
    private func sortedMapRoot(_ kind: StorageKind) throws {
        // a sorted map root
        let subject = try StorageUnderTest(kind)
        let db = try Database(storage: subject.storage, hashSize: 20)

        let map = try SortedMap<ReadWrite>(db.rootCursor)
        try map.put(.uint(2), forKey: utf8("b"))
        try map.put(.uint(1), forKey: utf8("a"))
        try map.put(.uint(3), forKey: utf8("c"))
        #expect(try map.remove(forKey: utf8("c")))
        #expect(try map.count == 2)
        #expect(try map.rank(of: utf8("b")) == 1)
        let a = try #require(try map.cursor(forKey: utf8("a")))
        #expect(try a.readUInt64() == 1)

        let size = try db.committedSize
        _ = try SortedMap<ReadWrite>(db.rootCursor)
        #expect(try db.committedSize == size)
    }

    /// test.zig 4348-4365: "a linked array list root".
    private func linkedArrayListRoot(_ kind: StorageKind) throws {
        // a linked array list root
        let subject = try StorageUnderTest(kind)
        let db = try Database(storage: subject.storage, hashSize: 20)

        let list = try LinkedArrayList<ReadWrite>(db.rootCursor)
        try list.append(.uint(1))
        try list.append(.uint(3))
        try list.insert(.uint(2), at: 1)
        #expect(try list.count == 3)
        let second = try #require(try list.cursor(at: 1))
        #expect(try second.readUInt64() == 2)
        try list.remove(at: 0)
        let first = try #require(try list.cursor(at: 0))
        #expect(try first.readUInt64() == 2)

        let size = try db.committedSize
        _ = try LinkedArrayList<ReadWrite>(db.rootCursor)
        #expect(try db.committedSize == size)
    }
}
