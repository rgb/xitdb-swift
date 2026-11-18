// The benchmark of the XitDB engine, to the workloads in the director's
// `spec/benchmarks.md`. The conformance session runs the same workloads on
// the Zig implementation, and the two must leave files of the same size.
//
//     swift run -c release XitDBBenchmark [workload ...]
//
// With no arguments every workload runs. Each prints three lines of JSON,
// one for its write phase, one for its read phase and one for its iterate
// phase: the median of five runs.
//
// Two things move an in-memory figure by more than the work does, and both
// were found on the release of 0.4.0, when one cell read 30% slower with
// two more arguments on the command line and another 5% slower than the
// release before.
//
// The first is where the stack lies. A load or a store of two neighbouring
// 8-byte words of the stack at once, which compilers make everywhere, costs
// tens of cycles when a page boundary falls between the two words. A
// million appends to a list in memory took 99 ms at most positions of the
// stack and up to 135 ms at 15 of the 1,024 sixteen-byte positions a 16 KB
// page has, the same 15 in 0.3.0 and in 0.4.0; a process's position is its
// environment, its arguments and its call depth, so a given start is always
// fast or always slow. The five runs of an in-memory phase are therefore
// made at five depths of the stack, a kilobyte or two apart, and the median
// does not rest on one position. One phase can be mapped over a whole page:
//
//     XitDBBenchmark --stack-sweep <workload> <kind> <write|read|iterate> [passes]
//
// The second is where the binary's code lies, and no mode takes it out. The
// same sources built with a few bytes of padding before the library's code
// ran a list's iteration in memory in 16.0 to 16.9 ms, a spread of 5%. So
// a difference of about that size between two binaries is not the
// library's until the instructions say so. On macOS each line has
// `instructions` and `cycles`, the processor's counts for the phase (the
// median run's), which the system gives a process about itself: equal
// instructions with more cycles is layout and not work. iOS has no such
// call, and Linux gives no such count without a permission the benchmark
// does not ask for: the lines have none there.
//
// For a profiler, one phase of one workload on one kind of storage can be
// run over and over for a number of seconds:
//
//     XitDBBenchmark --repeat <seconds> <workload> <kind> <write|read|iterate>
//
// With `--snapshot`, the read and iterate phases of every workload whose
// phases only read run through a snapshot of the database, on a fresh
// read-only database over it, instead of the database itself: the cost of
// reading through a snapshot (D25).
//
// `--hash-cost` measures no database: what hashing a key costs, by each way
// of computing it, for keys of three lengths (HashCost.swift).
//
// `--cold` runs none of the workloads: it is the cold lines of the memory
// map, what a walk in file order, the stream of a whole file, reads by key
// and a compaction cost when none of the file's pages is in memory, with
// the map's advice to the system and without it; `--cold report <folder>`
// runs all of them and prints the machine they ran on (ColdLines.swift).
//
// `--read-path` runs other workloads than the usual ones, each at one size
// on every kind of storage, read through the storage, a snapshot of it
// (`--snapshot`) or a reader of its own (`--reader`): what a read through a
// storage costs beside the same read through its snapshot (ReadPath.swift).
// Without the word the benchmark is what it was.
//
// With `--kind <kind>` the workloads run on that kind of storage alone,
// `memory`, `file` or `buffered_file`, and a workload that does not have
// the kind prints nothing. The gate's count of instructions
// (`scripts/instructions.sh`) runs the in-memory kind alone, which is the
// one whose figures a change in the engine moves by per cents.

import Foundation
import XitDB
import XitDBHashing

struct BenchmarkFailure: Error, CustomStringConvertible {
    let description: String
}

enum StorageKind: String {
    case memory
    case bufferedFile = "buffered_file"
    case file
    /// A buffered file whose file is read through a memory map.
    case mappedBufferedFile = "mapped_buffered_file"
    /// A file read through a memory map.
    case mappedFile = "mapped_file"

    /// The kind that reads the same file through a memory map, for the
    /// two kinds that have one.
    var mapped: StorageKind? {
        switch self {
        case .bufferedFile: .mappedBufferedFile
        case .file: .mappedFile
        case .memory, .mappedBufferedFile, .mappedFile: nil
        }
    }

    var isMapped: Bool { self == .mappedBufferedFile || self == .mappedFile }
}

/// With `--mapped` every workload runs on the mapped twins of its file
/// kinds and not in memory, so that the lines can be laid beside those of
/// a run without it.
let mappedRun = CommandLine.arguments.contains("--mapped")

/// With `--map-at-commits` a mapped storage reads through its map only
/// what is committed, and what the open transaction has written by file
/// calls: the other of the two limits, for measuring one against the
/// other.
let mapAtCommits = CommandLine.arguments.contains("--map-at-commits")

/// A storage of one kind for one run, in a file of its own that is removed
/// afterwards. Syncing is off, so that the engine is measured and not the
/// disk.
final class RunStorage {
    let kind: StorageKind
    let storage: any WritableStorage
    /// The file under the storage, for `--count` to put its counters on.
    let file: FileStorage?
    /// The file's path, for a reader of its own to open; `nil` in memory.
    let path: String?

