// The battery: what the fuzzer does with one damaged file. It opens the
// file, reads everything reachable, compacts it into memory and reads the
// result, replicates it, writes to a copy through every kind of collection,
// and iterates the last moment in a transaction. Every error is discarded
// with `try?`: the battery checks that the library neither traps nor hangs
// on the file (R23), and nothing about which error it gives or what it
// reads back. The hash size it needs comes from the file's own header.
//
// The damaged bytes are in memory, or, with `--mapped`, in files that are
// read through a memory map: there a damaged pointer or count must still
// give an error, and never a read of a part of the file that is not there,
// which would end the process with a signal.

import XitDB

/// Where the battery keeps the bytes it works on.
struct BatteryPlace {
    /// A directory for the battery's files, which are then read through a
    /// memory map; `nil` for memory.
    let directory: String?

    /// A storage that holds `bytes`, to read a database from.
    func readable(_ bytes: [UInt8]) -> (any WritableStorage)? {
        guard let directory else { return MemoryStorage(bytes: bytes) }
        let path = directory + "/source.db"
        guard put(bytes, at: path) else { return nil }
        return try? FileStorage(path: path, access: .readOnly, durability: .none, lock: .shared, reading: .memoryMap)
    }

    /// A storage that holds `bytes` and may grow by `room` bytes and no
    /// more, to write a database in.
    func writable(_ bytes: [UInt8], room: UInt64, name: String) -> (any WritableStorage)? {
        let limit = UInt64(bytes.count) + room
        guard let directory else { return MemoryStorage(bytes: bytes, maxSize: limit) }
        let path = directory + "/" + name
        guard put(bytes, at: path),
            let file = try? FileStorage(
                path: path, access: .readWrite, durability: .none, lock: .exclusive, reading: .memoryMap)
        else { return nil }
        // A file has no largest size of its own: a damaged count must not
        // fill the disk, so the calls that make the file longer refuse
        // beyond the room, as a memory storage does.
        let write = file.calls.write
        file.calls.write = { (descriptor: Int32, bytes: Span<UInt8>, offset: UInt64) throws(XitDBError) in
            guard offset <= limit, UInt64(bytes.count) <= limit - offset else { throw .maxSizeExceeded }
            try write(descriptor, bytes, offset)
        }
        let setLength = file.calls.setLength
        file.calls.setLength = { (descriptor: Int32, length: UInt64) throws(XitDBError) in
            guard length <= limit else { throw .maxSizeExceeded }
            try setLength(descriptor, length)
        }
        return BufferedFileStorage(file)
    }

    /// Makes the file at `path` hold `bytes` and nothing else.
    private func put(_ bytes: [UInt8], at path: String) -> Bool {
        guard let file = try? FileStorage(path: path, access: .truncate, durability: .none) else { return false }
        return (try? file.write(bytes.span, at: 0)) != nil
    }
}

