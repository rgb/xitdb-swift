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
                // The memory storage has no read-only mode, in Zig or here.
                .filter { !($0 == .memory && fixture.features.contains("read_only")) }
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

    /// The manifest was read and every script in it runs, on every storage
    /// kind. Nothing is skipped silently: a script that stops running changes
    /// this test.
    @Test func everyScriptRuns() {
        let all = ConformanceFixture.all
        #expect(all.count == 219)
        #expect(all.filter { $0.mustPass }.count == 121)
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

        // not applicable to the memory storage, which has no read-only mode
        let readOnly = all.filter { $0.features.contains("read_only") }.map(\.name).sorted()
        #expect(
            readOnly == [
                "read-only", "read-only-at-end", "read-only-leftovers", "replica-306", "safe-8", "safe-replica-302",
                "safe-replica-303", "safe-replica-306", "write-on-read-only-not-handled",
            ]
        )
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
