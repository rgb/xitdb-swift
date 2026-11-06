import Foundation
import Testing

@testable import XitDB

/// Runs the conformance scripts: what the Zig implementation does, recorded
/// by the conformance session, which this implementation must reproduce
/// byte for byte.
@Suite struct ConformanceTests {
    /// The scripts that can run now, on each storage they apply to.
    static let runnable: [(ConformanceFixture, ScriptStorageKind)] = ConformanceFixture.all
        .filter { $0.waitsFor == nil }
        .flatMap { fixture in
            ScriptStorageKind.allCases
                // The memory storage has no read-only mode, in Zig or here.
                .filter { !($0 == .memory && fixture.features.contains("read_only")) }
                .map { (fixture, $0) }
        }

    @Test(arguments: runnable)
    func script(fixture: ConformanceFixture, kind: ScriptStorageKind) throws {
        // Callbacks nest up to 64 deep in the scripts, and each level is a
        // dozen frames of runner and engine. Swift Testing runs tests on
        // threads with half a megabyte of stack, which a debug build of that
        // does not fit in.
        try onLargeStack { try fixture.run(on: kind) }
    }

    /// The manifest was read, and every script in it either runs or is
    /// waiting for a milestone that is named here. Nothing is skipped
    /// silently: a script that starts to wait, or stops, changes this test.
    @Test func everyScriptRunsOrWaitsForANamedMilestone() {
        let all = ConformanceFixture.all
        #expect(all.count == 149)
        #expect(all.filter { $0.waitsFor == nil && $0.mustPass }.count == 43)
        #expect(all.filter { $0.waitsFor == nil && !$0.mustPass }.count == 69)
        #expect(all.filter { $0.waitsFor == "M5" && $0.mustPass }.count == 16)
        #expect(all.filter { $0.waitsFor == "M5" && !$0.mustPass }.count == 1)
        #expect(all.filter { $0.waitsFor == "M6" && $0.mustPass }.count == 19)
        #expect(all.filter { $0.waitsFor == "M6" && !$0.mustPass }.count == 1)

        let waiting = all.filter { $0.waitsFor != nil }.map { "\($0.waitsFor ?? ""): \($0.name)" }.sorted()
        #expect(
            waiting == [
                "M5: deep-linked",
                "M5: every-construct-linked",
                "M5: gen-1",
                "M5: gen-10",
                "M5: gen-13",
                "M5: gen-16",
                "M5: gen-4",
                "M5: gen-7",
                "M5: iterator-tiers-linked",
                "M5: nested-linked",
                "M5: null-slot-var-in-concat",
                "M5: overwriting-committed-bytes-linked",
                "M5: reads-103",
                "M5: reads-106",
                "M5: reads-112",
                "M5: reads-iterators-linked",
                "M5: reads-stream-linked",
                "M6: deep-sorted",
                "M6: every-construct-sorted",
                "M6: gen-11",
                "M6: gen-14",
                "M6: gen-17",
                "M6: gen-2",
                "M6: gen-5",
                "M6: gen-8",
                "M6: iterator-tiers-sorted",
                "M6: nested-sorted",
                "M6: overwriting-committed-bytes-sorted",
                "M6: path-api-edges-sorted",
                "M6: reads-101",
                "M6: reads-104",
                "M6: reads-107",
                "M6: reads-110",
                "M6: reads-iterators-sorted",
                "M6: reads-sorted-root",
                "M6: reads-stream-sorted",
                "M6: wrong-rank",
            ]
        )

        // not applicable to the memory storage, which has no read-only mode
        let readOnly = all.filter { $0.features.contains("read_only") }.map(\.name).sorted()
        #expect(
            readOnly == [
                "gen-8", "read-only", "read-only-at-end", "read-only-leftovers", "write-on-read-only-not-handled",
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
    ]

    /// The scripts that need a collection of a later milestone: a cursor
    /// without a position is the key of a sorted set.
    static let waiting = ["stream-short-no-position": "M6"]

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
