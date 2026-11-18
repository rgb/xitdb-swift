import Foundation
import Testing
import XitDBHashing

@testable import XitDB

/// A byte array is held to the storage's length before it is allocated
/// for, and the storage is asked for that length only where the array does
/// not fit the length the reader knows already (brief 36: on a file the
/// asking is a system call, and every read of a byte array made one).
///
/// What a size no file could hold gets is in `CorruptFileTests` and the
/// conformance fixtures, as before. Here: that the storage is asked once
/// and not for each read; and the one case that moved, a file cut by
/// another process after the reader learnt its length, which ends as it
/// did, with `endOfStream`, a little later.
@Suite struct ByteArrayExtentTests {
    /// The file storages, by how a reader's own storage reads the file.
    enum FileKind: String, CaseIterable, CustomTestStringConvertible {
        case file, buffered, mappedFile, mappedBuffered

        var testDescription: String { rawValue }

        var isBuffered: Bool { self == .buffered || self == .mappedBuffered }
        var isMapped: Bool { self == .mappedFile || self == .mappedBuffered }

        /// The two that read by file calls, under which a file may be cut:
        /// a cut below what a map reads ends the process, by design.
        static let byFileCalls: [FileKind] = [.file, .buffered]
    }

    /// The calls of a storage for its file's length, counted.
    private final class Counted {
        var lengths = 0
    }

    /// A reader's storage of its own on a file, opened to be read with no
    /// lock, whose calls for the file's length are counted.
    private static func reader(_ kind: FileKind, at path: String, _ counted: Counted) throws -> any WritableStorage {
        var calls = FileCalls()
        let length = calls.length
        calls.length = { (descriptor: Int32) throws(XitDBError) -> UInt64 in
            counted.lengths += 1
            return try length(descriptor)
        }
        let file = try FileStorage(
            path: path, access: .readOnly, reading: kind.isMapped ? .memoryMap : .fileCalls,
            segmentSize: Platform.pageSize, calls: calls)
        guard file.isMemoryMapped == kind.isMapped else { throw NotReadThroughTheMap(path: path) }
        return kind.isBuffered ? BufferedFileStorage(file) : file
    }

    /// The text under key `index`: longer than a slot holds, so that it is
    /// a byte record in the file.
    private static func text(_ index: Int) -> String {
        "the value of entry \(index), which is longer than a slot holds"
    }

    /// The bytes of element `index` of the list of large values: ten
    /// thousand, so that a compaction copies each in three chunks.
    private static func large(_ index: Int) -> [UInt8] {
        [UInt8](repeating: UInt8(truncatingIfNeeded: index &+ 1), count: 10_000)
    }

    /// Writes a database to a new file at `path`: a history of one moment,
    /// a map with `texts` texts under "texts", by their keys "k0" and on,
    /// and a list of `values` large byte arrays under "values", written
    /// last, so that the last of them ends just before the commit's
    /// trailer.
    private static func write(at path: String, texts: Int, values: Int) throws {
        let database = try Database(
            creating: try BufferedFileStorage(path: path, access: .create, durability: .none), hashing: SHA256.self)
        let history = try ArrayList(database.rootCursor)
        try history.append(.slot(nil)) { cursor in
            let moment = try HashMap(cursor)
            let map = try HashMap(try moment.putCursor(forKey: "texts"))
            for index in 0..<texts { try map.put(text(index), forKey: "k\(index)") }
            let list = try ArrayList(try moment.putCursor(forKey: "values"))
            for index in 0..<values { try list.append(large(index)) }
        }
    }

