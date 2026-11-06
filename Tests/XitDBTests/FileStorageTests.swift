import Foundation
import Testing

@testable import XitDB

@Suite struct FileStorageTests {
    @Test func createsWritesReopensAndReadsBack() throws {
        let directory = try TemporaryDirectory()
        do {
            let storage = try FileStorage(path: directory.path())
            #expect(try storage.length() == 0)
            try writeBytes(storage, Array("Hello".utf8), at: 0)
            try writeBytes(storage, bigEndianBytes(42), at: 5)
            #expect(try storage.length() == 13)
        }
        #expect(try directory.contents() == Array("Hello".utf8) + bigEndianBytes(42))

        let reopened = try FileStorage(path: directory.path(), access: .readWrite)
        #expect(try reopened.length() == 13)
        #expect(try readBytes(reopened, at: 0, count: 5) == Array("Hello".utf8))
        #expect(try readBytes(reopened, at: 5, count: 100) == bigEndianBytes(42))
        #expect(try readBytes(reopened, at: 13, count: 4) == [])
    }

    @Test func accessDecidesWhetherTheFileIsCreatedOrEmptied() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path()

        // neither of these creates a file
        #expect(throws: XitDBError.storageFailure(errno: ENOENT)) { try FileStorage(path: path, access: .readOnly) }
        #expect(throws: XitDBError.storageFailure(errno: ENOENT)) { try FileStorage(path: path, access: .readWrite) }
        #expect(!FileManager.default.fileExists(atPath: path))

        // create makes it, and leaves an existing file as it is
        try writeBytes(try FileStorage(path: path, access: .create), [1, 2, 3], at: 0)
        #expect(try FileStorage(path: path, access: .create).length() == 3)
        #expect(try FileStorage(path: path, access: .readWrite).length() == 3)
        #expect(try FileStorage(path: path, access: .readOnly).length() == 3)

        // truncate empties it, and makes it when it is missing
        #expect(try FileStorage(path: path, access: .truncate).length() == 0)
        #expect(try directory.contents() == [])
        let other = directory.path("other.db")
        #expect(try FileStorage(path: other, access: .truncate).length() == 0)
        #expect(FileManager.default.fileExists(atPath: other))
    }

    @Test func theDefaultsAreCreateAndFullDurability() throws {
        let directory = try TemporaryDirectory()
        let storage = try FileStorage(path: directory.path())
        #expect(storage.durability == .full)
        if case .create = storage.access {} else { Issue.record("the default access is not create") }
    }

    @Test func aWritePastTheEndFillsTheGapWithZeros() throws {
        let directory = try TemporaryDirectory()
        let storage = try FileStorage(path: directory.path())
        try writeBytes(storage, [1, 2], at: 0)
        try writeBytes(storage, [9], at: 5)
        #expect(try directory.contents() == [1, 2, 0, 0, 0, 9])
        #expect(try readBytes(storage, at: 1, count: 10) == [2, 0, 0, 0, 9])

        // writing nothing does nothing, even beyond the end
        try writeBytes(storage, [], at: 100)
        #expect(try storage.length() == 6)
    }

    @Test func setLengthShortensAndNeverLengthens() throws {
        let directory = try TemporaryDirectory()
        let storage = try FileStorage(path: directory.path())
        try writeBytes(storage, [1, 2, 3, 4], at: 0)

        for length in [5, UInt64.max] {
            #expect(throws: XitDBError.invalidLength) { try storage.setLength(length) }
            #expect(try directory.contents() == [1, 2, 3, 4])
        }

        try storage.setLength(4)
        #expect(try directory.contents() == [1, 2, 3, 4])
        try storage.setLength(2)
        #expect(try directory.contents() == [1, 2])
        #expect(try readBytes(storage, at: 2, count: 1) == [])
        try storage.setLength(0)
        #expect(try storage.length() == 0)
    }

    @Test func aReadOnlyStorageRejectsWritesAndIgnoresTruncation() throws {
        let directory = try TemporaryDirectory()
        try writeBytes(try FileStorage(path: directory.path()), [1, 2, 3, 4], at: 0)

        let storage = try FileStorage(path: directory.path(), access: .readOnly)
        #expect(try readBytes(storage, at: 0, count: 10) == [1, 2, 3, 4])

        // Zig's writer fails; here it is the error of writing to a descriptor
        // that is not open for writing
        #expect(throws: XitDBError.storageFailure(errno: EBADF)) { try writeBytes(storage, [9], at: 0) }
        #expect(throws: XitDBError.storageFailure(errno: EBADF)) { try writeBytes(storage, [9], at: 4) }

        // a request to shorten is ignored, as in Zig
        try storage.setLength(2)
        try storage.setLength(0)
        #expect(try storage.length() == 4)
        #expect(try directory.contents() == [1, 2, 3, 4])

        // a request to lengthen is invalid for every storage
        #expect(throws: XitDBError.invalidLength) { try storage.setLength(5) }

        // flushing and syncing a file that was not written are harmless
        try storage.flush()
        try storage.sync(.beforeRootHeader)
        try storage.sync(.afterRootHeader)
    }

    @Test func readsThatReachTheEndAreShort() throws {
        let directory = try TemporaryDirectory()
        let storage = try FileStorage(path: directory.path())
        try writeBytes(storage, (0..<200).map { UInt8($0) }, at: 0)
        #expect(try readBytes(storage, at: 190, count: 50) == (190..<200).map { UInt8($0) })
        #expect(try readBytes(storage, at: 200, count: 50) == [])
        #expect(try readBytes(storage, at: .max, count: 50) == [])
        #expect(try readBytes(storage, at: 0, count: 0) == [])

        // the part of the buffer that was not read into is left as it was
        var buffer = [UInt8](repeating: 7, count: 4)
        var span = buffer.mutableSpan
        #expect(try storage.read(into: &span, at: 198) == 2)
        #expect(buffer == [198, 199, 7, 7])
    }

    @Test func anOffsetTheSystemCannotExpressIsAStorageFailure() throws {
        let directory = try TemporaryDirectory()
        let storage = try FileStorage(path: directory.path())
        #expect(throws: XitDBError.storageFailure(errno: EFBIG)) { try writeBytes(storage, [1], at: .max) }
        #expect(try storage.length() == 0)
    }
}

