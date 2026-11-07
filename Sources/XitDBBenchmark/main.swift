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
    let kind: StorageKind
    let storage: any WritableStorage
    private let path: String?

    init(_ kind: StorageKind) throws {
        self.kind = kind
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

/// The keys of a workload, computed before any clock starts, so that
/// hashing and formatting are not part of what is measured: the SHA-1 of
/// `key-<i>` for the hash map workloads, the text `key-<i>` itself for the
/// sorted map, for each `i` below the workload's key count.
struct Keys {
    var hashes: [KeyHash] = []
    var texts: [[UInt8]] = []
    var sortedKeys: [SortedKey] = []

    enum Kind {
        case none
        case hashes
        case texts
    }

    init(_ kind: Kind, count: Int) {
        switch kind {
        case .none:
            break
        case .hashes:
            hashes = (0..<count).map { index in
                KeyHash(Array(Insecure.SHA1.hash(data: Data("key-\(index)".utf8))))
            }
        case .texts:
            texts = (0..<count).map { index in Array("key-\(index)".utf8) }
            sortedKeys = texts.map { SortedKey($0) }
        }
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
func readMap(_ moment: Cursor<ReadOnly>, _ keys: Keys) throws {
    let hashes = keys.hashes
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
func iterateMap(_ moment: Cursor<ReadOnly>, _ keys: Keys) throws {
    let hashes = keys.hashes
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
///
/// A run gets a new, empty storage. `prepare` makes what the write phase
/// needs before the clock starts: for most workloads the database over
/// that storage; for a compaction, the source and the offset map. `write`
/// is the clocked phase, and returns the database the read and iterate
/// phases then use: the one prepared, or the compaction's target, which
/// is created inside the clocked call.
struct Workload {
    let name: String
    let size: Int
    let kinds: [StorageKind]
    /// The keys to compute before the clock starts, and how many.
    let keyKind: Keys.Kind
    let keyCount: Int
    let prepare: (RunStorage, Keys) throws -> Any
    let write: (RunStorage, Keys, Any) throws -> Database
    let read: (Database, Keys, Any) throws -> Void
    let iterate: (Database, Keys, Any) throws -> Void

    /// A workload whose write phase fills the prepared database.
    init(
        name: String, size: Int, kinds: [StorageKind], keyKind: Keys.Kind, keyCount: Int,
        write: @escaping (Database, Keys) throws -> Void,
        read: @escaping (Database, Keys) throws -> Void,
        iterate: @escaping (Database, Keys) throws -> Void
    ) {
        self.name = name
        self.size = size
        self.kinds = kinds
        self.keyKind = keyKind
        self.keyCount = keyCount
        prepare = { storage, _ in try newDatabase(storage.storage) }
        self.write = { _, keys, prepared in
            let database = prepared as! Database
            try write(database, keys)
            return database
        }
        self.read = { database, keys, _ in try read(database, keys) }
        self.iterate = { database, keys, _ in try iterate(database, keys) }
    }

    /// A workload whose write phase makes the database it measures, and
    /// whose phases all see what was prepared.
    init(
        name: String, size: Int, kinds: [StorageKind], keyKind: Keys.Kind, keyCount: Int,
        prepare: @escaping (RunStorage, Keys) throws -> Any,
        write: @escaping (RunStorage, Keys, Any) throws -> Database,
        read: @escaping (Database, Keys, Any) throws -> Void,
        iterate: @escaping (Database, Keys, Any) throws -> Void
    ) {
        self.name = name
        self.size = size
        self.kinds = kinds
        self.keyKind = keyKind
        self.keyCount = keyCount
        self.prepare = prepare
        self.write = write
        self.read = read
        self.iterate = iterate
    }
}

func mapInsert(_ size: Int, kinds: [StorageKind]) -> Workload {
    Workload(name: "map_insert", size: size, kinds: kinds, keyKind: .hashes, keyCount: size) { database, keys in
        let hashes = keys.hashes
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
    Workload(name: "list_append", size: size, kinds: kinds, keyKind: .none, keyCount: 0) { database, _ in
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

/// Writes `transactions` transactions of ten keys each, every one a new
/// moment of the history: `map_transactions`' write phase. The keys are
/// the ten of each transaction, counted from `first`.
func writeTransactions(_ transactions: Int, into database: Database, _ keys: Keys, from first: Int = 0) throws {
    let hashes = keys.hashes
    for transaction in first..<(first + transactions) {
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
}

func mapTransactions(_ transactions: Int, kinds: [StorageKind]) -> Workload {
    Workload(name: "map_transactions", size: transactions, kinds: kinds, keyKind: .hashes, keyCount: transactions * 10)
    {
        database,
        keys in
        try writeTransactions(transactions, into: database, keys)
    } read: { database, hashes in
        try readMap(try lastMoment(database), hashes)
    } iterate: { database, hashes in
        try iterateMap(try lastMoment(database), hashes)
    }
}

/// What a compaction run has before the clock starts: the source, the
/// `map_transactions` database after its write phase, on a storage of its
/// own, and a new offset map.
final class CompactionRun {
    let sourceStorage: RunStorage
    let source: Database
    var offsetMap = MemoryOffsetMap()

    init(_ kind: StorageKind, transactions: Int, _ keys: Keys) throws {
        sourceStorage = try RunStorage(kind)
        source = try newDatabase(sourceStorage.storage)
        try writeTransactions(transactions, into: source, keys)
    }
}

/// Compacts the `map_transactions` database into a new one of the same
/// kind, then reads every key from the target and walks it.
func mapCompact(_ transactions: Int, kinds: [StorageKind]) -> Workload {
    Workload(
        name: "map_compact", size: transactions, kinds: kinds, keyKind: .hashes, keyCount: transactions * 10
    ) { storage, keys in
        try CompactionRun(storage.kind, transactions: transactions, keys)
    } write: { storage, _, prepared in
        let run = prepared as! CompactionRun
        // the target's header and everything after it are written here
        return try run.source.compact(
            into: storage.storage, fileID: 0x0011_2233_4455_6677, offsetMap: &run.offsetMap)
    } read: { database, keys, _ in
        try readMap(try lastMoment(database), keys)
    } iterate: { database, keys, _ in
        try iterateMap(try lastMoment(database), keys)
    }
}

/// What a replication run has before the clock starts: the source with
/// `transactions` + 10 transactions, its committed size after the first
/// `transactions` noted, and the replica, a new database over the run's
/// storage.
final class ReplicationRun {
    let sourceStorage: RunStorage
    let source: Database
    let sizeAfterFirst: UInt64
    let replica: Database

    init(_ storage: RunStorage, transactions: Int, _ keys: Keys) throws {
        sourceStorage = try RunStorage(storage.kind)
        source = try newDatabase(sourceStorage.storage)
        try writeTransactions(transactions, into: source, keys)
        sizeAfterFirst = try source.committedSize()
        try writeTransactions(10, into: source, keys, from: transactions)
        replica = try newDatabase(storage.storage)
    }
}

/// A full sync of the source's first `transactions` transactions into an
/// empty replica, then an incremental sync of the ten after them, the bytes
/// travelling through memory; then a walk of the replica's last moment.
func replicate(_ transactions: Int, kinds: [StorageKind]) -> Workload {
    Workload(
        name: "replicate", size: transactions, kinds: kinds, keyKind: .hashes, keyCount: (transactions + 10) * 10
    ) { storage, keys in
        try ReplicationRun(storage, transactions: transactions, keys)
    } write: { _, _, prepared in
        let run = prepared as! ReplicationRun
        let bytes = try run.source.readCommitted(from: 0, to: run.sizeAfterFirst)
        try run.replica.applyReplicated(at: 0, bytes: bytes)
        guard try run.replica.committedSize() == run.sizeAfterFirst else {
            throw BenchmarkFailure(description: "the full sync did not bring the replica to the source's size")
        }
        return run.replica
    } read: { replica, _, prepared in
        let run = prepared as! ReplicationRun
        let start = try run.source.replicationStart(try replica.replicaState())
        guard start == run.sizeAfterFirst else {
            throw BenchmarkFailure(description: "the replica is not a prefix of the source")
        }
        let end = try run.source.committedSize()
        let bytes = try run.source.readCommitted(from: start, to: end)
        try replica.applyReplicated(at: start, bytes: bytes)
        guard try replica.committedSize() == end else {
            throw BenchmarkFailure(description: "the incremental sync did not bring the replica to the source's size")
        }
    } iterate: { replica, keys, _ in
        try iterateMap(try lastMoment(replica), keys)
    }
}

/// Appends `size` integers to a linked array list in one transaction, reads
/// each back by index, and walks the list.
func linkedAppend(_ size: Int, kinds: [StorageKind]) -> Workload {
    Workload(name: "linked_append", size: size, kinds: kinds, keyKind: .none, keyCount: 0) { database, _ in
        let path: InlineArray<4, PathPart> = [.arrayListInit, .arrayListAppend, .linkedArrayListInit, .ctx]
        _ = try database.rootCursor().writePath(path.span) { cursor in
            for index in 0..<size {
                let append: InlineArray<2, PathPart> = [.linkedArrayListAppend, .write(.uint(UInt64(index)))]
                _ = try cursor.writePath(append.span)
            }
        }
    } read: { database, _ in
        let moment = try lastMoment(database)
        for index in 0..<size {
            let path: InlineArray<1, PathPart> = [.linkedArrayListGet(Int64(index))]
            guard let cursor = try moment.readPath(path.span), try cursor.readUint() == UInt64(index) else {
                throw BenchmarkFailure(description: "element \(index) does not read back")
            }
        }
    } iterate: { database, _ in
        let list = try LinkedArrayList(try lastMoment(database))
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

/// Puts `size` keys `key-<i>` into a sorted map in one transaction, reads
/// each back by key, and walks the map checking the order of the keys.
func sortedInsert(_ size: Int, kinds: [StorageKind]) -> Workload {
    Workload(name: "sorted_insert", size: size, kinds: kinds, keyKind: .texts, keyCount: size) { database, keys in
        let sortedKeys = keys.sortedKeys
        let path: InlineArray<4, PathPart> = [.arrayListInit, .arrayListAppend, .sortedMapInit(), .ctx]
        _ = try database.rootCursor().writePath(path.span) { cursor in
            for index in sortedKeys.indices {
                let put: InlineArray<2, PathPart> = [
                    .sortedMapGet(.value, sortedKeys[index]), .write(.uint(UInt64(index))),
                ]
                _ = try cursor.writePath(put.span)
            }
        }
    } read: { database, keys in
        let moment = try lastMoment(database)
        let sortedKeys = keys.sortedKeys
        for index in sortedKeys.indices {
            let path: InlineArray<1, PathPart> = [.sortedMapGet(.value, sortedKeys[index])]
            guard let cursor = try moment.readPath(path.span), try cursor.readUint() == UInt64(index) else {
                throw BenchmarkFailure(description: "key-\(index) does not read back")
            }
        }
    } iterate: { database, keys in
        let texts = keys.texts
        let map = try SortedMap(try lastMoment(database))
        var iterator = try map.iterator()
        var count = 0
        // two buffers of sixteen bytes, the key just read and the one
        // before it, swapped after each entry: nothing is allocated
        var buffer = [UInt8](repeating: 0, count: 16)
        var previous = [UInt8](repeating: 0, count: 16)
        var previousCount = 0
        while let entry = try iterator.next() {
            let pair = try entry.readKeyValuePair()
            let value = try pair.valueCursor.readUint()
            guard value < UInt64(texts.count) else {
                throw BenchmarkFailure(description: "an entry is not one of the keys written")
            }
            var span = buffer.mutableSpan
            let read = try pair.keyCursor.readBytes(into: &span)
            guard sameBytes(buffer, read, texts[Int(value)], texts[Int(value)].count) else {
                throw BenchmarkFailure(description: "the key of key-\(value) does not read back")
            }
            // strictly greater than the key before it: the first key is
            // greater than nothing
            guard count == 0 || precedes(previous, previousCount, buffer, read) else {
                throw BenchmarkFailure(description: "key-\(value) is out of order")
            }
            swap(&previous, &buffer)
            previousCount = read
            count += 1
        }
        guard count == size else { throw BenchmarkFailure(description: "the iteration gave \(count) entries") }
    }
}

/// Whether the first `leftCount` bytes of `left` are the first `rightCount`
/// of `right`.
func sameBytes(_ left: [UInt8], _ leftCount: Int, _ right: [UInt8], _ rightCount: Int) -> Bool {
    guard leftCount == rightCount else { return false }
    for index in 0..<leftCount where left[index] != right[index] {
        return false
    }
    return true
}

/// Whether the first `leftCount` bytes of `left` come before the first
/// `rightCount` of `right`, bytewise, a shorter key first where it is a
/// prefix: strictly less.
func precedes(_ left: [UInt8], _ leftCount: Int, _ right: [UInt8], _ rightCount: Int) -> Bool {
    let common = min(leftCount, rightCount)
    for index in 0..<common where left[index] != right[index] {
        return left[index] < right[index]
    }
    return leftCount < rightCount
}

let workloads: [Workload] = [
    mapInsert(100_000, kinds: [.memory, .bufferedFile]),
    mapInsert(10_000, kinds: [.file]),
    listAppend(1_000_000, kinds: [.memory, .bufferedFile]),
    mapTransactions(2_000, kinds: [.memory, .bufferedFile]),
    linkedAppend(100_000, kinds: [.memory, .bufferedFile]),
    linkedAppend(10_000, kinds: [.file]),
    sortedInsert(100_000, kinds: [.memory, .bufferedFile]),
    sortedInsert(10_000, kinds: [.file]),
    mapCompact(2_000, kinds: [.memory, .bufferedFile]),
    mapCompact(200, kinds: [.file]),
    replicate(2_000, kinds: [.memory, .bufferedFile]),
    replicate(200, kinds: [.file]),
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
    let keys = Keys(workload.keyKind, count: workload.keyCount)
    for kind in workload.kinds {
        var writeTimes: [Double] = []
        var readTimes: [Double] = []
        var iterateTimes: [Double] = []
        var fileSize: UInt64 = 0
        // Every run starts from a new, empty storage.
        for _ in 0..<5 {
            let storage = try RunStorage(kind)
            let prepared = try workload.prepare(storage, keys)
            var database: Database? = nil
            writeTimes.append(try milliseconds { database = try workload.write(storage, keys, prepared) })
            guard let database else { throw BenchmarkFailure(description: "the write phase gave no database") }
            readTimes.append(try milliseconds { try workload.read(database, keys, prepared) })
            iterateTimes.append(try milliseconds { try workload.iterate(database, keys, prepared) })
            // the file as the phases leave it: reads change nothing, and
            // a replication's read phase is its second sync
            let size = try storage.storage.length()
            if fileSize != 0 && size != fileSize {
                throw BenchmarkFailure(description: "\(workload.name) left files of different sizes")
            }
            fileSize = size
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
    let keys = Keys(workload.keyKind, count: workload.keyCount)
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
    var runs = 0
    var total = 0.0
    if phase == "read" || phase == "iterate" {
        let storage = try RunStorage(kind)
        let prepared = try workload.prepare(storage, keys)
        let database = try workload.write(storage, keys, prepared)
        let run = phase == "read" ? workload.read : workload.iterate
        while DispatchTime.now().uptimeNanoseconds < deadline {
            total += try milliseconds { try run(database, keys, prepared) }
            runs += 1
        }
    } else {
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let storage = try RunStorage(kind)
            let prepared = try workload.prepare(storage, keys)
            total += try milliseconds { _ = try workload.write(storage, keys, prepared) }
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
