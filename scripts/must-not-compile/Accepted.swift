// The other half of `Refused.swift`: the same calls with the number's kind
// spelled, which must compile. `scripts/must-not-compile.sh` type-checks
// this file in the same way, so that a library that was not found, or a
// wrong flag, fails the step and cannot pass for a refusal.

import XitDB

func accepted(
    map: HashMap<ReadWrite>, counted: CountedHashMap<ReadWrite>, sorted: SortedMap<ReadWrite>,
    list: ArrayList<ReadWrite>, linked: LinkedArrayList<ReadWrite>, cursor: inout Cursor<ReadWrite>
) throws {
    // The kind spelled by the type.
    try map.put(UInt64(25), forKey: "age")
    try map.put(25 as Int64, forKey: "age")
    try map.put(-3 as Int64, forKey: "delta")
    let age: UInt64 = 25
    try map.put(age, forKey: "age")
    try counted.put(UInt64(25), forKey: "age")
    try sorted.put(UInt64(25), forKey: "age")
    try sorted.put(Int64(25), forKey: [UInt8]([1, 2]))
    try list.append(UInt64(25))
    try list.put(Int64(25), at: 0)
    try linked.append(UInt64(25))
    try linked.put(UInt64(25), at: 0)
    try linked.insert(Int64(25), at: 0)
    try cursor.write(UInt64(25))

    // The kind spelled by the case.
    try map.put(.uint(25), forKey: "age")
    try map.put(.int(-3), forKey: "delta")
    try list.append(.uint(25))
    try cursor.write(.int(25))

    // A literal with a fraction is the format's float, and so is a
    // `Double` made from an integer literal with the type spelled.
    try map.put(2.5, forKey: "ratio")
    try list.append(2.5)
    let ratio: Double = 25
    try map.put(ratio, forKey: "ratio")

    // An `Int` converted, which says the kind.
    let count = [1, 2, 3].count
    try map.put(UInt64(count), forKey: "count")
    try list.append(Int64(count))

    // Reading as the kinds the format has.
    _ = try map.value(forKey: "age", as: UInt64.self)
    _ = try map.value(forKey: "delta", as: Int64.self)
    _ = try map.value(forKey: "ratio", as: Double.self)
    _ = try sorted.value(forKey: "age", as: UInt64.self)
    _ = try list.value(at: 0, as: Int64.self)
    _ = try linked.value(at: 0, as: UInt64.self)
    _ = try cursor.read(UInt64.self)
    let inferred: UInt64? = try map.value(forKey: "age")
    _ = inferred

    // The other values.
    try map.put("Alice", forKey: "name")
    try list.append([UInt8]([1, 2, 3]))
    try cursor.write(Bytes([1, 2], formatTag: "tg"))
    _ = try map.value(forKey: "name", as: String.self)
}

// The other half of `RefusedUntyped.swift`: the four calls that take a
// closure of the caller's, made where the library's error is declared,
// through `XitDBError.carrying`. No error is spelled on any closure; a
// closure of one expression, one of several statements with a result, and
// several calls under one adapter all compile.

struct AcceptedOwnError: Error {}

func acceptedThroughTheAdapter(
    database: Database, list: ArrayList<ReadWrite>, linked: LinkedArrayList<ReadWrite>, cursor: inout Cursor<ReadWrite>
) throws(XitDBError) {
    try XitDBError.carrying { try database.withTransaction { root in _ = root } }
    let count = try XitDBError.carrying {
        try list.append(.uint(1)) { element in _ = element }
        try linked.append(.uint(1)) { element in
            _ = element
            if try list.count > 5 { throw AcceptedOwnError() }
        }
        return try list.count
    }
    _ = count
    try XitDBError.carrying { try cursor.writeBytes { writer in try writer.write([1, 2, 3]) } }
}

// The walks: a collection's `forEachEntry` or `forEachElement` through the
// adapter, and beside it
// what a typed function makes bare, since it takes no closure: whether a
// collection is empty, and the iterators that give entries and elements
// read as a type.

