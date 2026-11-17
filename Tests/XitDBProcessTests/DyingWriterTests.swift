import Foundation
import Testing
import XitDB

// The tests that start another process have a test target of their own,
// and so a process of their own to run in.
//
// While a process is being started, the new process holds the open files
// of the one that starts it, for a moment, the close-on-exec ones too; and
// a lock on a file belongs to the open file, not to who opened it. So in
// that moment a file the parent has just closed is still open, and still
// locked, and the parent's own next opening of it with the lock is refused
// (`EWOULDBLOCK`). In the tests' process hundreds of tests open, lock, close
// and reopen files while others run; a test beside them that started a
// process made one of them fail now and then: a conformance script's reopen
// of a mapped file, once in eight runs of the suite. Here nothing else
// holds a lock.

/// Whether a test can start another process, which iOS and its kin do not
/// allow.
#if os(macOS) || os(Linux)
    let aTestCanStartAProcess = true
#else
    let aTestCanStartAProcess = false
#endif

/// A tool of the package that a test runs was not found beside the tests.
struct ToolNotBuilt: Error, CustomStringConvertible {
    let name: String
    let lookedIn: [String]

    var description: String {
        "\(name) is not built beside the tests (looked in \(lookedIn)): build the package's tools, as `swift build` does"
    }
}

/// A class of the tests' own, by which Foundation finds where the tests'
/// code was loaded from.
private final class InTheTests {}

/// The built tool of that name, which the build puts beside the tests: in
/// the folder of the test bundle on macOS, and of the tests' runner on
/// Linux.
func builtTool(_ name: String) throws -> URL {
    let tests = Bundle(for: InTheTests.self).bundleURL
    var places = [tests, tests.deletingLastPathComponent()]
    if let executable = Bundle.main.executableURL {
        places.append(executable.deletingLastPathComponent())
    }
    for place in places {
        let tool = place.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: tool.path) { return tool }
    }
    throw ToolNotBuilt(name: name, lookedIn: places.map(\.path))
}

/// A folder for the files of one test, removed when the value goes away.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xitdb-process-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func path(_ name: String = "test.db") -> String {
        url.appendingPathComponent(name).path
    }
}

/// A storage a test made to read through a memory map does not.
private struct NotReadThroughTheMap: Error, CustomStringConvertible {
    let path: String

    var description: String {
        "the file at \(path) was to be read through a memory map and is not: its volume is not of a kind the library "
            + "maps, so the test would hold nothing of the map"
    }
}

/// Gives bytes a thousand at a time, so that a copy is written block by
/// block.
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

/// A writer that dies in the middle of a full copy onto a file, on each of
/// the four kinds of file storage: a second process, which ends at once at
/// a step it is given, with nothing flushed and nothing cleaned up. Whatever the step,
/// the path then holds a database that opens and is whole: the one that
/// was there, until the new file has been given the path's name, and the
/// copied one from then on. The next writer that opens the path finds that
/// database and leaves no file of the copy beside it.
///
/// What this shows is the order of the copy's steps, each of which leaves
/// the path with a whole database when the process ends there. It does not
/// show what a power cut leaves, which depends on what the system had
/// written to the disk and no test in a running system can see.
@Suite struct DyingWriterTests {
    /// The steps the writer can die at, by the tool's names for them.
    enum Step: String, CaseIterable, CustomTestStringConvertible {
        /// The new file has been made, and nothing written to it.
        case newFile = "new-file"
        /// Some of the copy's writes are in the file, others not.
        case midCopy = "mid-copy"
        /// The new file is whole and synced, and does not have the name.
        case beforeRename = "before-rename"
        /// The new file has the name, and the directory is not synced.
        case afterRename = "after-rename"

        var testDescription: String { rawValue }
    }

    /// The four kinds of file storage, by the tool's names for them.
    enum Kind: String, CaseIterable, CustomTestStringConvertible {
        case file, buffered
        case mappedFile = "mapped-file"
        case mappedBuffered = "mapped-buffered"

        var testDescription: String { rawValue }

        var isMapped: Bool { self == .mappedFile || self == .mappedBuffered }
        var isBuffered: Bool { self == .buffered || self == .mappedBuffered }
    }

    /// A database as a test starts from it or copies it: its committed
    /// bytes, how many entries its map has, and what it says of itself as
    /// a replica, which names the file and the commit.
    struct Known {
        let bytes: [UInt8]
        let entries: Int
        let state: ReplicaState
    }

