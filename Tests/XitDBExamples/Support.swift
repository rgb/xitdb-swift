import CryptoKit
import Foundation

// The hash the examples key their maps with.
func sha256(_ key: String) -> [UInt8] {
    Array(SHA256.hash(data: Array(key.utf8)))
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
