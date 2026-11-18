import Foundation
import Testing
import XitDBHashing

@testable import XitDB

/// A storage of the caller's own that can only read, and is no class: the
/// bytes it was given.
struct ReadingBytes: ReadableStorage {
    let bytes: [UInt8]

    func read(into buffer: inout MutableSpan<UInt8>, range: Range<Int>, at offset: UInt64) throws(XitDBError) -> Int {
        guard offset < UInt64(bytes.count) else { return 0 }
        let start = Int(offset)
        let count = min(range.count, bytes.count - start)
        for index in 0..<count { buffer[range.lowerBound + index] = bytes[start + index] }
        return count
    }

    var length: UInt64 { UInt64(bytes.count) }
}

/// A storage of the caller's own that can only read, over a memory storage
/// that a writer goes on writing to: what a reader that follows a writer
/// has, without a file.
final class ReadingWindow: ReadableStorage {
    private let memory: MemoryStorage

    init(onto memory: MemoryStorage) {
        self.memory = memory
    }

    func read(into buffer: inout MutableSpan<UInt8>, range: Range<Int>, at offset: UInt64) throws(XitDBError) -> Int {
        try memory.read(into: &buffer, range: range, at: offset)
    }

    var length: UInt64 { get throws(XitDBError) { try memory.length } }
}

/// The database that is opened to be read and has no writing members (the
/// first client's review of 0.5.1, item 12; decision D66): it opens what a
/// ``Database`` opens, follows a writer as one does, gives itself back as a
/// read-only cursor's database, serves what a database serves a reader,
/// and writes nothing. That a write through it does not compile is held by
/// the gate's compile check, `scripts/must-not-compile/RefusedReadOnly.swift`.
@Suite struct ReadOnlyDatabaseTests {
    /// A reader's storage of its own on a writer's file, as a client has
    /// it: a file opened to be read, read by file calls and through a
    /// memory map in either of its two ways.
    enum ReaderKind: String, CaseIterable, CustomTestStringConvertible {
        case file, fileMap, fileMapReadAhead

        var testDescription: String { rawValue }

        var reading: FileReading {
            switch self {
            case .file: .fileCalls
            case .fileMap: .memoryMap
            case .fileMapReadAhead: .memoryMapReadAhead
            }
        }

        /// The file at a path opened to be read, with no lock, mapped in
        /// segments of one page so that what is read crosses from one to the
        /// next; a kind that is to read through a map is held to it.
        func open(_ path: String) throws -> ReadOnlyFileStorage {
            let storage = try ReadOnlyFileStorage(path: path, reading: reading, segmentSize: Platform.pageSize)
            guard storage.isMemoryMapped == (reading != .fileCalls) else { throw NotReadThroughTheMap(path: path) }
            return storage
        }
    }

    /// The bytes under "blob" after a round's commit: long enough that a
    /// few commits pass a page.
    private static func blob(_ round: Int) -> [UInt8] {
        [UInt8](repeating: UInt8(truncatingIfNeeded: round), count: 3000)
    }

    /// One commit of the writer: the round's number under "n", bytes under
    /// "blob", and the number appended to the list under "items".
    private static func commit(_ round: Int, through writer: Database) throws {
        try writer.withTransaction { root in
            let map = try HashMap(root)
            try map.put(UInt64(round), forKey: "n")
            try map.put(blob(round), forKey: "blob")
            try ArrayList(try map.putCursor(forKey: "items")).append(UInt64(round))
        }
    }

    /// What a reader sees at a root: the number, the bytes, the list's
    /// count and its last element, all read through the one cursor.
    private struct State: Equatable {
        var n: UInt64?
        var blob: [UInt8]?
        var count: UInt64?
        var last: UInt64?

        init(round: Int) {
            n = UInt64(round)
            blob = ReadOnlyDatabaseTests.blob(round)
            count = UInt64(round)
            last = UInt64(round)
        }

