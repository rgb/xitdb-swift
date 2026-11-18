import Foundation
import Testing
import XitDBHashing

@testable import XitDB

/// A file opened to be read (decision D67): `ReadOnlyFileStorage`, the
/// public face of the file storage in its reading mode. It opens a file
/// that is there and makes none, reads it, has no way to write, needs no
/// lock, also for a memory map, takes one if asked, says whether its path
/// still leads to its file, and under a `ReadOnlyDatabase` gives the engine
/// its file storage by class. That a `Database` does not open over it, that
/// it is no storage to recover, and that it is not sent to another thread
/// are held by the gate's compile check
/// (`scripts/must-not-compile/RefusedReadOnly.swift`, `RefusedSendable.swift`).
@Suite struct ReadOnlyFileStorageTests {
    /// A database of one list of `count` numbers in the file at `path`.
    private static func write(_ count: Int, at path: String) throws {
        let database = try Database(
            creating: try BufferedFileStorage(path: path, access: .truncate, durability: .none), hashing: SHA256.self)
        try database.withTransaction { root in
            let list = try ArrayList(root)
            for number in 0..<count { try list.append(UInt64(number)) }
        }
    }

    /// The file's access mode, as the system has it for a descriptor.
    private static func accessMode(of descriptor: Int32) -> Int32 {
        fcntl(descriptor, F_GETFL) & O_ACCMODE
    }

    // MARK: Opening

    /// It opens a file that is there, and makes none where there is none:
    /// that is an error, `ENOENT`, with the folder as it was.
    @Test func itOpensAFileThatIsThereAndMakesNone() throws {
        let directory = try TemporaryDirectory()
        #expect(throws: XitDBError.storageFailure(errno: ENOENT)) { try ReadOnlyFileStorage(path: directory.path()) }
        #expect(throws: XitDBError.storageFailure(errno: ENOENT)) {
            try ReadOnlyFileStorage(path: directory.path(), lock: .shared, reading: .memoryMap)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == [])

