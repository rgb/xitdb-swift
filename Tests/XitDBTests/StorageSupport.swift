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

/// The kinds of storage, for tests that run against each.
enum StorageKind: String, CaseIterable, CustomTestStringConvertible {
    case memory
    case file
    case bufferedFile
    /// A buffered file whose window is so small that most writes restart it
    /// or go around it.
    case bufferedFileSmallWindow

    var testDescription: String { rawValue }
}

/// A new, empty storage of one kind, with a way to see the bytes that have
/// reached the place they are kept in.
struct StorageUnderTest {
    let storage: any WritableStorage
    /// The bytes in memory or on disk. For a buffered file, flush first.
    let stored: () throws -> [UInt8]

    init(_ kind: StorageKind) throws {
        switch kind {
        case .memory:
            let memory = MemoryStorage()
            storage = memory
            stored = { memory.bytes }
        case .file:
            let directory = try TemporaryDirectory()
            storage = try FileStorage(path: directory.path(), durability: .none)
            stored = { try directory.contents() }
        case .bufferedFile:
            let directory = try TemporaryDirectory()
            storage = try BufferedFileStorage(path: directory.path(), durability: .none)
            stored = { try directory.contents() }
        case .bufferedFileSmallWindow:
            let directory = try TemporaryDirectory()
            storage = try BufferedFileStorage(path: directory.path(), durability: .none, bufferLimit: 200)
            stored = { try directory.contents() }
        }
    }
}
