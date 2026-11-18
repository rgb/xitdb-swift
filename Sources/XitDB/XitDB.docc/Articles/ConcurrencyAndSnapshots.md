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
is how another task reads a database. What reads or writes through a database is not: ``Database``, ``ReadOnlyDatabase``,
``SnapshotDatabase``, ``Cursor``, the collections, ``Entry``, ``CollectionIterator`` and the two iterators that read as they
go, ``EntryIterator`` and ``ElementIterator``, ``ByteReader``, ``ByteWriter`` and the storages. In Swift 6
mode the compiler holds you to it. A database has no lock inside, so do not get around the compiler with
`@unchecked Sendable`.

### Readers and a writer

Each task, or each process, opens a storage and a database of its own: <doc:Storage> shows a reader's, and the lock a writer
takes. A database in memory has no file to share. Its ``MemoryStorage`` belongs to one thread or task at a time, as the
database does; other tasks read it through a snapshot.

Every call does its work on the thread that makes it, and returns when the work is done: nothing in the package is `async`. A
commit to a file at the default durability, ``Durability/full``, waits for the disk twice, which took about 4.1 ms for a small
commit in the table of durability levels (<doc:Transactions#Durability>), and its thread waits with it. On the main actor the
interface stops for that long, and an actor that has no executor of its own runs on the threads that all tasks share, and holds
one of them through each commit. So a writer wants a thread of its own: an actor with an executor of its own, or a thread that
runs only the writer.

### Snapshots

``Database/snapshot()`` takes a ``Snapshot`` of the last commit: its committed size and its root, read and verified
once. A snapshot is `Sendable`, so it can go to any task, and it never refreshes: it reads that commit, whatever the
writer does afterwards. Where it is used, ``Snapshot/rootCursor`` gives a read-only cursor at its root, and
``SnapshotDatabase`` makes a database of it, for compacting or replicating the commit. Neither reads anything. A
snapshot carries the hasher of its database, so what is made from it reads by key as the database does. A
``SnapshotDatabase``, and everything made from a snapshot, belongs to the task that made it, as a ``Database`` does. Two
tasks reading one snapshot share nothing but the snapshot.

Here a database in memory, which has no disk to wait for, is written on the main actor, and a task reads the commit it was
handed:

```swift
// The writer, on the main actor, hands the last commit to a reader.
let snapshot = try database.snapshot()
let reader = Task.detached {
    let history = try ArrayList<ReadOnly>(snapshot.rootCursor)
    let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
    return try moment.value(forKey: "count", as: UInt64.self)!
}

// The writer goes on, and the reader reads the commit it was given.
try history.append(.slot(try history.slot(at: -1))) { cursor in
    try HashMap<ReadWrite>(cursor).put(UInt64(2), forKey: "count")
}
let count = try await reader.value
```

`count` is 1, whichever of the two ran first: the snapshot was taken before the second commit. To see a later commit, take a
new snapshot.

A ``SnapshotDatabase`` has only reading members, and every cursor a snapshot gives is read-only, so nothing can write through
one. Nothing read from a snapshot is ever stale, since nothing runs a transaction on it. Code that only reads can take
`some ReadableDatabase`: a ``Database``, a ``ReadOnlyDatabase`` and a ``SnapshotDatabase`` are each one, as ``ReadableDatabase``
says. The second is the live reader, which follows the file as a writer commits to it (<doc:Storage#The-reader-pattern>); the
third reads the one commit its snapshot pinned. Each look at the file costs the live reader more than a read through a map, and
a snapshot's reads look at nothing: <doc:HowAFileIsRead> says what each costs, and how a live reader pays the look once for each
commit.

``Snapshot/init(_:)`` makes a snapshot of one collection inside a commit, so that one task can find it and hand it to many: the
new snapshot's root cursor is at that collection. It throws because, for a cursor of a live database, it first takes a
snapshot of that database, which reads the root header. A cursor at work that the running transaction has not committed yet
is refused with ``XitDBError/staleCursor``: take the snapshot after the commit.

A snapshot of a database in a file reads the file through the storage's own descriptor, so the file stays open until the storage
and the last snapshot have gone. A file lock is the storage's alone: it is let go when the storage goes, whatever snapshots are
left. A replication sync at 0 through that database brings the new database in a new file, which takes the old one's name, and
the snapshot goes on reading its commit in the old file until it is released. A snapshot of a database in memory keeps its
commit's bytes and reads on as well. What the library does not do of itself, a caller can: a write or a truncation below the
snapshot's committed size through the storage the snapshot was taken from makes every read through the snapshot throw
``XitDBError/snapshotOverwritten`` from then on. Only such a rewrite is seen. One through another storage opened on the same
path, or by another process, is not: the snapshot then reads the changed file at the old offsets, and the checks on what it
reads report damage, or at worst give a wrong value. Through a memory map, a cut below what the snapshot reads ends the process
at the next read there instead, and so does a cut through its own storage while a read through the map is under way on another
thread: see <doc:HowAFileIsRead>. See <doc:Replication>, and <doc:Compaction> for a file replaced while a snapshot reads it.

In memory, a snapshot shares the database's array, and the first write while it lives copies the whole array. So let one
go before the next write when you can, and keep data that is both large and written under readers in a file. The machine
has to hold both for that write: the copy is not checked against the storage's limit and the system is not asked for it
first, so a machine that cannot hold the bytes twice ends the process there, as it does for any array that is copied.

## See Also

- <doc:Storage>
- <doc:Transactions>
- <doc:CloningFreezeAndStaleHandles>
- <doc:DifferencesFromTheOriginal>