    /// The moment of a database written by ``write(at:texts:values:)``, by
    /// a cursor that is not at the root: a read through it does not look at
    /// the root header again.
    private static func moment(of database: ReadOnlyDatabase) throws -> HashMap<ReadOnly> {
        try HashMap(try #require(try ArrayList(database.rootCursor).cursor(at: -1)))
    }

    // MARK: The storage is asked once

    /// Reads of byte arrays ask the file for its length once and not each
    /// time: after the first, three hundred more of each kind of read make
    /// no call, by file calls and through the map, on both file storages.
    @Test(arguments: FileKind.allCases)
    func readsOfByteArraysAskTheFilesLengthOnce(kind: FileKind) throws {
        let directory = try TemporaryDirectory()
        try Self.write(at: directory.path(), texts: 300, values: 4)
        let counted = Counted()
        let database = try ReadOnlyDatabase(
            opening: try Self.reader(kind, at: directory.path(), counted), hashing: SHA256.self)
        let moment = try Self.moment(of: database)
        let texts = try HashMap(try #require(try moment.cursor(forKey: "texts")))

        // The first read of a byte array learns the length.
        #expect(try texts.value(forKey: "k0", as: String.self) == Self.text(0))
        #expect(counted.lengths >= 1)
        let learnt = counted.lengths

        for index in 0..<300 {
            let key = "k\(index)"
            let expected = Self.text(index)
            #expect(try texts.value(forKey: key, as: String.self) == expected)
            #expect(try texts.value(forKey: key, as: [UInt8].self) == Array(expected.utf8))
            #expect(try texts.value(forKey: key, as: Bytes.self) == Bytes(Array(expected.utf8)))
            let cursor = try #require(try texts.cursor(forKey: key))
            #expect(try cursor.readBytes() == Array(expected.utf8))
            var reader = try cursor.reader()
            #expect(try reader.readRemaining() == Array(expected.utf8))
        }
        #expect(counted.lengths == learnt, "fifteen hundred reads of byte arrays asked for the file's length")

        // The large values lie further on in the file than anything read
        // so far, and inside the length that was learnt: no call for them
        // either.
        let values = try ArrayList(try #require(try moment.cursor(forKey: "values")))
        for index in 0..<4 { #expect(try values.value(at: index, as: [UInt8].self) == Self.large(index)) }
        #expect(counted.lengths == learnt)
    }

    /// A byte array that lies past the length the reader knows is asked of
    /// the storage, once, and read: a writer that reads back, inside its
    /// transaction, what it has just written past the file's end as the
    /// transaction found it.
    @Test(arguments: FileKind.allCases)
    func aByteArrayPastTheLengthKnownIsAskedOfTheStorage(kind: FileKind) throws {
        let directory = try TemporaryDirectory()
        let counted = Counted()
        var calls = FileCalls()
        let length = calls.length
        calls.length = { (descriptor: Int32) throws(XitDBError) -> UInt64 in
            counted.lengths += 1
            return try length(descriptor)
        }
        let file = try FileStorage(
            path: directory.path(), access: .create, durability: .none, lock: kind.isMapped ? .exclusive : nil,
            reading: kind.isMapped ? .memoryMap : .fileCalls, segmentSize: Platform.pageSize, calls: calls)
        guard file.isMemoryMapped == kind.isMapped else { throw NotReadThroughTheMap(path: directory.path()) }
        let storage: any WritableStorage = kind.isBuffered ? BufferedFileStorage(file) : file
        let writer = try Database(creating: storage, hashing: SHA256.self)

        var read: [String] = []
        var asked: [Int] = []
        try writer.withTransaction { root in
            let map = try HashMap(root)
            try map.put(Self.text(1), forKey: "one")
            let one = try map.cursor(forKey: "one")
            asked.append(counted.lengths)
            read.append(try one?.read(String.self) ?? "")  // past the length known: asks
            asked.append(counted.lengths)
            read.append(try one?.read(String.self) ?? "")  // known now
            asked.append(counted.lengths)
            try map.put(Self.text(2), forKey: "two")
            let two = try map.cursor(forKey: "two")
            asked.append(counted.lengths)
            read.append(try two?.read(String.self) ?? "")  // past it again: asks
            asked.append(counted.lengths)
            read.append(try one?.read(String.self) ?? "")
            read.append(try two?.read(String.self) ?? "")
            asked.append(counted.lengths)
        }
        #expect(read == [Self.text(1), Self.text(1), Self.text(2), Self.text(1), Self.text(2)])
        // A read of what lies within the length known asks the file nothing.
        #expect(asked[2] == asked[1])
        #expect(asked[5] == asked[4])
        // One past it asks once at most: a buffered storage knows its own
        // length and need not ask its file.
        #expect(asked[1] - asked[0] <= 1)
        #expect(asked[4] - asked[3] <= 1)
        if !kind.isBuffered {
            #expect(asked[1] - asked[0] == 1)
            #expect(asked[4] - asked[3] == 1)
        }
    }

    /// A compaction asks for its source's length no more often for more
    /// byte records: it used to ask once for each it copied.
    @Test(arguments: FileKind.allCases)
    func aCompactionAsksNoMoreForMoreByteRecords(kind: FileKind) throws {
        func asked(values count: Int) throws -> Int {
            let directory = try TemporaryDirectory()
            try Self.write(at: directory.path(), texts: 3, values: count)
            let counted = Counted()
            let database = try ReadOnlyDatabase(
                opening: try Self.reader(kind, at: directory.path(), counted), hashing: SHA256.self)
            var offsets = MemoryOffsetMap()
            let target = try database.compact(into: MemoryStorage(), offsetMap: &offsets)
            let moment = try HashMap(try #require(try ArrayList(target.rootCursor.readOnly).cursor(at: -1)))
            let list = try ArrayList(try #require(try moment.cursor(forKey: "values")))
            #expect(try list.count == UInt64(count))
            #expect(try list.value(at: -1, as: [UInt8].self) == Self.large(count - 1))
            return counted.lengths
        }
        let few = try asked(values: 2)
        let many = try asked(values: 60)
        #expect(many == few, "sixty byte records asked \(many) times, two asked \(few)")
    }

    // MARK: A file cut under a reader that knows its length

    /// Cuts the file at `path` to `length` bytes, as another process does.
    private static func cut(_ path: String, to length: UInt64) throws {
        let handle = try #require(FileHandle(forWritingAtPath: path))
        defer { try? handle.close() }
        try handle.truncate(atOffset: length)
    }

    /// A file cut by another process, inside a byte array, after the
    /// reader learnt the file's length: a read of that array through a
    /// cursor the reader holds ends with `endOfStream`, as it did when the
    /// storage was asked each time. The length is not asked again: the
    /// read comes short, and that is what says so.
    @Test(arguments: FileKind.byFileCalls)
    func aFileCutSinceItsLengthWasLearntEndsTheStream(kind: FileKind) throws {
        let directory = try TemporaryDirectory()
        try Self.write(at: directory.path(), texts: 3, values: 3)
        let counted = Counted()
        let database = try ReadOnlyDatabase(
            opening: try Self.reader(kind, at: directory.path(), counted), hashing: SHA256.self)
        let moment = try Self.moment(of: database)
        let texts = try HashMap(try #require(try moment.cursor(forKey: "texts")))
        let values = try ArrayList(try #require(try moment.cursor(forKey: "values")))
        let first = try #require(try values.cursor(at: 0))
        let last = try #require(try values.cursor(at: 2))

        // The reader learns the length, and reads the last value whole.
        #expect(try texts.value(forKey: "k0", as: String.self) == Self.text(0))
        #expect(try last.read([UInt8].self) == Self.large(2))

        // Another process cuts the file inside the last value's bytes.
        let record = try last.slot.value
        try Self.cut(directory.path(), to: record + 8 + 5_000)
        let before = counted.lengths

        #expect(throws: XitDBError.endOfStream) { try last.read([UInt8].self) }
        #expect(throws: XitDBError.endOfStream) { try last.readBytes() }
        #expect(throws: XitDBError.endOfStream) { try last.read(Bytes.self) }
        #expect(throws: XitDBError.endOfStream) {
            var reader = try last.reader()
            _ = try reader.readRemaining()
        }
        #expect(counted.lengths == before, "the short read said so, with no call for the length")
        // What lies before the cut reads as it did.
        #expect(try first.read([UInt8].self) == Self.large(0))
        #expect(try texts.value(forKey: "k1", as: String.self) == Self.text(1))

        // An operation that starts at the root asks the length new, says
        // that the database is cut, and brings the length known up to
        // date: the held cursor's read is then refused by the length, with
        // a call for it, since the array no longer fits what is known.
        #expect(throws: XitDBError.truncatedDatabase) { try ArrayList(database.rootCursor).cursor(at: -1) }
        let afterTheRoot = counted.lengths
        #expect(afterTheRoot > before)
        #expect(throws: XitDBError.endOfStream) { try last.read([UInt8].self) }
        #expect(counted.lengths == afterTheRoot + 1)
    }

    // MARK: A file cut below its committed size is refused at the root

    /// A reader's file cut below its committed size by another descriptor,
    /// with the root header left saying the old size: the next operation
    /// that starts at the root is refused with `truncatedDatabase`, through
    /// `rootCursor` and through a collection made from it before the cut,
    /// by file calls and through either map, on both file storages. For a
    /// reader through a map this refusal is what stands between such a cut
    /// and a read of a mapped page past the file's end, which is a signal
    /// and no error: the process is still there to say so. (A cursor held
    /// from before the cut is not asked: under a map its read would be
    /// that signal, by design.)
    @Test(arguments: [FileReading.fileCalls, .memoryMap, .memoryMapReadAhead], [false, true])
    func aFileCutBelowItsCommittedSizeIsRefusedAtTheRoot(reading: FileReading, buffered: Bool) throws {
        let directory = try TemporaryDirectory()
        try Self.write(at: directory.path(), texts: 3, values: 3)
        let file = try FileStorage(
            path: directory.path(), access: .readOnly, reading: reading, segmentSize: Platform.pageSize)
        guard file.isMemoryMapped == (reading != .fileCalls) else {
            throw NotReadThroughTheMap(path: directory.path())
        }
        let storage: any WritableStorage = buffered ? BufferedFileStorage(file) : file
        let database = try ReadOnlyDatabase(opening: storage, hashing: SHA256.self)

        // The reader has read to the end of the file, through its map
        // where it has one, and holds a collection made from the root.
        let history = try ArrayList(database.rootCursor)
        let moment = try Self.moment(of: database)
        let values = try ArrayList(try #require(try moment.cursor(forKey: "values")))
        #expect(try values.value(at: 2, as: [UInt8].self) == Self.large(2))
        let committed = try database.committedSize

        // Another descriptor cuts the file inside the last value, well
        // below the committed size; the header still says the old size.
        try Self.cut(directory.path(), to: committed - 6_000)

        #expect(throws: XitDBError.truncatedDatabase) { try history.cursor(at: -1) }
        #expect(throws: XitDBError.truncatedDatabase) { try history.count }
        #expect(throws: XitDBError.truncatedDatabase) { try ArrayList(database.rootCursor).cursor(at: -1) }
        #expect(throws: XitDBError.truncatedDatabase) { try HashMap(database.rootCursor).cursor(forKey: "texts") }
        #expect(throws: XitDBError.truncatedDatabase) { try database.committedSize }
        #expect(throws: XitDBError.truncatedDatabase) { try database.snapshot() }
        #expect(throws: XitDBError.truncatedDatabase) { try database.replicaState }
        var offsets = MemoryOffsetMap()
        #expect(throws: XitDBError.truncatedDatabase) {
            try database.compact(into: MemoryStorage(), offsetMap: &offsets)
        }
        // And the file as it is now does not open: its root header is not
        // to be trusted.
        var opening: XitDBError.Code?
        do throws(XitDBError) {
            _ = try ReadOnlyDatabase(opening: try FileStorage(path: directory.path(), access: .readOnly))
        } catch {
            opening = error.code
        }
        #expect(opening == .untrustedRootHeader)
    }

    /// An error of the tests' own.
    private struct Mine: Error, Equatable {}

    /// An offset map that runs a hook the first time one source offset is
    /// looked up, which is the first thing a compaction does with a record.
    private struct HookedOffsetMap: OffsetMap {
        var inner = MemoryOffsetMap()
        let offset: UInt64
        let hook: () throws -> Void
        var fired = false

        mutating func reset() throws { inner.reset() }

        mutating func get(_ sourceOffset: UInt64) throws -> UInt64? {
            if sourceOffset == offset, !fired {
                fired = true
                try hook()
            }
            return inner.get(sourceOffset)
        }

        mutating func put(_ sourceOffset: UInt64, _ targetOffset: UInt64) throws {
            inner.put(sourceOffset, targetOffset)
        }
    }

    /// A source for a compaction: a new file with six large values, a
    /// reader of its own on it with its length calls counted, and where the
    /// last value's record begins.
    private struct Source {
        let directory: TemporaryDirectory
        let database: ReadOnlyDatabase
        let counted = Counted()
        let lastRecord: UInt64

        init(_ kind: FileKind) throws {
            directory = try TemporaryDirectory()
            try ByteArrayExtentTests.write(at: directory.path(), texts: 3, values: 6)
            database = try ReadOnlyDatabase(
                opening: try ByteArrayExtentTests.reader(kind, at: directory.path(), counted), hashing: SHA256.self)
            let moment = try ByteArrayExtentTests.moment(of: database)
            let values = try ArrayList(try #require(try moment.cursor(forKey: "values")))
            let last = try #require(try values.cursor(at: 5))
            lastRecord = try last.slot.value
        }

        /// An offset map that cuts the source's file inside the last
        /// value's second chunk when the compaction comes to that value.
        func cuttingMap() -> HookedOffsetMap {
            let path = directory.path()
            let record = lastRecord
            return HookedOffsetMap(offset: record) {
                try ByteArrayExtentTests.cut(path, to: record + 8 + 5_000)
            }
        }

        /// An offset map that fails with an error of its own at the same
        /// place.
        func failingMap() -> HookedOffsetMap {
            HookedOffsetMap(offset: lastRecord) { throw Mine() }
        }
    }

    /// A compaction whose source is cut by another process while it runs,
    /// inside a byte record it has not copied yet and within the length
    /// its reader knows: the record's first chunk is copied before the
    /// second comes short, the compaction ends with `endOfStream`, and a
    /// live target is left as it was, to the byte.
    @Test(arguments: FileKind.byFileCalls)
    func aCompactionThatMeetsTheCutLeavesALiveTargetAsItWas(kind: FileKind) throws {
        let source = try Source(kind)
        let targetStorage = MemoryStorage()
        let target = try Database(creating: targetStorage, hashing: SHA256.self)
        let before = targetStorage.bytes

        var offsets = source.cuttingMap()
        #expect(throws: XitDBError.endOfStream) { try source.database.compact(into: target, offsetMap: &offsets) }
        #expect(offsets.fired)
        // The file is cut where the map cut it: the compaction got that far.
        #expect(try FileStorage(path: source.directory.path(), access: .readOnly).length == source.lastRecord + 5_008)

        #expect(targetStorage.bytes == before)
        #expect(try target.rootCursor.slot.isEmpty)
        // And it takes a compaction afterwards, as an empty target does.
        let whole = try Source(kind)
        var again = MemoryOffsetMap()
        try whole.database.compact(into: target, offsetMap: &again)
        let moment = try HashMap(try #require(try ArrayList(target.rootCursor.readOnly).cursor(at: -1)))
        let values = try ArrayList(try #require(try moment.cursor(forKey: "values")))
        #expect(try values.value(at: 5, as: [UInt8].self) == Self.large(5))
    }

    /// The same into a storage: what is left there is what any compaction
    /// that fails at that place leaves, a new database with an empty root
    /// and nothing after its first commit. Held against one that fails by
    /// its offset map's own error at the same record: the two storages are
    /// the same bytes.
    @Test(arguments: FileKind.byFileCalls)
    func aCompactionThatMeetsTheCutLeavesAStorageAsAnyFailedOneDoes(kind: FileKind) throws {
        let cut = try Source(kind)
        let afterTheCut = MemoryStorage()
        var cutting = cut.cuttingMap()
        #expect(throws: XitDBError.endOfStream) {
            try cut.database.compact(into: afterTheCut, fileID: 9, offsetMap: &cutting)
        }
        #expect(cutting.fired)

        let failed = try Source(kind)
        let afterTheFailure = MemoryStorage()
        var failing = failed.failingMap()
        #expect(throws: XitDBError.callerError(Mine())) {
            try failed.database.compact(into: afterTheFailure, fileID: 9, offsetMap: &failing)
        }

        #expect(afterTheCut.bytes == afterTheFailure.bytes)
        let left = try Database(opening: afterTheCut, hashing: SHA256.self)
        #expect(try left.rootCursor.slot.isEmpty)
        #expect(try left.committedSize == UInt64(afterTheCut.bytes.count))
        #expect(left.header.fileID == 9)
    }

    /// The cut is met after the reader knew the length and without a call
    /// for it: the compaction asked for the source's length before the cut
    /// and not after, so it is the short read of the record's second chunk
    /// that ended it.
    @Test(arguments: FileKind.byFileCalls)
    func theCutIsMetByTheShortReadAndNotByTheLength(kind: FileKind) throws {
        let source = try Source(kind)
        let path = source.directory.path()
        let record = source.lastRecord
        let counted = source.counted
        var askedAtTheCut = -1
        var offsets = HookedOffsetMap(offset: record) {
            try Self.cut(path, to: record + 8 + 5_000)
            askedAtTheCut = counted.lengths
        }
        #expect(throws: XitDBError.endOfStream) {
            try source.database.compact(into: MemoryStorage(), offsetMap: &offsets)
        }
        #expect(askedAtTheCut >= 1)
        #expect(counted.lengths == askedAtTheCut)
    }
}
