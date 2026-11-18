// What must not compile, fourth file: a write through a database that was
// opened to be read, and a database that writes over a file that was opened
// to be read.
//
// `ReadOnlyDatabase` has no writing members and its root cursor is
// read-only, and `ReadOnlyFileStorage` is a storage to read and no storage
// to write, so that a reader's wrong write is refused by the compiler, and
// not by the storage when the program runs, as the original refuses it on
// a read-only file. `scripts/must-not-compile.sh` type-checks this file
// against the built library: each marked line must be refused, with the
// compiler's words that follow its mark, and nothing else may be refused.
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

func refusedOverAFileOpenedToBeRead(path: String, storage: ReadOnlyFileStorage, file: FileStorage, bytes: [UInt8]) throws {
    // No access opens a file storage read-only: a file opened to be read is
    // a type of its own.
    _ = try FileStorage(path: path, access: .readOnly)  // must not compile: type 'FileAccess' has no member 'readOnly'
    _ = try BufferedFileStorage(path: path, access: .readOnly)  // must not compile: type 'FileAccess' has no member 'readOnly'

    // No database that writes opens over it or is created in it; it is no
    // storage to recover, to sync onto, to compact into or to buffer.
    _ = try Database(opening: storage)  // must not compile: does not conform to expected type 'WritableStorage'
    _ = try Database(opening: storage, hashSize: 32)  // must not compile: does not conform to expected type 'WritableStorage'
    _ = try Database(creating: storage, hashSize: 32)  // must not compile: does not conform to expected type 'WritableStorage'
    _ = try Database.recover(storage)  // must not compile: does not conform to expected type 'WritableStorage'
    _ = BufferedFileStorage(storage)  // must not compile: cannot convert value of type 'ReadOnlyFileStorage'
    let writable: any WritableStorage = storage  // must not compile: does not conform to specified type 'WritableStorage'
    _ = writable

    // And it has no way to write.
    try storage.write(bytes.span, at: 0)  // must not compile: has no member 'write'
    try storage.truncate(to: 0)  // must not compile: has no member 'truncate'
    try storage.flush()  // must not compile: has no member 'flush'
    try storage.sync(.afterRootHeader)  // must not compile: has no member 'sync'

    // How a file storage was opened is not asked of it.
    _ = file.access  // must not compile: has no member 'access'
}