        #expect(FileManager.default.createFile(atPath: directory.path(), contents: Data([1, 2, 3])))
        let storage = try ReadOnlyFileStorage(path: directory.path())
        #expect(try storage.length == 3)
        #expect(try directory.contents() == [1, 2, 3])
    }

    /// The file is opened for reading and nothing more, as the system has
    /// it for the descriptor; a storage that writes has it for both.
    @Test func theFileIsOpenedForReadingAlone() throws {
        let directory = try TemporaryDirectory()
        let writer = try FileStorage(path: directory.path(), access: .create)
        #expect(Self.accessMode(of: writer.descriptor.rawValue) == O_RDWR)
        for reading in [FileReading.fileCalls, .memoryMap, .memoryMapReadAhead] {
            let reader = try ReadOnlyFileStorage(path: directory.path(), reading: reading)
            #expect(Self.accessMode(of: reader.file.descriptor.rawValue) == O_RDONLY, "\(reading)")
            #expect(reader.file.isReadOnly, "\(reading)")
        }
    }

    /// It is a storage to read and no storage to write, as a value too: a
    /// program that holds it as a readable storage cannot find a writable
    /// one behind it.
    @Test func itIsNoWritableStorage() throws {
        let directory = try TemporaryDirectory()
        #expect(FileManager.default.createFile(atPath: directory.path(), contents: Data([1, 2, 3])))
        let storage: any ReadableStorage = try ReadOnlyFileStorage(path: directory.path())
        #expect(storage as? any WritableStorage == nil)
        #expect(storage is ReadOnlyFileStorage)
    }

    // MARK: Reading

    /// What it reads is the file: whole, in parts, short at the end, and
    /// nothing past it; and its length is the file's, as the file grows
    /// under it.
    @Test(arguments: [FileReading.fileCalls, .memoryMap, .memoryMapReadAhead])
    func itReadsTheFile(reading: FileReading) throws {
        let directory = try TemporaryDirectory()
        let bytes = (0..<300).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let writer = try FileStorage(path: directory.path(), access: .create, durability: .none)
        try writeBytes(writer, bytes, at: 0)

        let storage = try ReadOnlyFileStorage(path: directory.path(), reading: reading)
        #expect(try storage.length == 300)
        #expect(try readBytes(storage, at: 0, count: 300) == bytes)
        #expect(try readBytes(storage, at: 17, count: 40) == Array(bytes[17..<57]))
        #expect(try readBytes(storage, at: 290, count: 50) == Array(bytes[290...]))
        #expect(try readBytes(storage, at: 300, count: 10) == [])
        #expect(try readBytes(storage, at: 5_000, count: 10) == [])
        // into a part of a buffer, the rest of which is left alone
        var buffer = [UInt8](repeating: 0xEE, count: 20)
        var span = buffer.mutableSpan
        #expect(try storage.read(into: &span, range: 5..<9, at: 100) == 4)
        #expect(
            buffer == [UInt8](repeating: 0xEE, count: 5) + Array(bytes[100..<104]) + [UInt8](repeating: 0xEE, count: 11)
        )

        // the writer goes on, and the reader reads what is there now
        try writeBytes(writer, [9, 8, 7], at: 300)
        #expect(try storage.length == 303)
        #expect(try readBytes(storage, at: 298, count: 10) == Array(bytes[298...]) + [9, 8, 7])
    }

    // MARK: The lock and the map

    /// How it reads its file is what was asked for: file calls where
    /// nothing is said, and either map, which it has with no lock, beside
    /// a writer that holds the exclusive one. A storage that writes is
    /// refused a map without that lock.
    @Test func itNeedsNoLockForAMap() throws {
        let directory = try TemporaryDirectory()
        try Self.write(2_000, at: directory.path())
        let writer = try FileStorage(path: directory.path(), access: .readWrite, lock: .exclusive, reading: .memoryMap)
        #expect(writer.isMemoryMapped)

        #expect(try ReadOnlyFileStorage(path: directory.path()).requestedReading == .fileCalls)
        #expect(try ReadOnlyFileStorage(path: directory.path()).isMemoryMapped == false)
        for reading in [FileReading.memoryMap, .memoryMapReadAhead] {
            let reader = try ReadOnlyFileStorage(path: directory.path(), reading: reading)
            #expect(reader.requestedReading == reading)
            #expect(reader.isMemoryMapped, "\(reading)")
            // and a database over it reads through the map what is committed
            let database = try ReadOnlyDatabase(opening: reader, hashing: SHA256.self)
            #expect(try ArrayList(database.rootCursor).count == 2_000, "\(reading)")
            #expect(reader.file.mappedLimit == (try database.committedSize), "\(reading)")
        }
        #expect(throws: XitDBError.memoryMapNeedsLock) {
            try FileStorage(path: directory.path(), access: .readWrite, reading: .memoryMap)
        }
        withExtendedLifetime(writer) {}
    }

    /// A reader that asked for a map on a volume the library does not map
    /// reads by file calls and says so, with no error.
    @Test func aMapThatWasNotHadIsSaid() throws {
        let directory = try TemporaryDirectory()
        try Self.write(10, at: directory.path())
        var calls = FileCalls()
        calls.isLocal = { _ in false }
        let reader = try ReadOnlyFileStorage(
            path: directory.path(), reading: .memoryMap, segmentSize: Platform.pageSize, calls: calls)
        #expect(reader.requestedReading == .memoryMap)
        #expect(!reader.isMemoryMapped)
        #expect(try ArrayList(try ReadOnlyDatabase(opening: reader, hashing: SHA256.self).rootCursor).count == 10)
    }

    /// No lock is taken unless one is asked for. One that is asked for is
    /// taken and never waited for: a shared lock is refused while a writer
    /// holds the exclusive one, is held beside another reader's, keeps a
    /// writer out while it is held, and goes with the storage.
    @Test func itTakesALockOnlyIfAsked() throws {
        let directory = try TemporaryDirectory()
        try Self.write(10, at: directory.path())
        let busy = XitDBError.storageFailure(errno: EWOULDBLOCK)
        do {
            let writer = try FileStorage(path: directory.path(), access: .readWrite, lock: .exclusive)
            #expect(throws: Never.self) { _ = try ReadOnlyFileStorage(path: directory.path()) }
            #expect(throws: busy) { try ReadOnlyFileStorage(path: directory.path(), lock: .shared) }
            #expect(throws: busy) { try ReadOnlyFileStorage(path: directory.path(), lock: .exclusive) }
            withExtendedLifetime(writer) {}
        }
        do {
            // a reader that asked for none keeps nobody out
            let unlocked = try ReadOnlyFileStorage(path: directory.path())
            #expect(throws: Never.self) {
                _ = try FileStorage(path: directory.path(), access: .readWrite, lock: .exclusive)
            }
            withExtendedLifetime(unlocked) {}
        }
        do {
            let first = try ReadOnlyFileStorage(path: directory.path(), lock: .shared)
            let second = try ReadOnlyFileStorage(path: directory.path(), lock: .shared)
            #expect(throws: busy) { try FileStorage(path: directory.path(), access: .readWrite, lock: .exclusive) }
            withExtendedLifetime((first, second)) {}
        }
        // the readers have gone, and their locks with them
        #expect(throws: Never.self) {
            _ = try FileStorage(path: directory.path(), access: .readWrite, lock: .exclusive)
        }
        do {
            let alone = try ReadOnlyFileStorage(path: directory.path(), lock: .exclusive)
            #expect(throws: busy) { try ReadOnlyFileStorage(path: directory.path(), lock: .shared) }
            withExtendedLifetime(alone) {}
        }
    }

    // MARK: Where the path leads

    /// A reader keeps the file it opened when another file is given the
    /// name, and is told: its path no longer leads to its file, it reads
    /// the old bytes on, and one that opens the path then has the new
    /// file.
    @Test func itSaysWhetherItsPathStillLeadsToItsFile() throws {
        let directory = try TemporaryDirectory()
        #expect(FileManager.default.createFile(atPath: directory.path(), contents: Data([1, 2, 3])))
        let reader = try ReadOnlyFileStorage(path: directory.path())
        #expect(try reader.isStillAtPath)

        #expect(FileManager.default.createFile(atPath: directory.path("other.db"), contents: Data([7, 7])))
        try Platform.renameFile(directory.path("other.db"), to: directory.path())
        #expect(try reader.isStillAtPath == false)
        #expect(try readBytes(reader, at: 0, count: 10) == [1, 2, 3])
        let again = try ReadOnlyFileStorage(path: directory.path())
        #expect(try again.isStillAtPath)
        #expect(try readBytes(again, at: 0, count: 10) == [7, 7])

        try FileManager.default.removeItem(atPath: directory.path())
        #expect(try again.isStillAtPath == false)
        #expect(try readBytes(again, at: 0, count: 10) == [7, 7])
    }

    // MARK: Under a database

    /// Under a `ReadOnlyDatabase` the engine holds the file storage the
    /// type is the face of, by its class, and not the face behind the
    /// protocol: its reads are the file storage's own, and a snapshot of
    /// the database reads the file through the storage's descriptor and
    /// map, where a snapshot of a storage behind the protocol would be a
    /// copy of the committed bytes.
    @Test(arguments: [FileReading.fileCalls, .memoryMap, .memoryMapReadAhead])
    func theEngineHoldsItsFileStorageByClass(reading: FileReading) throws {
        let directory = try TemporaryDirectory()
        try Self.write(500, at: directory.path())
        let storage = try ReadOnlyFileStorage(path: directory.path(), reading: reading, segmentSize: Platform.pageSize)
        let database = try ReadOnlyDatabase(opening: storage, hashing: SHA256.self)
        guard case .file(let held) = database.engine.storage else {
            Issue.record("the engine does not hold a file storage: \(database.engine.storage)")
            return
        }
        #expect(held === storage.file)

        let snapshot = try database.snapshot()
        guard case .file(let descriptor, _, let view) = snapshot.storage.source else {
            Issue.record("a snapshot of a database in a file opened to be read is a copy")
            return
        }
        #expect(descriptor === storage.file.descriptor)
        #expect((view != nil) == (reading != .fileCalls))
        #expect(try ArrayList(snapshot.rootCursor).count == 500)
    }

    /// Nothing is written through it, by the system's calls: opening a
    /// database over it, reading, a snapshot, the reading side of
    /// replication and a compaction from it make no write to the file, set
    /// no length, sync nothing, open no second file and rename or remove
    /// none; by file calls and through a map.
    @Test(arguments: [FileReading.fileCalls, .memoryMap])
    func nothingIsWrittenThroughIt(reading: FileReading) throws {
        final class Counted {
            var changes: [String] = []
            var reads = 0
        }
        let counted = Counted()
        var calls = FileCalls()
        let read = calls.read
        calls.read = {
            (descriptor: Int32, buffer: inout MutableSpan<UInt8>, range: Range<Int>, offset: UInt64)
                throws(XitDBError) -> Int in
            counted.reads += 1
            return try read(descriptor, &buffer, range, offset)
        }
        calls.write = { (_: Int32, _: Span<UInt8>, _: UInt64) throws(XitDBError) in counted.changes.append("write") }
        calls.setLength = { (_: Int32, _: UInt64) throws(XitDBError) in counted.changes.append("set length") }
        calls.sync = { (_: Int32, _: SyncCall) in
            counted.changes.append("sync")
            return 0
        }
        calls.open = { (_: String, _: FileAccess) throws(XitDBError) -> Int32 in
            counted.changes.append("open")
            throw .storageFailure(errno: EIO)
        }
        calls.rename = { (_: String, _: String) throws(XitDBError) in counted.changes.append("rename") }
        calls.remove = { (_: String) throws(XitDBError) -> Bool in
            counted.changes.append("remove")
            return false
        }

        let directory = try TemporaryDirectory()
        try Self.write(3_000, at: directory.path())
        let before = try directory.contents()
        #expect(FileManager.default.createFile(atPath: directory.path() + ".incoming", contents: Data([1])))

        let storage = try ReadOnlyFileStorage(
            path: directory.path(), lock: .exclusive, reading: reading, segmentSize: Platform.pageSize, calls: calls)
        let database = try ReadOnlyDatabase(opening: storage, hashing: SHA256.self)
        var sum: UInt64 = 0
        var iterator = try ArrayList(database.rootCursor).iterator()
        while let number = try iterator.next()?.read(UInt64.self) { sum += number }
        #expect(sum == 3_000 * 2_999 / 2)
        let snapshot = try database.snapshot()
        #expect(try ArrayList(snapshot.rootCursor).count == 3_000)
        let committed = try database.committedSize
        #expect(try database.readCommitted(from: 0, to: committed).count == Int(committed))
        #expect(try database.replicationStart(for: try database.replicaState) == committed)
        var offsets = MemoryOffsetMap()
        // a compaction keeps the root list's last element, the last moment
        let compacted = try database.compact(into: MemoryStorage(), offsetMap: &offsets)
        #expect(try ArrayList(compacted.rootCursor.readOnly).value(at: 0, as: UInt64.self) == 2_999)

        #expect(counted.changes == [])
        #expect(counted.reads > 0, "the counting is live")
        #expect(try directory.contents() == before)
        // a reader with the exclusive lock is no writer: what a full copy
        // that did not end left beside the file is not its to remove
        #expect(FileManager.default.fileExists(atPath: directory.path() + ".incoming"))
    }
}
