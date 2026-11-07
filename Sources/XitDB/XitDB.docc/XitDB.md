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
let database = try Database(creating: MemoryStorage(), hashSize: 32)

let history = try ArrayList<ReadWrite>(database.rootCursor)

for price: UInt64 in [10, 12, 15] {
    try history.append(.slot(try history.slot(at: -1))) { cursor in
        let moment = try HashMap<ReadWrite>(cursor)
        try moment.put(.uint(price), forHash: sha256("price"))
    }
}
```

Three things in that code are not what you might assume. You hash your own keys, here with a helper
`sha256(_:)`: see <doc:BringYourOwnHashes>. A collection is a view of a slot, made from a cursor, and it comes
in a read-only and a read-write form: see <doc:TheCollections>. And the file only grows until you compact it:
see <doc:MomentsAndHistory> for what that costs.

To start, read <doc:MomentsAndHistory>, then <doc:Transactions>. After that, each article stands on its own.

## Topics

### Essentials

Start with the tutorials, or read how a database works, in this order.

- <doc:/tutorials/XitDB>
- <doc:MomentsAndHistory>
- <doc:Transactions>
- <doc:CursorsAndValues>

### Opening a database

A database keeps its bytes in a storage. ``BufferedFileStorage`` is the one to use for a file, and
``MemoryStorage`` for a database that needs none.

- <doc:Storage>
- ``Database``
- ``BufferedFileStorage``
- ``MemoryStorage``
- ``FileStorage``
- ``FileAccess``
- ``Durability``
- ``FileLock``
- ``DatabaseHeader``
- ``HashID``

### Reading and writing values

A cursor is a position in the database: it reads the value there, and inside a transaction it writes one.

- ``Cursor``
- ``ReadOnly``
- ``ReadWrite``
- ``CursorAccess``
- ``WritableData``
- ``Slot``
- ``Slot/Tag``
- ``Entry``
- ``CollectionIterator``

### Choosing a collection

Eight collections, nested as you like. <doc:TheCollections> says when to use which.

- <doc:TheCollections>

### Lists

Elements addressed by position. A list is how a database usually keeps its history.

- ``ArrayList``
- ``LinkedArrayList``

### Maps and sets by hash

Values and keys found by a hash that you compute. The fastest lookups, in no useful order.

- <doc:BringYourOwnHashes>
- ``HashMap``
- ``HashSet``
- ``CountedHashMap``
- ``CountedHashSet``

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
