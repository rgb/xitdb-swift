// The lines of the read path: what a read through a storage costs beside
// the same read through a snapshot of it, and through a reader of its own
// on the same file (brief package-36).
//
//     XitDBBenchmark --read-path [--kind <kind>] [--mapped] [--snapshot | --reader]
//                                [--limit <seconds>] [--divide <d>] [workload ...]
//
// `--read-path` is a mode asked for by name. Without it the benchmark is
// what it was: no workload of the usual run has another name, size or line
// for it. With it the workloads are these, AT ONE SIZE ON EVERY KIND of
// storage, where the usual run gives the plain file a tenth of the size and
// so another depth of tree, and each line can be laid beside the same line
// of another kind:
//
//   map_insert     a hash map of 100,000 entries read by hash, and walked
//   list_append    an array list of 1,000,000 numbers read by index, and
//                  walked
//   sorted_insert  a sorted map of 100,000 entries looked up, and walked
//   map_typed      typed reads by key from two maps of 100,000, a number
//                  and a text for each key (the key's hash is on the clock)
//   list_compact   a compaction of a list of 400,000 values of 256 bytes
//                  into a database in memory, so that beside the copy only
//                  the source's reads are on the clock (its line is the
//                  write phase)
//   map_by_root    `map_insert`'s read made through the root cursor each
//   list_by_root   time, and `list_append`'s: what a program pays that
//                  reads through `database.rootCursor` and does not take
//                  the last moment's cursor once. Lay their read phase
//                  beside `map_insert`'s and `list_append`'s.
//
// The kinds are the usual three (`memory`, `buffered_file`, `file`) and,
// with `--mapped`, the two mapped ones (`mapped_buffered_file`,
// `mapped_file`); `--kind` names one. A phase reads through the storage it
// was written through unless `--snapshot` says a snapshot of it or
// `--reader` a reader of its own: a `ReadOnlyFileStorage` opened on the
// file, with no lock, read by file calls or through a map as the kind is,
// under a `ReadOnlyDatabase`. A reader has no buffered form, so the reader
// of a buffered kind is the reader of the plain kind that reads the same
// way. In memory there is no file for a reader to open, and `--reader`
// reads through the storage there.
//
// Every reading phase is run once off the clock before it is timed, so
// that no page is touched for the first time on the clock: these lines are
// the library's path and nothing of the disk's.
//
// BOUNDS. A run in this mode is ended by the system when it has taken
// longer than `--limit` seconds, 1,200 unless given, so that none runs
// without end; and a compaction's target in memory refuses to grow past
// 4 GiB.

import Foundation
import XitDB
import XitDBHashing

/// Whether this run is the read path's (`--read-path`).
let readPathRun = CommandLine.arguments.contains("--read-path")

/// Whether the read and iterate phases run through a reader of its own on
/// the run's file (`--reader`, in the read path's mode).
let readThroughReader = readPathRun && CommandLine.arguments.contains("--reader")

/// The seconds a run in the read path's mode may take: `--limit <seconds>`,
/// or 1,200.
let readPathLimit: UInt32 = {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--limit"), index + 1 < arguments.count,
        let seconds = UInt32(arguments[index + 1]), seconds > 0
    else { return 1_200 }
    return seconds
}()

/// A database that only reads, over a storage opened on a run's file to be
/// read, with no lock, and read as the run's kind is, by file calls or
/// through a map.
///
/// - Throws: A failure for a memory storage, which has no file, and for a
///   mapped kind whose file the library does not map, so that a line that
///   says "mapped" is one.
func readerDatabase(of storage: RunStorage) throws -> ReadOnlyDatabase {
    guard let path = storage.path else {
        throw BenchmarkFailure(description: "a memory storage has no file for a reader of its own to open")
    }
    let file = try ReadOnlyFileStorage(path: path, reading: storage.kind.isMapped ? .memoryMap : .fileCalls)
    guard file.isMemoryMapped == storage.kind.isMapped else {
        throw BenchmarkFailure(description: "the reader's storage is not read as the run's kind is")
    }
    return try ReadOnlyDatabase(opening: file, hashing: Insecure.SHA1.self)
}

extension Reading {
    /// A reader of its own on the run's file, as a reader beside a writer
    /// has one.
    init(readerOf storage: RunStorage) throws {
        root = try readerDatabase(of: storage).rootCursor
        database = nil
    }
}

/// What a compaction of a list has before the clock starts: the source, a
/// list of `elements` values of 256 bytes written in order in one moment, on
/// a storage of the run's kind, and the offset map.
final class ListCompactionRun {
    let sourceStorage: RunStorage
    let source: Database
    var offsetMap = MemoryOffsetMap()

