import Foundation
import Testing

@testable import XitDB

/// The replacement of a file by a new one, on the two file storages, read
/// through a memory map and not: its three steps called as a full copy will
/// call them. The new file is made beside the old, locked and given the
/// old one's attributes; the old file keeps its name, and its readers,
/// until the new one is given the name; and a replacement that is given up
/// leaves the old file as it was.
@Suite struct FileReplacementTests {
    /// The file storages a replacement is tried on.
    enum Kind: String, CaseIterable, CustomTestStringConvertible {
        case file, bufferedFile, mappedFile, mappedBufferedFile

        var testDescription: String { rawValue }

        var isMapped: Bool { self == .mappedFile || self == .mappedBufferedFile }
        var isBuffered: Bool { self == .bufferedFile || self == .mappedBufferedFile }
    }

    /// A writer's storage on a file, with the exclusive lock, and the file
    /// storage underneath it.
    struct Writer {
        let storage: any WritableStorage
        let file: FileStorage

        func beginReplacement() throws {
            if let buffered = storage as? BufferedFileStorage {
                try buffered.beginReplacement()
            } else {
                try file.beginReplacement()
            }
        }

        func commitReplacement() throws {
            if let buffered = storage as? BufferedFileStorage {
                try buffered.commitReplacement()
            } else {
                try file.commitReplacement()
            }
        }

        func abandonReplacement() {
            if let buffered = storage as? BufferedFileStorage {
                buffered.abandonReplacement()
            } else {
                file.abandonReplacement()
            }
        }
    }

    static let old = Array("the old file's bytes, which stay until the new file has the name".utf8)
    static let new = Array("the new one".utf8) + [UInt8](repeating: 7, count: 3 * Platform.pageSize)

    /// A writer of `kind` on the file at `path`, which is there, with these
    /// calls and this durability.
    private static func writer(
        _ kind: Kind, at path: String, calls: FileCalls = FileCalls(), durability: Durability = .none,
        lock: FileLock? = .exclusive
    ) throws -> Writer {
        var file = try FileStorage(
            path: path, access: .readWrite, durability: durability, lock: lock,
            memoryMapped: kind.isMapped && lock == .exclusive, segmentSize: Platform.pageSize, calls: calls)
        if kind.isMapped, lock == .exclusive { file = try readThroughTheMap(file, at: path) }
        return Writer(storage: kind.isBuffered ? BufferedFileStorage(file) : file, file: file)
    }

    /// A folder with the old file in it, under its bits.
    private static func folder(bits: Int = 0o600) throws -> TemporaryDirectory {
        let directory = try TemporaryDirectory()
        #expect(FileManager.default.createFile(atPath: directory.path(), contents: Data(old)))
        try FileManager.default.setAttributes([.posixPermissions: bits], ofItemAtPath: directory.path())
        return directory
    }

    private static func incoming(_ directory: TemporaryDirectory) -> String {
        directory.path() + FileStorage.incomingSuffix
    }

    private static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// The whole of what a storage holds.
    private static func all(_ storage: some ReadableStorage) throws -> [UInt8] {
        try readBytes(storage, at: 0, count: Int(try storage.length))
    }

    /// Writes the new file's bytes through the writer and syncs them, as a
    /// full copy does before it ends.
    private static func writeTheNewBytes(_ writer: Writer) throws {
        try writeBytes(writer.storage, new, at: 0)
        try writer.storage.sync(.beforeRootHeader)
        try writer.storage.sync(.afterRootHeader)
    }

    // MARK: The three steps