func acceptedWalks(
    list: ArrayList<ReadOnly>, linked: LinkedArrayList<ReadOnly>,
    map: HashMap<ReadOnly>, set: HashSet<ReadOnly>,
    countedMap: CountedHashMap<ReadOnly>, countedSet: CountedHashSet<ReadOnly>,
    sortedMap: SortedMap<ReadOnly>, sortedSet: SortedSet<ReadOnly>
) throws(XitDBError) -> UInt64 {
    var total: UInt64 = 0
    try XitDBError.carrying {
        try list.forEachElement { element in total += try element.read(UInt64.self) }
        try list.forEachElement(as: UInt64.self) { element in total += element }
        try linked.forEachElement { element in total += try element.read(UInt64.self) }
        try linked.forEachElement(as: UInt64.self) { element in total += element }
        try map.forEachEntry { entry in total += try entry.value.read(UInt64.self) }
        try set.forEachEntry { entry in
            _ = entry
            if total > 5 { throw AcceptedOwnError() }
        }
        try countedMap.forEachEntry { entry in total += try entry.value.read(UInt64.self) }
        try countedSet.forEachEntry { entry in _ = entry }
        try sortedMap.forEachEntry { entry in total += try entry.value.read(UInt64.self) }
        try sortedSet.forEachEntry { entry in _ = entry }
    }

    let empty = [
        try list.isEmpty, try linked.isEmpty, try map.isEmpty, try set.isEmpty, try countedMap.isEmpty,
        try countedSet.isEmpty, try sortedMap.isEmpty, try sortedSet.isEmpty,
    ]
    if empty.allSatisfy({ $0 }) { return 0 }

    var ages = try list.elements(as: UInt64.self)
    while let age = try ages.next() { total += age }
    var inferred: ElementIterator<Int64> = try linked.elements()
    while let delta = try inferred.next() { total += UInt64(delta.magnitude) }
    var entries = try sortedMap.entries()
    while let entry = try entries.next() { total += try entry.value.read(UInt64.self) }
    var members = try set.entries()
    while try members.next() != nil { total += 1 }
    return total
}

// The other half of `RefusedSendable.swift`: what is sent in place of a
// database, a cursor or a collection, with the same helper.

func sent<Value: Sendable & ~Copyable>(_ value: borrowing Value) {}

func acceptedToSend(snapshot: Snapshot, header: DatabaseHeader, slot: Slot, error: XitDBError) {
    sent(snapshot)
    sent(header)
    sent(slot)
    sent(error)
}

// The other half of `RefusedReadOnly.swift`: what a reader does through a
// database opened to be read, where the library's error is declared. Its
// root and everything made from it read; it gives a snapshot to send; and
// it is taken wherever a reader's database is, with its root where the
// root's access is named.

func acceptedReads(path: String, source: Database) throws(XitDBError) -> UInt64 {
    // A reader's file is opened to be read, a type of its own, with no lock
    // also where it is read through a memory map.
    let storage = try ReadOnlyFileStorage(path: path, reading: .memoryMap)
    let database = try ReadOnlyDatabase(opening: storage)
    let map = try HashMap(database.rootCursor)
    var total = try map.cursor(forHash: [UInt8](repeating: 1, count: 32))?.read(UInt64.self) ?? 0
    let list = try ArrayList(database.rootCursor)
    total += try list.count
    var elements = try list.elements(as: UInt64.self)
    while let element = try elements.next() { total += element }
    sent(try database.snapshot())
    total += try database.committedSize

    let reader: any ReadableDatabase<ReadOnly> = database
    total += try reader.rootCursor.count
    let behind: any ReadableDatabase = database.rootCursor.database
    total += try behind.committedSize
    if behind is ReadOnlyDatabase { total += 1 }

    // It is a compaction's source, never its target.
    var offsets = MemoryOffsetMap()
    try database.compact(into: source, offsetMap: &offsets)

    // The storage says how it reads and whether its path still leads to
    // its file, and is a storage to read wherever one is asked for; so is
    // a storage that writes, under the database that only reads.
    if storage.isMemoryMapped, storage.requestedReading == .memoryMap, try storage.isStillAtPath { total += 1 }
    let either: any ReadableStorage = total > 0 ? storage : try FileStorage(path: path, access: .readWrite)
    total += try ReadOnlyDatabase(opening: either).committedSize
    return total
}
