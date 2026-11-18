// What must not compile, fourth file: a write through a database that was
// opened to be read.
//
// `ReadOnlyDatabase` has no writing members and its root cursor is
// read-only, so that a reader's wrong write is refused by the compiler, and
// not by the storage when the program runs, as it is through a `Database`
// over a storage opened read-only. `scripts/must-not-compile.sh`
// type-checks this file against the built library: each marked line must be
// refused, with the compiler's words that follow its mark, and nothing else
// may be refused.
//
// What such a reader does do, its reads, is in `Accepted.swift`.

import XitDB

func refusedWrites(database: ReadOnlyDatabase, source: Database, storage: FileStorage, bytes: [UInt8]) throws {
    // No transaction, no freeze, no replication onto it, no recovery, and it
    // is no target of a compaction.
    try database.withTransaction { root in _ = root }  // must not compile: has no member 'withTransaction'
    try database.freeze()  // must not compile: has no member 'freeze'
    try database.applyReplicated(at: 0, bytes: bytes)  // must not compile: has no member 'applyReplicated'
    _ = try ReadOnlyDatabase.recover(storage, ignoringRootHeader: false)  // must not compile: has no member 'recover'
    var offsets = MemoryOffsetMap()
    try source.compact(into: database, offsetMap: &offsets)  // must not compile: no exact matches in call to instance method 'compact'

    // Its root is read-only, and so is everything made from it.
    var root = database.rootCursor
    try root.write(.uint(1))  // must not compile: requires the types 'ReadOnly' and 'ReadWrite' be equivalent
    try root.write(UInt64(1))  // must not compile: requires the types 'ReadOnly' and 'ReadWrite' be equivalent
    _ = try HashMap<ReadWrite>(database.rootCursor)  // must not compile: no exact matches in call to initializer
    let map = try HashMap(database.rootCursor)
    try map.put(UInt64(1), forKey: "n")  // must not compile: requires the types 'ReadOnly' and 'ReadWrite' be equivalent
    _ = try map.remove(forKey: "n")  // must not compile: requires the types 'ReadOnly' and 'ReadWrite' be equivalent
    let list = try ArrayList(database.rootCursor)
    try list.append("x")  // must not compile: requires the types 'ReadOnly' and 'ReadWrite' be equivalent

    // It is no `Database`, and a cursor of it does not lead to one.
    let writer: Database = database  // must not compile: cannot convert value of type 'ReadOnlyDatabase'
    let behind: Database = database.rootCursor.database  // must not compile: cannot convert value of type 'any ReadableDatabase'
    _ = (writer, behind)
}
