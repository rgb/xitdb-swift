import Foundation
import Testing

@testable import XitDB

/// Runs the conformance scripts: what the Zig implementation does, recorded
/// by the conformance session, which this implementation must reproduce
/// byte for byte.
@Suite struct ConformanceTests {
    /// The scripts that can run now, on each storage they apply to. A
    /// script that compacts runs twice more, with the offset map it does
    /// not name in place of the one it does.
    static let runnable: [(ConformanceFixture, StorageKind, otherOffsetMap: Bool)] = ConformanceFixture.all
        .flatMap { fixture in
            StorageKind.allCases
                .filter { fixture.runs(on: $0) }
                .flatMap { kind in
                    fixture.features.contains("compaction")
                        ? [(fixture, kind, otherOffsetMap: false), (fixture, kind, otherOffsetMap: true)]
                        : [(fixture, kind, otherOffsetMap: false)]
                }
        }

    @Test(arguments: runnable)
    func script(fixture: ConformanceFixture, kind: StorageKind, otherOffsetMap: Bool) throws {
        // Callbacks nest up to 64 deep in the scripts, and each level is a
        // dozen frames of runner and engine. Swift Testing runs tests on
        // threads with half a megabyte of stack, which a debug build of that
        // does not fit in.
        try onLargeStack { try fixture.run(on: kind, otherOffsetMap: otherOffsetMap) }
    }

    /// The fixtures' folder is the conformance repository's, copied as it
    /// stands: every file in it is one the manifest names, and every file
    /// the manifest names is in it. The few files the manifest does not
    /// name are named here, each with what it is, so that a file a copy
    /// left behind, or one a copy lost, fails this test. (A copy made into
    /// a folder that still held the older one kept three files that had
    /// left their fixture; nothing noticed, since no test names what should
    /// not be there.)
    @Test func theFixturesFolderHoldsWhatItsManifestNamesAndNothingElse() throws {
        let folder = try #require(Bundle.module.url(forResource: "fixtures", withExtension: nil))
        let manifest = try #require(
            try JSONSerialization.jsonObject(with: Data(try fixtureFile("manifest.json"))) as? [String: Any])
        let entries = try #require(manifest["fixtures"] as? [[String: Any]])

        var named: Set<String> = ["manifest.json", "README.md"]
        for entry in entries {
            for key in ["script", "db", "sidecar"] {
                if let path = entry[key] as? String { named.insert(path) }
            }
            for path in (entry["other_databases"] as? [String: String] ?? [:]).values { named.insert(path) }
            for path in entry["inputs"] as? [String] ?? [] { named.insert(path) }
        }
        // An input that only a script of `port-differs` loads, which the
        // manifest does not list: those scripts name their inputs by
        // `"input": "<name>"`.
        let portDiffers = try #require(Bundle.module.url(forResource: "port-differs", withExtension: nil))
        for name in try FileManager.default.contentsOfDirectory(atPath: portDiffers.path)
        where name.hasSuffix(".json") {
            let script = String(decoding: try Data(contentsOf: portDiffers.appendingPathComponent(name)), as: UTF8.self)
            for match in script.matches(of: /"input":\s*"([^"]+)"/) {
                named.insert("inputs/\(match.1).db")
            }
        }
        // The four sample files of the haxy project and what the original
        // lists of them, with their own table of digests and their note.
        for name in ["admin", "project-repo", "user-repo", "users-index"] {
            named.insert("samples/haxy/\(name).db")
            named.insert("samples/haxy/\(name).txt")
        }
        named.insert("samples/haxy/README.md")
        named.insert("samples/haxy/SHA256SUMS")

        var held: Set<String> = []
        let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        let root = folder.resolvingSymlinksInPath().path + "/"
        for case let url as URL in files where !url.hasDirectoryPath {
            let path = url.resolvingSymlinksInPath().path
            try #require(path.hasPrefix(root))
            held.insert(String(path.dropFirst(root.count)))
        }
        #expect(held.subtracting(named).sorted() == [], "files in the folder that nothing names")
        #expect(named.subtracting(held).sorted() == [], "files that are named and are not in the folder")
        #expect(held.count == 767)
    }

    /// The manifest was read and every script in it runs, on every storage
    /// kind it applies to. Nothing is skipped silently: a script that stops
    /// running changes this test, and so does one that stops applying to a
    /// kind.
    @Test func everyScriptRuns() {
        let all = ConformanceFixture.all
        #expect(all.count == 258)
        #expect(all.filter { $0.mustPass }.count == 160)
        #expect(all.filter { !$0.mustPass }.count == 98)

        // the failing scripts whose description pins the engine error that
        // their last op raises and nothing handles; the runner holds each
        // to that error, and the rest to any script failure
        let pinned = Dictionary(
            uniqueKeysWithValues: all.filter { !$0.mustPass }.compactMap { fixture -> (String, String)? in
                guard
                    let bytes = try? fixtureFile(fixture.script),
                    let script = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                    let error = ConformanceFixture.pinnedError(in: script["description"] as? String)
                else { return nil }
                return (fixture.name, error)
            })
        #expect(
            pinned == [
                "bytes-into-too-small-not-handled": "StreamTooLong",
                "invalid-range-not-handled": "InvalidRange",
                "iterator-from-key-on-a-list-not-handled": "UnexpectedTag",
                "iterator-on-a-number-not-handled": "UnexpectedTag",
                "max-size-too-small-not-handled": "StreamTooLong",
                "rank-on-a-number-not-handled": "UnexpectedTag",
                "reopen-error-not-handled": "InvalidDatabase",
                "short-apply-not-handled": "InvalidDatabase",
                "stream-end-not-handled": "EndOfStream",
                "stream-of-a-number-not-handled": "UnexpectedTag",
                "target-not-empty-not-handled": "TargetNotEmpty",
                "unhandled-error-through-callback": "UnexpectedTag",
                "unhandled-error": "ExpectedTxStart",
                "write-on-read-only-not-handled": "WriteFailed",
            ])

        // which scripts are left out, and on which kinds: these two lists
        // and nothing else
        let leftOut = Dictionary(
            grouping: all.flatMap { fixture in
                StorageKind.allCases.filter { !fixture.runs(on: $0) }.map { (fixture.name, $0) }
            }, by: { $0.1 }
        ).mapValues { $0.map(\.0).sorted() }
        let files: [StorageKind] = [.file, .bufferedFile, .bufferedFileSmallWindow, .mappedFile, .mappedBufferedFile]
        #expect(Set(leftOut.keys) == Set(StorageKind.allCases))
        // on a file a full copy cut short leaves the old database: the
        // scripts the manifest marks for that, which are these three
        let marked = all.filter { $0.features.contains(ConformanceFixture.cutShortCopy) }.map(\.name).sorted()
        #expect(
            marked == ["recover-without-first-commit--port", "replicate-copy-cut-short", "replicate-failed-first-sync"])
        for kind in files {
            #expect(leftOut[kind] == marked, "\(kind)")
        }

        // not applicable to the memory storage, which has no read-only mode
        let readOnly = all.filter { $0.features.contains("read_only") }.map(\.name).sorted()
        #expect(
            readOnly == [
                "read-only", "read-only-at-end", "read-only-leftovers", "recovery-cut-during-creation-read-only",
                "replica-306", "safe-8", "safe-replica-302", "safe-replica-303", "safe-replica-306",
                "version-1-read", "write-on-read-only-not-handled",
            ]
        )
        #expect(leftOut[.memory] == readOnly)
    }
}