    /// A database in memory whose root is a map of `entries` entries, each
    /// under a hash that starts with `mark`.
    private static func known(entries: Int, mark: UInt8) throws -> Known {
        let database = try Database(creating: MemoryStorage(), hashSize: 20)
        try database.withTransaction { root in
            let map = try HashMap<ReadWrite>(root)
            for index in 0..<entries {
                var hash = [UInt8](repeating: mark, count: 20)
                hash[18] = UInt8(index >> 8)
                hash[19] = UInt8(index & 0xFF)
                try map.put(.uint(UInt64(index)), forHash: hash)
            }
        }
        return Known(
            bytes: try database.readCommitted(from: 0, to: try database.committedSize), entries: entries,
            state: try database.replicaState)
    }

    /// The database a copy lands on, and the one that is copied onto it:
    /// another file, larger, of several of the copy's blocks.
    static let old = Result { try known(entries: 40, mark: 1) }
    static let new = Result { try known(entries: 300, mark: 2) }

    /// A writer's storage of `kind` on the file at `path`, with the
    /// exclusive lock; on the mapped kinds reading through a memory map in
    /// segments of one page.
    private static func writer(
        _ kind: Kind, at path: String, calls: FileCalls = FileCalls()
    ) throws -> any WritableStorage {
        let file = try FileStorage(
            path: path, access: .readWrite, lock: .exclusive, reading: kind.isMapped ? .memoryMap : .fileCalls,
            segmentSize: Int(getpagesize()), calls: calls)
        if kind.isMapped, !file.isMemoryMapped { throw NotReadThroughTheMap(path: path) }
        return kind.isBuffered ? BufferedFileStorage(file) : file
    }

    /// How many writes to the file a whole copy of `new` onto `old` makes
    /// on a storage of `kind`.
    private static func writesOfAWholeCopy(_ kind: Kind) throws -> Int {
        let folder = try TemporaryFolder()
        #expect(FileManager.default.createFile(atPath: folder.path(), contents: Data(try old.get().bytes)))
        let platform = FileCalls()
        var calls = FileCalls()
        var writes = 0
        calls.write = { (descriptor: Int32, bytes: Span<UInt8>, offset: UInt64) throws(XitDBError) -> Void in
            writes += 1
            try platform.write(descriptor, bytes, offset)
        }
        let database = try Database(opening: try writer(kind, at: folder.path(), calls: calls), hashSize: 20)
        writes = 0
        let bytes = try new.get().bytes
        var source = Piecewise(bytes: bytes)
        try database.applyReplicated(at: 0, from: &source, count: UInt64(bytes.count))
        return writes
    }

    /// The database is `expected`, and whole: it says of itself what that
    /// one says, and its map gives every entry.
    private static func hold(_ database: Database, to expected: Known, _ who: String) throws {
        #expect(try database.replicaState == expected.state, "\(who)'s account of itself")
        var entries = 0
        var iterator = try HashMap<ReadOnly>(database.rootCursor.readOnly).iterator()
        while try iterator.next() != nil {
            entries += 1
        }
        #expect(entries == expected.entries, "\(who)'s entries")
    }

    @Test(
        .enabled(if: aTestCanStartAProcess, "a test cannot start another process on this system"),
        arguments: Step.allCases, Kind.allCases)
    func aWriterThatDiesInACopyLeavesTheOldDatabaseOrTheNew(step: Step, kind: Kind) throws {
        #if os(macOS) || os(Linux)
            let old = try Self.old.get()
            let new = try Self.new.get()
            let folder = try TemporaryFolder()
            #expect(FileManager.default.createFile(atPath: folder.path(), contents: Data(old.bytes)))
            #expect(FileManager.default.createFile(atPath: folder.path("copied.bytes"), contents: Data(new.bytes)))
            // the middle one of the writes a whole copy of this kind makes
            let writes = try Self.writesOfAWholeCopy(kind)
            try #require(writes >= 3)

            let writer = Process()
            writer.executableURL = try builtTool("XitDBFuzz")
            writer.arguments = [
                "die", step.rawValue, kind.rawValue, folder.path(), folder.path("copied.bytes"),
                String(writes / 2 + 1),
            ]
            let said = Pipe()
            writer.standardError = said
            writer.standardOutput = FileHandle.nullDevice
            try writer.run()
            let words = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            writer.waitUntilExit()

            #expect(writer.terminationReason == .exit, "\(words)")
            #expect(writer.terminationStatus == 86, "the writer was to die at \(step): \(words)")

            let expected = step == .afterRename ? new : old
            let reader = try Database(
                opening: try FileStorage(path: folder.path(), access: .readOnly), hashSize: 20)
            try Self.hold(reader, to: expected, "a reader after \(step)")
            let next = try Database(opening: try Self.writer(kind, at: folder.path()), hashSize: 20)
            try Self.hold(next, to: expected, "the next writer after \(step)")
            #expect(!FileManager.default.fileExists(atPath: folder.path() + ".incoming"), "after \(step)")
        #endif
    }
}
