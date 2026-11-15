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

    /// A file storage that reads through a map of segments of one page,
    /// with its calls counted.
    private static func mapped(_ directory: TemporaryDirectory) throws -> (FileStorage, CallCounts) {
        let file = try readThroughTheMap(
            try FileStorage(
                path: directory.path(), access: .create, durability: .none, lock: .exclusive, memoryMapped: true,
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

    /// The map needs the lock that keeps a second opener from cutting the
    /// file: an exclusive one, or a shared one where the file is opened for
    /// reading only. Without it the initialiser refuses before the file is
    /// opened, so nothing is created.
    @Test func theMapNeedsItsLock() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path()
        let writable: [FileAccess] = [.readWrite, .create, .truncate]
        for access in writable {
            #expect(throws: XitDBError.memoryMapNeedsLock, "\(access), no lock") {
                _ = try FileStorage(path: path, access: access, memoryMapped: true)
            }
            #expect(throws: XitDBError.memoryMapNeedsLock, "\(access), a shared lock") {
                _ = try FileStorage(path: path, access: access, lock: .shared, memoryMapped: true)
            }
            #expect(throws: XitDBError.memoryMapNeedsLock, "\(access), buffered, no lock") {
                _ = try BufferedFileStorage(path: path, access: access, memoryMapped: true)
            }
        }
        #expect(throws: XitDBError.memoryMapNeedsLock) {
            _ = try FileStorage(path: path, access: .readOnly, memoryMapped: true)
        }
        #expect(!FileManager.default.fileExists(atPath: path), "refused before the file was opened")

        do {
            let file = try FileStorage(path: path, access: .create, lock: .exclusive, memoryMapped: true)
            #expect(file.isMemoryMapped)
            try writeBytes(file, [1, 2, 3], at: 0)
        }
        // For reading only a shared lock is enough, and an exclusive one
        // does as well.
        do {
            let shared = try FileStorage(path: path, access: .readOnly, lock: .shared, memoryMapped: true)
            #expect(shared.isMemoryMapped)
            #expect(try readBytes(shared, at: 0, count: 3) == [1, 2, 3])
        }
        do {
            let exclusive = try BufferedFileStorage(path: path, access: .readOnly, lock: .exclusive, memoryMapped: true)
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
    @Test func onlyBytesKnownToBeInTheFileAreReadThroughTheMap() throws {
        let directory = try TemporaryDirectory()
        let (file, counts) = try Self.mapped(directory)
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
    @Test func aCutLowersTheLimitFirst() throws {
        let directory = try TemporaryDirectory()
        let (file, counts) = try Self.mapped(directory)
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
    @Test func withTheLimitAtCommitsAWriteIsReadByFileCallUntilTheCommit() throws {
        let directory = try TemporaryDirectory()
        let (file, counts) = try Self.mapped(directory)
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
                path: directory.path(), access: .readWrite, durability: .none, lock: .exclusive, memoryMapped: true,
                segmentSize: page, calls: calls), at: directory.path())
        #expect(try Self.afterTheHeaders(file, bytes.count) == Array(bytes[Self.headers...]))
        #expect(try readBytes(file, at: UInt64(page + 1), count: page) == Array(bytes[(page + 1)..<(2 * page + 1)]))
        #expect(counts.reads == 0)
    }

    /// The two headers are read by a file call always, by a writer too: a
    /// read that starts in them is a file call for all of it, and one that
    /// starts right after them is none.
    @Test func theHeadersAreReadByAFileCall() throws {
        let directory = try TemporaryDirectory()
        let (file, counts) = try Self.mapped(directory)
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
                path: directory.path(), access: .readOnly, durability: .none, lock: .shared, memoryMapped: true,
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
    @Test func aWriteInPlaceLeavesTheLimit() throws {
        let directory = try TemporaryDirectory()
        let (file, counts) = try Self.mapped(directory)
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
            path: directory.path(), access: .create, durability: .none, lock: .exclusive, memoryMapped: true,
            segmentSize: Self.page, calls: calls)
        #expect(!file.isMemoryMapped)
        let bytes = Self.pattern(2 * Self.page)
        try writeBytes(file, bytes, at: 0)
        #expect(try Self.afterTheHeaders(file, bytes.count) == Array(bytes[Self.headers...]))
        #expect(counts.reads == 1)
        #expect(counts.maps == 0)

        // A snapshot of a database in it has no map either, and the file
        // may be cut under it, as without the map.
        let other = try TemporaryDirectory()
        let storage = try FileStorage(
            path: other.path(), access: .create, durability: .none, lock: .exclusive, memoryMapped: true,
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
        try storage.truncate(to: 0)
        #expect(throws: XitDBError.snapshotOverwritten) { try readBytes(snapshot.storage, at: 0, count: 8) }
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
    @Test func aSegmentTheSystemRefusesIsReadByFileCall() throws {
        let directory = try TemporaryDirectory()
        let (file, counts) = try Self.mapped(directory)
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
        let database = try Database(creating: subject.storage, hashSize: 20)
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

    /// The file is never cut below what a live snapshot reads through the
    /// map: the cut is refused, nothing is changed, and the snapshot reads
    /// its commit. A cut at or above the snapshot's size, as a rolled-back
    /// transaction makes, goes through. When the snapshot has gone, so
    /// does the cut below it.
    @Test(arguments: mappedKinds)
    func aCutBelowALiveSnapshotIsRefused(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Self.filled(subject)
        let committed = try database.committedSize
        #expect(committed > UInt64(3 * Self.page), "the database spans several segments")
        let walk = try StructureWalk.describe(database.rootCursor.readOnly)
        try subject.storage.flush()
        let before = try subject.stored()

        var snapshot: Snapshot? = try database.snapshot()
        #expect(throws: XitDBError.snapshotStillMapped) { try subject.storage.truncate(to: 0) }
        #expect(throws: XitDBError.snapshotStillMapped) { try subject.storage.truncate(to: committed - 1) }
        #expect(try subject.stored() == before, "nothing was changed")
        #expect(try subject.storage.length == committed)

        // A transaction that rolls back cuts its tail, which lies above
        // the snapshot.
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
        #expect(try StructureWalk.describe(try #require(snapshot).rootCursor) == walk)
        #expect(try readBytes(try #require(snapshot).storage, at: 0, count: Int(committed)).count == Int(committed))

        // A copy of the snapshot is a snapshot: the cut waits for both.
        var copy = snapshot
        snapshot = nil
        #expect(throws: XitDBError.snapshotStillMapped) { try subject.storage.truncate(to: 0) }
        #expect(try StructureWalk.describe(try #require(copy).rootCursor) == walk)
        copy = nil

        try subject.storage.truncate(to: 0)
        #expect(try subject.storage.length == 0)
    }

    /// A sync from zero begins with a cut to nothing, so it is refused
    /// while a snapshot of the database reads through the map: the replica
    /// stays the database it was, its file as it was, and the snapshot
    /// reads its commit. With the snapshot released the same sync goes
    /// through. This is what the snapshot proof no longer shows on the
    /// mapped kinds, where it releases its snapshots before such a sync.
    @Test(arguments: mappedKinds)
    func aSyncFromZeroIsRefusedUnderALiveSnapshot(kind: StorageKind) throws {
        let sourceStorage = MemoryStorage()
        let source = try Database(creating: sourceStorage, hashSize: 20)
        try source.withTransaction { root in
            let map = try HashMap<ReadWrite>(root)
            for index in 0..<50 {
                try map.put(.uint(UInt64(index)), forHash: hashInt("source-\(index)"))
            }
        }
        let incoming = try source.readCommitted(from: 0, to: try source.committedSize)

        let subject = try StorageUnderTest(kind)
        let replica = try Self.filled(subject)
        let walk = try StructureWalk.describe(replica.rootCursor.readOnly)
        try subject.storage.flush()
        let before = try subject.stored()
        let fileID = replica.header.fileID

        var snapshot: Snapshot? = try replica.snapshot()
        #expect(throws: XitDBError.snapshotStillMapped) { try replica.applyReplicated(at: 0, bytes: incoming) }
        try subject.storage.flush()
        #expect(try subject.stored() == before, "the file is as it was")
        #expect(replica.header.fileID == fileID, "the replica is the database it was")
        #expect(try StructureWalk.describe(replica.rootCursor.readOnly) == walk)
        #expect(try StructureWalk.describe(try #require(snapshot).rootCursor) == walk)

        snapshot = nil
        try replica.applyReplicated(at: 0, bytes: incoming)
        try subject.storage.flush()
        #expect(try subject.stored() == incoming)
        #expect(
            try StructureWalk.describe(replica.rootCursor.readOnly)
                == StructureWalk.describe(source.rootCursor.readOnly))
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
        #expect(map.lease != nil)

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

    /// With the lock that the map needs, a file whose database was closed
    /// while a snapshot of it lives cannot be opened again: the snapshot
    /// keeps the descriptor open, and with it the lock. When the snapshot
    /// has gone the file opens.
    @Test func aSnapshotKeepsTheLockTheMapNeeds() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path()
        var snapshot: Snapshot?
        do {
            let storage = try BufferedFileStorage(
                path: path, access: .create, durability: .none, lock: .exclusive, memoryMapped: true)
            let database = try Database(creating: storage, hashSize: 20)
            try database.withTransaction { root in
                try HashMap<ReadWrite>(root).put(.uint(1), forHash: hashInt("one"))
            }
            snapshot = try database.snapshot()
        }
        #expect(throws: XitDBError.storageFailure(errno: EWOULDBLOCK)) {
            _ = try BufferedFileStorage(path: path, access: .readWrite, lock: .exclusive, memoryMapped: true)
        }
        #expect(snapshot != nil)
        snapshot = nil
        let again = try BufferedFileStorage(path: path, access: .readWrite, lock: .exclusive, memoryMapped: true)
        let reopened = try Database(opening: again, hashSize: 20)
        #expect(try HashMap<ReadOnly>(reopened.rootCursor.readOnly).cursor(forHash: hashInt("one"))?.readUInt64() == 1)
    }
}