    init(_ kind: StorageKind) throws {
        self.kind = kind
        switch kind {
        case .memory:
            path = nil
            file = nil
            storage = MemoryStorage()
        case .bufferedFile, .file:
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("xitdb-benchmark-\(UUID().uuidString).db").path
            self.path = path
            let file = try FileStorage(path: path, access: .truncate, durability: .none)
            self.file = file
            storage = kind == .file ? file : BufferedFileStorage(file)
        case .mappedBufferedFile, .mappedFile:
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("xitdb-benchmark-\(UUID().uuidString).db").path
            self.path = path
            let file = try FileStorage(
                path: path, access: .truncate, durability: .none, lock: .exclusive, reading: .memoryMap)
            // A line that says "mapped" must be one: on a volume the
            // library does not map the storage would read by file calls.
            guard file.isMemoryMapped else {
                throw BenchmarkFailure(description: "the temporary folder is on a volume that is not mapped")
            }
            file.mapsCommittedBytesOnly = mapAtCommits
            self.file = file
            storage = kind == .mappedFile ? file : BufferedFileStorage(file)
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
    /// The same hashes as plain arrays, as a caller who hashed a key holds
    /// them.
    var hashBytes: [[UInt8]] = []
    var texts: [[UInt8]] = []
    var sortedKeys: [SortedKey] = []
    /// The keys themselves, `key-<i>`, for the workloads that give a
    /// collection its keys and leave the hashing to the database, or that
    /// give a sorted map its keys as text.
    var strings: [String] = []
    /// A text for each key, `value-<i>`, for the workloads that store
    /// strings.
    var values: [String] = []

    enum Kind {
        case none
        case hashes
        case texts
        /// The keys as strings, and their hashes for checking.
        case keys
    }

    init(_ kind: Kind, count: Int) {
        switch kind {
        case .none:
            break
        case .hashes:
            hashBytes = (0..<count).map { index in Insecure.SHA1.keyHash(of: "key-\(index)") }
            hashes = hashBytes.map { KeyHash($0) }
        case .texts:
            strings = (0..<count).map { index in "key-\(index)" }
            texts = strings.map { key in Array(key.utf8) }
            sortedKeys = texts.map { SortedKey($0) }
        case .keys:
            strings = (0..<count).map { index in "key-\(index)" }
            hashBytes = strings.map { key in Insecure.SHA1.keyHash(of: key) }
            hashes = hashBytes.map { KeyHash($0) }
            values = (0..<count).map { index in "value-\(index)" }
        }
    }
}

func newDatabase(_ storage: any WritableStorage) throws -> Database {
    try Database(creating: storage, hashSize: 20, hashID: "sha1", fileID: 0x0011_2233_4455_6677)
}

func milliseconds(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

/// What one run of a phase took: its time, and the processor's counts for
/// it where the system gives them.
struct Measurement {
    var milliseconds: Double
    var instructions: UInt64?
    var cycles: UInt64?
}

/// The instructions this process has retired and the cycles it has taken so
/// far, on macOS, where a process may ask the system about itself; nil
/// elsewhere (the call is not in iOS's SDK), and where the system gives no
/// answer.
func processorCounts() -> (instructions: UInt64, cycles: UInt64)? {
    #if os(macOS)
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
            }
        }
        return status == 0 ? (info.ri_instructions, info.ri_cycles) : nil
    #else
        return nil
    #endif
}

/// The time `body` takes, with the processor's counts for it. The counts
/// are read outside the clock.
func measured(_ body: () throws -> Void) rethrows -> Measurement {
    let before = processorCounts()
    let time = try milliseconds(body)
    let after = processorCounts()
    guard let before, let after else { return Measurement(milliseconds: time) }
    return Measurement(
        milliseconds: time, instructions: after.instructions &- before.instructions,
        cycles: after.cycles &- before.cycles)
}

/// How many levels of ``atStackDepth(_:byLongerFrames:_:)`` each of the
/// five runs of an in-memory phase is made under: the stack a kilobyte or
/// two further down from one run to the next, by amounts that are no
/// multiple of one another.
let stackDepths = [0, 23, 61, 113, 167]

/// What ``atStackDepth(_:byLongerFrames:_:)`` runs at the bottom of its
/// recursion. The recursion takes no closure of its own: the compiler makes
/// a copy of a function for each closure it is called with, each with a
/// frame of its own length, and the depth would not be the same for two
/// callers.
nonisolated(unsafe) var bodyAtStackDepth: () throws -> Void = {}

/// Two numbers for the recursions to carry across their calls. They are
/// written after the call a level makes, so that the call is not the last
/// thing the level does and each level keeps a frame of its own.
nonisolated(unsafe) var stackLevels = (returned: 0, entered: 0)

/// Runs ``bodyAtStackDepth`` `levels` frames of this function further down
/// the stack.
@inline(never)
func descend(_ levels: Int) throws {
    if levels <= 0 {
        try bodyAtStackDepth()
    } else {
        try descend(levels - 1)
        stackLevels.returned &+= levels
    }
}

/// The same by longer frames: it carries three numbers across its call,
/// which takes one more pair of saved registers.
@inline(never)
func descendByLongerFrames(_ levels: Int) throws {
    if levels <= 0 {
        try bodyAtStackDepth()
    } else {
        let before = stackLevels
        try descendByLongerFrames(levels - 1)
        stackLevels = (before.returned &+ levels, before.entered &+ 1)
    }
}

/// Runs `body` with the stack `levels` frames further down, by one of two
/// recursions whose frames differ in length. `--stack-sweep` needs one that
/// moves the stack by an odd number of sixteen bytes a level, since only
/// that reaches every sixteen-byte position of a page, and takes whichever
/// of the two does.
func atStackDepth(_ levels: Int, byLongerFrames: Bool = false, _ body: () throws -> Void) throws {
    try withoutActuallyEscaping(body) { body in
        let outer = bodyAtStackDepth
        bodyAtStackDepth = body
        defer { bodyAtStackDepth = outer }
        if byLongerFrames {
            try descendByLongerFrames(levels)
        } else {
            try descend(levels)
        }
    }
}

/// Where the stack is: the address of a local of a function that is not
/// inlined.
@inline(never)
func stackMarker() -> UInt {
    var marker: UInt8 = 0
    return withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
}

/// What a read or iterate phase reads: a read-only cursor at the root,
/// the live database's or a snapshot's (`--snapshot`), and the live
/// database itself for the phases that need it, which `--snapshot` leaves
/// alone.
struct Reading {
    let root: Cursor<ReadOnly>
    let database: Database?

    init(_ database: Database) {
        root = database.rootCursor.readOnly
        self.database = database
    }

    init(snapshotOf database: Database) throws {
        root = SnapshotDatabase(try database.snapshot()).rootCursor
        self.database = nil
    }

