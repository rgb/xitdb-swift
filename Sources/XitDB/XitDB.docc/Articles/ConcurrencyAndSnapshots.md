# Concurrency and snapshots

Which types can cross between threads and tasks, how readers and a writer share a file, how a snapshot hands one commit
to other tasks, and what a cursor from another transaction reads.

## Overview

The rule is the original's: each thread or task uses a ``Database`` of its own, and writes come from one of them at a time.
Readers need no lock and can read while the writer commits. A commit changes one thing in place, the root header, and a reader
takes only the committed size from it: the root comes from the trailer at that size, once its checksum checks, and that trailer
and everything before it never change.

### What can cross between tasks

Plain values are `Sendable`: ``Slot`` and its ``Slot/Tag``, ``WritableData``, ``Bytes``, ``FormatTag``, ``HashID``,
``DatabaseHeader``, ``ReplicaState``, ``XitDBError``, ``MemoryOffsetMap``, ``ArrayByteSink``, ``ArrayByteSource``, and the
enums ``Durability``, ``FileAccess``, ``FileLock`` and ``SyncPoint``. So is a ``Snapshot``, which is how another task reads a
database: see <doc:ConcurrencyAndSnapshots#Snapshots>.

Nothing that reads or writes a database is: ``Database``, ``SnapshotDatabase``, ``Cursor``, the collections, ``Entry``,
``CollectionIterator``, ``ByteReader``, ``ByteWriter``, and the storages, whose conformance to `Sendable` is marked
unavailable. In Swift 6 mode the compiler holds you to it. It refuses to share a database between two tasks, and lets one move
to another task only when nothing left behind can use it. A database has no lock inside, so do not get around the compiler with
`@unchecked Sendable`.

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

A database in memory has no file to share. Its ``MemoryStorage`` belongs to one thread or task at a time, as the database
does; other tasks read it through a snapshot.

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
  transaction running, and ``XitDBError/staleCursor`` during a later one: see <doc:Transactions>.
- **If it did not commit**, its bytes were cut off and the next transaction writes in their place, so a read through it is
  refused with ``XitDBError/staleCursor`` too, and so is a read through an iterator or a byte reader made from it before the
  rollback. Only its ``Cursor/slot``, which touches no bytes, still reads.

The ``Database/rootCursor`` is never stale: every read through it looks up the last commit.

### Snapshots

``Database/snapshot()`` takes a ``Snapshot`` of the last commit: its committed size and its root, read and verified once. A
snapshot is `Sendable`, so it can go to any task, and it never refreshes: it reads that commit, whatever the writer does
afterwards. Where it is used, ``Snapshot/rootCursor`` gives a read-only cursor at its root, and ``SnapshotDatabase`` makes a
database of it, for compacting or replicating the commit. Neither reads anything. A ``SnapshotDatabase``, and everything made
from a snapshot, belongs to the task that made it, as a ``Database`` does. Two tasks reading one snapshot share nothing but the snapshot.

Here a database in memory is written on the main actor, and a task reads the commit it was handed:

```swift
// The writer, on the main actor, hands the last commit to a reader.
let snapshot = try database.snapshot()
let reader = Task.detached {
    let history = try ArrayList<ReadOnly>(snapshot.rootCursor)
    let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
    return try moment.cursor(forHash: sha256("count"))!.readUInt64()
}

// The writer goes on, and the reader reads the commit it was given.
try history.append(.slot(try history.slot(at: -1))) { cursor in
    try HashMap<ReadWrite>(cursor).put(.uint(2), forHash: sha256("count"))
}
let count = try await reader.value
```

`count` is 1, whichever of the two ran first: the snapshot was taken before the second commit. To see a later commit, take a
new snapshot.

A ``SnapshotDatabase`` has only reading members, and every cursor a snapshot gives is read-only, so nothing can write through
one. Nothing read from a snapshot is ever stale, since nothing runs a transaction on it. Code that only reads can take
`some ReadableDatabase`: both a ``Database`` and a ``SnapshotDatabase`` are one, as ``ReadableDatabase`` says.

``Snapshot/init(_:)`` makes a snapshot of one collection inside a commit, so that one task can find it and hand it to many: the
new snapshot's root cursor is at that collection. It throws because, for a cursor of a live database, it first takes a
snapshot of that database, which reads the root header. A cursor at work that the running transaction has not committed yet
is refused with ``XitDBError/staleCursor``: take the snapshot after the commit.

A snapshot of a database in a file reads the file through the storage's own descriptor, so the file stays open, and any lock
held, until the storage and the last snapshot have gone. If a replication sync at 0 through that database rewrites the file,
every read through the snapshot from then on, one under way included, throws ``XitDBError/snapshotOverwritten``: take a new
one. A snapshot of a database in memory keeps its commit's bytes and reads on. Only a rewrite through the storage the snapshot
was taken from is seen. One through another storage opened on the same path, or by another process, is not: the snapshot then
reads the new file at the old offsets, and the checks on what it reads report damage, or at worst give a wrong value. A file
lock, when the writer asked for one, keeps out a second opener that asks for the lock too, while the snapshot lives. See <doc:Replication>, and
<doc:Compaction> for a file replaced while a snapshot reads it.

### What a snapshot costs

| | In memory | In a file |
|---|---|---|
| Taking a snapshot | 52 ns | 0.9 µs, two reads |
| A snapshot, a database over it, and one key read | 0.28 µs | 2.8 µs |
| Reads through a snapshot, against the live database | 1 to 7% slower | the same, or up to 3% faster |

On a storage of your own, taking a snapshot copies the committed bytes, which costs their size.

Holding a snapshot across a commit is where memory costs more. A snapshot shares the database's array, and the first write
while it lives copies the whole array, at 17.6 µs per megabyte. After that the database's array is its own again, so one
snapshot held across many commits pays once. Every commit pays only when a snapshot taken since the last write is alive at
each one, as when the writer hands out a new snapshot after every commit. The benchmark does that: a database that grew to
9.66 MB paid about 170 µs for the copy at each commit, against 3.4 µs for the commit itself. On a buffered file the same
thing cost 4%. So let a snapshot of a memory database go before the next write when you can, and keep data that is both
large and written under readers in a file.

These are the package's measurements of 2026-11-08, in a release build. Yours will differ with the machine.

## See Also

- <doc:Storage>
- <doc:Transactions>
- <doc:CloningFreezeAndStaleHandles>
- <doc:DifferencesFromTheOriginal>
