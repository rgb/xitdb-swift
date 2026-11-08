# Concurrency and snapshots

Which types can cross between threads and tasks, how readers and a writer share a file, and what a cursor from another
transaction reads.

## Overview

The rule is the original's: each thread or task uses a ``Database`` of its own, and writes come from one of them at a time.
Readers need no lock and can read while the writer commits. A commit changes one thing in place, the root header, and a reader
takes only the committed size from it: the root comes from the trailer at that size, once its checksum checks, and that trailer
and everything before it never change.

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
exclusive lock so that no second writer that also asks for the lock can start. A reader opens it read-only:

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

In the test behind these lines, a writer on a task of its own, with a buffered file storage, the exclusive lock and
``Durability/none`` to keep the test quick, committed a hundred moments, each with the same number under both keys. Two readers
on other tasks read the last moment meanwhile, and none ever found the two numbers different, or a moment older than one it had
already read.

The lock, the read-only access mode and why a reader that opened the file read-write is a second writer are in <doc:Storage>.

A database in memory has no file to share. Its ``MemoryStorage`` belongs to one thread or task at a time, as the database does,
so no other thread can read it at the same time.

### Cursors from other transactions

A cursor belongs to the transaction it was made in, and to the ``Database`` that made it. Once that transaction is over:

- **If it committed**, a read through the cursor reads what the cursor saw when it was made or last written through, as any
  cursor read does. Once committed, those bytes never change, whatever is committed since:

  ```swift
  // A cursor from that commit goes on reading it.
  let count = try map.cursor(forHash: sha256("count"))!
  try map.put(.uint(2), forHash: sha256("count"))
  ```

  `count` still reads 1. A write through a read-write cursor kept this way throws ``XitDBError/expectedTxStart`` with no
  transaction running, and ``XitDBError/staleCursor`` during a later one: see <doc:CloningFreezeAndStaleHandles>.
- **If it did not commit**, its bytes were cut off and the next transaction writes in their place, so a read through it is
  refused with ``XitDBError/staleCursor`` too, and so is a read through an iterator or a byte reader made from it before the
  rollback. Only its ``Cursor/slot``, which touches no bytes, still reads.

The ``Database/rootCursor`` is never stale: every read through it looks up the last commit.

### Snapshots

Read snapshots that can be shared between threads and tasks are the next thing planned for the package, and are not here yet.

## See Also

- <doc:Storage>
- <doc:Transactions>
- <doc:CloningFreezeAndStaleHandles>
- <doc:DifferencesFromTheOriginal>
