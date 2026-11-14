import Foundation
import Testing
import XitDBHashing

@testable import XitDB

/// What the port reads from every expected file of the conformance fixtures
/// and from every input is what the original reads from it.
///
/// The conformance repository's `dump` prints a database through the
/// original as a listing that does not depend on where anything is in the
/// file, and ``OriginalListing`` prints the same listing through the port.
/// The original's listings of these three hundred files are eleven megabytes
/// of text, so what is kept is the SHA-256 of each, in
/// `Resources/listings/SHA256SUMS`, whose `README.md` says how they were
/// made. A listing that differs fails here by its file's name; to see
/// where, make the original's listing again and compare.
///
/// The four samples under `fixtures/samples/haxy` come with their listings,
/// and `ClientAcceptanceTests` compares those line for line.
@Suite struct OriginalListingTests {
    static func resources() throws -> URL {
        try #require(Bundle.module.resourceURL)
    }

    /// The pinned digests, by the file's path under `fixtures`.
    static func digests() throws -> [String: String] {
        let text = String(
            decoding: try Data(contentsOf: try resources().appendingPathComponent("listings/SHA256SUMS")),
            as: UTF8.self)
        var digests: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            try #require(parts.count == 2, "\(line)")
            digests[String(parts[1])] = String(parts[0])
        }
        return digests
    }

    static func sha256(_ text: String) -> String {
        var hex = ""
        for byte in Array(SHA256.hash(data: Array(text.utf8))) {
            let digits = String(byte, radix: 16)
            hex += digits.count == 1 ? "0" + digits : digits
        }
        return hex
    }

    /// Every `.db` under `fixtures/valid` and `fixtures/inputs` has a
    /// digest, but the one file the original's tool has no listing for: a
    /// single byte, too short to have a header, for which the port has none
    /// either. The files in which something cannot be read are among them:
    /// what cannot be read prints as the original's name for the error, so
    /// the two agree on that as well.
    @Test func everyExpectedFileAndInputReadsAsTheOriginalReadsIt() throws {
        let digests = try Self.digests()
        let fixtures = try Self.resources().appendingPathComponent("fixtures")
        var paths: [String] = []
        for folder in ["inputs", "valid"] {
            let names = try FileManager.default.contentsOfDirectory(
                atPath: fixtures.appendingPathComponent(folder).path)
            paths += names.filter { $0.hasSuffix(".db") }.sorted().map { "\(folder)/\($0)" }
        }
        #expect(paths.count == 300)

        var withErrors: [String] = []
        var withoutListing: [String] = []
        for path in paths {
            let file = fixtures.appendingPathComponent(path).path
            let listing: OriginalListing
            do {
                listing = try OriginalListing.listing(ofFileAt: file)
            } catch let error as OriginalListing.NoListing {
                #expect(error.reason == "too short to be a database", "\(path)")
                #expect(digests[path] == nil, "\(path)")
                withoutListing.append(path)
                continue
            }
            let expected = try #require(digests[path], "no digest for \(path)")
            #expect(Self.sha256(listing.text) == expected, "the port's listing of \(path) is not the original's")
            if listing.errors > 0 { withErrors.append(path) }
        }
        #expect(withoutListing == ["valid/recovery-cut-during-creation-read-only.db"])
        #expect(digests.count == paths.count - withoutListing.count)
        // the files in which the original cannot read something either
        #expect(
            withErrors == [
                "valid/recover-without-first-commit--port.before_the_data.db",
                "valid/recover-without-first-commit--port.v1_before_the_data.db",
                "valid/recover-without-first-commit--port.v1_cut.db",
                "valid/recovery-cut-during-creation.db",
                "valid/replicate-failed-first-sync.left_behind.db",
                "valid/write-if-empty-emptied-slot.db",
            ])
    }
}
