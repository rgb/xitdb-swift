// The benchmark of the XitDB engine, to the workloads in the director's
// `spec/benchmarks.md`. The conformance session runs the same workloads on
// the Zig implementation, and the two must leave files of the same size.
//
//     swift run -c release XitDBBenchmark [workload ...]
//
// With no arguments every workload runs. Each prints three lines of JSON,
// one for its write phase, one for its read phase and one for its iterate
// phase.
//
// For a profiler, one phase of one workload on one kind of storage can be
// run over and over for a number of seconds:
//
//     XitDBBenchmark --repeat <seconds> <workload> <kind> <write|read|iterate>

import CryptoKit
import Foundation
import XitDB

struct BenchmarkFailure: Error, CustomStringConvertible {
    let description: String
}

enum StorageKind: String {
    case memory
    case bufferedFile = "buffered_file"
    case file
}

/// A storage of one kind for one run, in a file of its own that is removed
/// afterwards. Syncing is off, so that the engine is measured and not the
/// disk.
final class RunStorage {
    let storage: any WritableStorage
    private let path: String?

    init(_ kind: StorageKind) throws {
        switch kind {
        case .memory:
            path = nil
            storage = MemoryStorage()
        case .bufferedFile, .file:
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("xitdb-benchmark-\(UUID().uuidString).db").path
            path = file
            storage =
                kind == .file
                ? try FileStorage(path: file, access: .truncate, durability: .none)
                : try BufferedFileStorage(path: file, access: .truncate, durability: .none)
        }
    }

