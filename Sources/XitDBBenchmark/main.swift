// The benchmark of the XitDB engine, to the workloads in the director's
// `spec/benchmarks.md`. The conformance session runs the same workloads on
// the Zig implementation, and the two must leave files of the same size.
//
//     swift run -c release XitDBBenchmark [workload ...]
//
// With no arguments every workload runs. Each prints two lines of JSON, one
// for its write phase and one for its read phase.

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

/// One workload: how to write it and how to read it back.
struct Workload {
    let name: String
    let size: Int
    let kinds: [StorageKind]
    /// The number of keys to hash before the clock starts.
    let keyCount: Int
    let write: (Database, [KeyHash]) throws -> Void
    let read: (Database, [KeyHash]) throws -> Void
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
        }
        report(workload, "write", kind, writeTimes, fileSize)
        report(workload, "read", kind, readTimes, fileSize)
    }
}

let wanted = CommandLine.arguments.dropFirst()
for workload in workloads where wanted.isEmpty || wanted.contains(workload.name) {
    try run(workload)
}
