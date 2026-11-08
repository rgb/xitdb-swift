// The battery: what the fuzzer does with one damaged file. It opens the
// file, reads everything reachable, compacts it into memory and reads the
// result, replicates it, writes to a copy through every kind of collection,
// and iterates the last moment in a transaction. Every error is discarded
// with `try?`: the battery checks that the library neither traps nor hangs
// on the file (R23), and nothing about which error it gives or what it
// reads back. The hash size it needs comes from the file's own header.

import XitDB

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
            var linked = try LinkedArrayList<ReadWrite>(moment.putCursor(forHash: hash("l", hashSize)))
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
func runBattery(on bytes: [UInt8]) {
    guard let database = try? Database(opening: MemoryStorage(bytes: bytes)) else { return }

    // read everything reachable from the root
    var budget = 3000
    walk(database.rootCursor, depth: 0, budget: &budget)

    // compact into memory, the target capped at 256 MiB, and read the result
    var offsets = MemoryOffsetMap()
    let target = MemoryStorage(maxSize: 1 << 28)
    if let compacted = try? database.compact(into: target, offsetMap: &offsets) {
        var compactedBudget = 2000
        walk(compacted.rootCursor, depth: 0, budget: &compactedBudget)
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
    let copy = MemoryStorage(bytes: bytes, maxSize: UInt64(bytes.count) + (1 << 26))
    if let writable = try? Database(opening: copy) {
        writeEverywhere(writable)
    }

    // one transaction that opens the last moment for writing, iterates it
    // and reads each entry
    let secondCopy = MemoryStorage(bytes: bytes, maxSize: UInt64(bytes.count) + (1 << 26))
    if let writable = try? Database(opening: secondCopy) {
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
