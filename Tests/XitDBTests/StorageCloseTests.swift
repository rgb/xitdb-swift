import Foundation
import Testing
import XitDBHashing

@testable import XitDB

/// `close()` on the three file storage types (the first client's review of
/// 0.5.1, item 13; decision D66): the file given up now. The lock is let
/// go at once; every later read and write is refused with `storageClosed`,
/// on the storage and through everything made over it, and makes no
/// system call; the file is closed at once unless a snapshot holds it, and
/// then when the last snapshot goes; a snapshot taken before reads on.
@Suite struct StorageCloseTests {
    /// The three file storage types, each read by file calls and through a
    /// memory map.
    enum Kind: String, CaseIterable, CustomTestStringConvertible {
        case file, mappedFile, bufferedFile, mappedBufferedFile, readOnlyFile, mappedReadOnlyFile

        var testDescription: String { rawValue }

        var isMapped: Bool { self == .mappedFile || self == .mappedBufferedFile || self == .mappedReadOnlyFile }
        var writes: Bool { self != .readOnlyFile && self != .mappedReadOnlyFile }

        /// The kinds that write.
        static let writers = allCases.filter(\.writes)
    }

    /// The system calls a storage made, by name, in order.
    final class Calls {
        var made: [String] = []

        /// A set of file calls, each of which is written down here before
        /// it is made.
        func counting() -> FileCalls {
            var calls = FileCalls()
            let (sync, write, read, length, setLength) = (
                calls.sync, calls.write, calls.read, calls.length, calls.setLength
            )
            let (map, isLocal, open, lock, rename) = (calls.map, calls.isLocal, calls.open, calls.lock, calls.rename)
            let (syncDirectory, remove, advise, carry) = (
                calls.syncDirectory, calls.remove, calls.advise, calls.carryAttributes
            )
            calls.sync = { [self] (descriptor: Int32, call: SyncCall) in
                made.append("sync")
                return sync(descriptor, call)
            }
            calls.write = { [self] (descriptor: Int32, bytes: Span<UInt8>, offset: UInt64) throws(XitDBError) in
                made.append("write")
                try write(descriptor, bytes, offset)
            }
            calls.read = {
                [self] (descriptor: Int32, buffer: inout MutableSpan<UInt8>, range: Range<Int>, offset: UInt64)
                    throws(XitDBError) -> Int in
                made.append("read")
                return try read(descriptor, &buffer, range, offset)
            }
            calls.length = { [self] (descriptor: Int32) throws(XitDBError) -> UInt64 in
                made.append("length")
                return try length(descriptor)
            }
            calls.setLength = { [self] (descriptor: Int32, length: UInt64) throws(XitDBError) in
                made.append("set length")
                try setLength(descriptor, length)
            }
            calls.map = { [self] (descriptor: Int32, offset: UInt64, length: Int) in
                made.append("map")
                return map(descriptor, offset, length)
            }
            calls.isLocal = { [self] (descriptor: Int32) in
                made.append("is local")
                return isLocal(descriptor)
            }
            calls.open = { [self] (path: String, access: FileAccess) throws(XitDBError) -> Int32 in
                made.append("open")
                return try open(path, access)
            }
            calls.lock = { [self] (descriptor: Int32, kind: FileLock) throws(XitDBError) in
                made.append("lock")
                try lock(descriptor, kind)
            }
            calls.rename = { [self] (from: String, to: String) throws(XitDBError) in
                made.append("rename")
                try rename(from, to)
            }
            calls.syncDirectory = { [self] (path: String, call: SyncCall) in
                made.append("sync directory")
                return syncDirectory(path, call)
            }
            calls.remove = { [self] (path: String) throws(XitDBError) -> Bool in
                made.append("remove")
                return try remove(path)
            }
            calls.advise = { [self] (address: UInt, length: Int) in
                made.append("advise")
                advise(address, length)
            }
            calls.carryAttributes = { [self] (old: Int32, new: Int32) throws(XitDBError) in
                made.append("carry attributes")
                try carry(old, new)
            }
            return calls
        }
    }

    /// A file with a database of one list in it, and a storage of one kind
    /// opened on it, whose system calls are written down.
    struct Subject {
        let directory: TemporaryDirectory
        let calls = Calls()
        /// The file storage underneath, which every kind has.
        let file: FileStorage
        /// The storage as a client holds it.
        let storage: any ReadableStorage
        /// The same where it writes.
        let writable: (any WritableStorage)?
        let close: () -> Bool
        let isStillAtPath: () throws(XitDBError) -> Bool

