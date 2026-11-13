# Concurrency and snapshots

Which types can cross between threads and tasks, how readers and a writer share a file, and how a snapshot hands one
commit to other tasks.

## Overview

The rule is the original's: each thread or task uses a ``Database`` of its own, and writes come from one of them at a time.
Readers need no lock and can read while the writer commits. A commit changes one thing in place, the root header, and a reader
takes only the committed size from it: the root comes from the trailer at that size, once its checksum checks, and that trailer
and everything before it never change.

### What can cross between tasks

Plain values, such as a ``Slot``, a ``ReplicaState`` or an ``XitDBError``, are `Sendable`, and so is a ``Snapshot``, which
is how another task reads a database. What reads or writes through a database is not: ``Database``, ``SnapshotDatabase``, the
storages, ``Cursor``, the collections, and what they give, such as an ``Entry``, a ``CollectionIterator`` or a ``ByteReader``.
In Swift 6 mode the compiler holds you to it. A database has no lock inside, so do not get around the compiler with
`@unchecked Sendable`.

### Readers and a writer

Each task, or each process, opens a storage and a database of its own: <doc:Storage> shows a reader's, and the lock a writer
takes. A database in memory has no file to share. Its ``MemoryStorage`` belongs to one thread or task at a time, as the
database does; other tasks read it through a snapshot.

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

In memory, a snapshot shares the database's array, and the first write while it lives copies the whole array. So let one
go before the next write when you can, and keep data that is both large and written under readers in a file.

## See Also

- <doc:Storage>
- <doc:Transactions>
- <doc:CloningFreezeAndStaleHandles>
- <doc:DifferencesFromTheOriginal>
