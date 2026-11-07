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
    static let runnable: [(ConformanceFixture, ScriptStorageKind, otherOffsetMap: Bool)] = ConformanceFixture.all
        .filter { $0.waitsFor == nil && $0.needsOp == nil }
        .flatMap { fixture in
            ScriptStorageKind.allCases
                // The memory storage has no read-only mode, in Zig or here.
                .filter { !($0 == .memory && fixture.features.contains("read_only")) }
                .flatMap { kind in
                    fixture.features.contains("compaction")
                        ? [(fixture, kind, otherOffsetMap: false), (fixture, kind, otherOffsetMap: true)]
                        : [(fixture, kind, otherOffsetMap: false)]
                }
        }

    @Test(arguments: runnable)
    func script(fixture: ConformanceFixture, kind: ScriptStorageKind, otherOffsetMap: Bool) throws {
        // Callbacks nest up to 64 deep in the scripts, and each level is a
        // dozen frames of runner and engine. Swift Testing runs tests on
        // threads with half a megabyte of stack, which a debug build of that
        // does not fit in.
        try onLargeStack { try fixture.run(on: kind, otherOffsetMap: otherOffsetMap) }
    }

    /// The manifest was read, and every script in it either runs or is
    /// waiting for a milestone that is named here. Nothing is skipped
    /// silently: a script that starts to wait, or stops, changes this test.
    @Test func everyScriptRunsOrWaitsForANamedMilestone() {
        let all = ConformanceFixture.all
        #expect(all.count == 208)
        #expect(all.filter { $0.waitsFor == nil && $0.needsOp == nil && $0.mustPass }.count == 110)
        #expect(all.filter { $0.waitsFor == nil && $0.needsOp == nil && !$0.mustPass }.count == 98)

        // nothing waits for a milestone any more
        #expect(all.filter { $0.waitsFor != nil }.isEmpty)

        // every op of the script format is in the runner
        #expect(all.filter { $0.needsOp != nil }.isEmpty)

        // not applicable to the memory storage, which has no read-only mode
        let readOnly = all.filter { $0.features.contains("read_only") }.map(\.name).sorted()
        #expect(
            readOnly == [
                "gen-8", "read-only", "read-only-at-end", "read-only-leftovers", "replica-302", "replica-303",
                "replica-306", "write-on-read-only-not-handled",
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

    /// The scripts that need something of a later milestone.
    static let waiting: [String: String] = [:]

    private func runs(_ script: String, on kind: ScriptStorageKind) throws -> Bool {
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

    @Test(arguments: corrections, ScriptStorageKind.allCases)
    func thePortsScriptPassesAndZigsFails(correction: (name: String, what: String), kind: ScriptStorageKind) throws {
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
        #expect(names == Set(Self.corrections.map(\.0)).union(Self.waiting.keys))
    }
}