    /// The live database, for a phase that needs one.
    func live() throws -> Database {
        guard let database else { throw BenchmarkFailure(description: "the phase needs the live database") }
        return database
    }
}

/// The last moment of the list at the root.
func lastMoment(_ reading: Reading) throws -> Cursor<ReadOnly> {
    let path: InlineArray<1, PathPart> = [.arrayListGet(-1)]
    guard let moment = try reading.root.readPath(path.span) else {
        throw BenchmarkFailure(description: "the database has no moment")
    }
    return moment
}

/// Reads every key from a map and checks that its value is its index.
func readMap(_ moment: Cursor<ReadOnly>, _ keys: Keys) throws {
    let hashes = keys.hashes
    for index in hashes.indices {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.value, hashes[index])]
        guard let cursor = try moment.readPath(path.span), try cursor.readUInt64() == UInt64(index) else {
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
        let pair = try entry.readEntry()
        let value = try pair.value.readUInt64()
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

/// Whether the read and iterate phases run through a snapshot of the
/// database (`--snapshot`).
let readThroughSnapshot = CommandLine.arguments.contains("--snapshot")

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
    let read: (Reading, Keys, Any) throws -> Void
    let iterate: (Reading, Keys, Any) throws -> Void
    /// Checks made after the write phase and after the read phase, off
    /// the clock: what a phase must have done, where checking it would
    /// cost time the phase does not.
    var afterWrite: (Database, Any) throws -> Void = { _, _ in }
    var afterRead: (Database, Any) throws -> Void = { _, _ in }
    /// Whether the read or iterate phase needs the live database, as a
    /// replication's second sync does, which writes, or a snapshot's cost
    /// does, which takes snapshots of it; `--snapshot` leaves such a
    /// workload on the database itself.
    var readPhasesNeedDatabase = false
    /// What the read phase needs put back before it runs, off the clock,
    /// for a phase that changes the database it reads and is run again
    /// on the same one under `--repeat`.
    var beforeRead: (Database, Any) throws -> Void = { _, _ in }

    /// A workload whose write phase fills the prepared database.
    init(
        name: String, size: Int, kinds: [StorageKind], keyKind: Keys.Kind, keyCount: Int,
        write: @escaping (Database, Keys) throws -> Void,
        read: @escaping (Reading, Keys) throws -> Void,
        iterate: @escaping (Reading, Keys) throws -> Void
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
        self.read = { reading, keys, _ in try read(reading, keys) }
        self.iterate = { reading, keys, _ in try iterate(reading, keys) }
    }

    /// A workload whose write phase makes the database it measures, and
    /// whose phases all see what was prepared.
    init(
        name: String, size: Int, kinds: [StorageKind], keyKind: Keys.Kind, keyCount: Int,
        prepare: @escaping (RunStorage, Keys) throws -> Any,
        write: @escaping (RunStorage, Keys, Any) throws -> Database,
        read: @escaping (Reading, Keys, Any) throws -> Void,
        iterate: @escaping (Reading, Keys, Any) throws -> Void
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
        _ = try database.rootCursor.writePath(path.span) { cursor in
            for index in hashes.indices {
                let put: InlineArray<2, PathPart> = [.hashMapGet(.value, hashes[index]), .write(.uint(UInt64(index)))]
                _ = try cursor.writePath(put.span)
            }
        }
    } read: { reading, hashes in
        try readMap(try lastMoment(reading), hashes)
    } iterate: { reading, hashes in
        try iterateMap(try lastMoment(reading), hashes)
    }
}

/// The map of `map_insert` written and read through the public collection
/// by hashes made before the clock starts, each an array as a caller who
/// hashed a key holds it: what `map_by_key` is read against. The two write
/// the same file.
func mapByHash(_ size: Int, kinds: [StorageKind]) -> Workload {
    Workload(name: "map_by_hash", size: size, kinds: kinds, keyKind: .keys, keyCount: size) { database, keys in
        let hashes = keys.hashBytes
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(nil)) { cursor in
            let map = try HashMap<ReadWrite>(cursor)
            for index in hashes.indices {
                try map.put(.uint(UInt64(index)), forHash: hashes[index])
            }
        }
    } read: { reading, keys in
        let hashes = keys.hashBytes
        let map = try HashMap<ReadOnly>(try lastMoment(reading))
        for index in hashes.indices {
            guard try map.cursor(forHash: hashes[index])?.readUInt64() == UInt64(index) else {
                throw BenchmarkFailure(description: "key-\(index) does not read back by its hash")
            }
        }
    } iterate: { reading, keys in
        try iterateMap(try lastMoment(reading), keys)
    }
}

/// The map of `map_by_hash` asked for as many keys that are not in it: a
/// lookup that finds nothing, which the library reports as `nil`. Read
/// against `map_by_hash`'s read, the difference is what a miss costs over a
/// hit. The keys are twice the map's: the first half are written, the
/// second half asked for.
func mapByHashMissing(_ size: Int, kinds: [StorageKind]) -> Workload {
    Workload(name: "map_by_hash_missing", size: size, kinds: kinds, keyKind: .keys, keyCount: 2 * size) {
        database, keys in
        let hashes = keys.hashBytes
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(nil)) { cursor in
            let map = try HashMap<ReadWrite>(cursor)
            for index in 0..<size {
                try map.put(.uint(UInt64(index)), forHash: hashes[index])
            }
        }
    } read: { reading, keys in
        let hashes = keys.hashBytes
        let map = try HashMap<ReadOnly>(try lastMoment(reading))
        for index in size..<(2 * size) {
            guard try map.cursor(forHash: hashes[index]) == nil else {
                throw BenchmarkFailure(description: "key-\(index) was never put and is found")
            }
        }
    } iterate: { reading, _ in
        let map = try HashMap<ReadOnly>(try lastMoment(reading))
        var iterator = try map.iterator()
        var count = 0
        while try iterator.next() != nil { count += 1 }
        guard count == size else {
            throw BenchmarkFailure(description: "the map holds \(count) entries, not \(size)")
        }
    }
}

/// The same map written and read by its keys, on a database that was
/// given SHA-1: each put and each get hashes its key on the clock. Read
/// against `map_by_hash`, the difference is what a keyed call costs over
/// its twin, which `key_hashing` breaks down. The iterate phase checks
/// that the entries are under the SHA-1 of the keys.
func mapByKey(_ size: Int, kinds: [StorageKind]) -> Workload {
    Workload(
        name: "map_by_key", size: size, kinds: kinds, keyKind: .keys, keyCount: size,
        prepare: { storage, _ in
            try Database(
                creating: storage.storage, hashing: Insecure.SHA1.self, hashID: "sha1", fileID: 0x0011_2233_4455_6677)
        },
        write: { _, keys, prepared in
            let database = prepared as! Database
            let strings = keys.strings
            let history = try ArrayList<ReadWrite>(database.rootCursor)
            try history.append(.slot(nil)) { cursor in
                let map = try HashMap<ReadWrite>(cursor)
                for index in strings.indices {
                    try map.put(.uint(UInt64(index)), forKey: strings[index])
                }
            }
            return database
        },
        read: { reading, keys, _ in
            let strings = keys.strings
            let map = try HashMap<ReadOnly>(try lastMoment(reading))
            for index in strings.indices {
                guard try map.cursor(forKey: strings[index])?.readUInt64() == UInt64(index) else {
                    throw BenchmarkFailure(description: "key-\(index) does not read back by its key")
                }
            }
        },
        iterate: { reading, keys, _ in
            try iterateMap(try lastMoment(reading), keys)
        })
}

