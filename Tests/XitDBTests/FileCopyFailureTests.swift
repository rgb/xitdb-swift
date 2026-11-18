import Foundation
import Testing

@testable import XitDB

/// The file calls of a storage, each counted, and one of them made to fail.
final class CountedFileCalls {
    /// The calls made while counting, by name, in order, the failed one
    /// among them.
    private(set) var made: [String] = []
    /// The calls that came back without an error, by name, in order.
    private(set) var succeeded: [String] = []
    /// The call that was made to fail, once it has been.
    private(set) var failed: String?
    /// Which call fails, counted from where counting began, or none.
    var failing: Int?
    /// Whether calls are counted: not while a test builds what it starts
    /// from.
    var counting = false

    /// Notes a call, and says whether it is the one that fails.
    private func fails(_ name: String) -> Bool {
        guard counting else { return false }
        defer { made.append(name) }
        guard made.count == failing else { return false }
        failed = name
        return true
    }

    private func came(_ name: String) {
        if counting { succeeded.append(name) }
    }

    /// The platform's calls, each counted, and the failing one answering
    /// with an input/output error, or, for a mapping, with the system's
    /// refusal for want of memory.
    var calls: FileCalls {
        var calls = FileCalls()
        calls.sync = { [self] (descriptor: Int32, call: SyncCall) in
            if fails("sync") { return EIO }
            let result = Platform.syncFile(descriptor, call)
            if result == 0 { came("sync") }
            return result
        }
        calls.write = { [self] (descriptor: Int32, bytes: Span<UInt8>, offset: UInt64) throws(XitDBError) -> Void in
            if fails("write") { throw .storageFailure(errno: EIO) }
            try Platform.writeFile(descriptor, bytes, at: offset)
            came("write")
        }
        calls.read = {
            [self] (descriptor: Int32, buffer: inout MutableSpan<UInt8>, range: Range<Int>, offset: UInt64)
                throws(XitDBError) -> Int in
            if fails("read") { throw .storageFailure(errno: EIO) }
            let read = try Platform.readFile(descriptor, into: &buffer, range: range, at: offset)
            came("read")
            return read
        }
        calls.length = { [self] (descriptor: Int32) throws(XitDBError) -> UInt64 in
            if fails("length") { throw .storageFailure(errno: EIO) }
            let length = try Platform.fileLength(descriptor)
            came("length")
            return length
        }
        calls.setLength = { [self] (descriptor: Int32, length: UInt64) throws(XitDBError) -> Void in
            let name = length == 0 ? "cut to nothing" : "set length"
            if fails(name) { throw .storageFailure(errno: EIO) }
            try Platform.setFileLength(descriptor, length)
            came(name)
        }
        calls.map = { [self] (descriptor: Int32, offset: UInt64, length: Int) in
            if fails("map") { return (0, ENOMEM) }
            let mapped = Platform.mapFile(descriptor, offset: offset, length: length)
            if mapped.error == 0 { came("map") }
            return mapped
        }
        calls.open = { [self] (path: String, access: FileAccess) throws(XitDBError) -> Int32 in
            if fails("open") { throw .storageFailure(errno: EIO) }
            let descriptor = try Platform.openFile(path, .toWrite(access))
            came("open")
            return descriptor
        }
        calls.lock = { [self] (descriptor: Int32, lock: FileLock) throws(XitDBError) -> Void in
            if fails("lock") { throw .storageFailure(errno: EIO) }
            try Platform.lockFile(descriptor, lock)
            came("lock")
        }
        calls.rename = { [self] (source: String, destination: String) throws(XitDBError) -> Void in
            if fails("rename") { throw .storageFailure(errno: EIO) }
            try Platform.renameFile(source, to: destination)
            came("rename")
        }
        calls.syncDirectory = { [self] (path: String, call: SyncCall) in
            if fails("sync directory") { return EIO }
            let result = Platform.syncDirectory(of: path, call)
            if result == 0 { came("sync directory") }
            return result
        }
        calls.remove = { [self] (path: String) throws(XitDBError) -> Bool in
            if fails("remove") { throw .storageFailure(errno: EIO) }
            let removed = try Platform.removeFile(path)
            came("remove")
            return removed
        }
        return calls
    }
}

