# Storage

Where a database keeps its bytes: the storages, how to open a file, and how to write your own.

## Overview

A ``Database`` keeps its bytes in a storage, a flat run of bytes addressed by offset, and it owns that storage: it is the only
thing that writes to it. The storage owns its file and closes it when it goes away and the last ``Snapshot`` of a database in it
has gone, or when it is closed (see Closing a file, below).

```swift
// A file, through a buffer: the one to use for a file.
let buffered = try BufferedFileStorage(path: "main.db", access: .create)
```

```swift
// A file, with a system call for every read and write.
let plain = try FileStorage(path: "main.db", access: .readWrite)
```

```swift
// A file opened to be read: what a reader of the file opens.
let reader = try ReadOnlyFileStorage(path: "main.db")
```

```swift
// Memory.
let memory = MemoryStorage()
```

The bytes are the same in all of them, and a database moves between them without any conversion.

### Which to use

Use ``BufferedFileStorage`` for a database in a file. Writes collect in a window of memory and reach the file together, when it
fills up or a commit syncs. The window holds up to ``BufferedFileStorage/bufferLimit``, 2 MiB by default, and a write larger than
that goes straight to the file.

``FileStorage`` makes a system call for every read and write, unless it reads through a memory map. On one machine that
made 100,000 puts in one transaction about three times as slow as through the buffer, and reading no slower, since the
buffer only holds writes.

``ReadOnlyFileStorage`` is a file opened to be read, for a reader of a file that another database writes and for any
file a program only looks at: see The reader pattern below. It has no way to write, so a ``Database`` does not open over
it, and it has no buffered form, since the buffer only holds writes.

``MemoryStorage`` keeps the bytes in memory. Syncing does nothing, so a commit costs only what it writes. The bytes are a complete
database, so one can be a value to send. There is no decoding step on the other side:

```swift
// A database as a value to send.
let source = MemoryStorage()
let database = try Database(creating: source, hashing: SHA256.self)
let map = try HashMap<ReadWrite>(database.rootCursor)
try map.put(UInt64(42), forKey: "answer")

let bytes = source.bytes

// On the other side there is nothing to decode.
let received = try Database(opening: MemoryStorage(bytes: bytes), hashing: SHA256.self)
let answers = try HashMap<ReadOnly>(received.rootCursor)
let answer = try answers.value(forKey: "answer", as: UInt64.self)
```

A memory storage has a limit, ``MemoryStorage/maxSize``. A write that would pass it throws
``XitDBError/maxSizeExceeded``, and the transaction fails with it. Set one of your own if what goes in is not under your
control, and a position given to ``ByteWriter/seek(to:)`` is part of what goes in.

Where you name none, the limit is the machine's physical memory, ``MemoryStorage/defaultMaxSize``. That one is a guard
against a runaway position, a write far beyond the end, and not a promise that the memory is there: no database held in
memory is larger than the memory, so it refuses no size the machine could hold and refuses at once one it could not.
Three things it does not do. On a phone the system ends an app well below the device's physical memory, so there the
limit that guards is yours. It is the machine's figure and not a container's, nor any other limit the process is under: a
server in a container sets `maxSize` to what the container is given. And a machine with more swap than memory can hold a
larger store: pass `nil`, which is no limit.