        init(_ kind: Kind, numbers: Int = 500, lock: Bool = true) throws {
            directory = try TemporaryDirectory()
            do {
                let made = try Database(
                    creating: try BufferedFileStorage(path: directory.path(), access: .create, durability: .none),
                    hashing: SHA256.self)
                try made.withTransaction { root in
                    let list = try ArrayList(root)
                    for number in 0..<numbers { try list.append(UInt64(number)) }
                }
            }
            let reading: FileReading = kind.isMapped ? .memoryMap : .fileCalls
            switch kind {
            case .file, .mappedFile, .bufferedFile, .mappedBufferedFile:
                // the map needs the writer's lock
                let file = try FileStorage(
                    path: directory.path(), access: .readWrite, durability: .none,
                    lock: lock || kind.isMapped ? .exclusive : nil, reading: reading, segmentSize: Platform.pageSize,
                    calls: calls.counting())
                self.file = file
                if kind == .file || kind == .mappedFile {
                    (storage, writable) = (file, file)
                    close = { file.close() }
                    isStillAtPath = { () throws(XitDBError) in try file.isStillAtPath }
                } else {
                    let buffered = BufferedFileStorage(file)
                    (storage, writable) = (buffered, buffered)
                    close = { buffered.close() }
                    isStillAtPath = { () throws(XitDBError) in try buffered.isStillAtPath }
                }
            case .readOnlyFile, .mappedReadOnlyFile:
                let reader = try ReadOnlyFileStorage(
                    path: directory.path(), lock: lock ? .shared : nil, reading: reading,
                    segmentSize: Platform.pageSize, calls: calls.counting())
                file = reader.file
                (storage, writable) = (reader, nil)
                close = { reader.close() }
                isStillAtPath = { () throws(XitDBError) in try reader.isStillAtPath }
            }
            guard file.isMemoryMapped == kind.isMapped else { throw NotReadThroughTheMap(path: directory.path()) }
        }

        /// A database over the storage: the one that writes where the
        /// storage does, and the one that only reads otherwise.
        func database() throws -> any ReadableDatabase {
            if let writable { return try Database(opening: writable, hashing: SHA256.self) }
            return try ReadOnlyDatabase(opening: storage, hashing: SHA256.self)
        }

        /// How many of the process's descriptors are open on the file: of
        /// the descriptors the system lists as open, the ones that lead to
        /// it. (Asking every number a descriptor could have takes a
        /// quarter of a second where the table is large.)
        func descriptorsOpen() -> Int {
            #if canImport(Darwin)
                let listing = "/dev/fd"
            #else
                let listing = "/proc/self/fd"
            #endif
            let open = (try? FileManager.default.contentsOfDirectory(atPath: listing))?.compactMap { Int32($0) } ?? []
            return open.count { (try? Platform.leads(directory.path(), to: $0)) == true }
        }
    }

    private static let closed = XitDBError.storageClosed

    /// A read-only cursor at a database's root, whichever database it is.
    private static func root(of database: some ReadableDatabase) -> Cursor<ReadOnly> {
        database.rootCursor.readOnly
    }

    // MARK: Every later call