/// A full copy onto a file storage, of each of the four kinds, with each
/// file call it makes failing in turn. Whatever fails, the path then holds
/// a database that opens and is whole, and it is the one that was there or
/// the one that was copied: the old one until the new file has been given
/// the path's name, the new one from then on. The writer's own database
/// object says the same, of itself and to a source that asks what to send
/// it next.
///
/// The writers here hold the exclusive lock, as a writer does that wants a
/// file left by a copy that did not end removed when it opens the path;
/// what a writer without the lock does about such a file has a test of its
/// own beside the replacement's.
@Suite struct FileCopyFailureTests {
    /// The four kinds of file storage.
    static let kinds: [StorageKind] = [.file, .bufferedFile, .mappedFile, .mappedBufferedFile]

    /// A database as a test starts from it or copies it: its file's bytes,
    /// how it walks, and what it says of itself as a replica.
    struct Known {
        let bytes: [UInt8]
        let walk: String
        let state: ReplicaState
    }

    /// A database of `count` entries named after `name`, made in memory.
    private static func known(_ name: String, count: Int) throws -> Known {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashSize: 20)
        try database.withTransaction { root in
            let map = try HashMap<ReadWrite>(root)
            for index in 0..<count {
                try map.put(.uint(UInt64(index)), forHash: hashInt("\(name)-\(index)"))
            }
        }
        return Known(
            bytes: try database.readCommitted(from: 0, to: try database.committedSize),
            walk: try StructureWalk.describe(database.rootCursor.readOnly),
            state: try database.replicaState)
    }

    /// How the bytes of a copy reach the database: all at once from an
    /// array, which is one write of the data, or from a source that gives a
    /// thousand at a time, which is a write for each block of the copy.
    enum Way: String, CaseIterable, CustomTestStringConvertible {
        case array, stream

        var testDescription: String { rawValue }
    }

    /// Gives bytes a thousand at a time.
    private struct Piecewise: ByteSource {
        let bytes: [UInt8]
        var given = 0

        mutating func read(into buffer: inout MutableSpan<UInt8>) throws -> Int {
            let count = min(1000, buffer.count, bytes.count - given)
            for index in 0..<count {
                buffer[index] = bytes[given + index]
            }
            given += count
            return count
        }
    }

    /// The database a copy lands on, and the one that is copied onto it:
    /// another file, larger, of several of the copy's blocks.
    static let old = Result { try known("old", count: 40) }
    static let new = Result { try known("new", count: 300) }

    /// A writer's storage of `kind` on the file at `path`, with the
    /// exclusive lock and its calls counted; on the mapped kinds reading
    /// through a memory map in segments of one page.
    private static func writer(_ kind: StorageKind, at path: String, calls: FileCalls) throws -> any WritableStorage {
        let mapped = kind == .mappedFile || kind == .mappedBufferedFile
        var file = try FileStorage(
            path: path, access: .readWrite, lock: .exclusive, reading: mapped ? .memoryMap : .fileCalls,
            segmentSize: Platform.pageSize, calls: calls)
        if mapped { file = try readThroughTheMap(file, at: path) }
        return kind == .bufferedFile || kind == .mappedBufferedFile ? BufferedFileStorage(file) : file
    }

    /// One full copy with one call failing, or none, and what came of it.
    struct Copy {
        let directory: TemporaryDirectory
        let counted: CountedFileCalls
        /// The writer's database, which the copy was applied to.
        var database: Database?
        /// What the copy threw, if it threw.
        let thrown: XitDBError?

        /// Whether the new file was given the path's name.
        var renamed: Bool { counted.succeeded.contains("rename") }
    }

    private static func copy(_ kind: StorageKind, _ way: Way, failing: Int?) throws -> Copy {
        let directory = try TemporaryDirectory()
        #expect(FileManager.default.createFile(atPath: directory.path(), contents: Data(try old.get().bytes)))
        let counted = CountedFileCalls()
        let database = try Database(opening: try writer(kind, at: directory.path(), calls: counted.calls), hashSize: 20)
        counted.failing = failing
        counted.counting = true
        var thrown: XitDBError?
        do {
            let bytes = try new.get().bytes
            switch way {
            case .array:
                try database.applyReplicated(at: 0, bytes: bytes)
            case .stream:
                var source = Piecewise(bytes: bytes)
                try database.applyReplicated(at: 0, from: &source, count: UInt64(bytes.count))
            }
        } catch let error as XitDBError {
            thrown = error
        }
        counted.counting = false
        return Copy(directory: directory, counted: counted, database: database, thrown: thrown)
    }

    /// The writer's own database answers as `expected`: its walk, and its
    /// account of itself as a replica.
    private static func theWritersObjectIs(_ expected: Known, _ copy: Copy, _ step: String) throws {
        let database = try #require(copy.database)
        #expect(try StructureWalk.describe(database.rootCursor.readOnly) == expected.walk, "the writer's walk, \(step)")
        #expect(try database.replicaState == expected.state, "the writer's account of itself, \(step)")
    }

    /// An opener without a lock, while the writer lives, opens `expected`.
    private static func aReaderOpens(_ expected: Known, _ copy: Copy, _ step: String) throws {
        let reader = try ReadOnlyDatabase(
            opening: try ReadOnlyFileStorage(path: copy.directory.path()), hashSize: 20)
        #expect(try StructureWalk.describe(reader.rootCursor) == expected.walk, "a reader's walk, \(step)")
    }

    /// With the first writer gone, the next writer opens `expected`.
    private static func theNextWriterOpens(_ expected: Known, _ kind: StorageKind, _ copy: Copy, _ step: String) throws
    {
        let next = try Database(
            opening: try writer(kind, at: copy.directory.path(), calls: FileCalls()), hashSize: 20)
        #expect(
            try StructureWalk.describe(next.rootCursor.readOnly) == expected.walk, "the next writer's walk, \(step)")
        #expect(try next.replicaState == expected.state, "the next writer's account of itself, \(step)")
    }

    /// A copy with nothing failing gives the new database, to the writer,
    /// to a reader and to the next writer, and leaves no file beside it.
    @Test(arguments: kinds, Way.allCases)
    func aWholeCopyGivesTheNewDatabase(kind: StorageKind, way: Way) throws {
        let new = try Self.new.get()
        var copy = try Self.copy(kind, way, failing: nil)
        #expect(copy.thrown == nil)
        try Self.theWritersObjectIs(new, copy, "after a whole copy")
        try Self.aReaderOpens(new, copy, "after a whole copy")
        copy.database = nil
        try Self.theNextWriterOpens(new, kind, copy, "after a whole copy")
        #expect(!FileManager.default.fileExists(atPath: copy.directory.path() + ".incoming"))
    }

    /// Every file call of a copy fails in turn. After each, the database is
    /// the old one, or, once the new file has the path's name or where the
    /// call that was made to fail is one the copy does without, the new
    /// one: for the writer's own object, for a reader that opens the path
    /// while the writer lives, and for the next writer; and once that
    /// writer has opened the path no file of the copy is left beside it.
    @Test(arguments: kinds, Way.allCases)
    func aCopyThatFailsAtAnyCallLeavesTheOldDatabaseOrTheNew(kind: StorageKind, way: Way) throws {
        let old = try Self.old.get()
        let new = try Self.new.get()
        let whole = try Self.copy(kind, way, failing: nil)
        let calls = whole.counted.made
        // a copy of several blocks: its writes, its syncs, and the calls
        // that end it
        #expect(calls.count > 8, "\(calls)")
        #expect(calls.filter { $0 == "write" }.count >= 3, "\(calls)")
        #expect(calls.contains("sync"), "\(calls)")

        for index in calls.indices {
            var copy = try Self.copy(kind, way, failing: index)
            let step = "with call \(index) failing, \(copy.counted.failed ?? "none"), of \(calls)"
            // the call that was to fail was made, and it is the one the
            // whole copy made at that place
            #expect(copy.counted.failed == calls[index], "\(step)")
            let expected = copy.thrown == nil || copy.renamed ? new : old

            try Self.theWritersObjectIs(expected, copy, step)
            try Self.aReaderOpens(expected, copy, step)
            copy.database = nil
            try Self.theNextWriterOpens(expected, kind, copy, step)
            #expect(!FileManager.default.fileExists(atPath: copy.directory.path() + ".incoming"), "\(step)")
        }
    }
}
