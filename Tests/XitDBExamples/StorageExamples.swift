import Testing
import XitDB

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

@Suite("Storage") struct StorageExamples {
    @Test func theThreeStorages() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }

        // A file, through a buffer: the one to use for a file.
        let buffered = try BufferedFileStorage(path: scratch.path("main.db"), access: .create)
        _ = try Database(creating: buffered, hashSize: 32)

        // A file, with a system call for every read and write.
        let reader = try FileStorage(path: scratch.path("main.db"), access: .readOnly)
        _ = try Database(opening: reader)

        // Memory.
        let memory = MemoryStorage()
        _ = try Database(creating: memory, hashSize: 32)
    }

    @Test func accessModes() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }

        // A path that does not exist is an error, unless you ask for a new file.
        #expect(throws: XitDBError.self) {
            try BufferedFileStorage(path: scratch.path("mistyped.db"), access: .readWrite)
        }
        #expect(throws: XitDBError.self) {
            try BufferedFileStorage(path: scratch.path("mistyped.db"), access: .readOnly)
        }
        _ = try BufferedFileStorage(path: scratch.path("new.db"), access: .create)
        _ = try BufferedFileStorage(path: scratch.path("new.db"), access: .readWrite)

        let existing = try BufferedFileStorage(path: scratch.path("new.db"), access: .create)
        let database = try Database(creating: existing, hashSize: 32)
        #expect(try database.committedSize == 57)

        // `.truncate` empties it.
        let emptied = try BufferedFileStorage(path: scratch.path("new.db"), access: .truncate)
        #expect(try emptied.length == 0)
    }

    @Test func aPathWithANulByteIsRefused() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }
        #expect(throws: XitDBError.storageFailure(errno: EINVAL)) {
            try FileStorage(path: scratch.path("main.db") + "\0.txt", access: .create)
        }
    }

    @Test func openingAndCreatingAreDifferent() throws {
        let storage = MemoryStorage()
        #expect(throws: XitDBError.invalidDatabase) {
            try Database(opening: storage)
        }
        _ = try Database(creating: storage, hashSize: 32)
        #expect(throws: XitDBError.storageNotEmpty) {
            try Database(creating: storage, hashSize: 32)
        }
    }

    @Test func openOrCreate() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }

        let storage = try BufferedFileStorage(path: scratch.path("main.db"), access: .create)
        let database =
            try storage.length == 0
            ? Database(creating: storage, hashSize: 32, hashID: "sha2")
            : Database(opening: storage, hashSize: 32)
        #expect(database.header.hashSize == 32)
    }

    @Test func theReaderPattern() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }

        // The writer.
        let writerStorage = try BufferedFileStorage(path: scratch.path("main.db"), access: .create)
        let writer = try Database(creating: writerStorage, hashSize: 32)
        let history = try ArrayList<ReadWrite>(writer.rootCursor)
        try history.append(.slot(nil))

        // The reader: a storage of its own, opened read-only.
        let storage = try FileStorage(path: scratch.path("main.db"), access: .readOnly)
        let database = try Database(opening: storage)
        let list = try ArrayList<ReadOnly>(database.rootCursor)
        #expect(try list.count == 1)

        // A read through the root sees the writer's later commits.
        try history.append(.slot(nil))
        #expect(try list.count == 2)

        // A write through the root fails, and changes nothing.
        #expect(throws: XitDBError.self) {
            try ArrayList<ReadWrite>(database.rootCursor).append(.uint(1))
        }
        #expect(try list.count == 2)
    }

    @Test func aLockIsNeverWaitedFor() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }

        // The writer holds an exclusive lock for as long as its storage lives.
        let writer = try BufferedFileStorage(
            path: scratch.path("main.db"), access: .create, lock: .exclusive)

        // A second writer does not wait: opening it fails at once.
        #expect(throws: XitDBError.storageFailure(errno: EWOULDBLOCK)) {
            try BufferedFileStorage(path: scratch.path("main.db"), access: .readWrite, lock: .exclusive)
        }
        // So does a reader who asks for a lock.
        #expect(throws: XitDBError.storageFailure(errno: EWOULDBLOCK)) {
            try BufferedFileStorage(path: scratch.path("main.db"), access: .readOnly, lock: .shared)
        }
        // A lock is advisory: one who does not ask gets in.
        _ = try FileStorage(path: scratch.path("main.db"), access: .readOnly)
        _ = writer
    }

    @Test func aMemoryStorageIsBytes() throws {
        // A database as a value to send.
        let source = MemoryStorage()
        let database = try Database(creating: source, hashSize: 32)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put(.uint(42), forHash: sha256("answer"))

        let bytes = source.bytes

        // On the other side there is nothing to decode.
        let received = try Database(opening: MemoryStorage(bytes: bytes))
        let answers = try HashMap<ReadOnly>(received.rootCursor)
        let answer = try answers.cursor(forHash: sha256("answer"))!.readUInt64()
        #expect(answer == 42)
    }

    @Test func aLimitOnAMemoryStorage() throws {
        // Writes that would pass the limit fail, and the transaction with them.
        let storage = MemoryStorage(maxSize: 1000)
        let database = try Database(creating: storage, hashSize: 32)
        #expect(storage.maxSize == 1000)
        #expect(throws: XitDBError.maxSizeExceeded) {
            try HashMap<ReadWrite>(database.rootCursor)
                .put(.bytes([UInt8](repeating: 1, count: 2000)), forHash: sha256("large"))
        }
        #expect(try database.committedSize < 1000)
    }

    @Test func theBufferLimit() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }
        let storage = try BufferedFileStorage(
            path: scratch.path("main.db"), access: .create, bufferLimit: 64 * 1024)
        #expect(storage.bufferLimit == 64 * 1024)
        #expect(BufferedFileStorage.defaultBufferLimit == 2 * 1024 * 1024)
    }

    // A storage of your own: here, bytes in an array, for all to see.
    final class ArrayStorage: WritableStorage {
        private(set) var bytes: [UInt8] = []

        func read(
            into buffer: inout MutableSpan<UInt8>,
            range: Range<Int>,
            at offset: UInt64
        ) throws(XitDBError) -> Int {
            guard offset < UInt64(bytes.count) else { return 0 }
            let start = Int(offset)
            let count = min(range.count, bytes.count - start)
            for index in 0..<count {
                buffer[range.lowerBound + index] = bytes[start + index]
            }
            return count
        }

        var length: UInt64 {
            UInt64(bytes.count)
        }

        func write(_ newBytes: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
            guard newBytes.count > 0 else { return }
            let end = Int(offset) + newBytes.count
            if end > bytes.count {
                bytes.append(contentsOf: repeatElement(0, count: end - bytes.count))
            }
            for index in 0..<newBytes.count {
                bytes[Int(offset) + index] = newBytes[index]
            }
        }

        func truncate(to length: UInt64) throws(XitDBError) {
            guard length <= UInt64(bytes.count) else { throw .invalidLength }
            bytes.removeLast(bytes.count - Int(length))
        }

        func flush() throws(XitDBError) {}

        func sync(_ point: SyncPoint) throws(XitDBError) {}
    }

    @Test func aStorageOfYourOwn() throws {
        let storage = ArrayStorage()
        let database = try Database(creating: storage, hashSize: 32, fileID: 1)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            try HashMap<ReadWrite>(cursor).put(.uint(42), forHash: sha256("answer"))
        }
        let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
        #expect(try moment.cursor(forHash: sha256("answer"))!.readUInt64() == 42)

        // It holds what any storage holds, so the bytes open anywhere.
        let copy = try Database(opening: MemoryStorage(bytes: storage.bytes))
        #expect(try ArrayList<ReadOnly>(copy.rootCursor).count == 1)

        // A new database's bytes depend only on its header.
        let expected = MemoryStorage()
        _ = try Database(creating: expected, hashSize: 32, fileID: 1)
        let fresh = ArrayStorage()
        _ = try Database(creating: fresh, hashSize: 32, fileID: 1)
        #expect(fresh.bytes == expected.bytes)
    }

    @Test func truncatingOnlyEverShortens() throws {
        let storage = MemoryStorage()
        _ = try Database(creating: storage, hashSize: 32)
        #expect(throws: XitDBError.invalidLength) {
            try storage.truncate(to: 1000)
        }
    }
}