    /// After `close()` every call on the storage is refused with
    /// `storageClosed`, the file is closed where no snapshot holds it, the
    /// storage says it reads through no map, and closing again does
    /// nothing and says the same.
    @Test(arguments: Kind.allCases)
    func everyLaterCallOnTheStorageIsRefused(kind: Kind) throws {
        let subject = try Subject(kind)
        #expect(try readBytes(subject.storage, at: 0, count: 3) == [0x78, 0x69, 0x74])
        #expect(subject.descriptorsOpen() == 1)

        #expect(subject.close())
        #expect(subject.descriptorsOpen() == 0, "the file is closed while the storage lives")
        #expect(subject.file.isClosed)
        #expect(!subject.file.isMemoryMapped)

        #expect(throws: Self.closed) { try readBytes(subject.storage, at: 0, count: 3) }
        #expect(throws: Self.closed) { try readBytes(subject.storage, at: 100, count: 3) }
        #expect(throws: Self.closed) { try subject.storage.length }
        #expect(throws: Self.closed) { try subject.isStillAtPath() }
        #expect(throws: Self.closed) { try subject.file.leadsToItsFile() }
        if let writable = subject.writable {
            #expect(throws: Self.closed) { try writeBytes(writable, [1, 2, 3], at: 0) }
            #expect(throws: Self.closed) { try writeBytes(writable, [1, 2, 3], at: 1 << 20) }
            #expect(throws: Self.closed) { try writable.truncate(to: 0) }
            #expect(throws: Self.closed) { try writable.truncate(to: 1 << 30) }
            #expect(throws: Self.closed) { try writable.flush() }
            #expect(throws: Self.closed) { try writable.sync(.beforeRootHeader) }
            #expect(throws: Self.closed) { try writable.sync(.afterRootHeader) }
            // writing nothing is nothing, as on every storage
            #expect(throws: Never.self) { try writeBytes(writable, [], at: 0) }
            // and a write that was refused left nothing behind to be read:
            // a buffered storage took none of it into its window
            #expect(throws: Self.closed) { try readBytes(writable, at: 0, count: 3) }
            #expect(throws: Self.closed) { try readBytes(writable, at: 1 << 20, count: 3) }
        }
        // the engine's own calls
        #expect(throws: Self.closed) { try subject.file.resize(to: 10) }
        #expect(throws: Self.closed) { try subject.file.beginReplacement() }
        var buffer = [UInt8](repeating: 0, count: 8)
        var span = buffer.mutableSpan
        #expect(throws: Self.closed) { try subject.file.readForStream(into: &span, range: 0..<8, at: 0) }
        subject.file.abandonReplacement()
        #expect(throws: Never.self) { try subject.file.commitReplacement() }

        // again: nothing more, and the same answer
        #expect(subject.close())
        #expect(subject.close())
        #expect(throws: Self.closed) { try subject.storage.length }
        // and the file is as it was
        #expect(try ReadOnlyFileStorage(path: subject.directory.path()).length > 57)
    }