@Suite struct FileLockTests {
    @Test func aSecondExclusiveLockFailsAtOnce() throws {
        let directory = try TemporaryDirectory()
        let holder = try FileStorage(path: directory.path(), lock: .exclusive)
        #expect(throws: XitDBError.storageFailure(errno: EWOULDBLOCK)) {
            try FileStorage(path: directory.path(), lock: .exclusive)
        }
        #expect(throws: XitDBError.storageFailure(errno: EWOULDBLOCK)) {
            try FileStorage(path: directory.path(), access: .readOnly, lock: .shared)
        }
        #expect(throws: XitDBError.storageFailure(errno: EWOULDBLOCK)) {
            try BufferedFileStorage(path: directory.path(), lock: .exclusive)
        }
        try holder.flush()
    }

    @Test func sharedLocksCoexistAndKeepOutAnExclusiveOne() throws {
        let directory = try TemporaryDirectory()
        let first = try FileStorage(path: directory.path(), lock: .shared)
        let second = try FileStorage(path: directory.path(), access: .readOnly, lock: .shared)
        #expect(throws: XitDBError.storageFailure(errno: EWOULDBLOCK)) {
            try FileStorage(path: directory.path(), lock: .exclusive)
        }
        try first.flush()
        try second.flush()
    }

    @Test func noLockIsTakenUnlessAskedFor() throws {
        let directory = try TemporaryDirectory()
        // two storages that ask for no lock do not get in each other's way
        let first = try FileStorage(path: directory.path())
        let second = try FileStorage(path: directory.path())
        // and an exclusive lock can still be had, because they hold none
        let locked = try FileStorage(path: directory.path(), lock: .exclusive)
        // locks are advisory: an opener that asks for none is not kept out
        let unlocked = try FileStorage(path: directory.path())
        try writeBytes(unlocked, [1], at: 0)
        #expect(try locked.length() == 1)
        try first.flush()
        try second.flush()
    }

    @Test func theLockIsReleasedWhenTheStorageGoesAway() throws {
        let directory = try TemporaryDirectory()
        do {
            let holder = try FileStorage(path: directory.path(), lock: .exclusive)
            try holder.flush()
        }
        let next = try FileStorage(path: directory.path(), lock: .exclusive)
        try next.flush()
    }

    @Test func anOpenerThatFailsToGetTheLockDoesNotEmptyTheFile() throws {
        let directory = try TemporaryDirectory()
        let holder = try FileStorage(path: directory.path(), lock: .exclusive)
        try writeBytes(holder, [1, 2, 3], at: 0)
        #expect(throws: XitDBError.storageFailure(errno: EWOULDBLOCK)) {
            try FileStorage(path: directory.path(), access: .truncate, lock: .exclusive)
        }
        #expect(try directory.contents() == [1, 2, 3])

        // with the lock free, the same opener empties the file
        try holder.flush()
    }

    @Test func truncateEmptiesTheFileOnceTheLockIsHeld() throws {
        let directory = try TemporaryDirectory()
        try writeBytes(try FileStorage(path: directory.path()), [1, 2, 3], at: 0)
        let storage = try FileStorage(path: directory.path(), access: .truncate, lock: .exclusive)
        #expect(try storage.length() == 0)
        #expect(try directory.contents() == [])
    }
}

/// Records the sync calls a storage makes, and can make chosen ones fail.
final class SyncRecorder {
    var calls: [SyncCall] = []
    var failures: [SyncCall: Int32] = [:]

    func call(_ descriptor: Int32, _ call: SyncCall) -> Int32 {
        calls.append(call)
        return failures[call] ?? 0
    }

    func take() -> [SyncCall] {
        defer { calls = [] }
        return calls
    }
}

@Suite struct DurabilityTests {
    private func storage(
        _ directory: TemporaryDirectory,
        _ durability: Durability,
        _ recorder: SyncRecorder
    ) throws -> FileStorage {
        try FileStorage(
            path: directory.path(),
            access: .create,
            durability: durability,
            lock: nil,
            syncCall: recorder.call
        )
    }