    deinit {
        if let path {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

/// The SHA-1 of `key-<i>` for each `i` below `count`. Computed before any
/// clock starts, so that hashing is not part of what is measured.
func keyHashes(_ count: Int) -> [KeyHash] {
    (0..<count).map { index in
        KeyHash(Array(Insecure.SHA1.hash(data: Data("key-\(index)".utf8))))
    }
}

func newDatabase(_ storage: any WritableStorage) throws -> Database {
    try Database(
        storage: storage,
        hashSize: 20,
        hashID: HashID(bytes: [0x73, 0x68, 0x61, 0x31]),
        fileID: 0x0011_2233_4455_6677
    )
}

func milliseconds(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

/// The last moment of the list at the root.
func lastMoment(_ database: Database) throws -> Cursor<ReadOnly> {
    let path: InlineArray<1, PathPart> = [.arrayListGet(-1)]
    guard let moment = try database.rootCursor().readPath(path.span) else {
        throw BenchmarkFailure(description: "the database has no moment")
    }
    return moment
}

/// Reads every key from a map and checks that its value is its index.
func readMap(_ moment: Cursor<ReadOnly>, _ hashes: [KeyHash]) throws {
    for index in hashes.indices {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.value, hashes[index])]
        guard let cursor = try moment.readPath(path.span), try cursor.readUint() == UInt64(index) else {
            throw BenchmarkFailure(description: "key-\(index) does not read back")
        }
    }
}

/// Goes through every entry of a map and checks that it is one of the keys
/// written, that its value is that key's index, and that nothing is missing
/// or given twice.
func iterateMap(_ moment: Cursor<ReadOnly>, _ hashes: [KeyHash]) throws {
    let map = try HashMap(moment)
    var iterator = try map.iterator()
    var count: UInt64 = 0
    var sum: UInt64 = 0
    while let entry = try iterator.next() {
        let pair = try entry.readKeyValuePair()
        let value = try pair.valueCursor.readUint()
        guard value < UInt64(hashes.count), pair.keyHash == hashes[Int(value)] else {
            throw BenchmarkFailure(description: "an entry is not one of the keys written")
        }
        count += 1
        sum += value
    }
    let written = UInt64(hashes.count)
    guard count == written, sum == written * (written - 1) / 2 else {
        throw BenchmarkFailure(description: "the iteration gave \(count) entries with a sum of \(sum)")
    }
}

/// One workload: how to write it and how to read it back.
struct Workload {
    let name: String
    let size: Int
    let kinds: [StorageKind]
    /// The number of keys to hash before the clock starts.
    let keyCount: Int
    let write: (Database, [KeyHash]) throws -> Void
    let read: (Database, [KeyHash]) throws -> Void
    let iterate: (Database, [KeyHash]) throws -> Void
}

func mapInsert(_ size: Int, kinds: [StorageKind]) -> Workload {
    Workload(name: "map_insert", size: size, kinds: kinds, keyCount: size) { database, hashes in
        let path: InlineArray<4, PathPart> = [.arrayListInit, .arrayListAppend, .hashMapInit(), .ctx]
        _ = try database.rootCursor().writePath(path.span) { cursor in
            for index in hashes.indices {
                let put: InlineArray<2, PathPart> = [.hashMapGet(.value, hashes[index]), .write(.uint(UInt64(index)))]
                _ = try cursor.writePath(put.span)
            }
        }
    } read: { database, hashes in
        try readMap(try lastMoment(database), hashes)
    } iterate: { database, hashes in
        try iterateMap(try lastMoment(database), hashes)
    }
}

func listAppend(_ size: Int, kinds: [StorageKind]) -> Workload {
    Workload(name: "list_append", size: size, kinds: kinds, keyCount: 0) { database, _ in
        let path: InlineArray<4, PathPart> = [.arrayListInit, .arrayListAppend, .arrayListInit, .ctx]
        _ = try database.rootCursor().writePath(path.span) { cursor in
            for index in 0..<size {
                let append: InlineArray<2, PathPart> = [.arrayListAppend, .write(.uint(UInt64(index)))]
                _ = try cursor.writePath(append.span)
            }
        }
    } read: { database, _ in
        let moment = try lastMoment(database)
        for index in 0..<size {
            let path: InlineArray<1, PathPart> = [.arrayListGet(Int64(index))]
            guard let cursor = try moment.readPath(path.span), try cursor.readUint() == UInt64(index) else {
                throw BenchmarkFailure(description: "element \(index) does not read back")
            }
        }
    } iterate: { database, _ in
        let list = try ArrayList(try lastMoment(database))
        var iterator = try list.iterator()
        var count: UInt64 = 0
        while let element = try iterator.next() {
            guard try element.readUint() == count else {
                throw BenchmarkFailure(description: "element \(count) is not in its place")
            }
            count += 1
        }
        guard count == UInt64(size) else { throw BenchmarkFailure(description: "the iteration gave \(count) elements") }
    }
}

func mapTransactions(_ transactions: Int, kinds: [StorageKind]) -> Workload {
    Workload(name: "map_transactions", size: transactions, kinds: kinds, keyCount: transactions * 10) {
        database,
        hashes in
        for transaction in 0..<transactions {
            let lastPath: InlineArray<1, PathPart> = [.arrayListGet(-1)]
            let last = try database.rootCursor().readPathSlot(lastPath.span)
            let path: InlineArray<5, PathPart> = [
                .arrayListInit, .arrayListAppend, .write(.slot(last)), .hashMapInit(), .ctx,
            ]
            _ = try database.rootCursor().writePath(path.span) { cursor in
                for index in (transaction * 10)..<(transaction * 10 + 10) {
                    let put: InlineArray<2, PathPart> = [
                        .hashMapGet(.value, hashes[index]), .write(.uint(UInt64(index))),
                    ]
                    _ = try cursor.writePath(put.span)
                }
            }
        }
    } read: { database, hashes in
        try readMap(try lastMoment(database), hashes)
    } iterate: { database, hashes in
        try iterateMap(try lastMoment(database), hashes)
    }
}

let workloads: [Workload] = [
    mapInsert(100_000, kinds: [.memory, .bufferedFile]),
    mapInsert(10_000, kinds: [.file]),
    listAppend(1_000_000, kinds: [.memory, .bufferedFile]),
    mapTransactions(2_000, kinds: [.memory, .bufferedFile]),
]

func median(_ values: [Double]) -> Double {
    values.sorted()[values.count / 2]
}

func report(_ workload: Workload, _ phase: String, _ kind: StorageKind, _ times: [Double], _ fileSize: UInt64) {
    let line = String(
        format: #"{"workload": "%@", "phase": "%@", "kind": "%@", "n": %d, "median_ms": %.3f, "file_size": %llu}"#,
        workload.name, phase, kind.rawValue, workload.size, median(times), fileSize
    )
    print(line)
}

func run(_ workload: Workload) throws {
    let hashes = keyHashes(workload.keyCount)
    for kind in workload.kinds {
        var writeTimes: [Double] = []
        var readTimes: [Double] = []
        var iterateTimes: [Double] = []
        var fileSize: UInt64 = 0
        // Every run starts from a new, empty database.
        for _ in 0..<5 {
            let storage = try RunStorage(kind)
            let database = try newDatabase(storage.storage)
            writeTimes.append(try milliseconds { try workload.write(database, hashes) })
            let size = try storage.storage.length()
            if fileSize != 0 && size != fileSize {
                throw BenchmarkFailure(description: "\(workload.name) left files of different sizes")
            }
            fileSize = size
            readTimes.append(try milliseconds { try workload.read(database, hashes) })
            iterateTimes.append(try milliseconds { try workload.iterate(database, hashes) })
        }
        report(workload, "write", kind, writeTimes, fileSize)
        report(workload, "read", kind, readTimes, fileSize)
        report(workload, "iterate", kind, iterateTimes, fileSize)
    }
}

/// Runs one phase of a workload until `seconds` have passed, and prints how
/// often it ran and how long a run took on average. The write phase starts
/// from a new, empty database each time, as it does when it is measured. The
/// read phase reads one database that is written first.
func runRepeatedly(_ workload: Workload, _ kind: StorageKind, phase: String, seconds: Double) throws {
    let hashes = keyHashes(workload.keyCount)
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
    var runs = 0
    var total = 0.0
    if phase == "read" || phase == "iterate" {
        let storage = try RunStorage(kind)
        let database = try newDatabase(storage.storage)
        try workload.write(database, hashes)
        let run = phase == "read" ? workload.read : workload.iterate
        while DispatchTime.now().uptimeNanoseconds < deadline {
            total += try milliseconds { try run(database, hashes) }
            runs += 1
        }
    } else {
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let storage = try RunStorage(kind)
            let database = try newDatabase(storage.storage)
            total += try milliseconds { try workload.write(database, hashes) }
            runs += 1
        }
    }
    let line = String(
        format: #"{"workload": "%@", "phase": "%@", "kind": "%@", "n": %d, "runs": %d, "mean_ms": %.3f}"#,
        workload.name, phase, kind.rawValue, workload.size, runs, total / Double(max(runs, 1))
    )
    print(line)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--repeat" {
    guard
        arguments.count == 5,
        let seconds = Double(arguments[1]),
        let kind = StorageKind(rawValue: arguments[3]),
        let workload = workloads.first(where: { $0.name == arguments[2] && $0.kinds.contains(kind) }),
        ["write", "read", "iterate"].contains(arguments[4])
    else {
        throw BenchmarkFailure(description: "usage: --repeat <seconds> <workload> <kind> <write|read|iterate>")
    }
    try runRepeatedly(workload, kind, phase: arguments[4], seconds: seconds)
} else {
    for workload in workloads where arguments.isEmpty || arguments.contains(workload.name) {
        try run(workload)
    }
}
