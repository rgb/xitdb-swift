import Foundation
import Testing

@testable import XitDB

// Reading a file through a memory map (decision D44): what the map needs,
// and the rules that keep a read of it from ever reaching a part of the
// file that is not there. Every suite over the kinds of storage also runs
// through the map, as the two mapped kinds of `StorageKind`; here are the
// tests of what is the map's own.

/// Counts the calls a file storage makes to read its file and to map it.
private final class CallCounts {
    var reads = 0
    var maps = 0
}

/// An error a test's transaction throws to roll itself back.
private struct RolledBack: Error {}

@Suite struct MemoryMapTests {
    static let page = Platform.pageSize

    /// The two ways of reading through a memory map. They differ in what
    /// the system is told and in nothing the library does, so the tests of
    /// what is read through the map and what is not run on both.
    static let maps: [FileReading] = [.memoryMap, .memoryMapReadAhead]

    /// A file storage that reads through a map of segments of one page,
    /// with its calls counted.
    private static func mapped(
        _ directory: TemporaryDirectory, _ reading: FileReading = .memoryMap
    ) throws -> (FileStorage, CallCounts) {
        let file = try readThroughTheMap(
            try FileStorage(
                path: directory.path(), access: .create, durability: .none, lock: .exclusive, reading: reading,
                segmentSize: page), at: directory.path())
        let counts = CallCounts()
        file.calls.read = {
            (descriptor: Int32, buffer: inout MutableSpan<UInt8>, range: Range<Int>, offset: UInt64)
                throws(XitDBError) -> Int in
            counts.reads += 1
            return try Platform.readFile(descriptor, into: &buffer, range: range, at: offset)
        }
        file.calls.map = { (descriptor: Int32, offset: UInt64, length: Int) in
            counts.maps += 1
            return Platform.mapFile(descriptor, offset: offset, length: length)
        }
        return (file, counts)
    }

    /// The bytes at a file's start that are its two headers, which a storage
    /// never reads through its map.
    static let headers = Int(FileStorage.headerBytes)

    /// The first `count` bytes of the file but for the headers: the read of
    /// a whole file that can go through the map.
    private static func afterTheHeaders(_ file: FileStorage, _ count: Int) throws -> [UInt8] {
        try readBytes(file, at: FileStorage.headerBytes, count: count - headers)
    }