    @Test func noneNeverSyncs() throws {
        let directory = try TemporaryDirectory()
        let recorder = SyncRecorder()
        let storage = try storage(directory, .none, recorder)
        try storage.sync(.beforeRootHeader)
        try storage.sync(.afterRootHeader)
        #expect(recorder.calls == [])
    }

    @Test func orderedUsesABarrierAtBothPoints() throws {
        let directory = try TemporaryDirectory()
        let recorder = SyncRecorder()
        let storage = try storage(directory, .ordered, recorder)
        try storage.sync(.beforeRootHeader)
        #expect(recorder.take() == [.barrier])
        try storage.sync(.afterRootHeader)
        #expect(recorder.take() == [.barrier])
    }

    @Test func fullUsesABarrierBeforeTheHeaderAndAFullSyncAfter() throws {
        let directory = try TemporaryDirectory()
        let recorder = SyncRecorder()
        let storage = try storage(directory, .full, recorder)
        try storage.sync(.beforeRootHeader)
        #expect(recorder.take() == [.barrier])
        try storage.sync(.afterRootHeader)
        #expect(recorder.take() == [.full])
    }

    @Test(arguments: [ENOTSUP, EOPNOTSUPP, ENOTTY, EINVAL])
    func aCallTheVolumeRejectsFallsBackToTheNextStrongest(rejection: Int32) throws {
        let directory = try TemporaryDirectory()
        let recorder = SyncRecorder()
        let storage = try storage(directory, .full, recorder)

        recorder.failures = [.full: rejection]
        try storage.sync(.afterRootHeader)
        #expect(recorder.take() == [.full, .barrier])

        recorder.failures = [.full: rejection, .barrier: rejection]
        try storage.sync(.afterRootHeader)
        #expect(recorder.take() == [.full, .barrier, .plain])
        try storage.sync(.beforeRootHeader)
        #expect(recorder.take() == [.barrier, .plain])

        // nothing left to fall back to
        recorder.failures = [.full: rejection, .barrier: rejection, .plain: rejection]
        #expect(throws: XitDBError.storageFailure(errno: rejection)) { try storage.sync(.afterRootHeader) }
        #expect(recorder.take() == [.full, .barrier, .plain])
    }

    @Test func aRealFailureIsNotPaperedOverByAWeakerCall() throws {
        let directory = try TemporaryDirectory()
        let recorder = SyncRecorder()
        let storage = try storage(directory, .full, recorder)

        recorder.failures = [.full: EIO]
        #expect(throws: XitDBError.storageFailure(errno: EIO)) { try storage.sync(.afterRootHeader) }
        #expect(recorder.take() == [.full])

        recorder.failures = [.barrier: ENOSPC]
        #expect(throws: XitDBError.storageFailure(errno: ENOSPC)) { try storage.sync(.beforeRootHeader) }
        #expect(recorder.take() == [.barrier])
    }

    @Test func theBufferedStorageFlushesBeforeItSyncs() throws {
        let directory = try TemporaryDirectory()
        let recorder = SyncRecorder()
        let file = try storage(directory, .full, recorder)
        let buffered = BufferedFileStorage(file)
        try writeBytes(buffered, [1, 2, 3], at: 0)
        #expect(try directory.contents() == [])

        try buffered.sync(.beforeRootHeader)
        #expect(recorder.take() == [.barrier])
        #expect(try directory.contents() == [1, 2, 3])

        // it flushes even when the durability level makes no sync call
        let quiet = try TemporaryDirectory()
        let none = BufferedFileStorage(try storage(quiet, .none, recorder))
        try writeBytes(none, [4, 5], at: 0)
        try none.sync(.afterRootHeader)
        #expect(recorder.take() == [])
        #expect(try quiet.contents() == [4, 5])
    }

    /// The three calls themselves, made for real on the volume the tests run
    /// on. This shows that the shim's calls exist and succeed, not that the
    /// data survives a power loss.
    @Test(arguments: [SyncCall.full, .barrier, .plain])
    func theSystemAcceptsEachCall(call: SyncCall) throws {
        let directory = try TemporaryDirectory()
        let storage = try FileStorage(path: directory.path())
        try writeBytes(storage, [1, 2, 3], at: 0)
        #expect(Platform.syncFile(storage.descriptor.rawValue, call) == 0)
    }

    @Test(arguments: [Durability.none, .ordered, .full])
    func everyLevelSyncsARealFile(durability: Durability) throws {
        let directory = try TemporaryDirectory()
        let storage = try FileStorage(path: directory.path(), durability: durability)
        try writeBytes(storage, [1, 2, 3], at: 0)
        try storage.sync(.beforeRootHeader)
        try storage.sync(.afterRootHeader)
        #expect(try directory.contents() == [1, 2, 3])
    }

    @Test func weakerCallsAreOrderedFromStrongestToWeakest() {
        #expect(SyncCall.full.nextWeaker == .barrier)
        #expect(SyncCall.barrier.nextWeaker == .plain)
        #expect(SyncCall.plain.nextWeaker == nil)
    }
}