    /// Asks everything of a storage that was closed, and of a database, a
    /// collection, a cursor and an iterator that were made over it before:
    /// whatever comes to read or write is refused with `storageClosed`;
    /// what was read before the close and is held is still given, since
    /// nothing is asked of the storage for it: a number in a cursor's own
    /// slot, the elements an iterator had read.
    private static func askEverything(
        of subject: Subject, _ database: any ReadableDatabase, root: Cursor<ReadOnly>, list: ArrayList<ReadOnly>,
        iterator: inout CollectionIterator, element: Cursor<ReadOnly>
    ) throws {
        #expect(throws: Self.closed) { try readBytes(subject.storage, at: 0, count: 64) }
        #expect(throws: Self.closed) { try readBytes(subject.storage, at: 4_000, count: 64) }
        #expect(throws: Self.closed) { try subject.storage.length }
        #expect(throws: Self.closed) { try subject.isStillAtPath() }
        if let writable = subject.writable {
            #expect(throws: Self.closed) { try writeBytes(writable, [1], at: 0) }
            #expect(throws: Self.closed) { try writable.truncate(to: 0) }
            #expect(throws: Self.closed) { try writable.flush() }
            #expect(throws: Self.closed) { try writable.sync(.afterRootHeader) }
        }
        // what was made over it before: a collection is refused,
        #expect(throws: Self.closed) { try list.count }
        #expect(throws: Self.closed) { try list.value(at: 3, as: UInt64.self) }
        #expect(throws: Self.closed) { try list.cursor(at: 9) }
        #expect(throws: Self.closed) { try ArrayList(Self.root(of: database)).count }
        // a cursor gives the number its own slot holds, which was read
        // before the close, and is refused what it would have to read,
        #expect(try element.read(UInt64.self) == 7)
        #expect(throws: Self.closed) { try ArrayList(root).count }
        // and an iterator gives the elements it had read and is refused
        // when it comes to read again, long before the list's end.
        var given = 1
        var refusal: XitDBError?
        do throws(XitDBError) {
            while try iterator.next() != nil { given += 1 }
        } catch {
            refusal = error
        }
        #expect(refusal == Self.closed)
        #expect(given < 100)
        // the database's own members
        #expect(throws: Self.closed) { try database.committedSize }
        #expect(throws: Self.closed) { try database.snapshot() }
        #expect(throws: Self.closed) { try database.replicaState }
        #expect(throws: Self.closed) { try database.readCommitted(from: 0, to: 57) }
        var offsets = MemoryOffsetMap()
        let target = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        #expect(throws: Self.closed) { try database.compact(into: target, offsetMap: &offsets) }
        if let writer = database as? Database {
            #expect(throws: Self.closed) {
                try writer.withTransaction { root in try ArrayList(root).append(UInt64(1)) }
            }
            #expect(throws: Self.closed) { try ArrayList<ReadWrite>(writer.rootCursor).append(UInt64(1)) }
            let other = try Database(creating: MemoryStorage(), hashing: SHA256.self)
            let whole = try other.readCommitted(from: 0, to: try other.committedSize)
            #expect(throws: Self.closed) { try writer.applyReplicated(at: 0, bytes: whole) }
            #expect(throws: Self.closed) { try Database.recover(try #require(subject.writable)) }
            #expect(throws: Self.closed) { try Database(opening: try #require(subject.writable)) }
            #expect(throws: Self.closed) { try Database(creating: try #require(subject.writable), hashSize: 32) }
        }
        #expect(throws: Self.closed) { try ReadOnlyDatabase(opening: subject.storage) }
        // the engine's own calls on the file storage, which do not go
        // through the storage's protocol
        #expect(throws: Self.closed) { try subject.file.resize(to: 10) }
        #expect(throws: Self.closed) { try subject.file.leadsToItsFile() }
        #expect(throws: Self.closed) { try subject.file.beginReplacement() }
        var stream = [UInt8](repeating: 0, count: 8)
        var span = stream.mutableSpan
        #expect(throws: Self.closed) { try subject.file.readForStream(into: &span, range: 0..<8, at: 0) }
        subject.file.abandonReplacement()
        #expect(throws: Never.self) { try subject.file.commitReplacement() }
        #expect(!subject.file.isMemoryMapped)
        #expect(subject.close(), "asked again, it says the same and does nothing")
    }

    /// After `close()` a call makes no system call: nothing is read,
    /// written, cut, synced, locked, mapped, opened, renamed or removed
    /// through the storage, whatever is asked of it and of a database, a
    /// cursor, a collection and an iterator made over it before. Whatever
    /// comes to read or write is refused. What was read before the close
    /// and is held is still given, since nothing is asked of the storage
    /// for it: a number in a cursor's own slot, the elements an iterator
    /// had read.
    @Test(arguments: Kind.allCases)
    func noSystemCallIsMadeAfterClose(kind: Kind) throws {
        let subject = try Subject(kind)
        let database = try subject.database()
        let root = Self.root(of: database)
        let list = try ArrayList(root)
        var iterator = try list.iterator()
        #expect(try iterator.next()?.read(UInt64.self) == 0)
        let element = try #require(try list.cursor(at: 7))
        #expect(!subject.calls.made.isEmpty, "the counting is live")

        #expect(subject.close())
        let before = subject.calls.made

        try Self.askEverything(of: subject, database, root: root, list: list, iterator: &iterator, element: element)

        #expect(subject.calls.made == before, "system calls after close: \(subject.calls.made.dropFirst(before.count))")
        #expect(!FileManager.default.fileExists(atPath: subject.directory.path() + ".incoming"))
    }

    /// The hazard itself, whatever way a call would go: once the file is
    /// closed, the system gives its descriptor's number to the next file
    /// that is opened, and a call the closed storage still made on its
    /// number would land on that file. So another file is given the
    /// number, with a lock on it and a position of its own, and
    /// everything is asked of the closed storage and of what was made
    /// over it; then they go. The other file's bytes, and with them its
    /// length, its position and its lock are as they were.
    ///
    /// The count of calls through the storage's table cannot see a member
    /// that reaches the system another way. This can.
    @Test(arguments: Kind.allCases)
    func nothingReachesAFileThatHasTheNumberAfterwards(kind: Kind) throws {
        let other = try TemporaryDirectory()
        let bytes = Array("the other file's bytes, which nothing of a closed storage's may touch".utf8)
        #expect(FileManager.default.createFile(atPath: other.path(), contents: Data(bytes)))
        // opened before the close, under a number of its own
        let first = try FileDescriptor(opening: other.path(), .toWrite(.readWrite))
        var given: Int32 = -1
        defer { if given >= 0 { Platform.closeFile(given) } }

        // Tests beside this one open files too, and one of them can be
        // given the number first: then this is tried again, with another
        // storage, and only a test that never had the number is given up.
        var numbers: [Int32] = []
        for _ in 1...50 where given < 0 {
            let subject = try Subject(kind)
            let database = try subject.database()
            let root = Self.root(of: database)
            let list = try ArrayList(root)
            var iterator = try list.iterator()
            #expect(try iterator.next()?.read(UInt64.self) == 0)
            let element = try #require(try list.cursor(at: 7))
            let number = subject.file.descriptor.rawValue
            #expect(number > 2)

            #expect(subject.close())
            #expect(subject.descriptorsOpen() == 0)
            // The number is free, and the other file is given the lowest
            // free number from it on: the same, unless another test opened
            // a file in between.
            let duplicate = fcntl(first.rawValue, F_DUPFD_CLOEXEC, number)
            guard duplicate == number else {
                numbers.append(number)
                if duplicate >= 0 { Platform.closeFile(duplicate) }
                continue
            }
            given = duplicate
            try Platform.lockFile(given, .exclusive)
            #expect(lseek(given, 5, SEEK_SET) == 5)

            try Self.askEverything(
                of: subject, database, root: root, list: list, iterator: &iterator, element: element)
            #expect(subject.file.descriptor.rawValue != number, "a closed storage holds no file's number")
        }
        if given < 0 {
            try Test.cancel(
                "in fifty tries the closed storage's number was taken by another test's file each time: \(numbers)")
        }
        // The closed storage, its database and what was made over it have
        // gone. The other file is as it was: its bytes and its length,
        #expect(try other.contents() == bytes)
        // its position,
        #expect(lseek(given, 0, SEEK_CUR) == 5)
        // and its lock, which a second opener is still refused.
        #expect(throws: XitDBError.storageFailure(errno: EWOULDBLOCK)) {
            try FileStorage(path: other.path(), access: .readWrite, lock: .exclusive)
        }
        withExtendedLifetime(first) {}
    }

    // MARK: The lock

    /// The lock is let go at once: while the storage lives, and while a
    /// snapshot keeps the file open, the next opener has the lock it asks
    /// for.
    @Test(arguments: Kind.allCases)
    func theLockIsLetGoAtOnce(kind: Kind) throws {
        let subject = try Subject(kind)
        let path = subject.directory.path()
        let snapshot = try subject.database().snapshot()
        #expect(throws: XitDBError.storageFailure(errno: EWOULDBLOCK)) {
            try FileStorage(path: path, access: .readWrite, lock: .exclusive)
        }

        #expect(subject.close() == false, "a snapshot holds the file")
        #expect(subject.descriptorsOpen() == 1)
        // The next opener is not refused the lock, though the file is
        // still open for the snapshot.
        var next: FileStorage?
        #expect(throws: Never.self) { next = try FileStorage(path: path, access: .readWrite, lock: .exclusive) }
        #expect(next != nil)
        #expect(subject.descriptorsOpen() == (next == nil ? 1 : 2))
        // And the snapshot is not refused: the close took nothing from
        // under it.
        var count: UInt64?
        #expect(throws: Never.self) { count = try ArrayList(snapshot.rootCursor).count }
        #expect(count == 500)
        withExtendedLifetime(subject.file) {}
    }

    // MARK: Snapshots

    /// A snapshot taken before the close goes on reading its commit, is
    /// never refused, and keeps the file open: `close()` says so, and the
    /// file is closed, and its map unmapped, when the last snapshot goes.
    /// No snapshot is taken of a closed storage.
    @Test(arguments: Kind.allCases)
    func aSnapshotTakenBeforeReadsOnAndKeepsTheFileOpen(kind: Kind) throws {
        let subject = try Subject(kind)
        let database = try subject.database()
        var first: Snapshot? = try database.snapshot()
        var second: Snapshot? = try database.snapshot()
        weak var segment: MappedSegment?
        if kind.isMapped {
            guard case .file(_, _, let view?) = try #require(first).storage.source else {
                Issue.record("a snapshot of a mapped file reads through no map")
                return
            }
            segment = view.segments[0]
            #expect(segment != nil)
        }

        #expect(subject.close() == false)
        #expect(subject.close() == false, "asked again while a snapshot lives")
        #expect(subject.descriptorsOpen() == 1)
        #expect(throws: Self.closed) { try database.snapshot() }

        // both read their commit, whole, by a walk and as bytes, and
        // neither is refused
        for snapshot in [try #require(first), try #require(second)] {
            var sum: UInt64 = 0
            var bytes = 0
            #expect(throws: Never.self) {
                var iterator = try ArrayList(snapshot.rootCursor).iterator()
                while let number = try iterator.next()?.read(UInt64.self) { sum += number }
                bytes = try SnapshotDatabase(snapshot).readCommitted(from: 0, to: snapshot.committedSize).count
            }
            #expect(sum == 500 * 499 / 2)
            #expect(bytes == Int(snapshot.committedSize))
        }

        first = nil
        #expect(subject.close() == false, "one snapshot is left")
        #expect(subject.descriptorsOpen() == 1)
        if kind.isMapped { #expect(segment != nil) }
        var count: UInt64?
        #expect(throws: Never.self) { count = try ArrayList(try #require(second).rootCursor).count }
        #expect(count == 500)

        second = nil
        #expect(subject.descriptorsOpen() == 0, "the last snapshot has gone")
        #expect(segment == nil, "and the map with it")
        #expect(subject.close(), "and close says so")
        withExtendedLifetime(database) {}
    }

    /// With no snapshot the map is unmapped as the storage is closed,
    /// while the storage and its database live.
    @Test(arguments: [Kind.mappedFile, .mappedBufferedFile, .mappedReadOnlyFile])
    func theMapIsUnmappedAtOnceWhereNoSnapshotHoldsIt(kind: Kind) throws {
        let subject = try Subject(kind)
        let database = try subject.database()
        weak var segment: MappedSegment?
        do {
            let snapshot = try database.snapshot()
            guard case .file(_, _, let view?) = snapshot.storage.source else {
                Issue.record("a snapshot of a mapped file reads through no map")
                return
            }
            segment = view.segments[0]
        }
        #expect(segment != nil, "the storage holds its map")
        #expect(subject.close())
        #expect(segment == nil)
        #expect(subject.descriptorsOpen() == 0)
        withExtendedLifetime(database) {}
    }

    // MARK: A transaction, and a full copy

    /// Closed inside a transaction, the transaction's next write fails,
    /// the transaction fails with it, and nothing of it is committed: the
    /// file reads as it did, and the next writer opens it and commits.
    @Test(arguments: Kind.writers)
    func closedInsideATransactionNothingIsCommitted(kind: Kind) throws {
        let subject = try Subject(kind)
        let database = try #require(try subject.database() as? Database)
        let committed = try database.committedSize

        #expect(throws: Self.closed) {
            try database.withTransaction { root in
                let list = try ArrayList(root)
                for number in 0..<300 { try list.append(UInt64(1_000 + number)) }
                #expect(subject.close())
                try list.append(UInt64(9_999))
            }
        }
        #expect(throws: Self.closed) { try database.committedSize }
        #expect(subject.descriptorsOpen() == 0)

        let reader = try ReadOnlyDatabase(opening: try ReadOnlyFileStorage(path: subject.directory.path()))
        #expect(try reader.committedSize == committed)
        #expect(try ArrayList(reader.rootCursor).count == 500)

        let next = try Database(
            opening: try BufferedFileStorage(path: subject.directory.path(), access: .readWrite, durability: .none),
            hashing: SHA256.self)
        try next.withTransaction { root in try ArrayList(root).append(UInt64(500)) }
        #expect(try ArrayList(next.rootCursor.readOnly).count == 501)
        #expect(try ArrayList(next.rootCursor.readOnly).value(at: 500, as: UInt64.self) == 500)
    }

    /// What a buffered storage holds and has not written is dropped by its
    /// close, as it is when a process ends.
    @Test(arguments: [Kind.bufferedFile, .mappedBufferedFile])
    func aBufferedStoragesUnwrittenBytesAreDropped(kind: Kind) throws {
        let subject = try Subject(kind)
        let writable = try #require(subject.writable)
        let before = try subject.directory.contents()
        try writeBytes(writable, [7, 7, 7, 7], at: UInt64(before.count))
        #expect(try writable.length == UInt64(before.count) + 4)
        #expect(try subject.directory.contents() == before, "held in the window")

        #expect(subject.close())
        #expect(try subject.directory.contents() == before)
        // what the window held is gone with it: a read of those bytes is
        // refused as every read is, and nothing is left to flush
        #expect(throws: Self.closed) { try readBytes(writable, at: UInt64(before.count), count: 4) }
        #expect(throws: Self.closed) { try writable.length }
        #expect(throws: Self.closed) { try writable.flush() }
        #expect(try subject.directory.contents() == before)
    }

    /// A source of a full copy that closes the storage it is copied onto.
    private struct ClosingSource: ByteSource {
        var bytes: [UInt8]
        var position = 0
        let closeAfter: Int
        let close: () -> Bool
        var closed: Bool?

        mutating func read(into buffer: inout MutableSpan<UInt8>) throws -> Int {
            if position >= closeAfter, closed == nil { closed = close() }
            let count = min(buffer.count, bytes.count - position, 1_000)
            for index in 0..<count { buffer[index] = bytes[position + index] }
            position += count
            return count
        }
    }

    /// Closed while a full copy onto it is under way, by the copy's own
    /// source: the copy fails with `storageClosed` and is given up as one
    /// that failed is: the new file is removed, the old one keeps the name
    /// and its bytes, and the next opener has the old database.
    @Test(arguments: Kind.writers)
    func closedDuringAFullCopyTheCopyIsGivenUp(kind: Kind) throws {
        let other = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try other.withTransaction { root in
            let list = try ArrayList(root)
            for number in 0..<2_000 { try list.append(UInt64(number * 3)) }
        }
        let incoming = try other.readCommitted(from: 0, to: try other.committedSize)
        #expect(incoming.count > 12_000)

        let subject = try Subject(kind)
        let database = try #require(try subject.database() as? Database)
        let before = try subject.directory.contents()
        var source = ClosingSource(bytes: incoming, closeAfter: 9_000, close: subject.close)

        #expect(throws: Self.closed) {
            try database.applyReplicated(at: 0, from: &source, count: UInt64(incoming.count))
        }
        #expect(source.closed == true, "the copy's source closed the storage, and the file was closed then")
        #expect(!FileManager.default.fileExists(atPath: subject.directory.path() + ".incoming"))
        #expect(try subject.directory.contents() == before)
        #expect(subject.descriptorsOpen() == 0)
        #expect(!subject.file.isReplacing)
        #expect(throws: Self.closed) { try database.committedSize }

        let reader = try ReadOnlyDatabase(opening: try ReadOnlyFileStorage(path: subject.directory.path()))
        #expect(try ArrayList(reader.rootCursor).count == 500)
        // and the next writer has the lock and no leftover to remove
        #expect(throws: Never.self) {
            _ = try FileStorage(path: subject.directory.path(), access: .readWrite, lock: .exclusive)
        }
    }

    /// The result need not be looked at, on each of the three types: a
    /// call that is a statement compiles with warnings as errors.
    @Test func theResultNeedNotBeLookedAt() throws {
        let directory = try TemporaryDirectory()
        let file = try FileStorage(path: directory.path(), access: .create)
        file.close()
        let buffered = try BufferedFileStorage(path: directory.path(), access: .readWrite)
        buffered.close()
        let reader = try ReadOnlyFileStorage(path: directory.path())
        reader.close()
        #expect(file.isClosed && buffered.file.isClosed && reader.file.isClosed)
    }

    // MARK: The storage's end

    /// A storage that was closed lets go of nothing a second time when it
    /// goes: a file opened since under a number the system has given
    /// again keeps its lock.
    @Test func aClosedStorageLetsNothingGoWhenItGoes() throws {
        let directory = try TemporaryDirectory()
        #expect(FileManager.default.createFile(atPath: directory.path(), contents: Data([1, 2, 3])))
        var next: FileStorage?
        do {
            let first = try FileStorage(path: directory.path(), access: .readWrite, lock: .exclusive)
            #expect(first.close())
            // the system gives the lowest free number, which is the one
            // the closed storage had
            next = try FileStorage(path: directory.path(), access: .readWrite, lock: .exclusive)
        }
        // the first storage has gone: the second still holds its lock
        #expect(throws: XitDBError.storageFailure(errno: EWOULDBLOCK)) {
            try FileStorage(path: directory.path(), access: .readWrite, lock: .exclusive)
        }
        #expect(try readBytes(try #require(next), at: 0, count: 3) == [1, 2, 3])
    }
}
