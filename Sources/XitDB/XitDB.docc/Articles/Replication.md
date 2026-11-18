# Replication

Keeping a copy of a database up to date by sending it the bytes it lacks.

## Overview

Once a transaction has committed, its bytes do not change, except for a small header that points at the latest commit. No
transaction changes them, since a write through a cursor kept from an earlier one is refused with ``XitDBError/staleCursor``. So a
replica that has a prefix of a database's file needs only what follows it. There is no log to ship, no protocol to speak and no
server: a sync is copying bytes.

![A source and its replica, side by side. The replica holds the same bytes as the start of the source, and the bytes it lacks are copied across.](replica.svg)

### A sync

A sync has four steps, two on each side. `source` is a database with something in it, and `replica` a new one with the same
hash size:

```swift
let replicaStorage = MemoryStorage()
let replica = try Database(creating: replicaStorage, hashSize: 32)

// On the replica: describe what it already has.
let state = try replica.replicaState

// On the source: decide which bytes to send, and write them.
let start = try source.replicationStart(for: state)
let end = try source.committedSize
var sink = ArrayByteSink()
try source.readCommitted(from: start, to: end, into: &sink)

// On the replica: apply them.
var bytes = ArrayByteSource(sink.bytes)
try replica.applyReplicated(at: start, from: &bytes, count: end - start)
```

Over a network, the replica sends its ``ReplicaState``, which is two integers, its ``ReplicaState/committedSize`` and
``ReplicaState/checksum``. The source replies with the start, the count and the bytes. A state read off a wire is made with
``ReplicaState/init(committedSize:checksum:)``.

After a sync the replica is the same bytes as the source, and that is what a byte-identical replica buys. A full copy
does not take the bytes between the database header and the committed size, and leaves zeros there: in a version 2 file that
is padding, zeros in the source too, and in a version 1 file a copy of the root slot that nothing reads, so a version 1
replica can differ from its source there. It is an ordinary database, so anything that reads the source can read it, with
its whole history, and it can be copied, compacted or promoted to be the source with no conversion. It can be checked by
comparing bytes, those aside.

For bytes held in memory, ``Database/readCommitted(from:to:)`` and ``Database/applyReplicated(at:bytes:)`` skip the sink and
the source, and go in one copy:

```swift
let nextState = try replica.replicaState
let nextStart = try source.replicationStart(for: nextState)
let nextEnd = try source.committedSize
let newBytes = try source.readCommitted(from: nextStart, to: nextEnd)
try replica.applyReplicated(at: nextStart, bytes: newBytes)
```

### Streaming

A sink and a source are how to avoid holding the bytes in memory. ``Database/readCommitted(from:to:into:)-(_,_,Sink)`` calls a
``ByteSink`` a chunk at a time, and ``Database/applyReplicated(at:from:count:)`` asks a ``ByteSource`` the same way, so bytes can
go straight onto a connection and come straight off one. These two use a file in place of the connection:

```swift
// Writes what it is given to a file, as it comes.
struct StorageSink: ByteSink {
    let storage: FileStorage
    var position: UInt64 = 0

    mutating func write(_ bytes: Span<UInt8>) throws {
        try storage.write(bytes, at: position)
        position += UInt64(bytes.count)
    }
}
```

```swift
// Reads what it is asked for from a file, a part at a time.
struct StorageSource: ByteSource {
    let storage: FileStorage
    var position: UInt64 = 0

    mutating func read(into buffer: inout MutableSpan<UInt8>) throws -> Int {
        let count = try storage.read(into: &buffer, at: position)
        position += UInt64(count)
        return count
    }
}
```

A source fills the buffer with as many bytes as it has at hand, which may be fewer than the buffer holds, as a socket gives them, and
returns zero only when they have run out. An error thrown by a sink or a source comes out of the call as
``XitDBError/callerError(_:)``, with your error inside it.

### The full sync at 0

``Database/replicationStart(for:)`` gives the replica's committed size if the replica's bytes are a prefix of this database,
and 0 if not. The checksum in a ``ReplicaState`` covers the file's ID and the random ID of the commit, so it identifies both the
file and the history that led there. A state never causes an error; one that does not match anything gives 0.

At 0 the replica is replaced by a full copy, and it takes the source's file ID, hash ID and format version. That happens
whenever the replica's bytes are not a prefix of the source's. For example:

- the replica is a new database, so a replica can start as any empty database with the source's hash size, or it is a replica of
  another database;
- the source has been replaced by a compacted copy, which is a new file;
- the source was restored from an older backup, whether the replica is now ahead of it or it has since committed past the replica;
- the replica has commits of its own.

The comparison goes by the checksum of the replica's last commit. A new database given the source's file ID has the same
first commit as the source, if the source is a version 2 file too, so it is given 57 and not 0, and it keeps its own header.
Leave the file ID to be chosen.

That last case is why you should only change a replica with ``Database/applyReplicated(at:from:count:)``. Written to directly, it
no longer matches the source, and the next sync replaces it.

A sync at 0 onto a file does not rewrite the file. The copy is written into a new file, which is given the replica's name when
it is complete. A ``Snapshot`` taken before the sync has the old file open and goes on reading its commit, after the sync
too, until it is released; the old file's space is freed then. A snapshot of a replica in memory keeps the old bytes and reads
on as well. Take a new snapshot after the sync to read what it brought: see <doc:ConcurrencyAndSnapshots>.

