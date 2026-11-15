import Foundation
import Testing

@testable import XitDB

/// The platform's calls that put a new file in the place of an old one:
/// the rename, the directory's sync and the removal of a name. A full copy
/// on a file storage that reads through a memory map is made of them.
@Suite struct ReplacingAFileTests {
    /// A file of these bytes at `path`, and a descriptor on it for reading.
    private func file(_ bytes: [UInt8], at path: String) throws -> FileDescriptor {
        #expect(FileManager.default.createFile(atPath: path, contents: Data(bytes)))
        return try FileDescriptor(opening: path, access: .readOnly)
    }

    private func bytes(of descriptor: FileDescriptor, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var span = buffer.mutableSpan
        let read = try Platform.readFile(descriptor.rawValue, into: &span, range: 0..<count, at: 0)
        return Array(buffer[..<read])
    }

    /// The directory of a path is what comes before its last slash.
    @Test func theDirectoryOfAPath() {
        #expect(Platform.directory(of: "/a/b/c.db") == "/a/b")
        #expect(Platform.directory(of: "/c.db") == "/")
        #expect(Platform.directory(of: "c.db") == ".")
        #expect(Platform.directory(of: "b/c.db") == "b")
        #expect(Platform.directory(of: "/a/b.incoming/c") == "/a/b.incoming")
    }

    /// After a rename over a name, the name is the new file's, the new
    /// file's old name is gone, and whoever had the old file open still
    /// reads it.
    @Test func aRenameGivesTheNameToTheNewFile() throws {
        let directory = try TemporaryDirectory()
        let old = try file(Array("the old one".utf8), at: directory.path())
        let new = try file(Array("the new".utf8), at: directory.path("test.db.incoming"))

        try Platform.renameFile(directory.path("test.db.incoming"), to: directory.path())

        #expect(try directory.contents() == Array("the new".utf8))
        #expect(!FileManager.default.fileExists(atPath: directory.path("test.db.incoming")))
        #expect(try bytes(of: old, count: 32) == Array("the old one".utf8))
        #expect(try bytes(of: new, count: 32) == Array("the new".utf8))
    }

    /// A rename of a name that is not there, or into a directory that is
    /// not there, is the system's error, and a path with a NUL in it is
    /// refused before the system sees the part before it.
    @Test func aRenameThatCannotBeMadeIsAnError() throws {
        let directory = try TemporaryDirectory()
        _ = try file([1, 2, 3], at: directory.path())
        #expect(throws: XitDBError.storageFailure(errno: ENOENT)) {
            try Platform.renameFile(directory.path("absent"), to: directory.path())
        }
        #expect(throws: XitDBError.storageFailure(errno: ENOENT)) {
            try Platform.renameFile(directory.path(), to: directory.path("no such folder/test.db"))
        }
        #expect(throws: XitDBError.storageFailure(errno: EINVAL)) {
            try Platform.renameFile(directory.path() + "\0x", to: directory.path("other"))
        }
        #expect(throws: XitDBError.storageFailure(errno: EINVAL)) {
            try Platform.renameFile(directory.path(), to: directory.path("other") + "\0x")
        }
        // nothing was renamed
        #expect(try directory.contents() == [1, 2, 3])
        #expect(!FileManager.default.fileExists(atPath: directory.path("other")))
    }

    /// The directory of a file is synced by each kind of sync call, and a
    /// directory that is not there is the system's error.
    @Test(arguments: [SyncCall.plain, .barrier, .full])
    func theDirectoryOfAFileIsSynced(call: SyncCall) throws {
        let directory = try TemporaryDirectory()
        _ = try file([1], at: directory.path())
        let result = Platform.syncDirectory(of: directory.path(), call)
        // a volume may not offer the stronger calls for a directory
        #expect(result == 0 || (call != .plain && Platform.isUnsupported(result)), "\(result)")
        #expect(Platform.syncDirectory(of: directory.path(), .plain) == 0)
        #expect(Platform.syncDirectory(of: directory.path("no such folder/test.db"), call) == ENOENT)
        #expect(Platform.syncDirectory(of: directory.path() + "\0x", call) == EINVAL)
    }

    /// Removing a name says whether it was there; the file lives on for
    /// whoever has it open.
    @Test func aNameIsRemoved() throws {
        let directory = try TemporaryDirectory()
        let open = try file(Array("left over".utf8), at: directory.path("test.db.incoming"))
        #expect(try Platform.removeFile(directory.path("test.db.incoming")))
        #expect(!FileManager.default.fileExists(atPath: directory.path("test.db.incoming")))
        #expect(try bytes(of: open, count: 32) == Array("left over".utf8))
        #expect(try !Platform.removeFile(directory.path("test.db.incoming")))
        #expect(throws: XitDBError.storageFailure(errno: EINVAL)) {
            try Platform.removeFile(directory.path() + "\0x")
        }
    }

    /// The calls a file storage makes for a replacement are these, until a
    /// test puts others in their place.
    @Test func theReplaceableCallsAreThePlatforms() throws {
        let directory = try TemporaryDirectory()
        let calls = FileCalls()
        let descriptor = try calls.open(directory.path("test.db.incoming"), .create)
        defer { Platform.closeFile(descriptor) }
        try calls.lock(descriptor, .exclusive)
        // a second descriptor on the same file is kept out by the lock
        let second = try Platform.openFile(directory.path("test.db.incoming"), access: .readWrite)
        defer { Platform.closeFile(second) }
        #expect(throws: XitDBError.storageFailure(errno: EWOULDBLOCK)) { try calls.lock(second, .exclusive) }

        try calls.rename(directory.path("test.db.incoming"), directory.path())
        #expect(FileManager.default.fileExists(atPath: directory.path()))
        #expect(calls.syncDirectory(directory.path(), .plain) == 0)
        // the lock went with the file to its new name
        let third = try Platform.openFile(directory.path(), access: .readWrite)
        defer { Platform.closeFile(third) }
        #expect(throws: XitDBError.storageFailure(errno: EWOULDBLOCK)) { try Platform.lockFile(third, .exclusive) }
        #expect(try calls.remove(directory.path()))
        #expect(try !calls.remove(directory.path()))
    }
}
