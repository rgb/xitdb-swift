import Testing

@testable import XitDB

/// The proof that a snapshot reads exactly what a read-only database opened
/// at its committed size reads, whatever the writer does afterwards, run
/// over the conformance fixtures (D25, the design paper's section 5).
///
/// The fixture's replay takes a snapshot of every open database after every
/// top-level op, with a copy of the storage's bytes at that moment, and at
/// the end holds each snapshot to its copy: its read half gives the copy's
/// first bytes, the root header excepted on the file kinds, where the file's
/// own is read and later commits rewrite it; a structural walk from its root
/// equals the walk of a database opened on the copy; and, for a database
/// that never synced from zero, the copy's first bytes are the expected
/// file's, since committed bytes never change.
///
/// Three kinds of op change a file in ways the guarantee does not cover, and
/// the snapshots of that database are checked before them and dropped on
/// the file kinds: a raw write, load or cut while the database is closed, a
/// recovery, and a reopening, which is a second storage object on the same
/// path and may create the file again where its creation did not finish. A
/// sync from zero is covered on every kind, and on every kind the snapshots
/// read on: in memory they keep the bytes, and on a file the copy goes into
/// a new file, so that the snapshots taken before it go on reading the old
/// one, through file calls or through its memory map, whether the copy went
/// through or failed.
final class SnapshotProof {
    struct Kept {
        let database: String
        let step: Int
        let snapshot: Snapshot
        let copy: [UInt8]
        /// Whether a sync from zero of the database came after it.
        var zeroSynced = false
        /// Whether a raw write or a recovery of the database came after it,
        /// so that the expected file says nothing about its copy.
        var fileChangedOutsideTheEngine = false
    }

    /// How often the walks of a fixture's snapshots say that a header and
    /// its tree disagree, in the two ways the walk has of saying it.
    struct Disagreements: Equatable, CustomStringConvertible {
        /// Positions of a linked array list that its tree does not have.
        var positionsLacking = 0
        /// Collections whose count is not the number of elements given.
        var countsApart = 0

        var description: String {
            "\(positionsLacking) positions a tree does not have and \(countsApart) counts apart from the elements given"
        }
    }

    /// The fixtures whose walks may say that a header and its tree
    /// disagree, and how often theirs do, over the snapshots of one replay:
    /// the files the freeze hazard leaves, which hold a copy whose header
    /// counts other elements than its tree has. Every other fixture's walks
    /// must say it nowhere. Without this list a fault that made a database
    /// and its snapshot lack the same position, or miscount alike, would
    /// walk to equal strings and pass as a proof.
    static let disagreements: [String: Disagreements] = [
        "linked-counts-above-leaves": Disagreements(positionsLacking: 2),
        "linked-counts-below-leaves": Disagreements(positionsLacking: 1),
        "linked-header-above-tree": Disagreements(positionsLacking: 10),
        "sorted-counts-above-leaves": Disagreements(countsApart: 2),
        "sorted-header-above-tree": Disagreements(countsApart: 2),
    ]

    let kind: StorageKind
    /// The fixture whose replay is proved, by its name.
    let fixture: String
    private(set) var kept: [Kept] = []
    /// How many snapshots were checked, so that a proof that checked none
    /// can be told from one that passed.
    private(set) var checked = 0
    /// What each snapshot's walk said of a header and its tree, by the
    /// database and the step it was taken at, so that one checked twice
    /// counts once.
    private var said: [String: Disagreements] = [:]

    init(kind: StorageKind, fixture: String) {
        self.kind = kind
        self.fixture = fixture
    }

    private var isFile: Bool { kind != .memory }

    /// Before a top-level op runs: the ops that change a file outside the
    /// engine's guarantee have the current database's snapshots checked and,
    /// on the file kinds, dropped.
    func before(op name: String, on database: String) throws {
        switch name {
        case "raw_write", "raw_append", "raw_load", "raw_truncate", "recover", "reopen":
            for index in kept.indices where kept[index].database == database {
                if name != "reopen" { kept[index].fileChangedOutsideTheEngine = true }
            }
            if isFile {
                let dropped = kept.filter { $0.database == database }
                kept.removeAll { $0.database == database }
                for one in dropped {
                    try check(one, expected: nil)
                }
            }
        default:
            break
        }
    }

    /// After a sync from zero of a database: its snapshots read on, on every
    /// kind, and what they read is no longer a prefix of the expected file.
    func zeroSynced(_ database: String) {
        for index in kept.indices where kept[index].database == database {
            kept[index].zeroSynced = true
        }
    }

    /// After a top-level op: a snapshot of every open database that is in a
    /// state to give one, which must have the committed size the sidecar
    /// has, with a copy of the storage.
    func after(step: Int, _ runner: ScriptRunner) throws {
        for name in runner.databaseNames {
            guard let database = runner.openDatabase(named: name), let size = try runner.committedSize(of: name) else {
                continue
            }
            let snapshot = try database.snapshot()
            guard snapshot.committedSize == size else {
                throw ScriptFailure(
                    "after op \(step) the snapshot of \(name) has committed size \(snapshot.committedSize), and the database says \(size)"
                )
            }
            // An op that committed nothing gives the snapshot the last op
            // gave, the same commit and root: checking it again proves
            // nothing more, and the proof's cost is in the checks.
            if let last = kept.last(where: { $0.database == name }), last.snapshot.committedSize == size,
                last.snapshot.root == snapshot.root, !last.zeroSynced, !last.fileChangedOutsideTheEngine
            {
                continue
            }
            kept.append(Kept(database: name, step: step, snapshot: snapshot, copy: try runner.contents(of: name)))
        }
    }