/// The map of `map_by_key` with every key stored beside its value, in one
/// of the two ways there are: by the one call, the keyed put given
/// `storingKey: true`, or by `putKey` and then the keyed put, which hashes
/// the key twice and walks to the entry twice. The two write the same
/// file. Read against `map_by_key`, the write phase says what storing the
/// keys costs in time, and the file's size what it costs in bytes. The
/// read phase is the read by key, as there. The iterate phase is what the
/// keys are stored for: it reads every entry's key as text and checks
/// that it is the key the value was put under.
func mapStoringKeys(byOneCall: Bool, _ size: Int, kinds: [StorageKind]) -> Workload {
    Workload(
        name: byOneCall ? "map_storing_key" : "map_put_key_then_put",
        size: size, kinds: kinds, keyKind: .keys, keyCount: size,
        prepare: { storage, _ in
            try Database(
                creating: storage.storage, hashing: Insecure.SHA1.self, hashID: "sha1", fileID: 0x0011_2233_4455_6677)
        },
        write: { _, keys, prepared in
            let database = prepared as! Database
            let strings = keys.strings
            let history = try ArrayList<ReadWrite>(database.rootCursor)
            try history.append(.slot(nil)) { cursor in
                let map = try HashMap<ReadWrite>(cursor)
                if byOneCall {
                    for index in strings.indices {
                        try map.put(.uint(UInt64(index)), forKey: strings[index], storingKey: true)
                    }
                } else {
                    for index in strings.indices {
                        try map.putKey(strings[index])
                        try map.put(.uint(UInt64(index)), forKey: strings[index])
                    }
                }
            }
            return database
        },
        read: { reading, keys, _ in
            let strings = keys.strings
            let map = try HashMap<ReadOnly>(try lastMoment(reading))
            for index in strings.indices {
                guard try map.cursor(forKey: strings[index])?.readUInt64() == UInt64(index) else {
                    throw BenchmarkFailure(description: "key-\(index) does not read back by its key")
                }
            }
        },
        iterate: { reading, keys, _ in
            let strings = keys.strings
            let map = try HashMap<ReadOnly>(try lastMoment(reading))
            var iterator = try map.iterator()
            var count = 0
            while let entry = try iterator.next() {
                let pair = try entry.readEntry()
                let value = try pair.value.readUInt64()
                guard value < UInt64(strings.count), try pair.key.read(String.self) == strings[Int(value)] else {
                    throw BenchmarkFailure(description: "an entry's stored key is not the key it was put under")
                }
                count += 1
            }
            guard count == strings.count else {
                throw BenchmarkFailure(description: "the iteration gave \(count) entries")
            }
        })
}

/// A key's bytes, asked for as a collection asks: through the protocol,
/// from code that does not know the key's type.
func keyBytes(of key: some KeyRepresentable) -> [UInt8] {
    key.keyBytes
}

/// What hashing the keys of `map_by_key` costs with no map: in the write
/// phase by hand, as the caller of a call by hash does it (the key's UTF-8
/// in an array, SHA-1, the digest in an array); in the read phase through
/// the hasher a database holds, which is all a keyed call adds to its
/// twin; in the iterate phase the key's bytes alone, the array that
/// `KeyRepresentable` asks a key for. Each phase checks what it made.
func keyHashing(_ size: Int) -> Workload {
    Workload(name: "key_hashing", size: size, kinds: [.memory], keyKind: .keys, keyCount: size) { _, keys in
        let strings = keys.strings
        var matching = 0
        for index in strings.indices {
            let digest = Insecure.SHA1.keyHash(of: strings[index])
            if digest == keys.hashBytes[index] { matching += 1 }
        }
        guard matching == strings.count else {
            throw BenchmarkFailure(description: "\(strings.count - matching) keys hashed by hand to another hash")
        }
    } read: { _, keys in
        let strings = keys.strings
        let hasher = KeyHasher(Insecure.SHA1.self)
        var matching = 0
        for index in strings.indices where hasher.hash(keyBytes(of: strings[index])) == keys.hashes[index] {
            matching += 1
        }
        guard matching == strings.count else {
            throw BenchmarkFailure(description: "\(strings.count - matching) keys hashed by the hasher to another hash")
        }
    } iterate: { _, keys in
        var bytes = 0
        for key in keys.strings {
            bytes += keyBytes(of: key).count
        }
        guard bytes == keys.strings.reduce(0, { $0 + $1.utf8.count }) else {
            throw BenchmarkFailure(description: "the keys' bytes are \(bytes)")
        }
    }
}

