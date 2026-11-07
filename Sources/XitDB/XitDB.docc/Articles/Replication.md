# Replication

Keeping a copy of a database up to date by sending it the bytes it lacks.

## Overview

Once a transaction has committed, its bytes never change, except for a small header that points at the latest commit. So a
replica that has a prefix of a database's file needs only what follows it. There is no log to ship, no protocol to speak and
no server: a sync is copying bytes.

![A source and its replica, side by side. The replica holds the same bytes as the start of the source, and the bytes it lacks are copied across.](replica.svg)

### A sync

A sync has four steps, two on each side:

```swift
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

After a sync the replica is the same bytes as the source, and that is what a byte-identical replica buys. It is an ordinary
database, so anything that reads the source can read it, with its whole history, and it can be copied, compacted or
promoted to be the source with no conversion. It can be checked by comparing bytes.

For bytes held in memory, ``Database/readCommitted(from:to:)`` and ``Database/applyReplicated(at:bytes:)`` skip the sink and
the source, and go in one copy:

```swift
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

At 0 the replica is replaced by a full copy, and it takes the source's file ID and hash ID. That happens when:

- the replica is a new database, so a replica can start as any empty database with the source's hash size;
- the source has been replaced by a compacted copy, which is a new file;
- the source was restored from an older backup, so the replica is ahead of it;
- the replica has commits of its own.

That last one is why you should only change a replica with ``Database/applyReplicated(at:from:count:)``. Written to directly, it
no longer matches the source, and the next sync replaces it.

### When a sync fails

If a sync at the replica's committed size is interrupted, the replica stays at its last commit. What was written past that is
ignored, and the next sync or transaction discards it, so you just sync again:

```swift
// A connection that drops halfway.
var half = ArrayByteSource(Array(bytes[..<(bytes.count / 2)]))
```

A sync at 0 is the exception. The replica is emptied before the copy begins, so an interrupted one leaves no database:
``Database/committedSize`` and ``Database/replicaState`` throw until a sync at 0 succeeds, and the source has to send from 0
without asking.

If that matters, check for it, and write the copy to a new file, which takes the place of the old one only when it is complete:

```swift
if start == 0 {
    // The whole file is coming. It goes to a new file, which takes the
    // old one's place only once it is complete.
    let storage = try BufferedFileStorage(path: "replica.new", access: .truncate)
    let incoming = try Database(creating: storage, hashSize: 32)
    try incoming.applyReplicated(at: 0, bytes: try source.readCommitted(from: 0, to: end))
}
```

A failed ``Database/applyReplicated(at:from:count:)`` can also mean the bytes were not what they should be:

- ``XitDBError/invalidRange``: a start that is neither 0 nor the replica's committed size. Nothing has changed.
- ``XitDBError/endOfStream``: the source ran out before the count, or claimed to have given more than its buffer holds.
- ``XitDBError/invalidDatabase``: the bytes do not end with a trailer that checks, or at 0 do not hold a database.
- ``XitDBError/truncatedDatabase``: at 0, the bytes stop short of the committed size they record.
- ``XitDBError/invalidHashSize``: at 0, a database with another hash size.

### An earlier commit

``Database/readCommitted(from:to:into:)-(_,_,Sink)`` from 0 to the committed size of any earlier commit gives a complete database as
of that commit, with a root header to match. Keep the committed size at the moment you want, and you can have the file as it was:

```swift
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
