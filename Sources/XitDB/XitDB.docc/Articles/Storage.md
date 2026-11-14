# Storage

Where a database keeps its bytes: the three storages, how to open a file, and how to write your own.

## Overview

A ``Database`` keeps its bytes in a storage, a flat run of bytes addressed by offset, and it owns that storage: it is the only
thing that writes to it. The storage owns its file and closes it when it goes away and the last ``Snapshot`` of a database in it
has gone.

```swift
// A file, through a buffer: the one to use for a file.
let buffered = try BufferedFileStorage(path: "main.db", access: .create)
```

```swift
// A file, with a system call for every read and write.
let reader = try FileStorage(path: "main.db", access: .readOnly)
```

```swift
// Memory.
let memory = MemoryStorage()
```

The bytes are the same in all three, and a database moves between them without any conversion.

### Which to use

Use ``BufferedFileStorage`` for a database in a file. Writes collect in a window of memory and reach the file together, when it
fills up or a commit syncs. The window holds up to ``BufferedFileStorage/bufferLimit``, 2 MiB by default, and a write larger than
that goes straight to the file.

``FileStorage`` makes a system call for every read and write. That makes writing slower: 100,000 puts in one transaction took
0.64 seconds against the buffered storage's 0.21. Reading came out the same, at about 0.26 seconds for 100,000 lookups, because
the buffer only holds writes, so a storage that is only read has nothing to gain from it. These times are indicative: measured
on 2026-11-07 on one machine, an Apple M4 with its internal SSD on APFS, in a release build with syncing off and the hashes
computed beforehand.

``MemoryStorage`` keeps the bytes in memory. Syncing does nothing, so a commit costs only what it writes. The bytes are a complete
database, so one can be a value to send. There is no decoding step on the other side:

```swift
// A database as a value to send.
let source = MemoryStorage()
let database = try Database(creating: source, hashSize: 32)
let map = try HashMap<ReadWrite>(database.rootCursor)
try map.put(.uint(42), forHash: sha256("answer"))

let bytes = source.bytes

// On the other side there is nothing to decode.
let received = try Database(opening: MemoryStorage(bytes: bytes))
let answers = try HashMap<ReadOnly>(received.rootCursor)
let answer = try answers.cursor(forHash: sha256("answer"))!.readUInt64()
```

A memory storage can have a limit, ``MemoryStorage/maxSize``. A write that would pass it throws
``XitDBError/maxSizeExceeded``, and the transaction fails with it. Set one if what goes in is not under your control: without a
limit, the storage grows as far as it is asked to, and the process ends if the memory cannot be had.

### Opening a file

``FileAccess`` says how to open the file, and there is no default:

| Access | If the file exists | If it does not |
|---|---|---|
| ``FileAccess/readOnly`` | Opens it for reading. Writing fails. | Fails. |
| ``FileAccess/readWrite`` | Opens it. | Fails. |
| ``FileAccess/create`` | Opens it. | Creates it. |
| ``FileAccess/truncate`` | Empties it. | Creates it. |

There is no default because each choice is one you would want to have made on purpose. With ``FileAccess/create`` as the default, a mistyped
path makes an empty file and the program goes on to the next error. With ``FileAccess/readWrite``, the first run of a new program fails.

A failure to open, including a missing file, throws ``XitDBError/storageFailure(errno:)``.

A database is then either opened or created, and these are different calls.
``Database/init(opening:hashSize:)`` throws ``XitDBError/invalidDatabase`` on an empty storage, and
``Database/init(creating:hashSize:hashID:fileID:)`` throws ``XitDBError/storageNotEmpty`` on one with anything in it but what a
creation that did not finish left (see below), so neither can do the other's job by accident. To do either, say so:

```swift
let storage = try BufferedFileStorage(path: "main.db", access: .create)
let database =
    try storage.length == 0
    ? Database(creating: storage, hashSize: 32, hashID: "sha2")
    : Database(opening: storage, hashSize: 32)
```

A creation or a copy that did not finish leaves a storage that is neither empty nor a whole database. A process that died
while creating a database leaves its header and nothing committed. Opening refuses that with ``XitDBError/endOfStream``,
``XitDBError/invalidDatabase`` or, where the first commit's trailer is whole,
``XitDBError/untrustedRootHeader(lastVerified:)``, so the pattern above gets one of those errors. Creating accepts it, for
the same hash size, and creates over it; where the trailer is whole, ``Database/recover(_:)`` finishes the creation instead.
A sync from 0 that did not finish leaves a database without a first commit. If that is longer than a new database, it opens,
for the next sync to replace, as <doc:Replication> says; if not, as when the copy stopped within the first 4,096 bytes
after the headers, it is taken for a creation that did not finish.

A ``Durability`` says how far a commit goes to reach the disk, ``Durability/full`` by default: see <doc:Transactions>.

### Two format versions

A file records the version of the format it was written in, ``DatabaseHeader/version``, and this package reads and writes
versions 1 and 2. A new database is version 2. A version 1 file is read and written as version 1 and stays one: nothing
converts it, though compacting it into a new storage gives a version 2 database (<doc:Compaction>), and so does replacing it
by a sync from a version 2 source (<doc:Replication>). Releases before 0.3.0 write version 1 and refuse version 2 with
``XitDBError/invalidVersion``.