        init(at root: Cursor<ReadOnly>) throws {
            let map = try HashMap(root)
            n = try map.value(forKey: "n", as: UInt64.self)
            blob = try map.value(forKey: "blob", as: [UInt8].self)
            if let items = try map.cursor(forKey: "items") {
                let list = try ArrayList(items)
                count = try list.count
                last = try list.value(at: -1, as: UInt64.self)
            }
        }
    }

    // MARK: A reader beside a writer

    /// What a reader that follows a writer is held to, whichever database
    /// it opened: after each commit a new root cursor reads that commit,
    /// and so does one held from the start, and a collection made from it
    /// once; what was reached from an earlier root stays at its commit; the
    /// committed size is the writer's.
    private func follows<Reader: ReadableDatabase>(_ reader: Reader, _ writer: Database, rounds: ClosedRange<Int>)
        throws
    {
        let heldRoot = reader.rootCursor.readOnly
        let heldMap = try HashMap(heldRoot)
        var earlier: (round: Int, number: Cursor<ReadOnly>, items: ArrayList<ReadOnly>)?
        for round in rounds {
            try Self.commit(round, through: writer)
            let expected = State(round: round)
            #expect(try State(at: reader.rootCursor.readOnly) == expected, "round \(round), a new root cursor")
            #expect(try State(at: heldRoot) == expected, "round \(round), a root cursor held from the start")
            #expect(try heldMap.value(forKey: "n", as: UInt64.self) == UInt64(round), "round \(round), a held map")
            #expect(try reader.committedSize == writer.committedSize, "round \(round)")
            #expect(try reader.replicaState == writer.replicaState, "round \(round)")
            if let earlier {
                #expect(try earlier.number.read(UInt64.self) == UInt64(earlier.round), "round \(round)")
                #expect(try earlier.items.count == UInt64(earlier.round), "round \(round)")
            }
            let map = try HashMap(reader.rootCursor.readOnly)
            earlier = (
                round, try #require(try map.cursor(forKey: "n")),
                try ArrayList(try #require(try map.cursor(forKey: "items")))
            )
        }
    }

    /// A reader on a storage of its own beside a writer on the same file
    /// sees each commit, however its storage reads the file.
    @Test(arguments: ReaderKind.allCases)
    func aReaderOnAStorageOfItsOwnSeesEachCommitOfAWriter(kind: ReaderKind) throws {
        let directory = try TemporaryDirectory()
        let writer = try Database(
            creating: try BufferedFileStorage(path: directory.path(), access: .create, durability: .none),
            hashing: SHA256.self)
        try Self.commit(1, through: writer)

        let reader = try ReadOnlyDatabase(opening: try kind.open(directory.path()), hashing: SHA256.self)
        #expect(try State(at: reader.rootCursor) == State(round: 1))
        try follows(reader, writer, rounds: 2...30)
        // Thirty commits of three thousand bytes and more: the file has
        // grown past several pages under the reader.
        #expect(try writer.committedSize > UInt64(4 * Platform.pageSize))
    }

    /// The engine's own database over the file storage in its reading
    /// mode, plain and under a buffer, follows a writer as well: the
    /// original's reader, with its one database type, and what a `read_only`
    /// of the conformance fixtures opens. A client cannot open one, since a
    /// `Database` does not open over a `ReadOnlyFileStorage`; the storage
    /// is reached by the package's door.
    @Test(arguments: [FileReading.fileCalls, .memoryMap, .memoryMapReadAhead], [false, true])
    func theEnginesDatabaseOverAFileOpenedToBeReadFollowsAWriter(reading: FileReading, buffered: Bool) throws {
        let directory = try TemporaryDirectory()
        let writer = try Database(
            creating: try BufferedFileStorage(path: directory.path(), access: .create, durability: .none),
            hashing: SHA256.self)
        try Self.commit(1, through: writer)

        let file = try FileStorage(openedToBeReadAt: directory.path(), reading: reading, segmentSize: Platform.pageSize)
        guard file.isMemoryMapped == (reading != .fileCalls) else {
            throw NotReadThroughTheMap(path: directory.path())
        }
        let storage: any WritableStorage = buffered ? BufferedFileStorage(file) : file
        let reader = try Database(opening: storage, hashing: SHA256.self)
        #expect(try State(at: reader.rootCursor.readOnly) == State(round: 1))
        try follows(reader, writer, rounds: 2...30)
        #expect(try writer.committedSize > UInt64(4 * Platform.pageSize))
    }

    /// A storage of the caller's own that can only read is enough, and a
    /// reader over one follows a writer too: here a window onto the
    /// writer's memory.
    @Test func aReaderOnAStorageThatCanOnlyReadSeesEachCommitOfAWriter() throws {
        let memory = MemoryStorage()
        let writer = try Database(creating: memory, hashing: SHA256.self)
        try Self.commit(1, through: writer)
        let reader = try ReadOnlyDatabase(opening: ReadingWindow(onto: memory), hashing: SHA256.self)
        #expect(try State(at: reader.rootCursor) == State(round: 1))
        try follows(reader, writer, rounds: 2...30)
    }

    // MARK: What it opens and what it refuses

    /// It opens what a ``Database`` opens and refuses what that refuses,
    /// with the same error: storages that are no database, or not a whole
    /// one, or one of another hash size, each given to both.
    @Test func itOpensWhatADatabaseOpensAndRefusesWhatThatRefuses() throws {
        let memory = MemoryStorage()
        let writer = try Database(creating: memory, hashing: SHA256.self)
        try Self.commit(1, through: writer)
        try Self.commit(2, through: writer)
        let good = memory.bytes
        let header = writer.header

        /// The bytes with some of them changed.
        func changed(_ range: Range<Int>, to byte: UInt8) -> [UInt8] {
            var bytes = good
            for index in range { bytes[index] = byte }
            return bytes
        }
        let sizeAt = Int(header.fileSizePosition)
        let cases: [(name: String, bytes: [UInt8], expected: XitDBError?)] = [
            ("a whole database", good, nil),
            ("with bytes of a transaction that did not finish after it", good + [UInt8](repeating: 7, count: 100), nil),
            ("nothing", [], .invalidDatabase),
            ("no database", [UInt8](repeating: 0x41, count: 200), .invalidDatabase),
            ("a version this package does not read", changed(4..<6, to: 0xFF), .invalidVersion),
            ("cut inside the headers", Array(good.prefix(sizeAt + 3)), .endOfStream),
            (
                "a committed size past the end", changed(sizeAt..<(sizeAt + 8), to: 0x7F),
                .untrustedRootHeader(lastVerified: UInt64(good.count))
            ),
            (
                "cut inside the last commit", Array(good.dropLast(5)),
                .untrustedRootHeader(lastVerified: try Self.sizeAfterTheFirstCommit())
            ),
        ]
        for (name, bytes, expected) in cases {
            /// The error opening gives, or `nil` where it opens.
            func outcome(_ open: () throws(XitDBError) -> Void) -> XitDBError? {
                do throws(XitDBError) {
                    try open()
                    return nil
                } catch {
                    return error
                }
            }
            let database = outcome { () throws(XitDBError) in _ = try Database(opening: MemoryStorage(bytes: bytes)) }
            let readOnly = outcome { () throws(XitDBError) in
                _ = try ReadOnlyDatabase(opening: MemoryStorage(bytes: bytes))
            }
            let reading = outcome { () throws(XitDBError) in
                _ = try ReadOnlyDatabase(opening: ReadingBytes(bytes: bytes))
            }
            #expect(database == expected, "\(name): a database")
            #expect(readOnly == expected, "\(name): the database that only reads")
            #expect(reading == expected, "\(name): the same over a storage that can only read")
        }

        // The hash size asked for, and the hasher's, are held as a
        // database holds them.
        #expect(throws: XitDBError.invalidHashSize) {
            try ReadOnlyDatabase(opening: MemoryStorage(bytes: good), hashSize: 20)
        }
        #expect(throws: XitDBError.invalidHashSize) {
            try ReadOnlyDatabase(opening: MemoryStorage(bytes: good), hashing: Insecure.SHA1.self)
        }
        #expect(throws: Never.self) { try ReadOnlyDatabase(opening: MemoryStorage(bytes: good), hashSize: 32) }
        #expect(throws: Never.self) { try ReadOnlyDatabase(opening: MemoryStorage(bytes: good), hashing: SHA256.self) }
    }

    /// The committed size of the database of the test above after its
    /// first commit of its own: where its file is cut back to when its
    /// second is damaged.
    private static func sizeAfterTheFirstCommit() throws -> UInt64 {
        let memory = MemoryStorage()
        let writer = try Database(creating: memory, hashing: SHA256.self)
        try commit(1, through: writer)
        return try writer.committedSize
    }

    // MARK: A read-only cursor's database

    /// A read-only cursor of it names it as its database, and so does a
    /// cursor of a collection read from it: never the engine underneath,
    /// whose root is read-write. Where the database object has gone and a
    /// cursor is left, the cursor's database is one made again over the
    /// same engine, once, with the hasher the first was given.
    @Test func aReadOnlyCursorsDatabaseIsTheDatabaseThatOnlyReads() throws {
        let memory = MemoryStorage()
        let writer = try Database(creating: memory, hashing: SHA256.self)
        try Self.commit(1, through: writer)

        let database = try ReadOnlyDatabase(opening: memory, hashing: SHA256.self)
        let root = database.rootCursor
        let number = try #require(try HashMap(root).cursor(forKey: "n"))
        #expect(root.database === database)
        #expect(number.database === database)
        #expect(root.database as? Database == nil)
        #expect(number.database is ReadOnlyDatabase)
        // What a holder of the protocol alone has: a snapshot, and through
        // it the root.
        #expect(try State(at: try number.database.snapshot().rootCursor) == State(round: 1))

        /// A cursor of a database that has gone by the time it is returned.
        func orphan() throws -> Cursor<ReadOnly> {
            let gone = try ReadOnlyDatabase(opening: memory, hashing: SHA256.self)
            return try #require(try HashMap(gone.rootCursor).cursor(forKey: "n"))
        }
        let left = try orphan()
        let remade = try #require(left.database as? ReadOnlyDatabase)
        #expect(left.database as? Database == nil)
        #expect(left.database === remade)
        #expect(remade.rootCursor.database === remade)
        // It reads, by key, with the hasher its engine was given.
        #expect(try State(at: remade.rootCursor) == State(round: 1))

        // A database's own read-only cursor still names the database.
        #expect(writer.rootCursor.readOnly.database === writer)
    }

    // MARK: Nothing is written

    /// Nothing is written through it: opening, reading, a snapshot, the
    /// reading side of replication and a compaction from it make no write,
    /// truncation, flush or sync of the storage, on a storage that could
    /// take them.
    @Test func nothingIsWrittenOnAStorageThatCouldBeWritten() throws {
        let memory = MemoryStorage()
        let writer = try Database(creating: memory, hashing: SHA256.self)
        for round in 1...5 { try Self.commit(round, through: writer) }
        // What a writer that died left after its last commit.
        try memory.write([UInt8](repeating: 9, count: 300).span, at: try memory.length)
        let before = memory.bytes

        let counting = CountingWrites(memory)
        let database = try ReadOnlyDatabase(opening: counting, hashing: SHA256.self)
        #expect(try State(at: database.rootCursor) == State(round: 5))
        let snapshot = try database.snapshot()
        #expect(try State(at: snapshot.rootCursor) == State(round: 5))
        let size = try database.committedSize
        #expect(try database.readCommitted(from: 0, to: size) == Array(before.prefix(Int(size))))
        #expect(try database.replicationStart(for: try database.replicaState) == size)
        var offsets = MemoryOffsetMap()
        let compacted = try database.compact(into: MemoryStorage(), offsetMap: &offsets)
        #expect(try State(at: compacted.rootCursor.readOnly) == State(round: 5))

        #expect(counting.calls == 0)
        #expect(memory.bytes == before)
    }

    /// Calls every member a database that only reads has, and holds each to
    /// the last commit, which is the third of ``commit(_:through:)``: the
    /// header, the committed size, a read through the root, a snapshot, the
    /// replica state and where a replica starts, the committed bytes each
    /// of the three ways, both compactions, and a cursor's database and a
    /// snapshot of what the cursor is at.
    private static func callEveryMember(of reader: ReadOnlyDatabase, beside writer: Database, committed: UInt64)
        throws
    {
        #expect(reader.header == writer.header)
        #expect(try reader.committedSize == committed)
        #expect(try State(at: reader.rootCursor) == State(round: 3))
        let snapshot = try reader.snapshot()
        #expect(snapshot.committedSize == committed)
        #expect(try State(at: snapshot.rootCursor) == State(round: 3))
        let state = try reader.replicaState
        #expect(state.committedSize == committed)
        #expect(try reader.replicationStart(for: state) == committed)
        let whole = try reader.readCommitted(from: 0, to: committed)
        #expect(whole.count == Int(committed))
        var appended: [UInt8] = []
        try reader.readCommitted(from: 0, to: committed, into: &appended)
        #expect(appended == whole)
        var sink = ArrayByteSink()
        try reader.readCommitted(from: 0, to: committed, into: &sink)
        #expect(sink.bytes == whole)
        var offsets = MemoryOffsetMap()
        let target = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try reader.compact(into: target, offsetMap: &offsets)
        #expect(try State(at: target.rootCursor.readOnly) == State(round: 3))
        let compacted = try reader.compact(into: MemoryStorage(), offsetMap: &offsets)
        #expect(try State(at: compacted.rootCursor.readOnly) == State(round: 3))
        // A cursor of it, its database, and a snapshot of what it is at.
        let number = try #require(try HashMap(reader.rootCursor).cursor(forKey: "n"))
        #expect(number.database === reader)
        #expect(try Snapshot(number).rootCursor.read(UInt64.self) == 3)
    }

    /// No member writes, flushes, cuts or syncs a storage that can be
    /// written: on each kind, opened to be written, with a writer's
    /// transaction under way on the same storage object, so that the
    /// storage holds bytes past the last commit and a buffered one holds
    /// them in its window. After every member has been called, the bytes on
    /// the disk, the bytes the storage reads and so its length are as they
    /// were, and the writer's transaction commits as if nothing had been
    /// asked.
    @Test(arguments: StorageKind.allCases)
    func noMemberWritesWhereAWritersTransactionIsUnderWay(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let writer = try Database(creating: subject.storage, hashing: SHA256.self)
        for round in 1...3 { try Self.commit(round, through: writer) }
        let committed = try writer.committedSize
        let small = [UInt8](repeating: 0x55, count: 40)
        let large = [UInt8](repeating: 0x66, count: 700)

        try writer.withTransaction { root in
            // The transaction's work so far: a few bytes, which a buffered
            // storage holds in its window, and more than a small window
            // holds.
            let map = try HashMap(root)
            try map.put(small, forKey: "small")
            try map.put(large, forKey: "large")
            try map.put(UInt64(99), forKey: "n")
            let onDisk = try subject.stored()
            let read = try wholeStorage(subject.storage)
            #expect(UInt64(read.count) > committed + 700)

            let reader = try ReadOnlyDatabase(opening: subject.storage, hashing: SHA256.self)
            try Self.callEveryMember(of: reader, beside: writer, committed: committed)

            #expect(try subject.stored() == onDisk, "the bytes on the disk")
            #expect(try wholeStorage(subject.storage) == read, "the bytes the storage reads")
        }

        // The transaction committed as if nothing had been asked.
        let after = try HashMap(writer.rootCursor.readOnly)
        #expect(try after.value(forKey: "n", as: UInt64.self) == 99)
        #expect(try after.value(forKey: "small", as: [UInt8].self) == small)
        #expect(try after.value(forKey: "large", as: [UInt8].self) == large)
        #expect(try ArrayList(try #require(try after.cursor(forKey: "items"))).count == 3)
    }

    /// The same on the two file storages, by the system's calls, which the
    /// bytes cannot show for a sync: with a writer's transaction under way
    /// on the same storage object, no member makes the storage write to
    /// its file, set its length or sync it, read by file calls or through
    /// a map, with a commit's syncs asked for in full.
    @Test(arguments: [false, true], [false, true])
    func noMemberMakesAFileStorageWriteCutOrSync(buffered: Bool, mapped: Bool) throws {
        final class Counted {
            var writes = 0
            var cuts = 0
            var syncs = 0
            var all: [Int] { [writes, cuts, syncs] }
        }
        let counted = Counted()
        var calls = FileCalls()
        let write = calls.write
        let setLength = calls.setLength
        let sync = calls.sync
        calls.write = { (descriptor: Int32, bytes: Span<UInt8>, offset: UInt64) throws(XitDBError) in
            counted.writes += 1
            try write(descriptor, bytes, offset)
        }
        calls.setLength = { (descriptor: Int32, length: UInt64) throws(XitDBError) in
            counted.cuts += 1
            try setLength(descriptor, length)
        }
        calls.sync = { (descriptor: Int32, call: SyncCall) in
            counted.syncs += 1
            return sync(descriptor, call)
        }
        let directory = try TemporaryDirectory()
        let file = try FileStorage(
            path: directory.path(), access: .create, durability: .full, lock: .exclusive,
            reading: mapped ? .memoryMap : .fileCalls, segmentSize: Platform.pageSize, calls: calls)
        guard file.isMemoryMapped == mapped else { throw NotReadThroughTheMap(path: directory.path()) }
        let storage: any WritableStorage = buffered ? BufferedFileStorage(file) : file

        let writer = try Database(creating: storage, hashing: SHA256.self)
        for round in 1...3 { try Self.commit(round, through: writer) }
        let committed = try writer.committedSize
        // The writer's own commits were counted: the counting is live.
        #expect(counted.writes > 0 && counted.syncs >= 6)

        try writer.withTransaction { root in
            let map = try HashMap(root)
            try map.put([UInt8](repeating: 0x55, count: 40), forKey: "small")
            try map.put([UInt8](repeating: 0x66, count: 700), forKey: "large")
            let before = counted.all

            let reader = try ReadOnlyDatabase(opening: storage, hashing: SHA256.self)
            try Self.callEveryMember(of: reader, beside: writer, committed: committed)

            #expect(counted.all == before, "writes, cuts and syncs of the file while the reader was asked")
        }
        #expect(try HashMap(writer.rootCursor.readOnly).value(forKey: "small", as: [UInt8].self)?.count == 40)
    }

    /// Over a storage that can only read, the engine underneath refuses a
    /// write, which nothing public reaches: the backstop a snapshot's
    /// database has.
    @Test func overAStorageThatCanOnlyReadTheEngineRefusesAWrite() throws {
        let memory = MemoryStorage()
        let writer = try Database(creating: memory, hashing: SHA256.self)
        try Self.commit(1, through: writer)

        let database = try ReadOnlyDatabase(opening: ReadingBytes(bytes: memory.bytes), hashing: SHA256.self)
        // Such a storage is the one kind the engine holds behind the
        // protocol, in a class whose writes refuse.
        let behindTheProtocol = if case .custom = database.engine.storage { true } else { false }
        #expect(behindTheProtocol)
        #expect(throws: XitDBError.cursorNotWritable) {
            try database.engine.rootCursor.writePath([
                .hashMapInit(), .hashMapGet(.value, KeyHash(SHA256.keyHash(of: "z"))), .write(.uint(1)),
            ])
        }
        #expect(try State(at: database.rootCursor) == State(round: 1))
        // A snapshot of it is a copy of the committed bytes, and reads.
        #expect(try State(at: try database.snapshot().rootCursor) == State(round: 1))
    }

    // MARK: What it serves

    /// It serves what a ``Database`` on the same storage serves a reader:
    /// the header, the committed size, the replica state and where a
    /// replica starts, the committed bytes, a snapshot, and a compaction
    /// that leaves the bytes a compaction from the database leaves.
    @Test(arguments: StorageKind.allCases)
    func itServesWhatADatabaseServesAReader(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let writer = try Database(
            storage: subject.storage, hashSize: 32, hashID: nil, fileID: 7,
            random: RandomSource(FixedRandom((1...40).map { UInt64($0) })), hasher: KeyHasher(SHA256.self))
        for round in 1...3 { try Self.commit(round, through: writer) }
        let earlier = try writer.replicaState
        for round in 4...6 { try Self.commit(round, through: writer) }
        let before = try wholeStorage(subject.storage)

        let reader = try ReadOnlyDatabase(opening: subject.storage, hashing: SHA256.self)
        // The storage reaches the engine as it is, by its class, and not
        // behind the protocol: so a file's snapshot shares its descriptor
        // and a map is read through, as under a database.
        let byItsClass =
            switch (kind, reader.engine.storage) {
            case (.memory, .memory), (.file, .file), (.mappedFile, .file), (.bufferedFile, .bufferedFile),
                (.bufferedFileSmallWindow, .bufferedFile), (.mappedBufferedFile, .bufferedFile):
                true
            default: false
            }
        #expect(byItsClass, "the engine holds the \(kind) storage another way")
        #expect(reader.header == writer.header)
        let size = try writer.committedSize
        #expect(try reader.committedSize == size)
        #expect(try reader.replicaState == writer.replicaState)
        // A replica at an earlier commit goes on from there; one at the
        // last has nothing to fetch; one of another file starts again.
        #expect(try reader.replicationStart(for: earlier) == earlier.committedSize)
        #expect(try reader.replicationStart(for: try writer.replicaState) == size)
        let foreign = ReplicaState(committedSize: earlier.committedSize, checksum: earlier.checksum ^ 1)
        #expect(try reader.replicationStart(for: foreign) == 0)

        let whole = try writer.readCommitted(from: 0, to: size)
        #expect(try reader.readCommitted(from: 0, to: size) == whole)
        let rest = Array(whole.dropFirst(Int(earlier.committedSize)))
        var appended: [UInt8] = [1, 2]
        try reader.readCommitted(from: earlier.committedSize, to: size, into: &appended)
        #expect(appended == [1, 2] + rest)
        var sink = ArrayByteSink()
        try reader.readCommitted(from: earlier.committedSize, to: size, into: &sink)
        #expect(sink.bytes == rest)
        #expect(throws: XitDBError.invalidRange) { try reader.readCommitted(from: 0, to: size + 1) }

        let snapshot = try reader.snapshot()
        #expect(snapshot.committedSize == size)
        #expect(try State(at: snapshot.rootCursor) == State(round: 6))

        // Two targets alike in everything, their commit IDs included.
        func target() throws -> (MemoryStorage, Database) {
            let storage = MemoryStorage()
            let target = try Database(
                storage: storage, hashSize: 32, hashID: nil, fileID: 9, random: FixedRandom([77, 78, 79]))
            return (storage, target)
        }
        let (fromWriter, writerTarget) = try target()
        var writerOffsets = MemoryOffsetMap()
        try writer.compact(into: writerTarget, offsetMap: &writerOffsets)
        let (fromReader, readerTarget) = try target()
        var readerOffsets = MemoryOffsetMap()
        try reader.compact(into: readerTarget, offsetMap: &readerOffsets)
        #expect(fromReader.bytes == fromWriter.bytes)
        // Nothing of all that was written to the storage it reads.
        #expect(try wholeStorage(subject.storage) == before)

        // The target it opens itself holds the hasher it was given.
        var offsets = MemoryOffsetMap()
        let compacted = try reader.compact(into: MemoryStorage(), fileID: 11, offsetMap: &offsets)
        #expect(compacted.header.fileID == 11)
        #expect(try State(at: compacted.rootCursor.readOnly) == State(round: 6))
        try Self.commit(7, through: compacted)
        #expect(try State(at: compacted.rootCursor.readOnly) == State(round: 7))
    }

    /// Opened with a hash size alone it holds no hasher, as a database
    /// opened so holds none: a read by a hash works, a read by a key says
    /// so.
    @Test func openedWithAHashSizeAloneItTakesHashesAndNoKeys() throws {
        let memory = MemoryStorage()
        let writer = try Database(creating: memory, hashing: SHA256.self)
        try Self.commit(1, through: writer)

        let database = try ReadOnlyDatabase(opening: memory)
        let map = try HashMap(database.rootCursor)
        #expect(throws: XitDBError.noKeyHashing) { try map.value(forKey: "n", as: UInt64.self) }
        #expect(try map.cursor(forHash: SHA256.keyHash(of: "n"))?.read(UInt64.self) == 1)
        #expect(throws: XitDBError.noKeyHashing) {
            try HashMap(try database.snapshot().rootCursor).value(forKey: "n", as: UInt64.self)
        }
    }

    /// Code written against the protocol takes it, with its root where the
    /// root's access is named: it stands beside a snapshot's database as a
    /// reader whose root is read-only.
    @Test func codeWrittenAgainstTheReadingProtocolTakesIt() throws {
        let memory = MemoryStorage()
        let writer = try Database(creating: memory, hashing: SHA256.self)
        try Self.commit(1, through: writer)

        func number(in database: some ReadableDatabase<ReadOnly>) throws -> UInt64? {
            try HashMap(database.rootCursor).value(forKey: "n", as: UInt64.self)
        }
        func size(of database: some ReadableDatabase) throws -> UInt64 {
            try database.committedSize
        }
        let live = try ReadOnlyDatabase(opening: memory, hashing: SHA256.self)
        let readers: [any ReadableDatabase<ReadOnly>] = [live, SnapshotDatabase(try live.snapshot())]
        for reader in readers {
            #expect(try number(in: reader) == 1)
            #expect(try HashMap(reader.rootCursor).value(forKey: "n", as: UInt64.self) == 1)
            #expect(try size(of: reader) == writer.committedSize)
        }

        // The writer goes on: the live reader follows, the snapshot's stays.
        try Self.commit(2, through: writer)
        #expect(try number(in: readers[0]) == 2)
        #expect(try number(in: readers[1]) == 1)
    }
}

/// A storage that passes everything through to another and counts every
/// call that would change it or push it to the disk.
private final class CountingWrites: WritableStorage {
    private let base: any WritableStorage
    private(set) var calls = 0

    init(_ base: any WritableStorage) {
        self.base = base
    }

    func read(into buffer: inout MutableSpan<UInt8>, range: Range<Int>, at offset: UInt64) throws(XitDBError) -> Int {
        try base.read(into: &buffer, range: range, at: offset)
    }

    var length: UInt64 { get throws(XitDBError) { try base.length } }

    func write(_ bytes: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        calls += 1
        try base.write(bytes, at: offset)
    }

    func truncate(to length: UInt64) throws(XitDBError) {
        calls += 1
        try base.truncate(to: length)
    }

    func flush() throws(XitDBError) {
        calls += 1
        try base.flush()
    }

    func sync(_ point: SyncPoint) throws(XitDBError) {
        calls += 1
        try base.sync(point)
    }
}
