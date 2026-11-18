// What a commit costs at each durability: `XitDBBenchmark --commit-cost`.
//
// The workloads run with syncing off, so that the engine is measured and
// not the disk. This is the other figure, the one the documentation's
// table of durability levels gives: how long one small commit takes at
// each level, which is the disk's time and hardly the library's.
//
//     XitDBBenchmark --commit-cost [<folder>]
//
// A small commit is the README's transaction with one value in it: a
// moment appended to the history, which starts as the moment before it,
// and one number put under a key. For a buffered file and for a file,
// and for each of `full`, `ordered` and `none`, it makes 300, 1,000 and
// 20,000 such commits (`--divide` divides them), each timed alone, in
// three rounds, each round on a new database in a new file and the order
// of the levels turned from round to round. The first five commits of a
// round are not timed. A line gives the median, the tenth and the
// ninetieth part of a hundred, the least and the most, in milliseconds.
//
// The files are made in the folder, or in the temporary folder if none is
// named, and removed. The figures are of the disk under that folder and
// of what its system does when asked to sync: on Apple's platforms `full`
// asks the drive to flush and `ordered` asks for a barrier; on Linux both
// are `fsync`; in a container or a virtual machine a sync may wait for
// less than a drive.

import Foundation
import XitDB
import XitDBHashing

/// The levels in the order of the documentation's table, each with its
/// name in a line and how many commits are timed at it.
private let measuredLevels: [(name: String, level: Durability, commits: Int)] = [
    ("full", .full, 300), ("ordered", .ordered, 1_000), ("none", .none, 20_000),
]

/// The commits of a round that are made before the clock is looked at.
private let untimedCommits = 5

/// Makes a new database in a new file in `folder`, commits `commits` small
/// transactions to it after the untimed ones, and gives what each took in
/// milliseconds. The file is removed.
private func commitTimes(
    _ kind: StorageKind, _ level: Durability, commits: Int, folder: String
) throws -> [Double] {
    let path = folder + "/xitdb-commit-cost-\(UUID().uuidString).db"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let storage: any WritableStorage =
        kind == .file
        ? try FileStorage(path: path, access: .truncate, durability: level)
        : try BufferedFileStorage(path: path, access: .truncate, durability: level)
    let database = try Database(creating: storage, hashing: SHA256.self, hashID: "sha2")
    let history = try ArrayList<ReadWrite>(database.rootCursor)

    var times: [Double] = []
    times.reserveCapacity(commits)
    let clock = ContinuousClock()
    for index in 0..<(untimedCommits + commits) {
        let began = clock.now
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            try moment.put(UInt64(index), forKey: "count")
        }
        let time = clock.now - began
        if index >= untimedCommits {
            times.append(Double(time.components.seconds) * 1e3 + Double(time.components.attoseconds) / 1e15)
        }
    }

    // every commit is there, and the last one's value
    guard try history.count == UInt64(untimedCommits + commits),
        let last = try history.cursor(at: -1),
        try HashMap<ReadOnly>(last).value(forKey: "count", as: UInt64.self) == UInt64(untimedCommits + commits - 1)
    else {
        throw BenchmarkFailure(description: "the commits do not read back")
    }
    return times
}

/// Runs `--commit-cost` with what follows it on the command line.
func runCommitCost(_ arguments: [String]) throws {
    guard arguments.count <= 1 else {
        throw BenchmarkFailure(description: "usage: --commit-cost [<folder>]")
    }
    let folder = arguments.first ?? FileManager.default.temporaryDirectory.path
    do {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    } catch {
        throw BenchmarkFailure(description: "the folder \(folder) is not there and cannot be made: \(error)")
    }

    let rounds = 3
    for kind in [StorageKind.bufferedFile, .file] {
        var times: [String: [Double]] = [:]
        for round in 0..<rounds {
            // the order turned from round to round
            for (name, level, commits) in measuredLevels[round...] + measuredLevels[..<round] {
                times[name, default: []] += try commitTimes(
                    kind, level, commits: max(sized(commits) / rounds, 1), folder: folder)
            }
        }
        for (name, _, _) in measuredLevels {
            let sorted = times[name, default: []].sorted()
            func part(_ hundredths: Int) -> Double { sorted[min(sorted.count * hundredths / 100, sorted.count - 1)] }
            let mean = sorted.reduce(0, +) / Double(sorted.count)
            print(
                String(
                    format: #"{"mode": "commit_cost", "kind": "%@", "durability": "%@", "commits": %ld, "#
                        + #""median_ms": %.4f, "tenth_ms": %.4f, "ninetieth_ms": %.4f, "least_ms": %.4f, "#
                        + #""most_ms": %.4f, "mean_ms": %.4f}"#,
                    kind.rawValue, name, sorted.count, part(50), part(10), part(90), sorted[0],
                    sorted[sorted.count - 1], mean))
        }
    }
}