    /// Bytes that differ from place to place, so that a read of the wrong
    /// place shows.
    private static func pattern(_ count: Int, seed: Int = 0) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: ($0 &+ seed) &* 31 &+ ($0 >> 8)) }
    }

    // MARK: The lock

    /// With the map the lock says "I am the writer": a storage that can
    /// write needs the exclusive one, and without it the initialiser
    /// refuses before the file is opened, so nothing is created. A storage
    /// that only reads needs none, and may take either.
    @Test func aMappedWriterNeedsTheExclusiveLockAndAReaderNone() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path()
        let writable: [FileAccess] = [.readWrite, .create, .truncate]
        for access in writable {
            for reading in Self.maps {
                #expect(throws: XitDBError.memoryMapNeedsLock, "\(access), \(reading), no lock") {
                    _ = try FileStorage(path: path, access: access, reading: reading)
                }
                #expect(throws: XitDBError.memoryMapNeedsLock, "\(access), \(reading), a shared lock") {
                    _ = try FileStorage(path: path, access: access, lock: .shared, reading: reading)
                }
                #expect(throws: XitDBError.memoryMapNeedsLock, "\(access), \(reading), buffered, no lock") {
                    _ = try BufferedFileStorage(path: path, access: access, reading: reading)
                }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: path), "refused before the file was opened")

        do {
            let writer = try FileStorage(path: path, access: .create, lock: .exclusive, reading: .memoryMap)
            #expect(writer.isMemoryMapped)
            try writeBytes(writer, Self.pattern(2 * Self.page), at: 0)

            // A reader with no lock, beside the writer that holds the
            // exclusive one: it is not refused, is mapped, and reads.
            #expect(throws: Never.self) { _ = try FileStorage(path: path, access: .readOnly, reading: .memoryMap) }
            #expect(throws: Never.self) {
                _ = try BufferedFileStorage(path: path, access: .readOnly, reading: .memoryMap)
            }
            let unlocked = try FileStorage(path: path, access: .readOnly, reading: .memoryMap)
            #expect(unlocked.isMemoryMapped)
            #expect(try readBytes(unlocked, at: 0, count: 3) == Array(Self.pattern(3)))
            let buffered = try BufferedFileStorage(path: path, access: .readOnly, reading: .memoryMap)
            #expect(buffered.isMemoryMapped)
            #expect(try readBytes(buffered, at: 0, count: 3) == Array(Self.pattern(3)))
            withExtendedLifetime(writer) {}
        }

        // A reader may take a lock all the same: a shared one, or the
        // exclusive one.
        do {
            let directory = try TemporaryDirectory()
            #expect(FileManager.default.createFile(atPath: directory.path(), contents: Data([1, 2, 3])))
            let shared = try FileStorage(path: directory.path(), access: .readOnly, lock: .shared, reading: .memoryMap)
            #expect(shared.isMemoryMapped)
            #expect(try readBytes(shared, at: 0, count: 3) == [1, 2, 3])
        }
        do {
            let directory = try TemporaryDirectory()
            #expect(FileManager.default.createFile(atPath: directory.path(), contents: Data([1, 2, 3])))
            let exclusive = try BufferedFileStorage(
                path: directory.path(), access: .readOnly, lock: .exclusive, reading: .memoryMap)
            #expect(exclusive.isMemoryMapped)
            #expect(try readBytes(exclusive, at: 0, count: 3) == [1, 2, 3])
        }
        // Without the argument nothing is mapped, with a lock or without.
        #expect(try FileStorage(path: path, access: .readWrite, lock: .exclusive).isMemoryMapped == false)
        #expect(try BufferedFileStorage(path: path, access: .readWrite).isMemoryMapped == false)
    }

    // MARK: The limit

    /// Only bytes known to be in the file are read through the map: what
    /// the storage wrote, across the segments' boundaries, with no file
    /// call; anything at or beyond the end by a file call, which is what
    /// says that nothing is there.
    @Test(arguments: maps)
    func onlyBytesKnownToBeInTheFileAreReadThroughTheMap(reading: FileReading) throws {
        let directory = try TemporaryDirectory()
        let (file, counts) = try Self.mapped(directory, reading)
        let page = Self.page
        let bytes = Self.pattern(3 * page + 100)
        try writeBytes(file, bytes, at: 0)

        #expect(try Self.afterTheHeaders(file, bytes.count) == Array(bytes[Self.headers...]))
        #expect(try readBytes(file, at: UInt64(page - 3), count: 10) == Array(bytes[(page - 3)..<(page + 7)]))
        #expect(
            try readBytes(file, at: UInt64(2 * page - 1), count: page + 2) == Array(bytes[(2 * page - 1)...(3 * page)]))
        #expect(counts.reads == 0, "what was written is read through the map")
        #expect(counts.maps == 4, "each segment is mapped once")

        // A read that reaches beyond the end: what is there from the map,
        // and one file call for the rest, which reads nothing.
        #expect(try readBytes(file, at: UInt64(bytes.count - 5), count: 50) == Array(bytes.suffix(5)))
        #expect(counts.reads == 1)
        // At the end and beyond it, a file call alone.
        #expect(try readBytes(file, at: UInt64(bytes.count), count: 9) == [])
        #expect(try readBytes(file, at: UInt64(10 * page), count: 9) == [])
        #expect(counts.reads == 3)
        #expect(counts.maps == 4, "nothing is mapped for a read beyond what is in the file")
    }

    /// The storage lowers its limit before it cuts the file: a part that
    /// was read through the map and is cut away is read by a file call
    /// afterwards, which reads nothing. Without that the read would be of a
    /// mapped page beyond the end of the file, and end the process. When
    /// the file has grown again the same segment gives what is there now.
    @Test(arguments: maps)
    func aCutLowersTheLimitFirst(reading: FileReading) throws {
        let directory = try TemporaryDirectory()
        let (file, counts) = try Self.mapped(directory, reading)
        let page = Self.page
        let bytes = Self.pattern(4 * page)
        try writeBytes(file, bytes, at: 0)
        #expect(try Self.afterTheHeaders(file, bytes.count) == Array(bytes[Self.headers...]))
        #expect(counts.reads == 0)

        try file.truncate(to: UInt64(page + 10))
        #expect(try readBytes(file, at: UInt64(2 * page), count: 16) == [])
        #expect(try readBytes(file, at: UInt64(page + 10), count: 16) == [])
        #expect(counts.reads == 2, "what was cut away is asked of the file")
        #expect(
            try readBytes(file, at: FileStorage.headerBytes, count: 2 * page)
                == Array(bytes[Self.headers..<(page + 10)]))
        #expect(counts.reads == 3, "the part below the cut from the map, the rest from the file")

        let again = Self.pattern(2 * page, seed: 77)
        try writeBytes(file, again, at: UInt64(page + 10))
        let whole = Array(bytes[..<(page + 10)]) + again
        let reads = counts.reads
        #expect(try Self.afterTheHeaders(file, whole.count) == Array(whole[Self.headers...]))
        #expect(try readBytes(file, at: UInt64(2 * page), count: 16) == Array(whole[(2 * page)..<(2 * page + 16)]))
        #expect(counts.reads == reads, "what was written again is read through the map")
        #expect(counts.maps == 4, "through the segments mapped before the cut")
        #expect(try directory.contents() == whole)
    }

    /// With the switch that lets the limit follow commits only, what is
    /// written is read by file calls until the commit's second sync, and
    /// through the map from then on. Either way the bytes are the same.
    @Test(arguments: maps)
    func withTheLimitAtCommitsAWriteIsReadByFileCallUntilTheCommit(reading: FileReading) throws {
        let directory = try TemporaryDirectory()
        let (file, counts) = try Self.mapped(directory, reading)
        file.mapsCommittedBytesOnly = true
        let page = Self.page
        let bytes = Self.pattern(2 * page + 7)
        try writeBytes(file, bytes, at: 0)
        #expect(try Self.afterTheHeaders(file, bytes.count) == Array(bytes[Self.headers...]))
        #expect(counts.reads == 1)
        #expect(counts.maps == 0)

        try file.sync(.beforeRootHeader)
        #expect(try readBytes(file, at: 5, count: 9) == Array(bytes[5..<14]))
        #expect(counts.reads == 2, "the first sync of a commit is not the commit")

        try file.sync(.afterRootHeader)
        #expect(try Self.afterTheHeaders(file, bytes.count) == Array(bytes[Self.headers...]))
        #expect(counts.reads == 2, "after the commit the bytes are read through the map")
        #expect(counts.maps == 3)
    }

    /// What is in the file when a writer opens it is known to be there, with
    /// the lock held, and is read through the map from the first read on.
    @Test func whatIsInTheFileWhenAWriterOpensItIsReadThroughTheMap() throws {
        let directory = try TemporaryDirectory()
        let page = Self.page
        let bytes = Self.pattern(2 * page + 33)
        do {
            let first = try FileStorage(path: directory.path(), access: .create, durability: .none)
            try writeBytes(first, bytes, at: 0)
        }
        let counts = CallCounts()
        var calls = FileCalls()
        calls.read = {
            (descriptor: Int32, buffer: inout MutableSpan<UInt8>, range: Range<Int>, offset: UInt64)
                throws(XitDBError) -> Int in
            counts.reads += 1
            return try Platform.readFile(descriptor, into: &buffer, range: range, at: offset)
        }
        let file = try readThroughTheMap(
            try FileStorage(
                path: directory.path(), access: .readWrite, durability: .none, lock: .exclusive, reading: .memoryMap,
                segmentSize: page, calls: calls), at: directory.path())
        #expect(try Self.afterTheHeaders(file, bytes.count) == Array(bytes[Self.headers...]))
        #expect(try readBytes(file, at: UInt64(page + 1), count: page) == Array(bytes[(page + 1)..<(2 * page + 1)]))
        #expect(counts.reads == 0)
    }

    /// The two headers are read by a file call always, by a writer too: a
    /// read that starts in them is a file call for all of it, and one that
    /// starts right after them is none.
    @Test(arguments: maps)
    func theHeadersAreReadByAFileCall(reading: FileReading) throws {
        let directory = try TemporaryDirectory()
        let (file, counts) = try Self.mapped(directory, reading)
        let bytes = Self.pattern(2 * Self.page)
        try writeBytes(file, bytes, at: 0)
        #expect(try readBytes(file, at: 0, count: 20) == Array(bytes[..<20]))
        #expect(counts.reads == 1)
        #expect(try readBytes(file, at: 24, count: 8) == Array(bytes[24..<32]))
        #expect(counts.reads == 2)
        #expect(try readBytes(file, at: 36, count: 100) == Array(bytes[36..<136]))
        #expect(counts.reads == 3, "a read that starts in the headers is a file call for all of it")
        #expect(counts.maps == 0)
        #expect(try readBytes(file, at: 37, count: 100) == Array(bytes[37..<137]))
        #expect(counts.reads == 3)
        #expect(counts.maps == 1)
    }

    /// A storage that only reads has no say over where the file ends: what
    /// lies past the last commit may be cut by the file's writer. So its
    /// limit is the committed size its engine has verified: nothing before
    /// a database on it has verified a commit, that commit's size after,
    /// and a later commit's once the engine has seen and verified it. What
    /// lies past the limit is read by a file call.
    @Test func aReadersLimitIsTheCommittedSizeItsEngineVerified() throws {
        let directory = try TemporaryDirectory()
        let page = Self.page
        // a database of several pages, by a writer without the map
        let writerStorage = try FileStorage(path: directory.path(), access: .create, durability: .none)
        let writer = try Database(creating: writerStorage, hashSize: 20)
        try writer.withTransaction { root in
            try HashMap<ReadWrite>(root).put(.bytes(Self.pattern(3 * page)), forHash: hashInt("first"))
        }
        let committed = try writer.committedSize
        try #require(committed > UInt64(3 * page))
        // and bytes past the commit, as a transaction that is not
        // committed leaves them
        try writeBytes(writerStorage, Self.pattern(page, seed: 5), at: committed)

        let counts = CallCounts()
        var calls = FileCalls()
        calls.read = {
            (descriptor: Int32, buffer: inout MutableSpan<UInt8>, range: Range<Int>, offset: UInt64)
                throws(XitDBError) -> Int in
            counts.reads += 1
            return try Platform.readFile(descriptor, into: &buffer, range: range, at: offset)
        }
        calls.map = { (descriptor: Int32, offset: UInt64, length: Int) in
            counts.maps += 1
            return Platform.mapFile(descriptor, offset: offset, length: length)
        }
        let file = try readThroughTheMap(
            try FileStorage(
                path: directory.path(), access: .readOnly, durability: .none, lock: .shared, reading: .memoryMap,
                segmentSize: page, calls: calls), at: directory.path())
        var onDisk = try directory.contents()
        let end = Int(committed)

        // nothing is verified yet: a file call, and nothing mapped
        #expect(try readBytes(file, at: UInt64(page), count: 100) == Array(onDisk[page..<(page + 100)]))
        #expect(counts.reads == 1)
        #expect(counts.maps == 0)

        // a database on the storage verifies the commit: up to its size
        // the map, past it a file call
        let reader = try Database(opening: file, hashSize: 20)
        #expect(try reader.committedSize == committed)
        var reads = counts.reads
        #expect(try readBytes(file, at: UInt64(page), count: 2 * page) == Array(onDisk[page..<(3 * page)]))
        #expect(counts.reads == reads, "what is committed is read through the map")
        #expect(counts.maps > 0)
        #expect(try readBytes(file, at: committed, count: 10) == Array(onDisk[end..<(end + 10)]))
        #expect(counts.reads == reads + 1, "what lies past the commit is asked of the file")
        #expect(try readBytes(file, at: committed - 4, count: 10) == Array(onDisk[(end - 4)..<(end + 6)]))
        #expect(counts.reads == reads + 2, "across the commit's end: its part from the map, the rest from the file")

        // the writer commits again; the reader has not looked, and its
        // limit is where it was
        try writer.withTransaction { root in
            try HashMap<ReadWrite>(root).put(.bytes(Self.pattern(2 * page, seed: 9)), forHash: hashInt("second"))
        }
        let later = try writer.committedSize
        try #require(later > committed + UInt64(2 * page))
        onDisk = try directory.contents()
        let laterEnd = Int(later)
        reads = counts.reads
        #expect(try readBytes(file, at: later - 50, count: 20) == Array(onDisk[(laterEnd - 50)..<(laterEnd - 30)]))
        #expect(counts.reads == reads + 1, "a commit the reader's engine has not verified is past its limit")

        // the reader's engine sees the commit and verifies it
        #expect(try reader.committedSize == later)
        reads = counts.reads
        #expect(try readBytes(file, at: later - 50, count: 20) == Array(onDisk[(laterEnd - 50)..<(laterEnd - 30)]))
        #expect(counts.reads == reads, "and from then on it is read through the map")
    }

    /// A write below the end, in place, leaves the limit where it was: what
    /// lies after it is still read through the map, and what was written
    /// is what the map gives.
    @Test(arguments: maps)
    func aWriteInPlaceLeavesTheLimit(reading: FileReading) throws {
        let directory = try TemporaryDirectory()
        let (file, counts) = try Self.mapped(directory, reading)
        let page = Self.page
        var bytes = Self.pattern(3 * page)
        try writeBytes(file, bytes, at: 0)
        #expect(try Self.afterTheHeaders(file, bytes.count) == Array(bytes[Self.headers...]))

        let patch = Self.pattern(40, seed: 9)
        try writeBytes(file, patch, at: 100)
        bytes.replaceSubrange(100..<140, with: patch)
        #expect(try Self.afterTheHeaders(file, bytes.count) == Array(bytes[Self.headers...]))
        #expect(
            try readBytes(file, at: UInt64(2 * page + 5), count: 100) == Array(bytes[(2 * page + 5)..<(2 * page + 105)])
        )
        #expect(counts.reads == 0, "the bytes after an overwrite in place are still read through the map")
    }

    // MARK: The advice, and a read in file order

    /// The system is told how the map is read once for each segment, right
    /// after the segment is mapped and for the whole of it; not again when
    /// the segment is read again, and not for a segment the system refused
    /// to map.
    @Test func eachSegmentIsAdvisedOnceWhenItIsMapped() throws {
        let directory = try TemporaryDirectory()
        let (file, counts) = try Self.mapped(directory)
        let page = Self.page
        final class Advised {
            var lengths: [Int] = []
            var addresses: Set<UInt> = []
        }
        let advised = Advised()
        file.calls.advise = { (address: UInt, length: Int) in
            advised.lengths.append(length)
            advised.addresses.insert(address)
            Platform.adviseRandom(address: address, length: length)
        }
        file.calls.map = { (descriptor: Int32, offset: UInt64, length: Int) in
            counts.maps += 1
            if offset >= UInt64(3 * page) { return (0, ENOMEM) }
            return Platform.mapFile(descriptor, offset: offset, length: length)
        }
        let bytes = Self.pattern(5 * page)
        try writeBytes(file, bytes, at: 0)
        #expect(advised.lengths.isEmpty, "nothing is advised before anything is mapped")

        #expect(try readBytes(file, at: UInt64(page + 3), count: 10) == Array(bytes[(page + 3)..<(page + 13)]))
        #expect(advised.lengths == [page])
        #expect(try Self.afterTheHeaders(file, 3 * page) == Array(bytes[Self.headers..<(3 * page)]))
        #expect(advised.lengths == [page, page, page], "one advice for each segment, of the segment's length")
        #expect(advised.addresses.count == 3)
        #expect(try Self.afterTheHeaders(file, 3 * page) == Array(bytes[Self.headers..<(3 * page)]))
        #expect(advised.lengths.count == 3, "a segment that is mapped is not advised again")

        // the fourth segment is refused: no advice for it, and none after
        #expect(try Self.afterTheHeaders(file, bytes.count) == Array(bytes[Self.headers...]))
        #expect(counts.maps == 4)
        #expect(advised.lengths.count == 3)
    }

    /// A map that is left to the system's own reading ahead is told
    /// nothing: the call that advises is never made, for any segment, and
    /// the file is read through the map all the same.
    @Test func aMapLeftToTheSystemsReadingAheadIsToldNothing() throws {
        let directory = try TemporaryDirectory()
        let (file, counts) = try Self.mapped(directory, .memoryMapReadAhead)
        final class Advised {
            var calls = 0
        }
        let advised = Advised()
        file.calls.advise = { (_: UInt, _: Int) in advised.calls += 1 }
        let bytes = Self.pattern(5 * Self.page)
        try writeBytes(file, bytes, at: 0)
        #expect(try Self.afterTheHeaders(file, bytes.count) == Array(bytes[Self.headers...]))
        #expect(counts.maps == 5, "each segment was mapped")
        #expect(counts.reads == 0, "and read through the map")
        #expect(advised.calls == 0, "and the system was told nothing")
        #expect(file.isMemoryMapped)
        #expect(file.requestedReading == .memoryMapReadAhead)
    }

    /// A storage says how it was asked to read its file, for its life, on
    /// both file storages: by file calls unless told otherwise; and what
    /// was asked is not whether the map was had, which a file on a volume
    /// that is not mapped shows.
    @Test func aStorageSaysHowItWasAskedToReadItsFile() throws {
        let directory = try TemporaryDirectory()
        #expect(FileManager.default.createFile(atPath: directory.path(), contents: Data([1, 2, 3])))
        #expect(try FileStorage(path: directory.path(), access: .readOnly).requestedReading == .fileCalls)
        #expect(try BufferedFileStorage(path: directory.path(), access: .readOnly).requestedReading == .fileCalls)
        for reading in [FileReading.fileCalls, .memoryMap, .memoryMapReadAhead] {
            let file = try FileStorage(path: directory.path(), access: .readOnly, reading: reading)
            #expect(file.requestedReading == reading)
            #expect(file.isMemoryMapped == (reading != .fileCalls), "\(reading)")
            let buffered = try BufferedFileStorage(path: directory.path(), access: .readOnly, reading: reading)
            #expect(buffered.requestedReading == reading)
            #expect(buffered.isMemoryMapped == (reading != .fileCalls), "\(reading)")
        }
        var calls = FileCalls()
        calls.isLocal = { _ in false }
        for reading in Self.maps {
            let file = try FileStorage(
                path: directory.path(), access: .readOnly, reading: reading, segmentSize: Self.page, calls: calls)
            #expect(file.requestedReading == reading, "what was asked")
            #expect(!file.isMemoryMapped, "is not what was had")
        }
    }

    /// The stream of committed bytes, which feeds a replica, reads a mapped
    /// file by file calls: the map is advised as read in no order, and the
    /// stream is the one read the library knows to be in file order. Its
    /// data comes in the stream's chunks, each a file call, one after
    /// another up to the committed size; an ordinary read of the same
    /// bytes makes no file call after the headers.
    @Test(arguments: mappedKinds)
    func theStreamOfCommittedBytesReadsByFileCalls(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(creating: subject.storage, hashSize: 20)
        try database.withTransaction { root in
            // a megabyte, which is several of the stream's chunks whatever
            // the system's page is
            try HashMap<ReadWrite>(root).put(.bytes(Self.pattern(1 << 20)), forHash: hashInt("large"))
        }
        let file = try #require(
            (subject.storage as? FileStorage) ?? (subject.storage as? BufferedFileStorage)?.file)
        /// The file calls that read, each with where it began and how many
        /// bytes it was asked for.
        final class FileReads {
            var all: [(offset: UInt64, count: Int)] = []
            /// Those that began after the headers, which a read through
            /// the map does not make.
            var afterTheHeaders: [(offset: UInt64, count: Int)] {
                all.filter { $0.offset >= UInt64(MemoryMapTests.headers) }
            }
        }
        let reads = FileReads()
        file.calls.read = {
            (descriptor: Int32, buffer: inout MutableSpan<UInt8>, range: Range<Int>, offset: UInt64)
                throws(XitDBError) -> Int in
            reads.all.append((offset, range.count))
            return try Platform.readFile(descriptor, into: &buffer, range: range, at: offset)
        }
        let size = try database.committedSize
        #expect(size > UInt64(1 << 20))

        // an ordinary read of everything after the headers: through the map
        let ordinary = try Self.afterTheHeaders(file, Int(size))
        #expect(reads.afterTheHeaders.isEmpty, "an ordinary read of committed bytes makes no file call")
        let expected = try readBytes(file, at: 0, count: Self.headers) + ordinary
        reads.all = []

        // the stream through a sink, which is how a replica's source sends it
        var sink = ArrayByteSink()
        try database.readCommitted(from: 0, to: size, into: &sink)
        #expect(sink.bytes == expected)
        // what is read before the data is the headers, by the engine and
        // by the stream, each within them
        let dataStart = database.header.dataStart
        let chunks = reads.all.filter { $0.offset >= dataStart }
        let others = reads.all.filter { $0.offset < dataStart }
        #expect(others.allSatisfy { $0.offset + UInt64($0.count) <= UInt64(Self.headers) })
        #expect(chunks.count >= 2, "the data in more than one of the stream's chunks")
        var position = chunks.first?.offset ?? 0
        #expect(position == dataStart, "the data begins where the header ends")
        for chunk in chunks {
            #expect(chunk.offset == position, "one chunk after another")
            position += UInt64(chunk.count)
        }
        #expect(position == size, "up to the committed size and no further")
        reads.all = []

        // the bytes read straight into an array: one file call for all of them
        #expect(try database.readCommitted(from: 0, to: size) == expected)
        #expect(reads.all.contains { $0.offset == 0 && $0.count == Int(size) })
        #expect(reads.afterTheHeaders.isEmpty)
    }

    // MARK: A compaction's reads

    /// What a mapped storage's calls did while a test watched.
    private final class Watched {
        var maps = 0
        var told = 0
        var reads = 0
        /// The mapping calls that succeed; the ones after them are refused.
        var grantedMaps: Int?
    }

    /// Watches the mappings a file storage makes, what it tells the system
    /// of them and its file reads, from now on.
    private static func watch(_ file: FileStorage) -> Watched {
        let watched = Watched()
        file.calls.advise = { (address: UInt, length: Int) in
            watched.told += 1
            Platform.adviseRandom(address: address, length: length)
        }
        file.calls.map = { (descriptor: Int32, offset: UInt64, length: Int) in
            watched.maps += 1
            if let granted = watched.grantedMaps, watched.maps > granted { return (0, ENOMEM) }
            return Platform.mapFile(descriptor, offset: offset, length: length)
        }
        file.calls.read = {
            (descriptor: Int32, buffer: inout MutableSpan<UInt8>, range: Range<Int>, offset: UInt64)
                throws(XitDBError) -> Int in
            watched.reads += 1
            return try Platform.readFile(descriptor, into: &buffer, range: range, at: offset)
        }
        return watched
    }

    /// An offset map in memory that calls a test back once, when the
    /// compaction records its first copy: the one moment at which a test
    /// can look at the source's storage while a compaction runs.
    private struct HookedOffsetMap: OffsetMap {
        var inner = MemoryOffsetMap()
        var puts = 0
        let atTheFirstCopy: () throws -> Void

        mutating func reset() throws { inner.reset() }
        mutating func get(_ sourceOffset: UInt64) throws -> UInt64? { inner.get(sourceOffset) }
        mutating func put(_ sourceOffset: UInt64, _ targetOffset: UInt64) throws {
            puts += 1
            if puts == 1 { try atTheFirstCopy() }
            inner.put(sourceOffset, targetOffset)
        }
    }

    /// An error a test's offset map throws to end a compaction.
    private struct Stopped: Error {}

    /// A mapped subject with its file storage watched from before anything
    /// is mapped, a database filled in it and read once, so that every
    /// segment of the storage's own view is mapped and told.
    private static func watchedSubject(
        _ kind: StorageKind
    ) throws -> (subject: StorageUnderTest, file: FileStorage, watched: Watched, database: Database, walk: String) {
        let subject = try StorageUnderTest(kind)
        let file = try #require(
            (subject.storage as? FileStorage) ?? (subject.storage as? BufferedFileStorage)?.file)
        let watched = watch(file)
        let database = try filled(subject)
        let walk = try StructureWalk.describe(database.rootCursor.readOnly)
        return (subject, file, watched, database, walk)
    }

    /// The segments that hold a file of `length` bytes.
    private static func segments(holding length: UInt64) -> Int {
        Int((length - 1) / UInt64(page)) + 1
    }

    /// For the length of a compaction, a storage whose map is told that it
    /// is read in no order reads through a second view, which the system
    /// reads ahead in: a compaction follows pointers from the root, which
    /// for data written in order is file order, and through the storage's
    /// own map it would bring a file that is not in memory in a page at a
    /// time. Every segment that holds the file is mapped a second time,
    /// once, and told nothing; the storage's own view is told nothing more
    /// and maps nothing more; the target is what the source reads as; and
    /// at the end the storage reads through its own view again.
    @Test(arguments: mappedKinds)
    func aCompactionReadsThroughASecondViewForItsLength(kind: StorageKind) throws {
        let (subject, file, watched, database, walk) = try Self.watchedSubject(kind)
        let segments = Self.segments(holding: try subject.storage.length)
        #expect(segments > 3, "the database spans several segments")
        #expect(watched.maps == segments)
        #expect(watched.told == segments, "each segment of the storage's own view was told once")
        #expect(file.compactionView == nil)

        var during: (inPlace: Bool, segments: Int) = (false, 0)
        var offsets = HookedOffsetMap {
            during = (file.compactionView != nil, file.compactionView?.segments.count ?? 0)
        }
        let target = try database.compact(into: MemoryStorage(), fileID: 9, offsetMap: &offsets)
        #expect(during.inPlace)
        #expect(during.segments == segments)
        #expect(try StructureWalk.describe(target.rootCursor.readOnly) == walk)
        #expect(watched.maps == 2 * segments)
        #expect(watched.told == segments)

        // and the source reads on through its own view, as it did
        #expect(file.compactionView == nil)
        #expect(try StructureWalk.describe(database.rootCursor.readOnly) == walk)
        #expect(watched.maps == 2 * segments)
        #expect(watched.told == segments)
    }

    /// A compaction that throws leaves the storage as it was: it reads
    /// through its own view, which was told nothing more and has every
    /// segment it had, and the second view's segments are gone, which is to
    /// say unmapped: a segment unmaps itself when the last reference to it
    /// goes.
    @Test(arguments: mappedKinds)
    func aCompactionThatThrowsLeavesTheStorageReadingThroughItsOwnView(kind: StorageKind) throws {
        let (subject, file, watched, database, walk) = try Self.watchedSubject(kind)
        let segments = Self.segments(holding: try subject.storage.length)

        final class Held {
            weak var first: MappedSegment?
            weak var last: MappedSegment?
            var count = 0
        }
        let held = Held()
        var offsets = HookedOffsetMap {
            let view = file.compactionView
            held.count = view?.segments.count ?? 0
            held.first = view?.segments.first ?? nil
            held.last = view?.segments.last ?? nil
            throw Stopped()
        }
        let failure = #expect(throws: XitDBError.self) {
            try database.compact(into: MemoryStorage(), fileID: 9, offsetMap: &offsets)
        }
        guard case .callerError(let carried)? = failure, carried is Stopped else {
            Issue.record("the compaction ends with the offset map's error, carried: \(String(describing: failure))")
            return
        }
        #expect(held.count == segments, "the second view was in place when the compaction was stopped")

        #expect(file.compactionView == nil)
        #expect(held.first == nil)
        #expect(held.last == nil)
        #expect(watched.told == segments)
        #expect(watched.maps == 2 * segments)
        #expect(try StructureWalk.describe(database.rootCursor.readOnly) == walk)
        #expect(watched.maps == 2 * segments, "its own segments are all there: none had to be mapped again")

        // and the next compaction goes through
        var again = MemoryOffsetMap()
        let target = try database.compact(into: MemoryStorage(), fileID: 9, offsetMap: &again)
        #expect(try StructureWalk.describe(target.rootCursor.readOnly) == walk)
        #expect(watched.maps == 3 * segments)
        #expect(file.compactionView == nil)
    }

    /// A segment of the second view that the system refuses is read by
    /// file calls, and no further one is asked for: the compaction is
    /// slower there and its target is the same. With the third mapping
    /// refused there are two mapped, one asked for in vain and none after
    /// it; with the first refused the second view holds nothing, and the
    /// whole source is read by file calls.
    @Test(arguments: mappedKinds, [2, 0])
    func aSegmentOfTheSecondViewThatIsRefusedIsReadByFileCalls(kind: StorageKind, granted: Int) throws {
        let (_, _, watched, database, walk) = try Self.watchedSubject(kind)
        // what a compaction reads by file calls when nothing is refused:
        // the two headers, which no storage reads through its map
        var plain = MemoryOffsetMap()
        let readsBefore = watched.reads
        _ = try database.compact(into: MemoryStorage(), fileID: 9, offsetMap: &plain)
        let plainReads = watched.reads - readsBefore

        let maps = watched.maps
        let told = watched.told
        let reads = watched.reads
        watched.grantedMaps = maps + granted
        var offsets = MemoryOffsetMap()
        let target = try database.compact(into: MemoryStorage(), fileID: 9, offsetMap: &offsets)
        #expect(try StructureWalk.describe(target.rootCursor.readOnly) == walk)
        #expect(watched.maps == maps + granted + 1)
        #expect(watched.told == told)
        #expect(watched.reads - reads > plainReads, "what the second view lacks came by file calls")
    }

    /// A snapshot taken before a compaction reads through the storage's
    /// own view all along, whose segments were told that they are read in
    /// no order: it holds a copy of that view, none of whose segments is
    /// one of the second view's, and it reads what it read while the
    /// compaction runs. The storage's own view is told nothing more: what
    /// the system was told belongs to a mapping, and those mappings are not
    /// touched.
    @Test(arguments: mappedKinds)
    func aSnapshotBesideACompactionReadsThroughTheViewItHad(kind: StorageKind) throws {
        let (subject, file, watched, database, walk) = try Self.watchedSubject(kind)
        let segments = Self.segments(holding: try subject.storage.length)
        let snapshot = try database.snapshot()
        guard case .file(_, _, let view?) = snapshot.storage.source else {
            Issue.record("a snapshot of a mapped storage reads through a view")
            return
        }
        #expect(view.segments.count == segments)
        #expect(watched.maps == segments, "the snapshot took the storage's segments and mapped none")
        #expect(watched.told == segments)

        var shared = -1
        var walkDuring = ""
        var offsets = HookedOffsetMap {
            let second = file.compactionView?.segments ?? []
            shared = view.segments.count { mine in second.contains { $0 === mine } }
            walkDuring = try StructureWalk.describe(snapshot.rootCursor)
        }
        let target = try database.compact(into: MemoryStorage(), fileID: 9, offsetMap: &offsets)
        #expect(shared == 0)
        #expect(walkDuring == walk)
        #expect(try StructureWalk.describe(target.rootCursor.readOnly) == walk)
        #expect(try StructureWalk.describe(snapshot.rootCursor) == walk)
        #expect(watched.told == segments)
        #expect(watched.maps == 2 * segments)
    }

    /// A buffered storage's window is read first, during a compaction as at
    /// any other time: bytes written through the storage that it has not
    /// yet given to the file are what the compaction copies. A value's
    /// bytes are overwritten through the storage after the commit; on the
    /// buffered storage they sit in its window and the file still holds the
    /// old ones, which is what a reader of the file alone would copy.
    @Test(arguments: mappedKinds)
    func aCompactionReadsABufferedStoragesWindowFirst(kind: StorageKind) throws {
        let (subject, _, watched, database, _) = try Self.watchedSubject(kind)
        let old = utf8("the value of entry 7, longer than a slot")
        let new = utf8("THE VALUE OF ENTRY 7, LONGER THAN A SLOT")
        let stored = try readBytes(subject.storage, at: 0, count: Int(try subject.storage.length))
        let position = try #require(stored.firstRange(of: old)?.lowerBound)
        try writeBytes(subject.storage, new, at: UInt64(position))
        if kind == .mappedBufferedFile {
            let onDisk = try Data(contentsOf: URL(fileURLWithPath: try #require(subject.path)))
            #expect(Array(onDisk[position..<(position + old.count)]) == old, "the file still holds the old bytes")
        }

        let maps = watched.maps
        var offsets = MemoryOffsetMap()
        let target = try database.compact(into: MemoryStorage(), fileID: 9, offsetMap: &offsets)
        #expect(watched.maps > maps, "the compaction read through a second view")
        let value = try #require(try HashMap<ReadOnly>(target.rootCursor.readOnly).cursor(forHash: hashInt("key-7")))
        #expect(try value.readBytes() == new)
    }

    /// Bytes past the last commit are read during a compaction as at any
    /// other time, which is what the original does with a damaged file. A
    /// committed header is made to lead to a byte appended past the commit;
    /// the compaction reads that byte and reports what it is (a tree node's
    /// kind that is not one), and with another byte there what that one
    /// leads to (a kind that is one, whose count the file ends before). A
    /// reader that stopped at the commit would report the file's end for
    /// both.
    @Test(arguments: mappedKinds)
    func aCompactionReadsBytesPastTheLastCommit(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let file = try #require(
            (subject.storage as? FileStorage) ?? (subject.storage as? BufferedFileStorage)?.file)
        let watched = Self.watch(file)
        let database = try Database(creating: subject.storage, hashSize: 20)
        try database.withTransaction { root in
            let map = try HashMap<ReadWrite>(root)
            let linked = try LinkedArrayList(try map.putCursor(forHash: hashInt("linked")))
            for index in 0..<3 { try linked.append(.uint(UInt64(index))) }
            for index in 0..<400 {
                try map.put(
                    .bytes(utf8("a value that makes the file some pages long, \(index)")),
                    forHash: hashInt("k-\(index)"))
            }
        }
        let header = try #require(
            try HashMap<ReadOnly>(database.rootCursor.readOnly).cursor(forHash: hashInt("linked"))
        ).slot.value
        let end = try subject.storage.length
        #expect(end == (try database.committedSize))
        try writeBytes(subject.storage, [5], at: end)
        try writeBytes(subject.storage, bigEndianBytes(end), at: header + 8)

        func compacting() -> XitDBError? {
            var offsets = MemoryOffsetMap()
            do throws(XitDBError) {
                _ = try database.compact(into: MemoryStorage(), fileID: 9, offsetMap: &offsets)
                return nil
            } catch {
                return error
            }
        }
        var maps = watched.maps
        #expect(compacting() == .invalidBTreeNodeKind)
        #expect(watched.maps > maps, "the compaction read through a second view")
        try writeBytes(subject.storage, [0], at: end)
        maps = watched.maps
        #expect(compacting() == .endOfStream)
        #expect(watched.maps > maps)
    }

    /// Where the storage's map is left to the system's reading ahead
    /// already, or there is no map, a compaction reads as every other read
    /// does: no second view is made.
    @Test(arguments: [FileReading.memoryMapReadAhead, .fileCalls])
    func aCompactionMakesNoSecondViewWhereTheSystemReadsAheadOrThereIsNoMap(reading: FileReading) throws {
        let directory = try TemporaryDirectory()
        let file = try FileStorage(
            path: directory.path(), access: .create, durability: .none, lock: .exclusive, reading: reading,
            segmentSize: Self.page)
        #expect(file.isMemoryMapped == (reading == .memoryMapReadAhead))
        let database = try Self.filled(in: file)
        let walk = try StructureWalk.describe(database.rootCursor.readOnly)

        let watched = Self.watch(file)
        var inPlace = true
        var offsets = HookedOffsetMap { inPlace = file.compactionView != nil }
        let target = try database.compact(into: MemoryStorage(), fileID: 9, offsetMap: &offsets)
        #expect(!inPlace)
        #expect(try StructureWalk.describe(target.rootCursor.readOnly) == walk)
        #expect(watched.maps == 0)
        #expect(watched.told == 0)
    }

    // MARK: The fallback

    /// A file on a volume that is not this machine's, as far as the system
    /// says, is read by file calls though the map was asked for: there is
    /// no error, the property says so, and nothing is mapped.
    @Test func aFileOnAVolumeThatIsNotMappedIsReadByFileCalls() throws {
        let directory = try TemporaryDirectory()
        let counts = CallCounts()
        var calls = FileCalls()
        calls.isLocal = { _ in false }
        calls.read = {
            (descriptor: Int32, buffer: inout MutableSpan<UInt8>, range: Range<Int>, offset: UInt64)
                throws(XitDBError) -> Int in
            counts.reads += 1
            return try Platform.readFile(descriptor, into: &buffer, range: range, at: offset)
        }
        calls.map = { (descriptor: Int32, offset: UInt64, length: Int) in
            counts.maps += 1
            return Platform.mapFile(descriptor, offset: offset, length: length)
        }
        let file = try FileStorage(
            path: directory.path(), access: .create, durability: .none, lock: .exclusive, reading: .memoryMap,
            segmentSize: Self.page, calls: calls)
        #expect(!file.isMemoryMapped)
        let bytes = Self.pattern(2 * Self.page)
        try writeBytes(file, bytes, at: 0)
        #expect(try Self.afterTheHeaders(file, bytes.count) == Array(bytes[Self.headers...]))
        #expect(counts.reads == 1)
        #expect(counts.maps == 0)

        // A snapshot of a database in it has no map either.
        let other = try TemporaryDirectory()
        let storage = try FileStorage(
            path: other.path(), access: .create, durability: .none, lock: .exclusive, reading: .memoryMap,
            segmentSize: Self.page, calls: calls)
        let database = try Database(creating: storage, hashSize: 20)
        try database.withTransaction { root in
            try HashMap<ReadWrite>(root).put(.uint(1), forHash: hashInt("one"))
        }
        let snapshot = try database.snapshot()
        guard case .file(_, _, let view) = snapshot.storage.source else {
            Issue.record("a snapshot of a file storage reads a file")
            return
        }
        #expect(view == nil)

        // A full copy onto it goes into a new file all the same, as on
        // every file storage: a reader that had the file open is told that
        // its path leads elsewhere, and the snapshot reads the old file on.
        let reader = try FileStorage(path: other.path(), access: .readOnly)
        let source = try Database(creating: MemoryStorage(), hashSize: 20)
        try source.withTransaction { root in
            try HashMap<ReadWrite>(root).put(.uint(2), forHash: hashInt("one"))
        }
        try database.applyReplicated(at: 0, bytes: try source.readCommitted(from: 0, to: try source.committedSize))
        #expect(try reader.isStillAtPath == false, "the file under the name is a new one")
        #expect(try storage.isStillAtPath)
        #expect(!storage.isMemoryMapped)
        #expect(try HashMap<ReadOnly>(snapshot.rootCursor).cursor(forHash: hashInt("one"))?.readUInt64() == 1)
        #expect(
            try HashMap<ReadOnly>(database.rootCursor.readOnly).cursor(forHash: hashInt("one"))?.readUInt64() == 2)

        // The caller's own cut under a snapshot is told to it, as without
        // the map.
        let after = try database.snapshot()
        try storage.truncate(to: 0)
        #expect(throws: XitDBError.snapshotOverwritten) { try readBytes(after.storage, at: 0, count: 8) }
    }

    /// The system's refusal of a mapping comes back as its error, and
    /// never as an address.
    @Test func aMappingTheSystemRefusesIsAnError() throws {
        let directory = try TemporaryDirectory()
        let file = try FileStorage(path: directory.path(), access: .create, durability: .none)
        try writeBytes(file, [1, 2, 3], at: 0)
        let tooLarge = Platform.mapFile(file.descriptor.rawValue, offset: 0, length: 1 << 52)
        #expect(tooLarge.error != 0)
        #expect(tooLarge.address == 0)
        #expect(Platform.mapFile(file.descriptor.rawValue, offset: 0, length: 0).error == EINVAL)
        #expect(MappedSegment(descriptor: file.descriptor.rawValue, offset: 0, length: 1 << 52) == nil)

        let mapped = Platform.mapFile(file.descriptor.rawValue, offset: 0, length: Self.page)
        #expect(mapped.error == 0)
        #expect(mapped.address != 0 && mapped.address != UInt.max)
        Platform.unmapFile(address: mapped.address, length: Self.page)
    }

    /// A segment the system refuses to map is read by file calls, and so is
    /// what follows it; what is mapped goes on being read through the map.
    /// The property says "partly" from then on, and no further segment is
    /// asked for.
    @Test(arguments: maps)
    func aSegmentTheSystemRefusesIsReadByFileCall(reading: FileReading) throws {
        let directory = try TemporaryDirectory()
        let (file, counts) = try Self.mapped(directory, reading)
        let page = Self.page
        file.calls.map = { (descriptor: Int32, offset: UInt64, length: Int) in
            counts.maps += 1
            if offset >= UInt64(2 * page) { return (0, ENOMEM) }
            return Platform.mapFile(descriptor, offset: offset, length: length)
        }
        let bytes = Self.pattern(5 * page)
        try writeBytes(file, bytes, at: 0)
        #expect(file.isMemoryMapped)

        #expect(try Self.afterTheHeaders(file, 2 * page) == Array(bytes[Self.headers..<(2 * page)]))
        #expect(counts.reads == 0)
        #expect(file.isMemoryMapped)

        // The read that reaches into the refused segment: two pages from
        // the map, the rest by a file call.
        #expect(try Self.afterTheHeaders(file, bytes.count) == Array(bytes[Self.headers...]))
        #expect(counts.reads == 1)
        #expect(counts.maps == 3, "two segments mapped and one refused")
        #expect(!file.isMemoryMapped, "partly")

        #expect(try readBytes(file, at: UInt64(4 * page), count: 20) == Array(bytes[(4 * page)..<(4 * page + 20)]))
        #expect(counts.reads == 2)
        #expect(counts.maps == 3, "after a refusal no further segment is asked for")
        #expect(try readBytes(file, at: 50, count: page) == Array(bytes[50..<(page + 50)]))
        #expect(counts.reads == 2, "what is mapped is still read through the map")
    }

    // MARK: The cut under a snapshot

    /// A database of a few hundred entries on a mapped storage, some pages
    /// long, committed.
    private static func filled(_ subject: StorageUnderTest) throws -> Database {
        try filled(in: subject.storage)
    }

    /// The same database in a storage a test made itself.
    private static func filled(in storage: any WritableStorage) throws -> Database {
        let database = try Database(creating: storage, hashSize: 20)
        try database.withTransaction { root in
            let map = try HashMap<ReadWrite>(root)
            for index in 0..<400 {
                try map.put(
                    .bytes(utf8("the value of entry \(index), longer than a slot")), forHash: hashInt("key-\(index)"))
            }
        }
        return database
    }

    static let mappedKinds: [StorageKind] = [.mappedFile, .mappedBufferedFile]

    /// The library never cuts a file below what a snapshot reads: a full
    /// copy goes into a new file, and a transaction that rolls back cuts
    /// its tail, which lies above every snapshot. A cut below one is the
    /// caller's own, through the storage's `truncate(to:)`, and it goes
    /// through. The snapshot is told by its fence, which it looks at before
    /// it reads through the map as well as after: every read through it is
    /// `snapshotOverwritten` from then on, and none reaches for the bytes
    /// that are gone.
    ///
    /// What this cannot show is the cut made while a read through the map
    /// is under way on another thread. That read has looked at the fence
    /// already, and reaches a part of the file that is no longer there:
    /// the system answers with a signal, which ends the process, and a
    /// test of it would end the tests. The storage's `truncate(to:)` says
    /// so to its caller.
    @Test(arguments: mappedKinds)
    func aCutBelowASnapshotIsTheCallersAndTheSnapshotRefusesItsReads(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Self.filled(subject)
        let committed = try database.committedSize
        #expect(committed > UInt64(3 * Self.page), "the database spans several segments")
        let walk = try StructureWalk.describe(database.rootCursor.readOnly)

        let snapshot = try database.snapshot()
        let early = try database.snapshot()
        // A transaction that rolls back cuts its tail, which lies above
        // the snapshots: they read on.
        #expect(throws: RolledBack.self) {
            try database.withTransaction { root in
                let map = try HashMap<ReadWrite>(root)
                for index in 0..<200 {
                    try map.put(
                        .bytes(utf8("a value that is rolled back, \(index)")), forHash: hashInt("gone-\(index)"))
                }
                throw RolledBack()
            }
        }
        #expect(try subject.storage.length == committed)
        #expect(try StructureWalk.describe(snapshot.rootCursor) == walk)
        #expect(try readBytes(snapshot.storage, at: 0, count: Int(committed)).count == Int(committed))

        // The fence is looked at BEFORE the map is read, and not only
        // after: with the fence tripped and the file still whole, a read is
        // refused with nothing copied into the caller's buffer. (After the
        // cut below, bytes copied first would be bytes that are gone.)
        do {
            guard case .file(_, let fence, _) = early.storage.source else {
                Issue.record("a snapshot of a file storage reads a file")
                return
            }
            let untouched = [UInt8](repeating: 0xEE, count: 64)
            var buffer = untouched
            var span = buffer.mutableSpan
            fence.trip()
            #expect(throws: XitDBError.snapshotOverwritten) {
                _ = try early.storage.read(into: &span, range: 0..<64, at: UInt64(2 * Self.page))
            }
            #expect(buffer == untouched, "nothing was read through the map before the fence was looked at")
        }

        // The caller's own cut, one byte below the snapshots: it is made.
        try subject.storage.truncate(to: committed - 1)
        #expect(try subject.storage.length == committed - 1)
        #expect(throws: XitDBError.snapshotOverwritten) { try StructureWalk.describe(snapshot.rootCursor) }
        #expect(throws: XitDBError.snapshotOverwritten) {
            try readBytes(snapshot.storage, at: UInt64(Self.headers), count: Int(committed) - Self.headers)
        }
        #expect(throws: XitDBError.snapshotOverwritten) {
            try readBytes(early.storage, at: UInt64(2 * Self.page), count: 16)
        }
        // And a cut to nothing, with every mapped byte of the snapshot
        // gone: its reads still refuse, and reach for nothing.
        try subject.storage.truncate(to: 0)
        #expect(try subject.storage.length == 0)
        #expect(throws: XitDBError.snapshotOverwritten) { try StructureWalk.describe(snapshot.rootCursor) }
        #expect(throws: XitDBError.snapshotOverwritten) {
            try readBytes(early.storage, at: UInt64(Self.headers), count: Int(committed) - Self.headers)
        }
    }

    // MARK: Snapshots

    /// A snapshot of a mapped file holds the segments of its commit, all
    /// mapped when it is taken, and reads the commit's bytes through them:
    /// the same bytes the file holds, and nothing beyond the commit.
    @Test(arguments: mappedKinds)
    func aSnapshotReadsItsCommitThroughTheMap(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Self.filled(subject)
        let committed = try database.committedSize
        let snapshot = try database.snapshot()
        guard case .file(_, _, let view) = snapshot.storage.source else {
            Issue.record("a snapshot of a file storage reads a file")
            return
        }
        let map = try #require(view, "the snapshot holds the map")

        // A read through the snapshot's storage is made through the map,
        // all of it: nothing is left to a file call.
        guard case .file(let descriptor, _, _) = snapshot.storage.source else { return }
        var whole = [UInt8](repeating: 0, count: Int(committed))
        var wholeSpan = whole.mutableSpan
        let split = try SnapshotStorage.readFile(
            descriptor, map, into: &wholeSpan, range: 0..<Int(committed), at: 0, limit: committed)
        #expect(split.mapped == Int(committed))
        #expect(split.byFileCall == 0)
        // Without the map the same read is a file call.
        let plain = try SnapshotStorage.readFile(
            descriptor, nil, into: &wholeSpan, range: 0..<Int(committed), at: 0, limit: committed)
        #expect(plain.mapped == 0)
        #expect(plain.byFileCall == Int(committed))

        // The view alone gives the whole commit: no part is left to a file
        // call.
        let room = Int(committed) + 64
        var buffer = [UInt8](repeating: 0, count: room)
        var span = buffer.mutableSpan
        let read = map.read(into: &span, range: 0..<room, at: 0, limit: committed)
        #expect(read == Int(committed))
        try subject.storage.flush()
        var stored = try subject.stored()
        #expect(stored.count == Int(committed))
        #expect(Array(buffer[..<read]) == stored)

        // The writer goes on; the snapshot reads what it read, and nothing
        // of what came after.
        try database.withTransaction { root in
            let more = try HashMap<ReadWrite>(root)
            for index in 0..<300 {
                try more.put(.uint(UInt64(index)), forHash: hashInt("later-\(index)"))
            }
        }
        #expect(try database.committedSize > committed)
        let through = try readBytes(snapshot.storage, at: 0, count: Int(committed) + 64)
        #expect(through.count == Int(committed))
        // All but the root header's committed size, which the later commit
        // rewrote in the file and no snapshot reads from it.
        let position = Int(snapshot.header.fileSizePosition)
        var masked = through
        for index in position..<(position + 8) {
            masked[index] = 0
            stored[index] = 0
        }
        #expect(masked == stored)
        #expect(try readBytes(snapshot.storage, at: committed, count: 8) == [])
    }

}