/// Ten write transactions on `database`, each a new moment that touches one
/// kind of collection: puts, appends, inserts, removals, truncations, a
/// slice and a join, as the kind allows.
func writeEverywhere(_ database: Database) {
    let hashSize = Int(database.header.hashSize)
    let operations: [(HashMap<ReadWrite>) throws -> Void] = [
        { moment in
            try moment.put(.uint(9), forHash: hash("n", hashSize))
        },
        { moment in
            let list = try ArrayList<ReadWrite>(moment.putCursor(forHash: hash("a", hashSize)))
            try list.append(.uint(1))
            try list.put(.uint(2), at: 0)
            try list.truncate(to: 3)
            try list.append(.bytes(Array("a long byte value".utf8)))
        },
        { moment in
            let list = try ArrayList<ReadWrite>(moment.putCursor(forHash: hash("aa", hashSize)))
            try list.append(.uint(1))
            try list.put(.uint(2), at: 100)
            try list.truncate(to: 10)
            try list.truncate(to: 1)
        },
        { moment in
            let linked = try LinkedArrayList<ReadWrite>(moment.putCursor(forHash: hash("l", hashSize)))
            try linked.append(.uint(1))
            try linked.insert(.uint(1), at: 3)
            try linked.remove(at: 7)
            try linked.remove(at: -1)
            try linked.put(.uint(4), at: 1)
            try linked.formSlice(offset: 2, count: 10)
            try linked.append(contentsOf: linked)
            try linked.append(.uint(2))
        },
        { moment in
            let set = try HashSet<ReadWrite>(moment.putCursor(forHash: hash("hs", hashSize)))
            try set.insert(.uint(1), forHash: hash("k1", hashSize))
            try set.remove(forHash: hash("k2", hashSize))
            try set.insert(.uint(1), forHash: hash("new", hashSize))
        },
        { moment in
            let map = try CountedHashMap<ReadWrite>(moment.putCursor(forHash: hash("cm", hashSize)))
            try map.put(.uint(1), forHash: hash("k1", hashSize))
            try map.remove(forHash: hash("k2", hashSize))
            try map.put(.uint(1), forHash: hash("new", hashSize))
        },
        { moment in
            let set = try CountedHashSet<ReadWrite>(moment.putCursor(forHash: hash("cs", hashSize)))
            try set.insert(.uint(1), forHash: hash("k1", hashSize))
            try set.remove(forHash: hash("k2", hashSize))
        },
        { moment in
            let map = try SortedMap<ReadWrite>(moment.putCursor(forHash: hash("sm", hashSize)))
            try map.put(.uint(1), forKey: Array("k1".utf8))
            try map.remove(forKey: Array("k2".utf8))
            try map.put(.uint(1), forKey: Array("new-key-new-key-new-key".utf8))
            for index in 0..<30 {
                try map.put(.uint(1), forKey: Array("kk\(index)".utf8))
            }
        },
        { moment in
            let set = try SortedSet<ReadWrite>(moment.putCursor(forHash: hash("ss", hashSize)))
            try set.insert(Array("new".utf8))
            try set.remove(forKey: Array("s1-long-key-long-key".utf8))
            for index in 0..<30 {
                try set.insert(Array("kk\(index)".utf8))
            }
        },
        { moment in
            try moment.remove(forHash: hash("hs", hashSize))
            try moment.remove(forHash: hash("n", hashSize))
            try moment.putKey(.bytes(Array("x".utf8)), forHash: hash("long", hashSize))
        },
    ]
    guard let history = try? ArrayList<ReadWrite>(database.rootCursor) else { return }
    for operation in operations {
        _ = try? history.append(.slot(try? history.slot(at: -1))) { cursor in
            try operation(try HashMap<ReadWrite>(cursor))
        }
    }
}

/// Runs the battery on the bytes of one file.
func runBattery(on bytes: [UInt8], in place: BatteryPlace) {
    guard let source = place.readable(bytes), let database = try? Database(opening: source) else { return }

    // read everything reachable from the root
    var budget = 3000
    walk(database.rootCursor, hashSize: Int(database.header.hashSize), depth: 0, budget: &budget)

    // through the map, a snapshot reads by another way than its database:
    // its own copy of the segments, up to its commit
    if place.directory != nil, let snapshot = try? database.snapshot() {
        var snapshotBudget = 2000
        walk(snapshot.rootCursor, hashSize: Int(snapshot.header.hashSize), depth: 0, budget: &snapshotBudget)
        _ = try? SnapshotDatabase(snapshot).readCommitted(from: 0, to: snapshot.committedSize)
    }

    // compact into memory, the target capped at 256 MiB, and read the result
    var offsets = MemoryOffsetMap()
    let target = MemoryStorage(maxSize: 1 << 28)
    if let compacted = try? database.compact(into: target, offsetMap: &offsets) {
        var compactedBudget = 2000
        walk(compacted.rootCursor, hashSize: Int(compacted.header.hashSize), depth: 0, budget: &compactedBudget)
    }

    // replicate: the state, the committed bytes, and applying the file to a
    // new database of the same hash size
    _ = try? database.replicaState
    if let end = try? database.committedSize {
        _ = try? database.readCommitted(from: 0, to: end)
        let hashSize = Int(database.header.hashSize)
        if let replica = try? Database(creating: MemoryStorage(), hashSize: hashSize == 0 ? 1 : hashSize) {
            _ = try? replica.applyReplicated(at: 0, bytes: bytes)
        }
    }

    // write on a copy, which may grow by 64 MiB and no more
    if let copy = place.writable(bytes, room: 1 << 26, name: "copy.db"), let writable = try? Database(opening: copy) {
        writeEverywhere(writable)
    }

    // one transaction that opens the last moment for writing, iterates it
    // and reads each entry
    if let secondCopy = place.writable(bytes, room: 1 << 26, name: "second-copy.db"),
        let writable = try? Database(opening: secondCopy)
    {
        _ = try? writable.withTransaction { cursor in
            let history = try ArrayList<ReadWrite>(cursor)
            let moment = try HashMap<ReadWrite>(try history.putCursor(at: -1))
            var iterator = try moment.iterator()
            var visited = 0
            while visited < 100, let entry = try? iterator.next() {
                visited += 1
                _ = try? entry.readEntry()
            }
        }
    }
}
