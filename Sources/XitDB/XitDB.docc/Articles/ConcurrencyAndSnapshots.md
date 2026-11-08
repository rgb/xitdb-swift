# Concurrency and snapshots

Which types can cross between threads and tasks, how readers and a writer share a file, and what a cursor from another
transaction reads.

## Overview

The rule is the original's: each thread or task uses a ``Database`` of its own, and writes come from one of them at a time.
Readers need no lock and can read while the writer commits, because a commit never changes bytes that are already committed.

### What can cross between tasks

Only plain values are `Sendable`: ``Slot`` and its ``Slot/Tag``, ``WritableData``, ``Bytes``, ``FormatTag``, ``HashID``,
``DatabaseHeader``, ``ReplicaState``, ``XitDBError``, ``MemoryOffsetMap``, ``ArrayByteSink``, ``ArrayByteSource``, and the
enums ``Durability``, ``FileAccess``, ``FileLock`` and ``SyncPoint``.

Nothing that reads or writes a database is: ``Database``, ``Cursor``, the collections, ``Entry``, ``CollectionIterator``,
``ByteReader``, ``ByteWriter``, and the storages, whose conformance to `Sendable` is marked unavailable. In Swift 6 mode the
compiler holds you to it. It refuses to share a database between two tasks, and lets one move to another task only when
nothing left behind can use it. A database has no lock inside, so do not get around the compiler with `@unchecked Sendable`.

### Readers and a writer

Each task, or each process, opens a storage and a database of its own. The writer opens the file read-write, and takes the
exclusive lock so that no second writer can start. A reader opens it read-only:

```swift
// A reader: a storage opened read-only, and a database of its own.
let storage = try FileStorage(path: "main.db", access: .readOnly)
let database = try Database(opening: storage)
let history = try ArrayList<ReadOnly>(database.rootCursor)
```

A read through the root looks at the file each time, so a reader sees the writer's commits as they come. A cursor below the
root holds what it found, so everything reached from one comes from one commit:

```swift
// One moment, from one commit, whatever the writer does meanwhile.
let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
let first = try moment.cursor(forHash: sha256("first"))!.readUInt64()
let second = try moment.cursor(forHash: sha256("second"))!.readUInt64()
```

In the test behind these lines, two readers on other tasks read the last moment while a writer committed a hundred more, each
writing the same number under both keys, and no reader ever found the two different.

The lock, the read-only access mode and why a reader that opened the file read-write is a second writer are in <doc:Storage>.

A database in memory has no file to share. Its ``MemoryStorage`` belongs to one thread or task at a time, as the database does,
so no other thread can read it.

### Cursors from other transactions

A cursor belongs to the transaction it was made in, and to the ``Database`` that made it. Once that transaction is over:

- **If it committed**, a read through the cursor reads the commit it came from, which nothing changes, whatever has been committed
  since:

  ```swift
  // A cursor from that commit goes on reading it.
  let count = try map.cursor(forHash: sha256("count"))!
  try map.put(.uint(2), forHash: sha256("count"))
  ```

  `count` still reads 1. A write through such a cursor is refused with ``XitDBError/staleCursor``: see
  <doc:CloningFreezeAndStaleHandles>.
- **If it did not commit**, its bytes were cut off and the next transaction writes in their place, so a read through it is
  refused with ``XitDBError/staleCursor`` too. Only its ``Cursor/slot``, which touches no bytes, still reads.

The ``Database/rootCursor`` is never stale: every read through it looks up the last commit.

### Snapshots

Read snapshots that can be shared between threads and tasks are the next thing planned for the package, and are not here yet.

## See Also

- <doc:Storage>
- <doc:Transactions>
- <doc:CloningFreezeAndStaleHandles>
- <doc:DifferencesFromTheOriginal>