    init(_ kind: StorageKind, elements: Int) throws {
        sourceStorage = try RunStorage(kind)
        source = try newDatabase(sourceStorage.storage)
        let path: InlineArray<4, PathPart> = [.arrayListInit, .arrayListAppend, .arrayListInit, .ctx]
        _ = try source.rootCursor.writePath(path.span) { cursor in
            // 256 bytes that differ from element to element, so that
            // nothing is stored once and pointed at many times
            var bytes = [UInt8](repeating: 0, count: 256)
            for index in 0..<elements {
                var value = UInt64(index) &* 0x9E37_79B9_7F4A_7C15
                for position in 0..<256 {
                    if position < 8 {
                        bytes[position] = UInt8(truncatingIfNeeded: value)
                        value >>= 8
                    } else {
                        bytes[position] = UInt8(truncatingIfNeeded: index)
                    }
                }
                let append: InlineArray<2, PathPart> = [.arrayListAppend, .write(.bytes(bytes))]
                _ = try cursor.writePath(append.span)
            }
        }
    }
}

/// Compacts a list of values of 256 bytes into a database in memory: its
/// write phase is the compaction, with its source read through the source's
/// storage, through a snapshot of it (`--snapshot`) or through a reader of
/// its own (`--reader`). The read phase reads the target's elements by
/// index and the iterate phase walks them, on the target, which is in
/// memory whatever the run's kind.
func listCompact(_ elements: Int, kinds: [StorageKind]) -> Workload {
    var workload = Workload(
        name: "list_compact", size: elements, kinds: kinds, keyKind: .none, keyCount: 0
    ) { storage, _ in
        try ListCompactionRun(storage.kind, elements: elements)
    } write: { _, _, prepared in
        let run = prepared as! ListCompactionRun
        // bounded: a target that would pass four gibibytes fails the run
        let target = MemoryStorage(maxSize: 4 << 30)
        if readThroughReader, run.sourceStorage.path != nil {
            return try readerDatabase(of: run.sourceStorage).compact(
                into: target, fileID: 0x0011_2233_4455_6677, offsetMap: &run.offsetMap)
        }
        if readThroughSnapshot {
            return try SnapshotDatabase(try run.source.snapshot()).compact(
                into: target, fileID: 0x0011_2233_4455_6677, offsetMap: &run.offsetMap)
        }
        return try run.source.compact(into: target, fileID: 0x0011_2233_4455_6677, offsetMap: &run.offsetMap)
    } read: { reading, _, _ in
        let moment = try lastMoment(reading)
        for index in 0..<elements {
            let path: InlineArray<1, PathPart> = [.arrayListGet(Int64(index))]
            guard try moment.readPath(path.span) != nil else {
                throw BenchmarkFailure(description: "element \(index) is not in the target")
            }
        }
    } iterate: { reading, _, _ in
        let list = try ArrayList(try lastMoment(reading))
        var iterator = try list.iterator()
        var count = 0
        while try iterator.next() != nil { count += 1 }
        guard count == elements else { throw BenchmarkFailure(description: "the iteration gave \(count) elements") }
    }
    // the reading phases are the target's, which no snapshot or reader of
    // the run's storage reaches
    workload.readPhasesNeedDatabase = true
    return workload
}

/// `map_insert` with its read phase made through the root cursor each time:
/// the last moment is found anew for every key, which reads the root header
/// and holds it to the storage's length each time.
func mapByRoot(_ size: Int, kinds: [StorageKind]) -> Workload {
    let base = mapInsert(size, kinds: kinds)
    return Workload(
        name: "map_by_root", size: size, kinds: kinds, keyKind: base.keyKind, keyCount: base.keyCount,
        prepare: base.prepare, write: base.write,
        read: { reading, keys, _ in
            let hashes = keys.hashes
            for index in hashes.indices {
                let path: InlineArray<2, PathPart> = [.arrayListGet(-1), .hashMapGet(.value, hashes[index])]
                guard let cursor = try reading.root.readPath(path.span), try cursor.readUInt64() == UInt64(index)
                else { throw BenchmarkFailure(description: "key-\(index) does not read back") }
            }
        }, iterate: base.iterate)
}

/// `list_append` with its read phase made through the root cursor each
/// time.
func listByRoot(_ size: Int, kinds: [StorageKind]) -> Workload {
    let base = listAppend(size, kinds: kinds)
    return Workload(
        name: "list_by_root", size: size, kinds: kinds, keyKind: base.keyKind, keyCount: base.keyCount,
        prepare: base.prepare, write: base.write,
        read: { reading, _, _ in
            for index in 0..<size {
                let path: InlineArray<2, PathPart> = [.arrayListGet(-1), .arrayListGet(Int64(index))]
                guard let cursor = try reading.root.readPath(path.span), try cursor.readUInt64() == UInt64(index)
                else { throw BenchmarkFailure(description: "element \(index) does not read back") }
            }
        }, iterate: base.iterate)
}

/// The workloads of the read path's mode: each at one size on every kind.
func readPathWorkloads() -> [Workload] {
    let kinds: [StorageKind] = [.memory, .bufferedFile, .file]
    return [
        mapInsert(sized(100_000), kinds: kinds),
        listAppend(sized(1_000_000), kinds: kinds),
        sortedInsert(sized(100_000), kinds: kinds),
        mapValues(typed: true, sized(100_000), kinds: kinds),
        listCompact(sized(400_000), kinds: kinds),
        mapByRoot(sized(100_000), kinds: kinds),
        listByRoot(sized(1_000_000), kinds: kinds),
    ]
}