    /// Until the new file is given the name, the path has the old file: a
    /// reader that opens it then reads the old bytes. The writer itself is
    /// on the new file from the beginning, which is empty and has the old
    /// one's permission bits. Once the name is given the path has the new
    /// file and nothing is left beside it; a reader that opened the old
    /// file goes on reading it, and is told that its path no longer leads
    /// to its file.
    @Test(arguments: Kind.allCases)
    func aReplacementThatIsCommittedGivesTheNewFileTheName(kind: Kind) throws {
        let directory = try Self.folder()
        let writer = try Self.writer(kind, at: directory.path())
        let before = try FileStorage(path: directory.path(), access: .readOnly)
        #expect(try Self.all(writer.storage) == Self.old)
        #expect(!writer.file.isReplacing)

        try writer.beginReplacement()
        #expect(writer.file.isReplacing)
        #expect(try writer.storage.length == 0)
        #expect(try readBytes(writer.storage, at: 0, count: 10) == [])
        #expect(try directory.contents() == Self.old, "the path still has the old file")
        #expect(Self.exists(Self.incoming(directory)))
        let bits = try FileManager.default.attributesOfItem(atPath: Self.incoming(directory))[.posixPermissions]
        #expect((bits as? NSNumber)?.intValue == 0o600, "the new file has the old one's bits before a byte is in it")
        // a reader that opens the path during the copy has the old file
        let during = try FileStorage(path: directory.path(), access: .readOnly)
        #expect(try Self.all(during) == Self.old)

        try Self.writeTheNewBytes(writer)
        #expect(try directory.contents() == Self.old, "the path has the old file until the name is given")
        #expect(try writer.file.leadsToItsFile() == false, "the writer is on the new file, which has not the name yet")

        try writer.commitReplacement()
        #expect(!writer.file.isReplacing)
        #expect(try directory.contents() == Self.new)
        #expect(!Self.exists(Self.incoming(directory)))
        #expect(try Self.all(writer.storage) == Self.new)
        #expect(try writer.file.leadsToItsFile())
        // the readers of the old file read it on, and know it is not at the path
        #expect(try Self.all(before) == Self.old)
        #expect(try Self.all(during) == Self.old)
        #expect(try before.leadsToItsFile() == false)
        #expect(try during.leadsToItsFile() == false)
        // and the writer goes on writing the new file
        try writeBytes(writer.storage, [1, 2, 3], at: UInt64(Self.new.count))
        try writer.storage.flush()
        #expect(try directory.contents() == Self.new + [1, 2, 3])
    }

    /// A replacement that is given up leaves the old file as it was, under
    /// its name, with nothing beside it; the writer reads and writes it
    /// again, and a reader's path still leads to its file.
    @Test(arguments: Kind.allCases)
    func aReplacementThatIsAbandonedLeavesTheOldFile(kind: Kind) throws {
        let directory = try Self.folder()
        let writer = try Self.writer(kind, at: directory.path())
        let reader = try FileStorage(path: directory.path(), access: .readOnly)
        #expect(try Self.all(writer.storage) == Self.old)

        try writer.beginReplacement()
        try writeBytes(writer.storage, Array(Self.new.prefix(5000)), at: 0)
        writer.abandonReplacement()
        #expect(!writer.file.isReplacing)
        #expect(!Self.exists(Self.incoming(directory)))
        #expect(try directory.contents() == Self.old)
        #expect(try Self.all(writer.storage) == Self.old)
        #expect(try writer.file.leadsToItsFile())
        #expect(try reader.leadsToItsFile())
        #expect(try Self.all(reader) == Self.old)

        // the old file is written on as before
        try writeBytes(writer.storage, [9, 9], at: UInt64(Self.old.count))
        try writer.storage.flush()
        #expect(try directory.contents() == Self.old + [9, 9])
        // and a replacement can begin again
        try writer.beginReplacement()
        try Self.writeTheNewBytes(writer)
        try writer.commitReplacement()
        #expect(try directory.contents() == Self.new)
    }

    /// A storage that cannot write begins no replacement, and makes no
    /// file.
    @Test func aReaderBeginsNoReplacement() throws {
        let directory = try Self.folder()
        let reader = try FileStorage(path: directory.path(), access: .readOnly)
        #expect(throws: XitDBError.storageFailure(errno: Platform.notOpenForWriting)) { try reader.beginReplacement() }
        #expect(!reader.isReplacing)
        #expect(!Self.exists(Self.incoming(directory)))
    }

    // MARK: The lock

