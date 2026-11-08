import Foundation
import XitDB

#if canImport(CryptoKit)
    import CryptoKit
#else
    import XitDBTestSupport
#endif

// The hash the examples key their maps with.
func sha256(_ key: String) -> SHA256Digest {
    SHA256.hash(data: Array(key.utf8))
}

/// A directory of a test's own for database files, so that tests can run at
/// once and the documentation can name its files simply: the check of the
/// documentation's code reads `scratch.path("main.db")` as `"main.db"`.
struct ScratchDirectory {
    private let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xitdb-examples-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func path(_ name: String) -> String {
        url.appendingPathComponent(name).path
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A storage in memory that counts its reads, for the examples that quote what
/// an operation costs.
final class CountingStorage: WritableStorage {
    private let inner = MemoryStorage()
    private(set) var reads = 0

    func read(into buffer: inout MutableSpan<UInt8>, range: Range<Int>, at offset: UInt64) throws(XitDBError) -> Int {
        reads += 1
        return try inner.read(into: &buffer, range: range, at: offset)
    }

    var length: UInt64 {
        get throws(XitDBError) { try inner.length }
    }

    func write(_ bytes: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        try inner.write(bytes, at: offset)
    }

    func truncate(to length: UInt64) throws(XitDBError) {
        try inner.truncate(to: length)
    }

    func flush() throws(XitDBError) {}

    func sync(_ point: SyncPoint) throws(XitDBError) {}
}
