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
    static func run(seed: UInt64, transactions count: Int) throws {
        var generator = ModelGenerator(seed: seed)
        let runner = try ModelRunner(kinds: kinds)
        var transactions: [ModelTransaction] = []
        for _ in 0..<count {
            let transaction = generator.transaction(against: runner.moments.last ?? .map(ModelMap()))
            transactions.append(transaction)
            let found = try runner.run(transaction)
            if !found.isEmpty {
                let shrunk = ModelShrinker.shrink(transactions) { prefix in
                    (try? Self.fails(prefix)) ?? true
                }
                let message =
                    "seed \(seed), transaction \(transactions.count): \(found.joined(separator: "; "))\n"
                    + "shrunk to \(shrunk.count) transactions:\n" + ModelScriptPrinter.script(shrunk)
                Issue.record(Comment(rawValue: message))
                return
            }
        }
    }

    /// Whether a sequence fails on a memory database alone.
    static func fails(_ transactions: [ModelTransaction]) throws -> Bool {
        let runner = try ModelRunner(kinds: [.memory])
        for transaction in transactions where try !runner.run(transaction).isEmpty {
            return true
        }
        return false
    }
}
