import Foundation
import Testing

@testable import XitDB

/// Reads up to `count` bytes at `offset` and returns the bytes that were read.
func readBytes(_ storage: some ReadableStorage, at offset: UInt64, count: Int) throws -> [UInt8] {
    var result = [UInt8](repeating: 0xEE, count: count)
    var span = result.mutableSpan
    let read = try storage.read(into: &span, at: offset)
    return Array(result[..<read])
}

/// Writes `bytes` at `offset`.
func writeBytes(_ storage: some WritableStorage, _ bytes: [UInt8], at offset: UInt64) throws {
    try storage.write(bytes.span, at: offset)
}

/// A random number generator that gives the same sequence for the same seed
/// (SplitMix64), so that a failing random test can be run again.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// A directory for the files of one test, removed when the value goes away.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xitdb-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// The path of a file in the directory. The file is not created.
    func path(_ name: String = "test.db") -> String {
        url.appendingPathComponent(name).path
    }

    /// The contents of a file in the directory, as it is on disk now.
    func contents(_ name: String = "test.db") throws -> [UInt8] {
        [UInt8](try Data(contentsOf: url.appendingPathComponent(name)))
    }
}

/// A storage of a test was asked to read through a memory map and does not.
struct NotReadThroughTheMap: Error, CustomStringConvertible {
    let path: String

    var description: String {
        "the file at \(path) was to be read through a memory map and is not: its volume is not of a kind the library "
            + "maps, so a test on it would hold nothing of the map"
    }
}

/// Holds a storage that a test made of a mapped kind to being mapped. A
/// storage that was asked for the map and reads by file calls says so only
/// through ``FileStorage/isMemoryMapped``, by design, and a suite "on the
/// mapped kinds" whose files lay on a volume that is not mapped, as a
/// container's mounted folder is, would pass and have tested nothing of
/// the map.
func readThroughTheMap(_ file: FileStorage, at path: String) throws -> FileStorage {
    guard file.isMemoryMapped else { throw NotReadThroughTheMap(path: path) }
    return file
}

/// The kinds of storage, for tests that run against each.
enum StorageKind: String, CaseIterable, CustomTestStringConvertible {
    case memory
    case file
    case bufferedFile
    /// A buffered file whose window is so small that most writes restart it
    /// or go around it.
    case bufferedFileSmallWindow
    /// A file read through a memory map, in segments of one page, so that
    /// reads cross from one segment to the next; with the exclusive lock
    /// the map needs.
    case mappedFile
    /// A buffered file over such a file.
    case mappedBufferedFile

    var testDescription: String { rawValue }

    /// The kinds on which a full copy is made in place, as the original
    /// makes it: memory. (A storage of the caller's own takes it in place
    /// too, and is no kind here.) What such a copy leaves when it is cut
    /// short is a database without a first commit.
    static let takingACopyInPlace: [StorageKind] = [.memory]

    /// The kinds that are files, on which a full copy is written into a
    /// new file that is given the old one's name at the end: a copy that
    /// is cut short leaves the old database.
    static let files: [StorageKind] = allCases.filter { $0 != .memory }
}

/// A new, empty storage of one kind, with a way to see the bytes that have
/// reached the place they are kept in.
struct StorageUnderTest {
    let storage: any WritableStorage
    /// The bytes in memory or on disk. For a buffered file, flush first.
    let stored: () throws -> [UInt8]
    /// The path of the file, for a test that opens it a second time, or
    /// `nil` for a memory storage.
    let path: String?

    init(_ kind: StorageKind) throws {
        switch kind {
        case .memory:
            let memory = MemoryStorage()
            storage = memory
            stored = { memory.bytes }
            path = nil
        case .file:
            let directory = try TemporaryDirectory()
            storage = try FileStorage(path: directory.path(), access: .create, durability: .none)
            stored = { try directory.contents() }
            path = directory.path()
        case .bufferedFile:
            let directory = try TemporaryDirectory()
            storage = try BufferedFileStorage(path: directory.path(), access: .create, durability: .none)
            stored = { try directory.contents() }
            path = directory.path()
        case .bufferedFileSmallWindow:
            let directory = try TemporaryDirectory()
            storage = try BufferedFileStorage(
                path: directory.path(), access: .create, durability: .none, bufferLimit: 200)
            stored = { try directory.contents() }
            path = directory.path()
        case .mappedFile:
            let directory = try TemporaryDirectory()
            storage = try readThroughTheMap(
                try FileStorage(
                    path: directory.path(), access: .create, durability: .none, lock: .exclusive, reading: .memoryMap,
                    segmentSize: Platform.pageSize), at: directory.path())
            stored = { try directory.contents() }
            path = directory.path()
        case .mappedBufferedFile:
            let directory = try TemporaryDirectory()
            storage = BufferedFileStorage(
                try readThroughTheMap(
                    try FileStorage(
                        path: directory.path(), access: .create, durability: .none, lock: .exclusive,
                        reading: .memoryMap, segmentSize: Platform.pageSize), at: directory.path()))
            stored = { try directory.contents() }
            path = directory.path()
        }
    }
}