With a limit or without, the storage asks the system for the memory before it grows, and a size the system refuses is
``XitDBError/storageFailure(errno:)`` with `ENOMEM`, with nothing changed. That is as far as a process can see. A system
can grant memory it cannot back (macOS grants address space far beyond the machine's memory), and then slows the machine
or ends the process when the bytes are written; nothing inside a process can turn that into an error, and only a limit
refuses such a size.

### Opening a file

``FileAccess`` says how to open a file that is read and written, and there is no default:

| Access | If the file exists | If it does not |
|---|---|---|
| ``FileAccess/readWrite`` | Opens it. | Fails. |
| ``FileAccess/create`` | Opens it. | Creates it. |
| ``FileAccess/truncate`` | Empties it. | Creates it. |

There is no default because each choice is one you would want to have made on purpose. With ``FileAccess/create`` as the default, a mistyped
path makes an empty file and the program goes on to the next error. With ``FileAccess/readWrite``, the first run of a new program fails.

A file that is only to be read is opened as a ``ReadOnlyFileStorage``, which takes no access: it opens the file if it
exists and fails if it does not.

A failure to open, including a missing file, throws ``XitDBError/storageFailure(errno:)``.

A file storage reads its file by file calls unless it is opened with `reading:` for a memory map, which makes a read a copy from
memory: ``FileReading/memoryMap``, the one to take for reads by key, or ``FileReading/memoryMapReadAhead``. A map asks for the
exclusive lock of a storage that writes, and which of the two suits a program depends on whether its file fits in memory: see
<doc:HowAFileIsRead>.

The path is a `String`. A program that has Foundation opens a file by its `URL` with the package's `XitDBFoundation` module,
and on Apple's platforms by a `FilePath`.

A database is then either opened or created, and these are different calls. ``Database/init(opening:hashing:)`` throws
``XitDBError/invalidDatabase`` on an empty storage, and ``Database/init(creating:hashing:hashID:fileID:)`` throws
``XitDBError/storageNotEmpty`` on one with anything in it but what a creation that did not finish left (see below), so
neither can do the other's job by accident. Each is given the hasher of the database's keys; the forms with a hash size
in its place, ``Database/init(opening:hashSize:)`` and ``Database/init(creating:hashSize:hashID:fileID:)``, make a
database that takes hashes alone (see <doc:Hashing>), and open and create the same files. To do either, say so:

```swift
let storage = try BufferedFileStorage(path: "main.db", access: .create)
let database =
    try storage.length == 0
    ? Database(creating: storage, hashing: SHA256.self, hashID: "sha2")
    : Database(opening: storage, hashing: SHA256.self)
```

A creation or a copy that did not finish leaves a storage that is neither empty nor a whole database. A process that died while
creating a database leaves its header and nothing committed. Opening refuses that with ``XitDBError/endOfStream``,
``XitDBError/invalidDatabase`` or, where the first commit's trailer is whole, ``XitDBError/untrustedRootHeader(lastVerified:)``,
so the pattern above gets one of those errors. Creating accepts it, for the same hash size, and creates over it; where the
trailer is whole, ``Database/recover(_:ignoringRootHeader:)`` finishes the creation instead. A sync from 0 that did not finish
leaves a database without a first commit in memory, in a storage of your own, and in a file that the original or a version up to
0.5.1 synced in place; this package's file storages write the copy into a new file and keep the old database. Such a database,
if it is longer than a new one, opens, for the next sync to replace, as <doc:Replication> says; if not, as when a copy from a
``ByteSource`` stopped within its first 4,096 bytes of data, which leaves the headers alone, it is taken for a creation that did
not finish.

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

A reader opens the file to be read, with a storage of its own, a ``ReadOnlyFileStorage``, and a ``ReadOnlyDatabase``
over it:

```swift
// The reader: a storage of its own, opened to be read, and a database that only reads.
let storage = try ReadOnlyFileStorage(path: "main.db")
let database = try ReadOnlyDatabase(opening: storage, hashing: SHA256.self)
let list = try ArrayList(database.rootCursor)
```

Any number of readers can do this, in other processes or with a database of their own on other threads, without locks and while
a writer commits. A read through the root looks at the file each time, so it sees the writer's later commits. Everything reached
from one root comes from one commit, and is not affected by what is committed afterwards. Through a memory map that look costs
several times the read, and by file calls about as much as the read: a reader that reads much takes the last moment's cursor
once for each commit it wants to see, and reads through it, as <doc:HowAFileIsRead> shows.

A ``ReadOnlyDatabase`` has no writing members, and its root is a ``Cursor`` of ``ReadOnly`` access, so the collections made
from it are the read-only ones: a write through a reader does not compile. It reads any ``ReadableStorage``, a storage of
your own that can only read included, and serves what a database serves a reader: a ``Snapshot`` for other tasks, the
reading side of <doc:Replication>, and <doc:Compaction> into a target.

A ``ReadOnlyFileStorage`` is a ``ReadableStorage`` and no ``WritableStorage``, so a ``Database`` does not open over it,
and neither does a recovery or a sync onto it: what the original refuses on a read-only file when the program runs does
not compile here (see <doc:DifferencesFromTheOriginal>). That is the protection. A reader that opens the file to be
written, with a ``Database``, is a second writer: making a read-write collection on its root cursor discards whatever the
real writer's transaction has written so far.

A reader's file and a writer's are two types. A program that decides while it runs whether it only reads holds its
storage as `any ReadableStorage`, and the database that only reads opens over either:

```swift
// Decided while the program runs: either is a storage to read, under a database that only reads.
let storage: any ReadableStorage =
    onlyReads
    ? try ReadOnlyFileStorage(path: "main.db")
    : try BufferedFileStorage(path: "main.db", access: .readWrite)
let database = try ReadOnlyDatabase(opening: storage, hashing: SHA256.self)
```

A reader keeps the file it opened. When the writer brings a new file under the name, as a sync from 0 does
(<doc:Replication>), or a restore or a deployment replaces the file, the reader goes on reading the old one, whole;
``ReadOnlyFileStorage/isStillAtPath`` tells it, and it opens the path again.

### The lock

One writer at a time is your responsibility, and an advisory lock is the tool. A storage takes one if you ask, when it opens, and
holds it until it goes away or is closed. The lock is the storage's alone: a ``Snapshot`` reads through the storage's own file
descriptor, so the file stays open for as long as one lives, but a snapshot holds no lock:

```swift
// The writer holds an exclusive lock for as long as its storage lives.
let writer = try BufferedFileStorage(
    path: "main.db", access: .create, lock: .exclusive)
```

A ``FileLock`` is never waited for. If it cannot be had at once, opening fails with ``XitDBError/storageFailure(errno:)`` carrying
`EWOULDBLOCK`, and you decide whether to try again. It is advisory, so it keeps out only those who ask for one too. A reader need
not ask: it does not get in the writer's way, and it gets a consistent view without one. A reader that takes a ``FileLock/shared``
lock does keep the writer out, and holds that lock until its storage goes away or is closed. A writer
of this package that asks for its lock is refused while any reader holds one; one that waits for its lock, as the writer in the
original's README does, stands still for as long as any reader holds one.

No lock is taken unless you ask for one. Holding a lock on a file in a shared container while an iOS app is suspended gets the app
terminated, so that decision is left to you: let the storage go, or close it, before the app is suspended. Elsewhere on iOS a lock
between processes is moot, since an app's own files are not open to other processes.

### Closing a file

A storage's file is closed when the storage and the last snapshot of a database in it have gone, which is no sooner than the
last reference to its database, a cursor or a collection. A program that has to give a file up at a moment of its own, because
the user removes it, its volume goes away or access to its folder ends, closes the storage:

```swift
// Give the file up now: the lock is let go, and nothing reads or writes through the storage any more.
let closedNow = storage.close()
```

``BufferedFileStorage/close()``, ``FileStorage/close()`` and ``ReadOnlyFileStorage/close()`` let the lock go at once. From then
on whatever reads or writes through the storage throws ``XitDBError/storageClosed``: the storage itself, a database opened over
it, and the cursors, collections and iterators made from that database, as soon as they come to read or write. Nothing ends the
process.

The file is closed at once if no snapshot of a database in it is alive, and `close()` returns `true`. A snapshot is read on
other threads, and a file is not taken from under a read: a snapshot taken before goes on reading its commit and keeps the file
open, `close()` returns `false`, and the file is closed when the last such snapshot goes. Let your snapshots go first where
the file has to be closed now.

Close after a commit. A buffered storage drops what it holds and has not written, and a transaction that is under way fails at
its next write and commits nothing: what it wrote lies past the last commit, where the next writer discards it.

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
