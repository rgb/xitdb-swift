import Foundation
import Testing
import XitDB
import XitDBHashing

#if canImport(CryptoKit)
    import CryptoKit
#endif

/// The package's own SHA-1 and SHA-256 against a table of digests kept as a
/// resource, so that every platform is held to the same answers and not
/// only the one where a system routine is there to agree with.
///
/// The table is `Resources/digests.txt`, made by `scripts/pin-digests.py`
/// with Python's hashlib: one line a message, with its length, its seed
/// (`-` for the pattern), its SHA-1 and its SHA-256 in hex. The messages
/// are the pattern at every length from 0 to 300 and the seeded messages,
/// up to 64 KB. Where CryptoKit exists it is held to the same table, which
/// ties the table to the system's routine as well.
@Suite("pinned digests")
struct PinnedDigestTests {
    struct Line {
        var length: Int
        var seed: UInt64?
        var sha1: [UInt8]
        var sha256: [UInt8]

        /// The message the line's digests are of.
        var message: [UInt8] {
            if let seed { seededMessage(count: length, seed: seed) } else { pattern(count: length) }
        }
    }

    static func table() throws -> [Line] {
        let url = try #require(Bundle.module.url(forResource: "digests", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            let fields = line.split(separator: " ")
            try #require(fields.count == 4, "\(line)")
            let length: Int = try #require(Int(fields[0]))
            var seed: UInt64?
            if fields[1] != "-" {
                let value: UInt64 = try #require(UInt64(fields[1]))
                seed = value
            }
            return Line(
                length: length, seed: seed, sha1: bytes(fromHex: String(fields[2])),
                sha256: bytes(fromHex: String(fields[3])))
        }
    }

    /// The table has the messages the tests name, in their order: nothing
    /// in it is hashed that the tests do not make, and nothing is missing.
    @Test("the table is of the pattern to 300 and of the seeded messages")
    func whole() throws {
        let table = try Self.table()
        #expect(table.count == 301 + seededMessages.count)
        for (index, line) in table.prefix(301).enumerated() {
            #expect(line.length == index && line.seed == nil, "line \(index + 1)")
        }
        for (line, message) in zip(table.dropFirst(301), seededMessages) {
            #expect(line.length == message.length && line.seed == message.seed)
        }
        #expect(table.allSatisfy { $0.sha1.count == 20 && $0.sha256.count == 32 })
        #expect(table.contains { $0.length > 60_000 })
    }

    @Test("the portable SHA-256 gives the table's digests")
    func sha256() throws {
        for line in try Self.table() {
            #expect(
                appendedSHA256(line.message) == line.sha256, "\(line.length), seed \(String(describing: line.seed))")
        }
    }

    @Test("the portable SHA-1 gives the table's digests")
    func sha1() throws {
        for line in try Self.table() {
            #expect(appendedSHA1(line.message) == line.sha1, "\(line.length), seed \(String(describing: line.seed))")
        }
    }

    /// The public hashers, by the call a database makes: where the system
    /// has a routine, the long messages of the table go through it.
    @Test("the public hashers give the table's digests")
    func publicHashers() throws {
        for line in try Self.table() {
            let message = line.message
            #expect(
                required(SHA256.self, message) == line.sha256, "\(line.length), seed \(String(describing: line.seed))")
            #expect(
                required(Insecure.SHA1.self, message) == line.sha1,
                "\(line.length), seed \(String(describing: line.seed))")
        }
    }

    #if canImport(CryptoKit)
        @Test("the system's routine gives the table's digests")
        func system() throws {
            for line in try Self.table() {
                let message = line.message
                #expect(Array(CryptoKit.SHA256.hash(data: message)) == line.sha256, "\(line.length)")
                #expect(Array(CryptoKit.Insecure.SHA1.hash(data: message)) == line.sha1, "\(line.length)")
            }
        }
    #endif
}
