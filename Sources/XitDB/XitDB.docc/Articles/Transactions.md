# Transactions

Grouping writes so that they commit together or not at all, what that does to the file, and what a commit costs.

## Overview

Every write happens in a transaction, and a transaction commits whole or not at all. There are two ways to run
one: give ``Database/withTransaction(_:)`` a body, or write through a collection at the root, where each write
is a transaction of its own. The history pattern of <doc:MomentsAndHistory> is the second kind, with a body.

The examples use `sha256(_:)`, a helper that hashes a string: see <doc:BringYourOwnHashes>.

### Running a transaction

``Database/withTransaction(_:)`` runs its body with a cursor at the root of the transaction, commits when the body
returns, and gives back what the body returned:

```swift
let database = try Database(creating: MemoryStorage(), hashSize: 32)

let total = try database.withTransaction { cursor in
    let map = try HashMap<ReadWrite>(cursor)
    try map.put(.uint(3), forHash: sha256("apples"))
    try map.put(.uint(4), forHash: sha256("pears"))
    return 3 + 4
}
```

If the body throws, nothing it wrote stays, and the error comes out of the call as it was thrown:

```swift
struct OutOfStock: Error {}

try database.withTransaction { cursor in
    let map = try HashMap<ReadWrite>(cursor)
    try map.put(.uint(0), forHash: sha256("stock"))
    throw OutOfStock()
}
```

### When an operation fails inside the body

The transaction is the only unit of rollback: nothing undoes part of one. So an operation that fails after it has
written to the storage poisons its transaction. From then on every write in it is refused with
``XitDBError/poisonedTransaction``, and so is the commit, which means the transaction rolls back when the body returns,
whatever the body did with the error. Reads still work.

```swift
let small = try Database(creating: MemoryStorage(maxSize: 2_000), hashSize: 32)
do {
    try small.withTransaction { cursor in
        let map = try HashMap<ReadWrite>(cursor)
        try map.put(.uint(1), forHash: sha256("small"))
        do {
            // Too large for the storage, and only found out
            // after the entry was written.
            let large = [UInt8](repeating: 7, count: 3_000)
            try map.put(.bytes(large), forHash: sha256("large"))
        } catch XitDBError.maxSizeExceeded {
            // Caught, but the transaction is poisoned:
            // the next write, and the commit, fail.
        }
    }
} catch XitDBError.poisonedTransaction {
    // Nothing of the transaction stays, the small value included.
}
```

Having written means any write the operation issued to the storage, whether or not the bytes it wrote were different. Making
a collection is the one exception: its initialiser writes the collection's slot back even when it copies nothing, and that
alone does not count.

An operation that fails before it writes anything leaves the transaction as it was, and the body can catch the error and go on.
Every guard is of that kind: a write through a stale cursor (see <doc:CloningFreezeAndStaleHandles>), a structural slot, an
index that names no element, a collection of the wrong kind for its slot. What poisons is a failure partway: a storage that fails
or runs out of room, a byte array whose body throws, even with a guard's error such as ``XitDBError/byteWriterOpen``, or an
``ArrayList/append(_:_:)`` whose body throws, as the element is already there. The original commits what such an operation
left: see <doc:DifferencesFromTheOriginal>.

### A write through the root is a transaction

A collection made from ``Database/rootCursor`` writes through the root, and each such write commits:

```swift
let separately = try Database(creating: MemoryStorage(), hashSize: 32)
let grouped = try Database(creating: MemoryStorage(), hashSize: 32)

// Three commits: making the map is one, and each write is another.
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

The first database is 691 bytes after that and the second 335, and the first has paid for three times as many syncs.
If you make many writes, group them.

``ArrayList/append(_:_:)`` on a list at the root is the same kind of transaction, with a body that runs before
it commits. The body may write as much as it likes, so one element of the list costs one commit.

### Where a write is allowed

A write below the root needs a transaction in progress, and a write through the root must not have one in
progress, because it would commit before the transaction ended. Both are errors:

- ``XitDBError/expectedTxStart``: a write through a cursor below the root when no transaction is running.
- ``XitDBError/nestedTopLevelWrite``: a write through the root, or a second ``Database/withTransaction(_:)``,
  while one is running.

A cursor belongs to the transaction that made it. Do not keep one for the next transaction; make a new one from
the root. With no transaction running, a write through it throws ``XitDBError/expectedTxStart``, and during a later
transaction ``XitDBError/staleCursor``. A read through it still works if its transaction committed, and reads what the
cursor saw; if the transaction did not commit, the read is refused with ``XitDBError/staleCursor`` too. A collection at
the root is the exception, because it reads the root again each time.

### What a commit does to the file

There is no journal and no write-ahead log. A transaction goes like this:

1. It discards any bytes past the committed size, which only an earlier failure can have left there, and appends
   a 9-byte copy of the root slot to work on. If the root is a collection, it also readies it as its initialiser does:
   an array list copies its header and first block, 160 bytes; a hash map or set its first block, 144, or 152 if it
   keeps a count; a linked array list or a sorted collection its header, 16.
2. The body's writes append to the end of the storage. What the transaction made itself is changed in place;
   anything older is copied first.
3. To commit, it appends a 25-byte trailer: the new root slot, a random commit ID, and a checksum over those, the
   file's ID and the trailer's position.
4. It syncs the storage.
5. It rewrites the committed size in the root header: eight bytes, at offset 24, or at 29 in a version 1 file (see
   <doc:Storage>). The transaction takes effect here.
6. It syncs the storage again. If this one fails, the call throws, and the commit stands, but it may not survive a crash
   or a power loss.

So a transaction that writes nothing costs 34 bytes with an empty root, 50 with a linked array list or a sorted collection
at the root, 178 with a hash map or set, 186 with a counted one, and 194 with an array list.

A reader looks only at the root header. It reads the committed size there and takes the root from the trailer
that ends at that size, whose checksum it checks. So a transaction's bytes are invisible until step 5, and a
crash before that leaves bytes that nothing refers to.

Rolling back is cutting those bytes off. When a body throws, the storage goes back to its committed size at once, or, if
the storage refuses to be cut, when the next write gets there. If the process died instead, they stay until the next write discards them: a transaction, a replica's sync, or a
read-write collection made on the root cursor.

### Durability

A file storage is opened with a ``Durability``, which decides what the two syncs do:

```swift
let storage = try BufferedFileStorage(
    path: "cache.db", access: .create, durability: .none)
```

| Level | The syncs | After a power loss | A small commit took |
|---|---|---|---|
| ``Durability/full`` (the default) | A barrier, then a full flush of the drive | A commit that returned is there | about 4.3 ms |
| ``Durability/ordered`` | A barrier, twice | The file opens; the latest commits may be missing | 0.3 to 1 ms |
| ``Durability/none`` | Nothing | The file may not open at all | about 0.008 ms |

The times are indicative: measured on 2026-11-07 on one machine, an Apple M4 with its internal SSD on APFS, committing one
value through a ``BufferedFileStorage``. Yours will differ, by a lot on another kind of disk. What to take from them is
the ratios: a full flush is expensive, and it is paid per commit, not per byte.

On Apple platforms a barrier is `F_BARRIERFSYNC` and a full flush is `F_FULLFSYNC`. On Linux there is no barrier call
and `fsync` waits for the drive to flush, so every sync there is a full flush: ``Durability/ordered`` gives what
``Durability/full`` gives, at the same price. ``Durability`` says which calls each level makes, and that a volume that
does not support one gets the next best.

The table has one hole, at every level. A power loss in the middle of rewriting the committed size can leave it
unreadable. Such a file does not open, although its commits are intact behind it: opening refuses it with
``XitDBError/untrustedRootHeader(lastVerified:)``, and ``Database/recover(_:)`` repairs it. See <doc:Recovery>, which also
says what recovering can keep at ``Durability/none``.

None of the levels matters if only the process crashes: what has been written is in the operating system's hands
by then, and a commit that returned survives at every level. They are about power loss and system crashes.

How to choose:

- Use ``Durability/full`` for data you cannot get back, and group writes to keep the number of commits down.
- Use ``Durability/ordered`` where losing the last few transactions is acceptable and a damaged file is not.
- Use ``Durability/none`` for a file you would delete after a crash anyway, such as a scratch database or a cache.

A ``MemoryStorage`` has nothing to sync, and its commits cost only what they write. <doc:Storage> says how a level is
given, along with the rest of how to open a file.

## See Also

- <doc:MomentsAndHistory>
- <doc:CursorsAndValues>
- <doc:CloningFreezeAndStaleHandles>
- <doc:Recovery>
- <doc:Storage>
- ``Database``
