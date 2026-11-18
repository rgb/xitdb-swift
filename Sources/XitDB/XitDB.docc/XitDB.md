# ``XitDB``

An immutable database that runs inside your program, in one file or in memory, and reads and writes the same
files as the original xitdb.

## Overview

XitDB is a Swift port of [xitdb](https://github.com/xit-vcs/xitdb). A database has no schema and no query
language. It is a tree of lists, maps and sets that you nest as you need, read and written a part at a time,
so it can be larger than memory.

A transaction appends what it changes to the end of the file and then rewrites one small header to point at
it. It leaves what is already committed as it is, so every earlier state of the database stays readable. It is usual to keep them
in a list at the root, one element per transaction:

```swift
let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)

let history = try ArrayList<ReadWrite>(database.rootCursor)

for price: UInt64 in [10, 12, 15] {
    try history.append(.slot(try history.slot(at: -1))) { cursor in
        let moment = try HashMap<ReadWrite>(cursor)
        try moment.put(price, forKey: "price")
    }
}
```

Three things in that code are not what you might assume. The database is given the hasher of its keys, `SHA256` from the
package's `XitDBHashing`, and a put stores its value under the key's hash and, unless it is given `storingKey: true`,
not the key, which the original's put never stores: see <doc:Hashing>. A collection is a view of a slot, made from a
cursor, and it comes in a read-only and a read-write form: see <doc:TheCollections>. And the file only grows until you
compact it: see <doc:MomentsAndHistory> for what that costs.

A database whose root header or last trailer is damaged does not open. Opening names the last commit that
verifies, and one explicit call cuts the file back to it, which can lose the commits after it: see <doc:Recovery>.

The package's `XitDBHashing` module, which has documentation of its own, has SHA-256 and SHA-1, the same on every
platform, to give a database as the hasher of its keys. This library imports no Foundation; the package's
`XitDBFoundation` module, with documentation of its own too, is for a program that has it: an error's
`localizedDescription` is then the error's own line, a file storage is opened by a `URL`, and `Data` is a value and a key.
The package's `xitdb-dump` prints a file as it is on disk: see <doc:ReadingAFileWithXitdbDump>.

To start, read the four articles under Essentials in order. After those, each article stands on its own.

## Topics

### Essentials

How a database works, in the order to read it.

- <doc:MomentsAndHistory>
- <doc:Transactions>
- <doc:CursorsAndValues>
- <doc:TheCollections>

### Opening a database

A database keeps its bytes in a storage. ``BufferedFileStorage`` is the one to use for a file, and ``MemoryStorage`` for
a database that needs none. What opening does with a damaged file, how a file is read, how threads and processes share
one, the file and the database a reader opens, neither of which can write, and the snapshot that hands one commit to
other tasks are here too.

- <doc:Storage>
- <doc:HowAFileIsRead>
- <doc:Recovery>
- <doc:ReadingAFileWithXitdbDump>
- <doc:ConcurrencyAndSnapshots>
- ``Database``
- ``ReadOnlyDatabase``
- ``Snapshot``
- ``SnapshotDatabase``
- ``ReadableDatabase``
- ``BufferedFileStorage``
- ``MemoryStorage``
- ``FileStorage``
- ``ReadOnlyFileStorage``
- ``FileAccess``
- ``FileLock``
- ``FileReading``
- ``DatabaseHeader``
- ``HashID``

### Running transactions

Every write happens in a transaction, which commits whole or not at all, and a commit goes as far towards the disk as its
durability says. A copy of something the same transaction wrote needs a freeze, which makes every handle from before it
stale.

- <doc:CloningFreezeAndStaleHandles>
- ``Database/withTransaction(_:)``
- ``Database/rootCursor``
- ``Database/committedSize``
- ``Database/freeze()``
- ``Durability``

### Reading and writing values

A cursor is a position in the database: it reads the value there, and inside a transaction it writes one. An iterator
goes through a collection.

- <doc:Iterating>
- ``Cursor``
- ``ReadOnly``
- ``ReadWrite``
- ``CursorAccess``
- ``StorableValue``
- ``WritableData``
- ``Slot``
- ``Slot/Tag``
- ``Entry``
- ``CollectionIterator``
- ``EntryIterator``
- ``ElementIterator``

### Lists

Elements addressed by position. A list is how a database usually keeps its history.

- ``ArrayList``
- ``LinkedArrayList``

### Maps and sets by key

Values and keys found by the hash of their key, which the database's hasher computes, in no useful order.

- <doc:Hashing>
- ``HashMap``
- ``HashSet``
- ``CountedHashMap``
- ``CountedHashSet``
- ``KeyRepresentable``
- ``KeyHashing``

### Sorted maps and sets

Values and keys held in the order of their bytes, for what has to be sorted or paged through.

- <doc:SortingAndPaginating>
- ``SortedMap``
- ``SortedSet``

### Byte arrays

A byte array is a value like any other, and can be written and read a part at a time.

- <doc:LargeByteArrays>
- ``Bytes``
- ``FormatTag``
- ``ByteWriter``
- ``ByteReader``

### Compacting a database

A new database holding only what the latest moment reaches, which is the way to get space back.

- <doc:Compaction>
- ``OffsetMap``
- ``MemoryOffsetMap``

### Replicating a database

Bringing a copy up to date by sending it the bytes it lacks.

- <doc:Replication>
- ``ReplicaState``
- ``ByteSink``
- ``ByteSource``
- ``ArrayByteSink``
- ``ArrayByteSource``

### Errors

Everything the package throws, grouped by what caused it.

- <doc:Errors>
- ``XitDBError``

### Writing a storage

The protocols a storage of your own conforms to.

- ``WritableStorage``
- ``ReadableStorage``
- ``SyncPoint``

### The original

What this package does differently from xitdb in Zig, and how its names map to the original's.

- <doc:DifferencesFromTheOriginal>