    /// The path's file is never without its writer's lock across a
    /// replacement: a second writer that asks for the lock is refused
    /// before the new file is made, when the new file is about to be given
    /// the name, after it has the name and before the directory is synced,
    /// and after the replacement, while the first writer lives. The new
    /// file is locked before anything is written to it and before the
    /// rename. Once the first writer has gone, the lock can be had.
    @Test(arguments: Kind.allCases)
    func bothLocksAreHeldAcrossTheRename(kind: Kind) throws {
        let directory = try Self.folder()
        let path = directory.path()
        final class Seen {
            var order: [String] = []
            var refusals: [String: Bool] = [:]
        }
        let seen = Seen()
        /// Whether a second writer that asks for the lock on the path is
        /// refused it now.
        func aSecondWriterIsRefused() -> Bool {
            let opening = Result { () throws(XitDBError) -> FileStorage in
                try FileStorage(path: path, access: .readWrite, lock: .exclusive)
            }
            if case .failure(let error) = opening { return error == .storageFailure(errno: EWOULDBLOCK) }
            return false
        }
        let platform = FileCalls()
        var calls = FileCalls()
        calls.open = { (path: String, access: FileAccess) throws(XitDBError) -> Int32 in
            seen.refusals["before the new file is made"] = aSecondWriterIsRefused()
            seen.order.append("open")
            return try platform.open(path, access)
        }
        calls.lock = { (descriptor: Int32, lock: FileLock) throws(XitDBError) -> Void in
            seen.order.append("lock")
            try platform.lock(descriptor, lock)
        }
        calls.write = { (descriptor: Int32, bytes: Span<UInt8>, offset: UInt64) throws(XitDBError) -> Void in
            seen.order.append("write")
            try platform.write(descriptor, bytes, offset)
        }
        calls.rename = { (source: String, destination: String) throws(XitDBError) -> Void in
            seen.refusals["when the new file is about to be given the name"] = aSecondWriterIsRefused()
            seen.order.append("rename")
            try platform.rename(source, destination)
        }
        calls.syncDirectory = { (path: String, call: SyncCall) in
            seen.refusals["after the rename, before the directory is synced"] = aSecondWriterIsRefused()
            seen.order.append("sync directory")
            return platform.syncDirectory(path, call)
        }
        // The replacement's own failure is looked at after what was seen.
        // The rule about a leftover and the rule about the lock depend on
        // each other: a writer that holds the lock removes a new file it
        // finds beside the database, because by the lock nobody is writing
        // it. So a second writer that were let in during a replacement
        // would remove the first writer's new file, and the first writer's
        // rename would fail with "no such file"; which is what happens
        // when the old file's lock is let go too early, and the reason the
        // lock is held across the whole replacement.
        var failure: (any Error)?
        do {
            let writer = try Self.writer(kind, at: path, calls: calls, durability: .full)
            #expect(aSecondWriterIsRefused())
            try writer.beginReplacement()
            try Self.writeTheNewBytes(writer)
            try writer.commitReplacement()
            #expect(aSecondWriterIsRefused(), "after the replacement, while the first writer lives")
        } catch {
            failure = error
        }
        #expect(
            seen.refusals == [
                "before the new file is made": true,
                "when the new file is about to be given the name": true,
                "after the rename, before the directory is synced": true,
            ])
        #expect(failure == nil, "\(String(describing: failure))")
        #expect(try directory.contents() == Self.new)
        // the new file is locked before a byte is in it, and before it has the name
        let lock = try #require(seen.order.firstIndex(of: "lock"))
        #expect(lock == seen.order.firstIndex(of: "open").map { $0 + 1 })
        #expect(lock < (try #require(seen.order.firstIndex(of: "write"))))
        #expect(lock < (try #require(seen.order.firstIndex(of: "rename"))))
        #expect(seen.order.contains("sync directory"))
        // with the first writer gone, the lock is free
        #expect(!aSecondWriterIsRefused())
    }

    // MARK: Every call failing

    /// Each file call of a replacement fails in turn: the beginning, the
    /// new bytes and their syncs, the end. Whoever runs the three steps
    /// gives the replacement up when a step throws while it is under way,
    /// as a full copy will. After each failure the path has the old file,
    /// whole, or, once the new file has been given the name, the new one;
    /// and once a writer that holds the lock has opened the path again,
    /// no file is left beside it.
    @Test(arguments: Kind.allCases)
    func everyCallOfAReplacementFailingInTurn(kind: Kind) throws {
        /// One replacement with one call failing, or none.
        func replace(failing: Int?) throws -> (directory: TemporaryDirectory, counted: CountedFileCalls, threw: Bool) {
            let directory = try Self.folder()
            let counted = CountedFileCalls()
            let writer = try Self.writer(kind, at: directory.path(), calls: counted.calls, durability: .full)
            counted.failing = failing
            counted.counting = true
            var threw = false
            do {
                try writer.beginReplacement()
                try Self.writeTheNewBytes(writer)
                try writer.commitReplacement()
            } catch {
                threw = true
                if writer.file.isReplacing { writer.abandonReplacement() }
            }
            counted.counting = false
            #expect(!writer.file.isReplacing)
            return (directory, counted, threw)
        }

        let whole = try replace(failing: nil)
        #expect(!whole.threw)
        #expect(try whole.directory.contents() == Self.new)
        let calls = whole.counted.made
        // the removal of a leftover, the new file's making, its lock, its
        // attributes' call is not a file call of the storage's own and is
        // not counted; its emptying, the bytes, the syncs, the rename and
        // the directory's sync
        for call in ["remove", "open", "lock", "cut to nothing", "write", "sync", "rename", "sync directory"] {
            #expect(calls.contains(call), "\(call) in \(calls)")
        }

        for index in calls.indices {
            let (directory, counted, threw) = try replace(failing: index)
            let step = "with call \(index) failing, \(counted.failed ?? "none"), of \(calls)"
            #expect(counted.failed == calls[index], "\(step)")
            let renamed = counted.succeeded.contains("rename")
            #expect(try directory.contents() == (renamed || !threw ? Self.new : Self.old), "\(step)")
            // the next writer with the lock finds that file, and leaves nothing beside it
            let next = try Self.writer(kind, at: directory.path())
            #expect(try Self.all(next.storage) == (renamed || !threw ? Self.new : Self.old), "\(step)")
            #expect(!Self.exists(Self.incoming(directory)), "\(step)")
        }
    }

    /// The call that gives the new file the old one's attributes failing
    /// is the beginning's failure: nothing is begun, no file is left, and
    /// the old file is as it was.
    @Test(arguments: Kind.allCases)
    func theAttributesCallFailingBeginsNothing(kind: Kind) throws {
        let directory = try Self.folder()
        var calls = FileCalls()
        calls.carryAttributes = { (_: Int32, _: Int32) throws(XitDBError) -> Void in
            throw .storageFailure(errno: EPERM)
        }
        let writer = try Self.writer(kind, at: directory.path(), calls: calls)
        #expect(throws: XitDBError.storageFailure(errno: EPERM)) { try writer.beginReplacement() }
        #expect(!writer.file.isReplacing)
        #expect(!Self.exists(Self.incoming(directory)))
        #expect(try directory.contents() == Self.old)
        #expect(try Self.all(writer.storage) == Self.old)
    }

    // MARK: What is left behind, and a path that is a link

    /// A file left beside the database by a copy that did not end is
    /// removed by a writer that opens the database with its lock, and left
    /// alone by a reader and by a writer that holds no lock.
    @Test func aLeftoverIsRemovedByAWriterWithTheLockAndLeftAloneByOthers() throws {
        let directory = try Self.folder()
        #expect(FileManager.default.createFile(atPath: Self.incoming(directory), contents: Data([1, 2, 3])))
        do {
            _ = try FileStorage(path: directory.path(), access: .readOnly)
            #expect(Self.exists(Self.incoming(directory)), "a reader leaves it")
            _ = try FileStorage(path: directory.path(), access: .readOnly, lock: .shared)
            #expect(Self.exists(Self.incoming(directory)), "a reader with a shared lock leaves it")
            _ = try FileStorage(path: directory.path(), access: .readWrite)
            #expect(Self.exists(Self.incoming(directory)), "a writer without the lock leaves it")
            _ = try BufferedFileStorage(path: directory.path(), access: .readWrite)
            #expect(Self.exists(Self.incoming(directory)), "a buffered writer without the lock leaves it")
        }
        _ = try FileStorage(path: directory.path(), access: .readWrite, lock: .exclusive)
        #expect(!Self.exists(Self.incoming(directory)), "the writer with the lock removes it")
        #expect(try directory.contents() == Self.old)
    }

    /// A path that is a symbolic link: the storage resolves it once, at
    /// opening, and a replacement gives the real file's name to the new
    /// file, so that the link stays a link and leads to the new file. A
    /// reader that opened the link before is told that its path no longer
    /// leads to its file; and so is any storage whose link is changed to
    /// lead elsewhere, the writer among them, which goes on with the file
    /// it opened.
    @Test(arguments: Kind.allCases)
    func aPathThatIsALinkKeepsItsLink(kind: Kind) throws {
        let directory = try Self.folder()
        let link = directory.path("link.db")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: directory.path())
        let writer = try Self.writer(kind, at: link)
        #expect(writer.file.path == link)
        #expect(writer.file.realPath == (try Platform.realPath(directory.path())))
        let reader = try FileStorage(path: link, access: .readOnly)
        #expect(try reader.leadsToItsFile())

        try writer.beginReplacement()
        #expect(Self.exists(Self.incoming(directory)), "the new file is beside the real file")
        #expect(!Self.exists(link + FileStorage.incomingSuffix))
        try Self.writeTheNewBytes(writer)
        try writer.commitReplacement()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == directory.path())
        #expect(try [UInt8](Data(contentsOf: URL(fileURLWithPath: link))) == Self.new)
        #expect(try writer.file.leadsToItsFile())
        #expect(try reader.leadsToItsFile() == false)

        // the link is changed to lead to another file
        #expect(FileManager.default.createFile(atPath: directory.path("elsewhere.db"), contents: Data([4, 5, 6])))
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: directory.path("elsewhere.db"))
        #expect(try writer.file.leadsToItsFile() == false)
        // the writer goes on with the real file it opened
        try writeBytes(writer.storage, [8], at: UInt64(Self.new.count))
        try writer.storage.flush()
        #expect(try directory.contents() == Self.new + [8])
        #expect(try directory.contents("elsewhere.db") == [4, 5, 6])
    }

    /// A file that has been removed is not at its path; nor one whose name
    /// another file has been given; a path that still leads to the file
    /// is.
    @Test func whetherAPathLeadsToItsFile() throws {
        let directory = try Self.folder()
        let storage = try FileStorage(path: directory.path(), access: .readOnly)
        #expect(try storage.leadsToItsFile())
        #expect(try BufferedFileStorage(path: directory.path(), access: .readOnly).leadsToItsFile())

        #expect(FileManager.default.createFile(atPath: directory.path("other.db"), contents: Data([1])))
        try Platform.renameFile(directory.path("other.db"), to: directory.path())
        #expect(try storage.leadsToItsFile() == false, "another file has the name")
        #expect(try Self.all(storage) == Self.old)

        let second = try FileStorage(path: directory.path(), access: .readOnly)
        #expect(try second.leadsToItsFile())
        try FileManager.default.removeItem(atPath: directory.path())
        #expect(try second.leadsToItsFile() == false, "no file has the name")
        #expect(try Platform.leads(directory.path("no such folder/x.db"), to: second.descriptor.rawValue) == false)
        #expect(throws: XitDBError.storageFailure(errno: EINVAL)) {
            try Platform.leads(directory.path() + "\0x", to: second.descriptor.rawValue)
        }
    }

    /// The real path of a file is the file's own, through any links, and a
    /// path that leads nowhere is the system's error.
    @Test func theRealPathOfAFile() throws {
        let directory = try Self.folder()
        let real = try Platform.realPath(directory.path())
        try FileManager.default.createSymbolicLink(atPath: directory.path("a"), withDestinationPath: directory.path())
        try FileManager.default.createSymbolicLink(
            atPath: directory.path("b"), withDestinationPath: directory.path("a"))
        #expect(try Platform.realPath(directory.path("b")) == real)
        #expect(try Platform.realPath(real) == real)
        #expect(throws: XitDBError.storageFailure(errno: ENOENT)) { try Platform.realPath(directory.path("absent")) }
        #expect(throws: XitDBError.storageFailure(errno: EINVAL)) { try Platform.realPath(directory.path() + "\0x") }
    }
}