/// The behaviours the port corrects by decision, each with two scripts from
/// the conformance repository's `tests/port-differs`: one that says what the
/// Zig original does, which must fail here, and one that says what the port
/// does, which must pass.
@Suite struct PortDifferencesTests {
    static let corrections = [
        ("none-into-buffer", "finding 8: a slot set to nothing read into a buffer is empty"),
        ("stream-none", "finding 21: a slot set to nothing streams as nothing"),
        ("stream-short-overwritten", "finding 9: a short value streams from the cursor's own slot"),
        ("iterator-past-slice", "finding 26: an iterator stops at the size of a cut-down list"),
        ("stream-short-no-position", "finding 9: a short key of a sorted set streams from the cursor's own slot"),
        (
            "iterator-from-key-past-size",
            "the freeze hazard: an iterator from a key whose place is past the size gives nothing"
        ),
    ]

    private func runs(_ script: String, on kind: StorageKind) throws -> Bool {
        let runner = ScriptRunner(storage: try ScriptStorage(kind), random: FixedRandom((1...64).map { UInt64($0) }))
        do {
            for op in try runner.start(try JSONSerialization.jsonObject(with: Data(try portDifferenceFile(script)))) {
                try runner.run(op, topLevel: true)
            }
        } catch is ScriptFailure {
            return false
        }
        return true
    }

    @Test(arguments: corrections, StorageKind.allCases)
    func thePortsScriptPassesAndZigsFails(correction: (name: String, what: String), kind: StorageKind) throws {
        #expect(try runs("\(correction.name).port.json", on: kind), "\(correction.what)")
        #expect(try !runs("\(correction.name).zig.json", on: kind), "\(correction.what)")
    }

    /// Every script in the folder is either run above or waits for a named
    /// milestone.
    @Test func everyScriptRunsOrWaits() throws {
        let folder = try #require(Bundle.module.url(forResource: "port-differs", withExtension: nil))
        let names = Set(
            try FileManager.default.contentsOfDirectory(atPath: folder.path)
                .filter { $0.hasSuffix(".json") }
                .map {
                    $0.replacingOccurrences(of: ".port.json", with: "").replacingOccurrences(of: ".zig.json", with: "")
                }
        )
        #expect(names == Set(Self.corrections.map(\.0)))
    }
}