The two differ only in the root header, which follows the 20-byte database header and holds the committed size, the eight
bytes a commit rewrites. In version 1 a copy of the root slot comes first, nine bytes that nothing reads or updates any more,
so the size is at offset 29 and the data starts at 37. In version 2 four bytes of padding come first, so the size is at
offset 24, a multiple of eight, and the data starts at 32. A new database is 57 bytes where a version 1 one is 62.

### The reader pattern

A reader opens the file read-only, with a storage of its own, and reads through read-only collections:

```swift
// The reader: a storage of its own, opened read-only.
let storage = try FileStorage(path: "main.db", access: .readOnly)
let database = try Database(opening: storage)
let list = try ArrayList<ReadOnly>(database.rootCursor)
```

Any number of readers can do this, in other processes or with a ``Database`` of their own on other threads, without locks and
while a writer commits. A read through the root looks at the file each time, so it sees the writer's later commits. Everything
reached from one root comes from one commit, and is not affected by what is committed afterwards.

``Database/rootCursor`` is a ``Cursor`` of ``ReadWrite`` access on every storage, including a read-only one. Pass it straight to a read-only
collection, as above, or take ``Cursor/readOnly`` first. A write through it on a read-only storage fails at once with
``XitDBError/storageFailure(errno:)`` carrying `EBADF`, and it truncates nothing.

The read-only access mode is the protection. A reader that opened the file read-write is a second writer, and making a read-write
collection on its root cursor discards whatever the real writer's transaction has written so far.

### The lock

One writer at a time is your responsibility, and an advisory lock is the tool. A storage takes one if you ask, when it opens, and
holds it until it goes away and the last ``Snapshot`` of a database in it has gone. A snapshot reads through the storage's own
file descriptor, so the file stays open, and the lock held, for as long as one lives:

```swift
// The writer holds an exclusive lock for as long as its storage lives.
let writer = try BufferedFileStorage(
    path: "main.db", access: .create, lock: .exclusive)
```

A ``FileLock`` is never waited for. If it cannot be had at once, opening fails with ``XitDBError/storageFailure(errno:)`` carrying
`EWOULDBLOCK`, and you decide whether to try again. It is advisory, so it keeps out only those who ask for one too. A reader
need not ask: it does not get in the writer's way, and it gets a consistent view without one. A reader that takes a
``FileLock/shared`` lock does keep the writer out.

No lock is taken unless you ask for one. Holding a lock on a file in a shared container while an iOS app is suspended gets the app
terminated, so that decision is left to you, and a snapshot kept alive holds the lock too. Elsewhere on iOS a lock between processes
is moot, since an app's own files are not open to other processes.

### Writing a storage

To keep the bytes anywhere else, write a class that conforms to ``WritableStorage``. This one keeps them in an array:

```swift
// A storage of your own: here, bytes in an array, for all to see.
final class ArrayStorage: WritableStorage {
    private(set) var bytes: [UInt8] = []

    func read(
        into buffer: inout MutableSpan<UInt8>,
        range: Range<Int>,
        at offset: UInt64
    ) throws(XitDBError) -> Int {
        guard offset < UInt64(bytes.count) else { return 0 }
        let start = Int(offset)
        let count = min(range.count, bytes.count - start)
        for index in 0..<count {
            buffer[range.lowerBound + index] = bytes[start + index]
        }
        return count
    }

    var length: UInt64 {
        UInt64(bytes.count)
    }

    func write(_ newBytes: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        guard newBytes.count > 0 else { return }
        let end = Int(offset) + newBytes.count
        if end > bytes.count {
            bytes.append(contentsOf: repeatElement(0, count: end - bytes.count))
        }
        for index in 0..<newBytes.count {
            bytes[Int(offset) + index] = newBytes[index]
        }
    }

    func truncate(to length: UInt64) throws(XitDBError) {
        guard length <= UInt64(bytes.count) else { throw .invalidLength }
        bytes.removeLast(bytes.count - Int(length))
    }

    func flush() throws(XitDBError) {}

    func sync(_ point: SyncPoint) throws(XitDBError) {}
}
```

The engine relies on these points:

- **A read is short only at the end.** Fewer bytes than asked for means the storage ended, and reading at or beyond the end reads
  nothing and is not an error.
- **A write past the end fills the gap with zeros.** A write of no bytes does nothing, whatever the offset.
- **``WritableStorage/truncate(to:)`` only shortens.** A length larger than the current one throws ``XitDBError/invalidLength``.
- **``ReadableStorage/length`` counts what has been written**, including anything not yet flushed.
- **``WritableStorage/sync(_:)`` comes twice in every commit**, a replica's sync included, and three times in a sync at 0,
  which syncs the incoming headers before their data. ``SyncPoint`` says which it is.
  The data has to reach the disk before the header does. A failure of any of them reaches the caller of the transaction.

Report a failure with ``XitDBError/storageFailure(errno:)``. A storage is used from one thread at a time, and it should be a class,
which the protocol requires, since a database and its cursors share the one instance.

## See Also

- ``BufferedFileStorage``
- ``FileStorage``
- ``MemoryStorage``
- <doc:Transactions>
- <doc:Errors>
