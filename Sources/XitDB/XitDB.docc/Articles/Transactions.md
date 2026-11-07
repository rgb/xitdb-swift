# Transactions

Grouping writes so that they commit together or not at all, what that does to the file, and what a commit costs.

## Overview

Every write happens in a transaction, and a transaction commits whole or not at all. There are two ways to run
one: give ``Database/withTransaction(_:)`` a body, or write through a collection at the root, where each write
is a transaction of its own. The history pattern of <doc:MomentsAndHistory> is the second kind, with a body.

The examples use `sha256(_:)`, a helper that hashes a string: see <doc:BringYourOwnHashes>.

### Running a transaction

``Database/withTransaction(_:)`` runs its body with a cursor at the root, commits when the body returns, and
gives back what the body returned:

```swift
let total = try database.withTransaction { cursor in
    let map = try HashMap<ReadWrite>(cursor)
    try map.put(.uint(3), forHash: sha256("apples"))
    try map.put(.uint(4), forHash: sha256("pears"))
    return 3 + 4
}
```

If the body throws, nothing it wrote stays, and the error comes out of the call as it was thrown:

```swift
try database.withTransaction { cursor in
    let map = try HashMap<ReadWrite>(cursor)
    try map.put(.uint(0), forHash: sha256("stock"))
    throw OutOfStock()
}
```

The transaction is the only unit of rollback. If an operation inside the body throws, let the error leave the
body. A body that catches it and carries on commits whatever the failed operation had already written.

### A write through the root is a transaction

A collection made from ``Database/rootCursor`` writes through the root, and each such write commits:

```swift
// Two commits: each write through a root collection is a transaction.
let map = try HashMap<ReadWrite>(separately.rootCursor)
try map.put(.uint(3), forHash: sha256("apples"))
try map.put(.uint(4), forHash: sha256("pears"))

// One commit.
try grouped.withTransaction { cursor in
    let map = try HashMap<ReadWrite>(cursor)
    try map.put(.uint(3), forHash: sha256("apples"))
    try map.put(.uint(4), forHash: sha256("pears"))
}
```

The first database is 696 bytes after that and the second 340, and the first has paid for twice as many syncs.
If you make many writes, group them.

``ArrayList/append(_:_:)`` on a list at the root is the same kind of transaction, with a body that runs before
it commits. The body may write as much as it likes, so one element of the list costs one commit.

### The body's cursor

The cursor is `inout` because a write through it changes it: it is a value that remembers what its slot holds,
and the write has to reach the cursor the transaction goes on with.

```swift
try database.withTransaction { cursor in
    try cursor.write(.uint(42))
}
```

Whatever that slot holds when the body returns is the new root. In ``ArrayList/append(_:_:)``, the cursor is at
the new element instead, and the element is what the slot holds. Passing the cursor to a collection's
initialiser, as most bodies do, gives the collection a copy of it, and the collection writes through the same
position.

Reads depend on which cursor they go through. A cursor at the root of the database reads the last commit, so the
transaction's writes do not show there until it commits. The body's cursor, and collections made from it, see
what the transaction has written:

```swift
try history.append(.slot(try history.slot(at: -1))) { cursor in
    // The list at the root has no new element yet: the root is read
    // from the last commit until this one is made.
    let committed = try history.count  // 0

    // The body's cursor sees what the transaction has written.
    let moment = try HashMap<ReadWrite>(cursor)
    try moment.put(.uint(1), forHash: sha256("seen"))
    let seen = try moment.cursor(forHash: sha256("seen"))!.readUInt64()  // 1
}
```

### Where a write is allowed

A write below the root needs a transaction in progress, and a write through the root must not have one in
progress, because it would commit before the transaction ended. Both are errors:

- ``XitDBError/expectedTxStart``: a write through a cursor below the root when no transaction is running.
- ``XitDBError/nestedTopLevelWrite``: a write through the root, or a second ``Database/withTransaction(_:)``,
  while one is running.

A cursor belongs to the transaction that made it. Do not keep one for the next transaction; make a new one from
the root. A collection at the root is the exception, because it reads the root again each time.

### What a commit does to the file

There is no journal and no write-ahead log. A transaction goes like this:

1. It discards any bytes past the committed size, which only an earlier failure can have left there, and appends
   a 9-byte copy of the root slot to work on.
2. The body's writes append to the end of the storage. What the transaction made itself is changed in place;
   anything older is copied first.
3. To commit, it appends a 25-byte trailer: the new root slot, a random commit ID, and a checksum over those, the
   file's ID and the trailer's position.
4. It syncs the storage.
5. It rewrites the root header, 17 bytes at offset 20, with the new root and the new committed size. This is the
   moment the transaction takes effect.
6. It syncs the storage again.

A reader looks only at the root header. It reads the committed size there and takes the root from the trailer
that ends at that size, whose checksum it checks. So a transaction's bytes are invisible until step 5, and a
crash before that leaves bytes that nothing refers to.

Rolling back is cutting those bytes off. When a body throws, the storage goes back to its committed size at once.
If the process died instead, they stay until the next transaction starts, or until a read-write collection is
made on the root cursor, either of which discards them.

### Durability

A file storage is opened with a ``Durability``, which decides what the two syncs do:

```swift
let storage = try BufferedFileStorage(path: "cache.db", access: .create, durability: .none)
```

| Level | The syncs | After a power loss | A small commit took |
|---|---|---|---|
| ``Durability/full`` (the default) | A barrier, then a full flush of the drive | A commit that returned is there | about 4.3 ms |
| ``Durability/ordered`` | A barrier, twice | The file opens; the latest commits may be missing | about 0.3 ms |
| ``Durability/none`` | Nothing | The file may not open at all | about 0.008 ms |

The times are from one machine, an Apple M4 with its internal SSD on APFS, committing one value. Yours will
differ, by a lot on another kind of disk. What to take from them is the ratios: a full flush is expensive, and
it is paid per commit, not per byte.

On Apple platforms a barrier is `F_BARRIERFSYNC` and a full flush is `F_FULLFSYNC`. Plain `fsync` is not a level,
because it promises neither that writes reach the disk in order nor that the drive flushes them. A volume that
does not support a call gets another that keeps what the level promises, and plain `fsync` only when nothing
better is left.

None of the levels matters if only the process crashes: what has been written is in the operating system's hands
by then, and a commit that returned survives at every level. They are about power loss and system crashes.

How to choose:

- Use ``Durability/full`` for data you cannot get back, and group writes to keep the number of commits down.
- Use ``Durability/ordered`` where losing the last few transactions is acceptable and a damaged file is not.
- Use ``Durability/none`` for a file you would delete after a crash anyway, such as a scratch database or a cache.

A ``MemoryStorage`` has nothing to sync, and its commits cost only what they write.

## See Also

- <doc:MomentsAndHistory>
- <doc:CursorsAndValues>
- ``Database``
