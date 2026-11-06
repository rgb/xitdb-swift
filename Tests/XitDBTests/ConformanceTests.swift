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
        #expect(all.count == 93)
        #expect(all.filter { $0.waitsFor == nil && $0.mustPass }.count == 31)
        #expect(all.filter { $0.waitsFor == nil && !$0.mustPass }.count == 42)
        #expect(all.filter { $0.waitsFor == "M5" && $0.mustPass }.count == 9)
        #expect(all.filter { $0.waitsFor == "M5" && !$0.mustPass }.count == 1)
        #expect(all.filter { $0.waitsFor == "M6" && $0.mustPass }.count == 10)

        let waiting = all.filter { $0.waitsFor != nil }.map { "\($0.waitsFor ?? ""): \($0.name)" }.sorted()
        #expect(
            waiting == [
                "M5: every-construct-linked",
                "M5: gen-1",
                "M5: gen-10",
                "M5: gen-13",
                "M5: gen-16",
                "M5: gen-4",
                "M5: gen-7",
                "M5: nested-linked",
                "M5: null-slot-var-in-concat",
                "M5: overwriting-committed-bytes-linked",
                "M6: every-construct-sorted",
                "M6: gen-11",
                "M6: gen-14",
                "M6: gen-17",
                "M6: gen-2",
                "M6: gen-5",
                "M6: gen-8",
                "M6: nested-sorted",
                "M6: overwriting-committed-bytes-sorted",
                "M6: path-api-edges-sorted",
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
