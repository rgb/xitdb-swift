import Foundation
import Testing

@testable import XitDB

/// Model-based tests: random sequences of operations run against plain
/// Swift collections and against a database of each storage kind, and
/// checked against each other after every commit, with compaction,
/// replication and snapshots along the way. Where the conformance
/// generator finds what differs from Zig, this finds what differs from
/// the model: wrong values the port and the original might share. On a
/// failure the sequence is cut down to the shortest that still fails and
/// printed as a conformance-style script.
///
/// The gate runs the fixed seeds below; `XITDB_MODEL_SOAK=<seconds>` runs
/// fresh seeds for that long, `scripts/soak.sh` sets it.
@Suite("model-based", .serialized)
struct ModelTests {
    /// The seeds the gate runs, and how many transactions each.
    static let seeds: [UInt64] = Array(1...32)
    static let transactionsPerSeed = 32
    static let kinds: [StorageKind] = [.memory, .file, .bufferedFile]

    @Test(arguments: seeds)
    func theEngineMatchesTheModel(seed: UInt64) throws {
        try Self.run(seed: seed, transactions: Self.transactionsPerSeed)
    }

    /// The same on databases that start from a version 1 file, a new
    /// database the original wrote at `6b93af1`: everything the model
    /// checks holds, and each is still version 1 at the end, in its header
    /// and in its storage, with its committed size at 29. Along the way the
    /// runner holds every database to its version after every commit, the
    /// replica to its source's, and what a compaction makes to version 2.
    @Test(arguments: [UInt64(1), 2, 3, 4])
    func theEngineMatchesTheModelOnAVersionOneFile(seed: UInt64) throws {
        let runner = try #require(
            try Self.run(seed: seed, transactions: Self.transactionsPerSeed, version: .one))
        #expect(runner.transactionsRun == Self.transactionsPerSeed)
        #expect(runner.databases.count == Self.kinds.count)
        for database in runner.databases {
            #expect(database.database.header.version == 1, "\(database.kind)")
            let stored = try database.subject.stored()
            #expect(Array(stored[..<6]) == [0x78, 0x69, 0x74, 0x00, 0x00, 0x01], "\(database.kind)")
            #expect(Array(stored[29..<37]) == bigEndianBytes(UInt64(stored.count)), "\(database.kind)")
            if let path = database.subject.path {
                let reopened = try Database(opening: FileStorage(path: path, access: .readOnly, durability: .none))
                #expect(reopened.header.version == 1, "\(database.kind)")
            }
        }
    }

    /// Fresh seeds for as long as the environment asks, or one when it
    /// does not: the soak that the gate does not pay for.
    @Test func soak() throws {
        let seconds = ProcessInfo.processInfo.environment["XITDB_MODEL_SOAK"].flatMap(Double.init) ?? 0
        let deadline = Date().addingTimeInterval(seconds)
        var seed = UInt64(Date().timeIntervalSince1970) &* 2_654_435_761
        var runs = 0
        repeat {
            try Self.run(seed: seed, transactions: Self.transactionsPerSeed)
            seed &+= 1
            runs += 1
        } while Date() < deadline
        if seconds > 0 {
            print("soak: \(runs) seeds of \(Self.transactionsPerSeed) transactions, the last \(seed - 1)")
        }
    }

    /// Runs one seed's transactions, and on a mismatch shrinks and records.
    ///
    /// - Returns: The runner at the end of a run that agreed throughout, or
    ///   `nil` after a mismatch, which is recorded.
    @discardableResult
    static func run(seed: UInt64, transactions count: Int, version: FormatVersion = .two) throws -> ModelRunner? {
        var generator = ModelGenerator(seed: seed)
        let runner = try ModelRunner(kinds: kinds, version: version)
        var transactions: [ModelTransaction] = []
        for _ in 0..<count {
            let transaction = generator.transaction(against: runner.moments.last ?? .map(ModelMap()))
            transactions.append(transaction)
            let found = try runner.run(transaction)
            if !found.isEmpty {
                let shrunk = ModelShrinker.shrink(transactions) { prefix in
                    (try? Self.fails(prefix, version: version)) ?? true
                }
                let message =
                    "seed \(seed), \(version), transaction \(transactions.count): \(found.joined(separator: "; "))\n"
                    + "shrunk to \(shrunk.count) transactions:\n" + ModelScriptPrinter.script(shrunk)
                Issue.record(Comment(rawValue: message))
                return nil
            }
        }
        return runner
    }

    /// Whether a sequence fails on a memory database alone.
    static func fails(_ transactions: [ModelTransaction], version: FormatVersion = .two) throws -> Bool {
        let runner = try ModelRunner(kinds: [.memory], version: version)
        for transaction in transactions where try !runner.run(transaction).isEmpty {
            return true
        }
        return false
    }
}