A source can be a ``SnapshotDatabase``, made over a snapshot, so that another task serves the sync while the writer goes on. It serves the whole commit's bytes, even for a snapshot of one collection, since the file is the unit of
replication.

### When a sync fails

If a sync at the replica's committed size is interrupted, the replica stays at its last commit. What was written past that is
ignored, and the next sync or transaction discards it, so you sync again:

```swift
let start = try source.replicationStart(for: try replica.replicaState)
let end = try source.committedSize
let bytes = try source.readCommitted(from: start, to: end)

// A connection that drops halfway.
var half = ArrayByteSource(Array(bytes[..<(bytes.count / 2)]))
```

A sync at 0 is different. It reads and checks the incoming database header before it touches the replica, so a count too
small for the headers, bytes that do not start with a database header, a format version this package does not read, another
hash size, and a source that ends or throws within those first 20 bytes leave the replica as it was. What a copy that fails
after that leaves depends on where the replica is.

On a file, a ``FileStorage`` or a ``BufferedFileStorage``, the copy is written into a new file beside the replica's, named
after it with `.incoming` added, and the new file is given the replica's name only when the copy's committed size has been
written and synced. A copy that fails, or a process that ends in the middle of one, leaves the replica the database it was:
its last commit, and its own ``Database/replicaState``, to which the source answers as before. The new file is removed when
the copy fails. One left by a process that ended is removed by the next full sync, and when the replica is next opened for
writing with ``FileLock/exclusive``; it is the library's own file, no larger than the database, and safe to delete while no
process has the replica open for writing. A full sync onto a file therefore needs room for the old file and the new one
together, and a directory in which the process may create and rename a file: where it may not, the sync fails with
``XitDBError/storageFailure(errno:)`` and the replica is as it was.

The new file is given the old one's permission bits before a byte is written to it, and on Apple's platforms its access control
list, flags and extended attributes, the mark that keeps a file out of backups among them, its data protection class, and its
owner and group where the process may set them; on Linux its owner and group where the process may. Not carried: the file's
other names, a hard link keeping the old file; and on Linux its extended attributes, access control list, security labels and
flags, which a program that sets them sets again after a full sync. A symbolic link at the replica's path stays a link: the new
file takes the name of the file it leads to.

Two writers of one replica without a lock, which one writer at a time rules out, can begin full copies that overlap. The later
one removes the earlier one's new file and makes its own, and the earlier sync then fails with
``XitDBError/storageFailure(errno:)`` carrying `ENOENT`: one copy is lost, and the earlier writer, finding its new file gone,
gives the name to nothing and goes back to the old file. Only a lock keeps two writers' copies apart. A writer that wants a new
file left by a process that ended gone when it opens the replica takes ``FileLock/exclusive``.

In memory, and in a storage of your own, the copy is made in place, as the original makes it. The replica
is emptied, so a copy that fails then leaves a database without a first commit: the incoming header, a committed size of
zero, and what of the data was written. A copy from an array writes all of its bytes before it checks the trailer, so bytes
cut short are all there. A copy from a ``ByteSource`` writes the data in blocks of 4,096 bytes, counted from the end of the
root header, each once all of it has arrived, as the original does, so it leaves the blocks that arrived whole, and one
that stops within the first 4,096 bytes after the headers leaves the headers alone. The replica's
``Database/replicaState`` is a size of zero and a checksum of zero, to which the source answers 0, so the next sync replaces
it; everything else on it throws ``XitDBError/invalidDatabase`` until then. What was written may still hold the source's
earlier commits whole, and ``Database/recover(_:ignoringRootHeader:)`` keeps the last of them, after which the source sends only the rest: see <doc:Recovery>. A
file can hold such a database too, written by the original or by a version of this package up to 0.5.1, which copied onto
files in place. Opened, such a file opens if it is longer than a new database; one no longer than that, such as the headers
alone, is taken for a creation that did not finish, which opening refuses and creating builds over (see <doc:Storage>).

What a file storage does for a full sync can be done by hand, for a replica in a storage of your own that must not be left
without a first commit, or to keep the old file: check for a full sync, and write the copy to a new file, which takes the
place of the old one only when it is complete:

```swift
let start = try source.replicationStart(for: try replica.replicaState)
let end = try source.committedSize

if start == 0 {
    // The whole file is coming. It goes to a new file, which takes the
    // old one's place only once it is complete.
    let storage = try BufferedFileStorage(path: "replica.new", access: .truncate)
    let incoming = try Database(creating: storage, hashSize: 32)
    let bytes = try source.readCommitted(from: 0, to: end)
    try incoming.applyReplicated(at: 0, bytes: bytes)
}
```

### An earlier commit

``Database/readCommitted(from:to:into:)-(_,_,Sink)`` from 0 to the committed size of any earlier commit gives a complete database as
of that commit, with a root header to match. Keep the committed size of the commit you want, and you can have the file as it was.
Here `commit(_:to:)` is a helper that adds a moment:

```swift
let asOfFirstCommit = try source.committedSize
try commit(2, to: history)

let bytes = try source.readCommitted(from: 0, to: asOfFirstCommit)
let copy = try Database(opening: MemoryStorage(bytes: bytes))
```

An end where no commit ends throws ``XitDBError/invalidDatabase``, and one past the committed size throws
``XitDBError/invalidRange``.

## See Also

- ``ReplicaState``
- ``ByteSink``
- ``ByteSource``
- <doc:Compaction>
- <doc:Recovery>
