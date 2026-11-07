import Testing

@testable import XitDB

/// When the engine asks its storage to sync, seen through the file storage's
/// replaceable sync call. With full durability a commit makes exactly two
/// calls: a barrier before the root header and a full sync after it.
@Suite struct CommitSyncTests {
    let directory: TemporaryDirectory
    let recorder = SyncRecorder()
    let file: FileStorage

    init() throws {
        directory = try TemporaryDirectory()
        file = try FileStorage(path: directory.path(), access: .create, durability: .full)
        file.calls.sync = recorder.call
    }

    private func database() throws -> Database {
        try Database(storage: file, hashSize: 20, hashID: nil, fileID: 1, random: FixedRandom([1, 2, 3, 4, 5, 6]))
    }

    @Test func creatingADatabaseCommitsOnce() throws {
        _ = try database()
        #expect(recorder.take() == [.barrier, .full])
    }

    @Test func openingADatabaseDoesNotSync() throws {
        _ = try database()
        _ = recorder.take()
        _ = try database()
        #expect(recorder.take() == [])
    }

    @Test func aCommittingTransactionSyncsExactlyTwice() throws {
        let database = try database()
        _ = recorder.take()

        _ = try database.rootCursor.writePath([.arrayListInit, .arrayListAppend, .write(.uint(1))])
        #expect(recorder.take() == [.barrier, .full])

        var root = database.rootCursor
        _ = try root.writePath([.arrayListInit, .arrayListAppend, .ctx]) { cursor in
            // writes inside the transaction do not sync
            try cursor.write(.uint(2))
            _ = try cursor.writePath([])
        }
        #expect(recorder.take() == [.barrier, .full])

        try database.withTransaction { cursor in
            _ = try cursor.writePath([.arrayListAppend, .write(.uint(3))])
        }
        #expect(recorder.take() == [.barrier, .full])
        root = database.rootCursor
        #expect(try root.count() == 3)
    }

    /// Initialising a root that is already initialised commits nothing, so
    /// it does not sync. Zig does, with what is a full flush here.
    @Test func aFreeInitDoesNotSync() throws {
        let database = try database()
        _ = try database.rootCursor.writePath([.arrayListInit])
        #expect(recorder.take() == [.barrier, .full, .barrier, .full])
        let sizeBefore = try database.committedSize

        let list = try database.rootCursor.writePath([.arrayListInit])
        #expect(recorder.take() == [])
        #expect(try database.committedSize == sizeBefore)
        #expect(try list.count() == 0)
    }

    /// An empty path on a root cursor commits nothing either.
    @Test func anEmptyPathDoesNotSync() throws {
        let database = try database()
        _ = recorder.take()
        _ = try database.rootCursor.writePath([])
        #expect(recorder.take() == [])
    }

    @Test func aTransactionThatFailsDoesNotSyncAfterTheRootHeader() throws {
        struct Cancel: Error {}
        let database = try database()
        _ = recorder.take()
        #expect(throws: Cancel.self) {
            try database.withTransaction { cursor in
                try cursor.write(.uint(1))
                throw Cancel()
            }
        }
        #expect(recorder.take() == [])
        #expect(try database.committedSize == 62)
    }

    @Test func aBufferedDatabaseFlushesItsCommitToTheFile() throws {
        let buffered = BufferedFileStorage(file)
        let database = try Database(storage: buffered, hashSize: 20, hashID: nil, fileID: 1, random: FixedRandom([9]))
        #expect(recorder.take() == [.barrier, .full])
        _ = try database.rootCursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("a")), .write(.uint(1))])
        #expect(recorder.take() == [.barrier, .full])
        // everything committed is in the file, with nothing left in memory
        #expect(UInt64(try directory.contents().count) == (try database.committedSize))
    }
}
