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
/// `Resources/listings/SHA256SUMS`. A listing that differs fails here by
/// its file's name; to see where, make the original's listing again and
/// compare.
///
/// The digests are made again whenever the fixtures follow another commit
/// of the original, since the expected files change with it. Build `dump`
/// in the conformance repository at the commit the fixtures are copied
/// from (`zig build` there, with the original beside it at the commit the
/// fixtures' manifest names as `zig_commit`), run it on every `.db` under
/// `fixtures/valid` and `fixtures/inputs`, and write the SHA-256 of what
/// each prints; the loop is in `Resources/listings/README.md`. The ones
/// here were made again whole for the fixtures of the conformance commit
/// `62ef163`, with a `dump` that says by `dump --version` which commits
/// it was built from: the original at `274418f`. Every line that was
/// there before came out the same; that README has the history.
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
        for byte in SHA256.keyHash(of: text) {
            let digits = String(byte, radix: 16)
            hex += digits.count == 1 ? "0" + digits : digits
        }
        return hex
    }

    /// Every `.db` under `fixtures/valid` and `fixtures/inputs` has a
    /// digest, but the five files the original's tool has no listing for,
    /// for which the port has none either, by the tool's own words for
    /// each: a single byte, too short to have a header, and four that
    /// neither opens. The files in which something cannot be read are
    /// among those that have one:
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
        #expect(paths.count == 355)

        // The files the original's tool prints no listing for, with what it
        // says instead: a single byte, and the four in which the root header
        // names a trailer whose root slot has a tag no version knows, which
        // neither the original nor the port opens (the fixtures of the
        // conformance commit 62ef163).
        let unopened = "the file can't be opened: InvalidEnumTag"
        let noListing = [
            "valid/recovery-cut-during-creation-read-only.db": "too short to be a database",
            "valid/recover-sound-root-header--port.c2.db": unopened,
            "valid/recover-sound-root-header--port.c2_ignoring.db": unopened,
            "valid/recover-sound-root-header-version-1--port.c2.db": unopened,
            "valid/recover-sound-root-header-version-1--port.c2_ignoring.db": unopened,
        ]
        var withErrors: [String] = []
        var withoutListing: [String] = []
        for path in paths {
            let file = fixtures.appendingPathComponent(path).path
            let listing: OriginalListing
            do {
                listing = try OriginalListing.listing(ofFileAt: file)
            } catch let error as OriginalListing.NoListing {
                // The tool's own words, on its standard error, for each.
                #expect(error.reason == (noListing[path] ?? "a listing"), "\(path)")
                #expect(digests[path] == nil, "\(path)")
                withoutListing.append(path)
                continue
            }
            let expected = try #require(digests[path], "no digest for \(path)")
            #expect(Self.sha256(listing.text) == expected, "the port's listing of \(path) is not the original's")
            if listing.errors > 0 { withErrors.append(path) }
        }
        #expect(withoutListing == noListing.keys.sorted())
        #expect(digests.count == paths.count - withoutListing.count)
        // The files in which the original cannot read something either.
        // Five of the freeze hazard's eight clones are among them, as
        // inputs and as the expected files they are byte for byte: a
        // position that the size has and the tree does not is
        // `InvalidBTreeNode` in both. So are the eighteen files that the
        // writes through three of those clones leave (the fixtures of the
        // conformance commit 0aa572e): each holds such a clone still.
        #expect(
            withErrors == [
                "inputs/linked-counts-above-leaves.db",
                "inputs/linked-counts-below-leaves.db",
                "inputs/linked-header-above-tree.db",
                "inputs/sorted-counts-above-leaves.db",
                "inputs/sorted-header-above-tree.db",
                "valid/linked-counts-above-leaves-writes.db",
                "valid/linked-counts-above-leaves-writes.get_at_21.db",
                "valid/linked-counts-above-leaves-writes.get_at_24.db",
                "valid/linked-counts-above-leaves-writes.insert_at_22.db",
                "valid/linked-counts-above-leaves-writes.insert_at_25.db",
                "valid/linked-counts-above-leaves-writes.remove_at_21.db",
                "valid/linked-counts-above-leaves-writes.remove_at_24.db",
                "valid/linked-counts-above-leaves-writes.slice_at_22.db",
                "valid/linked-counts-above-leaves-writes.slice_at_25.db",
                "valid/linked-counts-above-leaves.db",
                "valid/linked-counts-below-leaves-writes--port.db",
                "valid/linked-counts-below-leaves-writes--port.get_at_39.db",
                "valid/linked-counts-below-leaves-writes--port.remove_at_39.db",
                "valid/linked-counts-below-leaves-writes--port.slice_at_39.db",
                "valid/linked-counts-below-leaves.db",
                "valid/linked-header-above-tree-writes--port.db",
                "valid/linked-header-above-tree-writes--port.get_at_30.db",
                "valid/linked-header-above-tree-writes--port.insert_at_31.db",
                "valid/linked-header-above-tree-writes--port.remove_at_30.db",
                "valid/linked-header-above-tree-writes--port.slice_at_30.db",
                "valid/linked-header-above-tree.db",
                "valid/recover-cut-during-creation--port.v1_cut.db",
                "valid/recover-without-first-commit--port.before_the_data.db",
                "valid/recover-without-first-commit--port.v1_before_the_data.db",
                "valid/recovery-cut-during-creation.db",
                "valid/replicate-failed-first-sync.left_behind.db",
                "valid/sorted-counts-above-leaves.db",
                "valid/sorted-header-above-tree.db",
                "valid/write-if-empty-emptied-slot.db",
            ])
    }
}