func listAppend(_ size: Int, kinds: [StorageKind]) -> Workload {
    Workload(name: "list_append", size: size, kinds: kinds, keyKind: .none, keyCount: 0) { database, _ in
        let path: InlineArray<4, PathPart> = [.arrayListInit, .arrayListAppend, .arrayListInit, .ctx]
        _ = try database.rootCursor.writePath(path.span) { cursor in
            for index in 0..<size {
                let append: InlineArray<2, PathPart> = [.arrayListAppend, .write(.uint(UInt64(index)))]
                _ = try cursor.writePath(append.span)
            }
        }
    } read: { reading, _ in
        let moment = try lastMoment(reading)
        for index in 0..<size {
            let path: InlineArray<1, PathPart> = [.arrayListGet(Int64(index))]
            guard let cursor = try moment.readPath(path.span), try cursor.readUInt64() == UInt64(index) else {
                throw BenchmarkFailure(description: "element \(index) does not read back")
            }
        }
    } iterate: { reading, _ in
        let list = try ArrayList(try lastMoment(reading))
        var iterator = try list.iterator()
        var count: UInt64 = 0
        while let element = try iterator.next() {
            guard try element.readUInt64() == count else {
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
func writeTransactions(
    _ transactions: Int, into database: Database, _ keys: Keys, from first: Int = 0,
    afterCommit: (Database) throws -> Void = { _ in }
) throws {
    let hashes = keys.hashes
    for transaction in first..<(first + transactions) {
        let lastPath: InlineArray<1, PathPart> = [.arrayListGet(-1)]
        let last = try database.rootCursor.readPathSlot(lastPath.span)
        let path: InlineArray<5, PathPart> = [
            .arrayListInit, .arrayListAppend, .write(.slot(last)), .hashMapInit(), .ctx,
        ]
        _ = try database.rootCursor.writePath(path.span) { cursor in
            for index in (transaction * 10)..<(transaction * 10 + 10) {
                let put: InlineArray<2, PathPart> = [
                    .hashMapGet(.value, hashes[index]), .write(.uint(UInt64(index))),
                ]
                _ = try cursor.writePath(put.span)
            }
        }
        try afterCommit(database)
    }
}

/// `map_transactions` with a snapshot taken after every commit and held
/// until the next one: what a writer that publishes each commit to readers
/// pays, which in memory is a copy of the array per commit (D25).
func mapTransactionsSnapshot(_ transactions: Int, kinds: [StorageKind]) -> Workload {
    Workload(
        name: "map_transactions_snapshot", size: transactions, kinds: kinds, keyKind: .hashes,
        keyCount: transactions * 10
    ) { database, keys in
        var held: Snapshot? = nil
        try writeTransactions(transactions, into: database, keys) { database in
            held = try database.snapshot()
        }
        guard let held, held.committedSize == (try database.committedSize) else {
            throw BenchmarkFailure(description: "the last snapshot is not of the last commit")
        }
    } read: { reading, hashes in
        try readMap(try lastMoment(reading), hashes)
    } iterate: { reading, hashes in
        try iterateMap(try lastMoment(reading), hashes)
    }
}

/// The cost of a snapshot, per kind: the write phase makes a database with
/// a map of a thousand keys; the read phase takes `size` snapshots of it,
/// each dropped at once; the iterate phase takes one, opens a database over
/// it and reads one key, `size` times, which is what a task pays to look at
/// a snapshot.
func snapshotTake(_ size: Int, kinds: [StorageKind]) -> Workload {
    var workload = Workload(
        name: "snapshot_take", size: size, kinds: kinds, keyKind: .hashes, keyCount: 1_000
    ) { database, keys in
        let hashes = keys.hashes
        let path: InlineArray<4, PathPart> = [.arrayListInit, .arrayListAppend, .hashMapInit(), .ctx]
        _ = try database.rootCursor.writePath(path.span) { cursor in
            for index in hashes.indices {
                let put: InlineArray<2, PathPart> = [.hashMapGet(.value, hashes[index]), .write(.uint(UInt64(index)))]
                _ = try cursor.writePath(put.span)
            }
        }
    } read: { reading, _ in
        let database = try reading.live()
        for _ in 0..<size {
            _ = try database.snapshot()
        }
    } iterate: { reading, keys in
        let database = try reading.live()
        let hashes = keys.hashes
        for index in 0..<size {
            let pinned = try Reading(snapshotOf: database)
            let key = index % hashes.count
            let path: InlineArray<1, PathPart> = [.hashMapGet(.value, hashes[key])]
            guard let cursor = try lastMoment(pinned).readPath(path.span), try cursor.readUInt64() == UInt64(key)
            else {
                throw BenchmarkFailure(description: "key-\(key) does not read back through a snapshot")
            }
        }
    }
    workload.readPhasesNeedDatabase = true
    return workload
}

func mapTransactions(_ transactions: Int, kinds: [StorageKind]) -> Workload {
    Workload(name: "map_transactions", size: transactions, kinds: kinds, keyKind: .hashes, keyCount: transactions * 10)
    {
        database,
        keys in
        try writeTransactions(transactions, into: database, keys)
    } read: { reading, hashes in
        try readMap(try lastMoment(reading), hashes)
    } iterate: { reading, hashes in
        try iterateMap(try lastMoment(reading), hashes)
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
    } read: { reading, keys, _ in
        try readMap(try lastMoment(reading), keys)
    } iterate: { reading, keys, _ in
        try iterateMap(try lastMoment(reading), keys)
    }
}

/// What a replication run has before the clock starts: the source with
/// `transactions` + 10 transactions, its committed size after the first
/// `transactions` noted, the replica, a new database over the run's
/// storage, and the two buffers the bytes travel through, empty, so that
/// their growth is on the clock.
final class ReplicationRun {
    let sourceStorage: RunStorage
    let source: Database
    let sizeAfterFirst: UInt64
    let replica: Database
    var fullSync: [UInt8] = []
    var incrementalSync: [UInt8] = []
    /// What the incremental sync found, checked off the clock.
    var start: UInt64 = 0
    var end: UInt64 = 0

    init(_ storage: RunStorage, transactions: Int, _ keys: Keys) throws {
        sourceStorage = try RunStorage(storage.kind)
        source = try newDatabase(sourceStorage.storage)
        try writeTransactions(transactions, into: source, keys)
        sizeAfterFirst = try source.committedSize
        try writeTransactions(10, into: source, keys, from: transactions)
        replica = try newDatabase(storage.storage)
    }
}

/// A full sync of the source's first `transactions` transactions into an
/// empty replica, then an incremental sync of the ten after them, the bytes
/// travelling through memory; then a walk of the replica's last moment.
func replicate(_ transactions: Int, kinds: [StorageKind]) -> Workload {
    var workload = Workload(
        name: "replicate", size: transactions, kinds: kinds, keyKind: .hashes, keyCount: (transactions + 10) * 10
    ) { storage, keys in
        try ReplicationRun(storage, transactions: transactions, keys)
    } write: { _, _, prepared in
        let run = prepared as! ReplicationRun
        try run.source.readCommitted(from: 0, to: run.sizeAfterFirst, into: &run.fullSync)
        try run.replica.applyReplicated(at: 0, bytes: run.fullSync)
        return run.replica
    } read: { reading, _, prepared in
        let replica = try reading.live()
        let run = prepared as! ReplicationRun
        run.start = try run.source.replicationStart(for: try replica.replicaState)
        run.end = try run.source.committedSize
        try run.source.readCommitted(from: run.start, to: run.end, into: &run.incrementalSync)
        try replica.applyReplicated(at: run.start, bytes: run.incrementalSync)
    } iterate: { reading, keys, _ in
        try iterateMap(try lastMoment(reading), keys)
    }
    workload.afterWrite = { replica, prepared in
        let run = prepared as! ReplicationRun
        guard try replica.committedSize == run.sizeAfterFirst else {
            throw BenchmarkFailure(description: "the full sync did not bring the replica to the source's size")
        }
    }
    workload.readPhasesNeedDatabase = true
    workload.afterRead = { replica, prepared in
        let run = prepared as! ReplicationRun
        guard run.start == run.sizeAfterFirst else {
            throw BenchmarkFailure(description: "the replica is not a prefix of the source")
        }
        guard try replica.committedSize == run.end else {
            throw BenchmarkFailure(description: "the incremental sync did not bring the replica to the source's size")
        }
    }
    // The read phase syncs the ten transactions and keeps their bytes. Run
    // again on the same replica, it would find nothing to sync and apply
    // the kept bytes a second time, so the replica is put back to the full
    // sync's state and the buffer emptied, and each run does the first
    // run's work.
    workload.beforeRead = { replica, prepared in
        let run = prepared as! ReplicationRun
        if try replica.committedSize != run.sizeAfterFirst {
            try replica.applyReplicated(at: 0, bytes: run.fullSync)
        }
        run.incrementalSync = []
    }
    return workload
}

/// Appends `size` integers to a linked array list in one transaction, reads
/// each back by index, and walks the list.
func linkedAppend(_ size: Int, kinds: [StorageKind]) -> Workload {
    Workload(name: "linked_append", size: size, kinds: kinds, keyKind: .none, keyCount: 0) { database, _ in
        let path: InlineArray<4, PathPart> = [.arrayListInit, .arrayListAppend, .linkedArrayListInit, .ctx]
        _ = try database.rootCursor.writePath(path.span) { cursor in
            for index in 0..<size {
                let append: InlineArray<2, PathPart> = [.linkedArrayListAppend, .write(.uint(UInt64(index)))]
                _ = try cursor.writePath(append.span)
            }
        }
    } read: { reading, _ in
        let moment = try lastMoment(reading)
        for index in 0..<size {
            let path: InlineArray<1, PathPart> = [.linkedArrayListGet(Int64(index))]
            guard let cursor = try moment.readPath(path.span), try cursor.readUInt64() == UInt64(index) else {
                throw BenchmarkFailure(description: "element \(index) does not read back")
            }
        }
    } iterate: { reading, _ in
        let list = try LinkedArrayList(try lastMoment(reading))
        var iterator = try list.iterator()
        var count: UInt64 = 0
        while let element = try iterator.next() {
            guard try element.readUInt64() == count else {
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
        _ = try database.rootCursor.writePath(path.span) { cursor in
            for index in sortedKeys.indices {
                let put: InlineArray<2, PathPart> = [
                    .sortedMapGet(.value, sortedKeys[index]), .write(.uint(UInt64(index))),
                ]
                _ = try cursor.writePath(put.span)
            }
        }
    } read: { reading, keys in
        let moment = try lastMoment(reading)
        let sortedKeys = keys.sortedKeys
        for index in sortedKeys.indices {
            let path: InlineArray<1, PathPart> = [.sortedMapGet(.value, sortedKeys[index])]
            guard let cursor = try moment.readPath(path.span), try cursor.readUInt64() == UInt64(index) else {
                throw BenchmarkFailure(description: "key-\(index) does not read back")
            }
        }
    } iterate: { reading, keys in
        let texts = keys.texts
        let map = try SortedMap(try lastMoment(reading))
        var iterator = try map.iterator()
        var count = 0
        // two buffers of sixteen bytes, the key just read and the one
        // before it, swapped after each entry: nothing is allocated
        var buffer = [UInt8](repeating: 0, count: 16)
        var previous = [UInt8](repeating: 0, count: 16)
        var previousCount = 0
        while let entry = try iterator.next() {
            let pair = try entry.readEntry()
            let value = try pair.value.readUInt64()
            guard value < UInt64(texts.count) else {
                throw BenchmarkFailure(description: "an entry is not one of the keys written")
            }
            var span = buffer.mutableSpan
            let read = try pair.key.readBytes(into: &span)
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

/// `--divide <d>` divides every size by `d`, as the Zig benchmark's does, to
/// check quickly that every workload runs: the gate's smoke run. The sizes
/// then say nothing, and the file sizes no longer match the spec's.
let divide: Int = {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--divide"), index + 1 < arguments.count,
        let value = Int(arguments[index + 1]), value > 0
    else { return 1 }
    return value
}()

/// A workload's size under `--divide`, never below one.
func sized(_ size: Int) -> Int { max(size / divide, 1) }

let usualWorkloads: [Workload] = [
    mapInsert(sized(100_000), kinds: [.memory, .bufferedFile]),
    mapInsert(sized(10_000), kinds: [.file]),
    mapByHash(sized(100_000), kinds: [.memory, .bufferedFile]),
    mapByHashMissing(sized(100_000), kinds: [.memory, .bufferedFile]),
    mapByKey(sized(100_000), kinds: [.memory, .bufferedFile]),
    mapStoringKeys(byOneCall: true, sized(100_000), kinds: [.memory, .bufferedFile]),
    mapStoringKeys(byOneCall: false, sized(100_000), kinds: [.memory, .bufferedFile]),
    keyHashing(sized(100_000)),
    mapByHashSpan(sized(100_000), kinds: [.memory, .bufferedFile]),
    sortedByForm(.span, sized(100_000), kinds: [.memory, .bufferedFile]),
    sortedByForm(.bytes, sized(100_000), kinds: [.memory, .bufferedFile]),
    sortedByForm(.text, sized(100_000), kinds: [.memory, .bufferedFile]),
    mapValues(typed: false, sized(100_000), kinds: [.memory, .bufferedFile]),
    mapValues(typed: true, sized(100_000), kinds: [.memory, .bufferedFile]),
    listValues(typed: false, sized(100_000), kinds: [.memory, .bufferedFile]),
    listValues(typed: true, sized(100_000), kinds: [.memory, .bufferedFile]),
    cursorValues(typed: false, sized(100_000), kinds: [.memory, .bufferedFile]),
    cursorValues(typed: true, sized(100_000), kinds: [.memory, .bufferedFile]),
    cursorValues(typed: false, sized(10_000), kinds: [.file]),
    cursorValues(typed: true, sized(10_000), kinds: [.file]),
    listAppend(sized(1_000_000), kinds: [.memory, .bufferedFile]),
    mapTransactions(sized(2_000), kinds: [.memory, .bufferedFile]),
    linkedAppend(sized(100_000), kinds: [.memory, .bufferedFile]),
    linkedAppend(sized(10_000), kinds: [.file]),
    sortedInsert(sized(100_000), kinds: [.memory, .bufferedFile]),
    sortedInsert(sized(10_000), kinds: [.file]),
    mapCompact(sized(2_000), kinds: [.memory, .bufferedFile]),
    mapCompact(sized(200), kinds: [.file]),
    replicate(sized(2_000), kinds: [.memory, .bufferedFile]),
    replicate(sized(200), kinds: [.file]),
    snapshotTake(sized(10_000), kinds: [.memory, .bufferedFile]),
    snapshotTake(sized(1_000), kinds: [.file]),
    mapTransactionsSnapshot(sized(2_000), kinds: [.memory, .bufferedFile]),
]

/// The workloads of this run: the usual ones, or with `--read-path` the
/// read path's (ReadPath.swift).
let workloads: [Workload] = readPathRun ? readPathWorkloads() : usualWorkloads

func median(_ values: [Double]) -> Double {
    values.sorted()[values.count / 2]
}

/// The three phases of a workload, each by the word the output and the
/// command line have for it.
enum Phase: String, CaseIterable {
    case write, read, iterate
}

/// One line for a phase: the run of median time, with its counts where
/// there are any.
func report(
    _ workload: Workload, _ phase: Phase, _ kind: StorageKind, _ runs: [Measurement], _ fileSize: UInt64
) {
    let middle = runs.sorted { $0.milliseconds < $1.milliseconds }[runs.count / 2]
    var line = String(
        format: #"{"workload": "%@", "phase": "%@", "kind": "%@", "n": %ld, "median_ms": %.6f, "file_size": %llu"#,
        workload.name, phase.rawValue, kind.rawValue, workload.size, middle.milliseconds, fileSize
    )
    if let instructions = middle.instructions, let cycles = middle.cycles {
        line += String(format: #", "instructions": %llu, "cycles": %llu"#, instructions, cycles)
    }
    print(line + "}")
}

/// The one kind of storage to run on, under `--kind <kind>`, or `nil` for
/// every kind a workload has.
let onlyKind: StorageKind? = {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--kind"), index + 1 < arguments.count else { return nil }
    guard let kind = StorageKind(rawValue: arguments[index + 1]) else {
        FileHandle.standardError.write(
            Data("--kind takes memory, file or buffered_file, or with --mapped a mapped kind\n".utf8))
        exit(2)
    }
    return kind
}()

/// The kinds a workload runs on: its own, or with `--mapped` the mapped
/// twins of its file kinds; with `--kind`, the one of them that was named.
func runKinds(_ workload: Workload) -> [StorageKind] {
    let kinds = mappedRun ? workload.kinds.compactMap(\.mapped) : workload.kinds
    return kinds.filter { onlyKind == nil || $0 == onlyKind }
}

/// Whether a workload runs on a kind: one of its own, or the mapped twin
/// of one.
func runs(_ workload: Workload, on kind: StorageKind) -> Bool {
    workload.kinds.contains(kind) || workload.kinds.contains { $0.mapped == kind }
}

func run(_ workload: Workload) throws {
    let keys = Keys(workload.keyKind, count: workload.keyCount)
    for kind in runKinds(workload) {
        var writes: [Measurement] = []
        var reads: [Measurement] = []
        var iterates: [Measurement] = []
        var fileSize: UInt64 = 0
        // Every run starts from a new, empty storage. In memory each of the
        // five is made at its own depth of the stack; on a file the stack's
        // place is lost in the system calls.
        for depth in stackDepths {
            try atStackDepth(kind == .memory ? depth : 0) {
                let storage = try RunStorage(kind)
                let prepared = try workload.prepare(storage, keys)
                var database: Database? = nil
                writes.append(try measured { database = try workload.write(storage, keys, prepared) })
                guard let database else { throw BenchmarkFailure(description: "the write phase gave no database") }
                try workload.afterWrite(database, prepared)
                try workload.beforeRead(database, prepared)
                // With --snapshot the reading phases see one snapshot, taken
                // off the clock, through a fresh read-only database; with
                // --reader, in the read path's mode, a reader of its own on
                // the run's file, where there is one.
                let reading: Reading
                if workload.readPhasesNeedDatabase {
                    reading = Reading(database)
                } else if readThroughReader, storage.path != nil {
                    reading = try Reading(readerOf: storage)
                } else if readThroughSnapshot {
                    reading = try Reading(snapshotOf: database)
                } else {
                    reading = Reading(database)
                }
                if readPathRun {
                    // off the clock: every page a phase reads has been read
                    try workload.read(reading, keys, prepared)
                    try workload.iterate(reading, keys, prepared)
                }
                reads.append(try measured { try workload.read(reading, keys, prepared) })
                try workload.afterRead(database, prepared)
                iterates.append(try measured { try workload.iterate(reading, keys, prepared) })
                // the file as the phases leave it: reads change nothing, and
                // a replication's read phase is its second sync
                let size = try storage.storage.length
                if fileSize != 0 && size != fileSize {
                    throw BenchmarkFailure(description: "\(workload.name) left files of different sizes")
                }
                fileSize = size
            }
        }
        report(workload, .write, kind, writes, fileSize)
        report(workload, .read, kind, reads, fileSize)
        report(workload, .iterate, kind, iterates, fileSize)
    }
}

/// The system calls a file storage made: what `--count` reports per phase.
final class IOCounts {
    var preadCalls = 0
    var preadBytes = 0
    var pwriteCalls = 0
    var pwriteBytes = 0
    var fstatCalls = 0
    var ftruncateCalls = 0

    /// The file's own calls, kept from the first install so that a later
    /// one counts once, not through the counters already there.
    private var base: FileCalls?

    func install(on file: FileStorage) {
        let base = self.base ?? file.calls
        self.base = base
        file.calls.read = {
            (descriptor: Int32, buffer: inout MutableSpan<UInt8>, range: Range<Int>, offset: UInt64)
                throws(XitDBError) -> Int in
            let read = try base.read(descriptor, &buffer, range, offset)
            self.preadCalls += 1
            self.preadBytes += read
            return read
        }
        file.calls.write = { (descriptor: Int32, bytes: Span<UInt8>, offset: UInt64) throws(XitDBError) in
            self.pwriteCalls += 1
            self.pwriteBytes += bytes.count
            try base.write(descriptor, bytes, offset)
        }
        file.calls.length = { (descriptor: Int32) throws(XitDBError) -> UInt64 in
            self.fstatCalls += 1
            return try base.length(descriptor)
        }
        file.calls.setLength = { (descriptor: Int32, length: UInt64) throws(XitDBError) in
            self.ftruncateCalls += 1
            try base.setLength(descriptor, length)
        }
    }

    func report(_ workload: Workload, _ phase: Phase, _ kind: StorageKind) {
        print(
            "counts \(workload.name) \(phase.rawValue) \(kind.rawValue): pread \(preadCalls) calls \(preadBytes) bytes, "
                + "pwrite \(pwriteCalls) calls \(pwriteBytes) bytes, fstat \(fstatCalls), ftruncate \(ftruncateCalls)")
        preadCalls = 0
        preadBytes = 0
        pwriteCalls = 0
        pwriteBytes = 0
        fstatCalls = 0
        ftruncateCalls = 0
    }
}

/// Runs one run of a workload on one kind of storage with the file's system
/// calls counted, and prints the counts of each phase: calls and bytes of
/// pread and pwrite, calls of fstat and ftruncate.
func runCounting(_ workload: Workload, _ kind: StorageKind) throws {
    let keys = Keys(workload.keyKind, count: workload.keyCount)
    let storage = try RunStorage(kind)
    guard let file = storage.file else { throw BenchmarkFailure(description: "a memory storage makes no calls") }
    let counts = IOCounts()
    let prepared = try workload.prepare(storage, keys)
    counts.install(on: file)
    let database = try workload.write(storage, keys, prepared)
    counts.report(workload, .write, kind)
    try workload.afterWrite(database, prepared)
    try workload.beforeRead(database, prepared)
    counts.install(on: file)
    try workload.read(Reading(database), keys, prepared)
    counts.report(workload, .read, kind)
    try workload.afterRead(database, prepared)
    counts.install(on: file)
    try workload.iterate(Reading(database), keys, prepared)
    counts.report(workload, .iterate, kind)
}

/// One phase of one workload timed at every sixteen-byte position of the
/// stack that a page has, `passes` times over, the least time kept for
/// each: `--stack-sweep`. One line of JSON a position, with the stack's
/// offset in its page there, and a last line that says how many positions
/// were reached and how many stand out from the median by more than 5%.
///
/// A level of recursion moves the stack by one frame, and as many levels
/// are run as a page has positions; they reach every position when a frame
/// is an odd number of sixteen bytes, so the one of the two recursions that
/// is so is found first, by where a marker lands.
func stackSweep(_ workload: Workload, _ kind: StorageKind, phase: Phase, passes: Int) throws {
    let page = UInt(getpagesize())
    let levels = Int(page / 16)
    /// How far one level of a recursion moves the stack.
    func frame(byLongerFrames: Bool) throws -> UInt {
        // One closure for both depths: two closures have frames of their own.
        var seen: UInt = 0
        let mark = { seen = stackMarker() }
        try atStackDepth(1, byLongerFrames: byLongerFrames, mark)
        let one = seen
        try atStackDepth(2, byLongerFrames: byLongerFrames, mark)
        return one - seen
    }
    let frames = [try frame(byLongerFrames: false), try frame(byLongerFrames: true)]
    guard let odd = frames.firstIndex(where: { $0 % 16 == 0 && ($0 / 16) % 2 == 1 }) else {
        throw BenchmarkFailure(
            description: "--stack-sweep: its two recursions move the stack by \(frames[0]) and \(frames[1]) bytes a "
                + "level, and neither is an odd number of sixteen, so a sweep would miss positions of the page. "
                + "The compiler lays their frames out otherwise than when this was written: it is "
                + "descend(_:) and descendByLongerFrames(_:) in the benchmark that need another look, not the library.")
    }
    let byLongerFrames = odd == 1

    let keys = Keys(workload.keyKind, count: workload.keyCount)
    var best = [Double](repeating: .infinity, count: levels)
    var offsets = [UInt](repeating: 0, count: levels)
    // The read and iterate phases read one database, written before.
    var written: (database: Database, prepared: Any, storage: RunStorage)?
    if phase != .write {
        let storage = try RunStorage(kind)
        let prepared = try workload.prepare(storage, keys)
        written = (try workload.write(storage, keys, prepared), prepared, storage)
    }
    for _ in 0..<passes {
        for level in 0..<levels {
            var time = 0.0
            if let written {
                if phase == .read { try workload.beforeRead(written.database, written.prepared) }
                let run = phase == .read ? workload.read : workload.iterate
                try atStackDepth(level, byLongerFrames: byLongerFrames) {
                    offsets[level] = stackMarker() % page
                    time = try milliseconds { try run(Reading(written.database), keys, written.prepared) }
                }
            } else {
                let storage = try RunStorage(kind)
                let prepared = try workload.prepare(storage, keys)
                try atStackDepth(level, byLongerFrames: byLongerFrames) {
                    offsets[level] = stackMarker() % page
                    time = try milliseconds { _ = try workload.write(storage, keys, prepared) }
                }
            }
            best[level] = min(best[level], time)
        }
    }
    for level in 0..<levels {
        print(
            String(format: #"{"level": %ld, "page_offset": %lu, "best_ms": %.6f}"#, level, offsets[level], best[level]))
    }
    let middle = median(best)
    let reached = Set(offsets.map { $0 / 16 }).count
    guard reached == levels else {
        throw BenchmarkFailure(
            description: "--stack-sweep reached \(reached) of the page's \(levels) positions: the recursion it chose "
                + "does not move the stack by the same amount at every level. It is the benchmark's recursions that "
                + "need another look, not the library.")
    }
    let above = best.count { $0 > middle * 1.05 }
    print(
        String(
            format: #"{"workload": "%@", "phase": "%@", "kind": "%@", "positions": %ld, "frame_bytes": %lu, "#
                + #""median_ms": %.6f, "least_ms": %.6f, "most_ms": %.6f, "above_5_percent": %ld}"#,
            workload.name, phase.rawValue, kind.rawValue, reached, frames[odd], middle, best.min() ?? 0,
            best.max() ?? 0,
            above))
}

/// Runs one phase of a workload until `seconds` have passed, and prints how
/// often it ran and how long a run took on average. The write phase starts
/// from a new, empty database each time, as it does when it is measured. The
/// read phase reads one database that is written first.
func runRepeatedly(_ workload: Workload, _ kind: StorageKind, phase: Phase, seconds: Double) throws {
    let keys = Keys(workload.keyKind, count: workload.keyCount)
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
    var runs = 0
    var total = 0.0
    switch phase {
    case .read, .iterate:
        let storage = try RunStorage(kind)
        let prepared = try workload.prepare(storage, keys)
        let database = try workload.write(storage, keys, prepared)
        let run = phase == .read ? workload.read : workload.iterate
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if phase == .read { try workload.beforeRead(database, prepared) }
            total += try milliseconds { try run(Reading(database), keys, prepared) }
            runs += 1
        }
    case .write:
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let storage = try RunStorage(kind)
            let prepared = try workload.prepare(storage, keys)
            total += try milliseconds { _ = try workload.write(storage, keys, prepared) }
            runs += 1
        }
    }
    let line = String(
        format: #"{"workload": "%@", "phase": "%@", "kind": "%@", "n": %ld, "runs": %ld, "mean_ms": %.3f}"#,
        workload.name, phase.rawValue, kind.rawValue, workload.size, runs, total / Double(max(runs, 1))
    )
    print(line)
}

let arguments: [String] = {
    var arguments = Array(CommandLine.arguments.dropFirst())
    if let index = arguments.firstIndex(of: "--divide"), index + 1 < arguments.count {
        arguments.removeSubrange(index...(index + 1))
    }
    if let index = arguments.firstIndex(of: "--kind"), index + 1 < arguments.count {
        arguments.removeSubrange(index...(index + 1))
    }
    if let index = arguments.firstIndex(of: "--limit"), index + 1 < arguments.count {
        arguments.removeSubrange(index...(index + 1))
    }
    arguments.removeAll {
        $0 == "--snapshot" || $0 == "--mapped" || $0 == "--map-at-commits" || $0 == "--read-path" || $0 == "--reader"
    }
    return arguments
}()
if readPathRun {
    // a run in the read path's mode is ended when it has taken too long
    alarm(readPathLimit)
}
if arguments.first == "--cold" {
    // the cold lines of the memory map (ColdLines.swift)
    // a failure is said in a line and is status 1: the report is run by
    // people on other machines, who can do nothing with a trap's dump
    do {
        try runColdLines(Array(CommandLine.arguments.dropFirst().drop { $0 != "--cold" }.dropFirst()))
    } catch {
        FileHandle.standardError.write(Data("XitDBBenchmark --cold: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}
if arguments.first == "--hash-cost" {
    runHashCost()
    exit(0)
}
if arguments.first == "--count" {
    guard arguments.count == 3, let workload = workloads.first(where: { $0.name == arguments[1] }),
        let kind = StorageKind(rawValue: arguments[2])
    else {
        FileHandle.standardError.write(Data("usage: XitDBBenchmark --count <workload> <kind>\n".utf8))
        exit(2)
    }
    do {
        try runCounting(workload, kind)
    } catch {
        FileHandle.standardError.write(Data("XitDBBenchmark: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}
if arguments.first == "--stack-sweep" {
    guard
        arguments.count == 4 || arguments.count == 5,
        let kind = StorageKind(rawValue: arguments[2]),
        let workload = workloads.first(where: { $0.name == arguments[1] && runs($0, on: kind) }),
        let phase = Phase(rawValue: arguments[3]),
        let passes = arguments.count == 5 ? Int(arguments[4]) : 3, passes > 0
    else {
        throw BenchmarkFailure(
            description: "usage: --stack-sweep <workload> <kind> <write|read|iterate> [passes]")
    }
    try stackSweep(workload, kind, phase: phase, passes: passes)
} else if arguments.first == "--repeat" {
    guard
        arguments.count == 5,
        let seconds = Double(arguments[1]),
        let kind = StorageKind(rawValue: arguments[3]),
        let workload = workloads.first(where: { $0.name == arguments[2] && runs($0, on: kind) }),
        let phase = Phase(rawValue: arguments[4])
    else {
        throw BenchmarkFailure(description: "usage: --repeat <seconds> <workload> <kind> <write|read|iterate>")
    }
    try runRepeatedly(workload, kind, phase: phase, seconds: seconds)
} else {
    for workload in workloads where arguments.isEmpty || arguments.contains(workload.name) {
        try run(workload)
    }
}