    /// At the end: every snapshot still kept against its copy, and against
    /// the expected file of its database where that says anything.
    func finish(expectedFiles: [String: [UInt8]]) throws {
        for one in kept {
            try check(one, expected: expectedFiles[one.database])
        }
        kept.removeAll()

        // The walks said that a header and its tree disagree exactly as
        // often as this fixture is known to, which for all but the freeze
        // hazard's files is never.
        var total = Disagreements()
        for one in said.values {
            total.positionsLacking += one.positionsLacking
            total.countsApart += one.countsApart
        }
        let expected = Self.disagreements[fixture] ?? Disagreements()
        guard total == expected else {
            throw ScriptFailure(
                "the walks of \(fixture)'s snapshots hold \(total), and \(expected) are expected of it")
        }
    }

    private func check(_ one: Kept, expected: [UInt8]?) throws {
        checked += 1
        let size = Int(one.snapshot.committedSize)
        guard one.copy.count >= size else {
            throw ScriptFailure(
                "step \(one.step): the copy of \(one.database) is shorter than the snapshot's committed size")
        }

        // The read half gives the copy's first bytes, the root header
        // excepted on the file kinds.
        let read = try readBytes(one.snapshot.storage, at: 0, count: size)
        var expectedBytes = Array(one.copy[..<size])
        if isFile { mask(&expectedBytes) }
        var readMasked = read
        if isFile { mask(&readMasked) }
        if let difference = firstDifference(readMasked, expectedBytes) {
            throw ScriptFailure(
                "step \(one.step): the snapshot of \(one.database) reads other bytes than its copy: \(difference)")
        }
        guard try readBytes(one.snapshot.storage, at: UInt64(size), count: 1).isEmpty else {
            throw ScriptFailure("step \(one.step): the snapshot of \(one.database) reads past its committed size")
        }

        // The walk from the snapshot's root equals the walk of a database
        // opened on the copy.
        let fromSnapshot: String
        let fromCopy: String
        do {
            fromSnapshot = try StructureWalk.describe(one.snapshot.rootCursor)
        } catch {
            throw ScriptFailure("step \(one.step): walking the snapshot of \(one.database) failed: \(error)")
        }
        do {
            let onCopy = try Database(opening: MemoryStorage(bytes: one.copy))
            fromCopy = try StructureWalk.describe(onCopy.rootCursor.readOnly)
        } catch {
            throw ScriptFailure("step \(one.step): walking the copy of \(one.database) failed: \(error)")
        }
        guard fromSnapshot == fromCopy else {
            throw ScriptFailure("step \(one.step): the snapshot of \(one.database) walks differently from its copy")
        }
        said["\(one.database) at \(one.step)"] = Disagreements(
            positionsLacking: fromSnapshot.ranges(of: StructureWalk.noPosition).count,
            countsApart: fromSnapshot.ranges(of: StructureWalk.countedAndGiven).count)

        // Committed bytes never change, so the copy's first bytes are the
        // final file's, unless something outside the engine changed the file
        // or a sync from zero replaced the database.
        if let expected, !one.zeroSynced, !one.fileChangedOutsideTheEngine {
            guard expected.count >= size else {
                throw ScriptFailure("step \(one.step): the expected file of \(one.database) is shorter than a snapshot")
            }
            var copyPrefix = Array(one.copy[..<size])
            var expectedPrefix = Array(expected[..<size])
            mask(&copyPrefix)
            mask(&expectedPrefix)
            if let difference = firstDifference(copyPrefix, expectedPrefix) {
                throw ScriptFailure(
                    "step \(one.step): the committed bytes of \(one.database) differ from the expected file's: \(difference)"
                )
            }
        }
    }

    /// Zeroes the root header's committed size, which every commit
    /// rewrites, where the file's own format version keeps it.
    private func mask(_ bytes: inout [UInt8]) {
        guard let header = try? DatabaseHeader(decoding: bytes.span) else { return }
        let start = Int(header.fileSizePosition)
        let end = min(Int(header.dataStart), bytes.count)
        guard start < end else { return }
        for index in start..<end {
            bytes[index] = 0
        }
    }
}

/// The snapshot proof over every passing fixture on every storage kind:
/// the fixtures' replay with `proving`. In a debug build the proof costs
/// many times the replay, so the gate runs this suite in release only and
/// the debug run skips it.
@Suite struct SnapshotProofTests {
    /// Every passing script on every storage kind it runs on, as the
    /// conformance suite selects them.
    static let runnable: [(ConformanceFixture, StorageKind)] = ConformanceFixture.all
        .filter(\.mustPass)
        .flatMap { fixture in
            StorageKind.allCases
                .filter { fixture.runs(on: $0) }
                .map { (fixture, $0) }
        }

    /// The fixtures named for a header and a tree that disagree are
    /// fixtures the proof runs on, so that a name that is no longer one
    /// does not stay in the list unnoticed.
    @Test func theFixturesNamedForADisagreementAreProved() {
        let proved = Set(Self.runnable.map(\.0.name))
        for name in SnapshotProof.disagreements.keys.sorted() {
            #expect(proved.contains(name), "\(name)")
        }
    }

    @Test(arguments: runnable)
    func proof(fixture: ConformanceFixture, kind: StorageKind) throws {
        // The replay nests callbacks up to 64 deep, as the conformance
        // suite notes; the walk itself keeps its own stack.
        try onLargeStack { try fixture.run(on: kind, proving: true) }
    }
}
