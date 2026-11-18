# How a file is read

By file calls or through a memory map, which of the two maps suits a program, and what a read through the root costs.

## Overview

A file storage reads its file in one of three ways, said with `reading:` when it is opened and kept for its life. Writes
are file writes whichever it is, and what is read is the same.

- ``FileReading/fileCalls``, the default: every read is a system call. It asks nothing of the file or of its volume.
- ``FileReading/memoryMap``: a read is a copy from memory that the system keeps for the file, and the system is told that
  the file is read in no order.
- ``FileReading/memoryMapReadAhead``: the same map, with nothing told to the system, which reads ahead as it does for any
  file.

```swift
// A reader that reads by key, through a map the system is told is read in no order.
let storage = try ReadOnlyFileStorage(path: "main.db", reading: .memoryMap)
let database = try ReadOnlyDatabase(opening: storage, hashing: SHA256.self)
```

``ReadOnlyFileStorage/requestedReading`` is what was asked, and ``ReadOnlyFileStorage/isMemoryMapped`` what is so. A
file on a volume that is not this machine's own is read by file calls though a map was asked for, with no error, and
`isMemoryMapped` is `false` from the start. A developer meets that first in a folder of the host passed into a Linux
virtual machine, or into a container in one, which Linux mounts as 9p, virtiofs or FUSE (a bind mount on a Linux host
keeps its own kind, and is mapped); the others are a network's file systems, NFS, SMB, Ceph, AFS and Lustre, and GFS2, a
disk shared by a cluster, and on Apple's platforms any volume the system does not call local. What the other side of
such a mount does to the file is not the library's to know. The file is mapped in parts of 64 MB as reads reach them, so
a database takes as much address space as its file is long, and an iOS process has far less of that than one on macOS or
Linux. `false` after `true` means partly: the system refused to map a further part, and that part and what follows are
read by file calls.

A storage that writes, a ``BufferedFileStorage`` or a ``FileStorage``, reads through a map only with `lock: .exclusive`,
which says that it is the file's one writer: a map is sound only for a file that nothing else shortens. Asked for without
it, opening throws ``XitDBError/memoryMapNeedsLock`` before the file is opened. A reader needs no lock for the map, since
it reads through it only what is committed. A file in an iOS app's shared container cannot hold a lock while the app is
suspended, so its writer reads by file calls.

```swift
// The writer: a map needs the exclusive lock.
let writer = try BufferedFileStorage(
    path: "main.db", access: .create, lock: .exclusive, reading: .memoryMap)
```

### What each costs

A read through a map takes about what it takes in memory, and by file calls it takes a system call. Warm, a read, in ns, on
a Mac (an M4, macOS 27.2.1, APFS on its internal SSD) and in a Linux container on it:

| A read | By file calls | Through a map | In memory |
|---|---|---|---|
| A list by index | 1,683 / 935 | 65.9 / 64.9 | 51.6 / 51.1 |
| A map by hash | 1,739 / 1,038 | 129 / 138 | 111 / 120 |
| A list's walk, an element | 34.0 / 30.6 | 16.3 / 20.6 | 16.0 / 20.2 |

The two maps differ only while the file's pages are not in memory. A database is read by following pointers, and a
system left to itself answers a read of a page that is not in memory by bringing in the pages around it as well,
megabytes of them on the Linux machines measured. A process that may hold less memory than its file pays for those with
the pages it needs next. Told that the file is read in no order, the system brings the one page; then a read in file
order, a walk of a large collection, brings a cold file in a page at a time. The library cannot see which program it is
in: whether the file fits is the machine's, and whether it is read by key or walked is the program's. A list of
4,000,000 values of 256 bytes, a file of 1.09 GB, and a map of 3,000,000 gave this:

| | The file fits in memory | The file does not fit |
|---|---|---|
| **Read by key** | Either. `.memoryMap` costs only while the file is brought in: 1,623,000 reads a second on one thread against 1,746,000 (Mac), 1,594,000 against 1,658,000 (container), and over the first twenty seconds 771,000 against 1,098,000 (runner). | **`.memoryMap`.** Left to read ahead under a limit of half the file, 269 reads a second against 35,561, and 132 against 22,782 under a quarter (runner); 1,506 against 253,876 under half (container). |
| **Walked in file order** | **`.memoryMapReadAhead`.** A cold walk of the list took 1.35 s against 1.94 (Mac), 0.19 against 0.72 (container), 0.57 against 6.76 (runner). By file calls it took 2.37 s (Mac) and 1.41 (container). Warm the maps are alike, 0.16 s on the Mac. | No one value serves both. A program that only walks takes `.memoryMapReadAhead`, 0.70 s a walk against 6.40 under half the file (runner). One that also reads by key takes `.memoryMap` and pays at every walk, which never finds its pages in memory. |

So `.memoryMap` is the one to take unless the database is known to fit and to be walked: its worst case is a tax on a
cold walk, the other's is a cliff. In doubt take `.memoryMap`, whose price is a cold walk in file order and which does
not collapse when the file outgrows memory. The stream of committed bytes that feeds a replica,
``Database/readCommitted(from:to:into:)-(_,_,Sink)``, reads by file calls either way, as the system reads ahead of them.

The Mac's and the container's figures are of this release, taken on 2026-11-18; "under half" is a container held to half
the file's size in memory. The container's cold page comes from the Mac's memory, so its cold reads are not a disk's.
The runner is Linux in a virtual machine on a Ryzen 7 PRO 5750GE, 4 processors, 7.9 GB, ext4 on a virtual disk that
reads ahead by 8 MB, in a container with no limit and held to half and to a quarter of the file, measured on 2026-11-17
before this release's last change to the read path. No Linux machine with a disk of its own has been measured: there a
cold walk through `.memoryMap` waits for the device at every page and may cost more than the twelve times seen, and a
disk that reads ahead by 128 KB may make the cliff lower than the hundredfold seen. The direction of the table does not
depend on either; its numbers do.

A compaction of the database itself does not pay `.memoryMap`'s price. For its length the storage reads through a second
mapping of the file, left to the system's reading ahead, while its own map stays as it was told for the readers beside
it. It reads the same bytes, and takes the file's length in address space a second time while it runs. The list above,
compacted cold into a new file, took 2.39 s through `.memoryMap` and as long through `.memoryMapReadAhead`, against 3.92
s by file calls (Mac); 0.96 s, 0.89 and 2.16 (container). Before this release's last change, on the runner and with no
second mapping, the map read in no order took 10.9 s, against 8.9 by file calls and 4.9 through the map that reads
ahead. A compaction of a ``SnapshotDatabase`` has no second mapping: it reads through the snapshot's map, as that map
was told, and pays the price, so a server compacts a snapshot of a storage of its own opened with `.memoryMapReadAhead`,
as <doc:Compaction> shows.

Pages read through a map count in the process's resident size, as `ps` and Linux report it, and not in the memory
footprint macOS reports for a process: after a mapped file of 1.09 GB was read whole, a process on the Mac had a
resident size of 1,642 MB and a peak memory footprint of 543 MB (`/usr/bin/time -l`). They are the file's pages in the
system's cache, shared, and taken back when memory is short, not memory the process allocated.

### What ends the process

With file calls, a read that fails is an error. Through a map, a read of a part of the file that is no longer there is a
signal, and it ends the process. The library reads through the map only bytes it knows to be in the file, and its writer
never cuts a file below what is committed: a full copy is written into a new file (<doc:Replication>). Every reading of
the root, below, asks the system for the file's length, and a file cut below its committed size is
``XitDBError/truncatedDatabase`` there. What ends the process is such a cut made by something else after that reading
and before a read through the map: the original or a version of this package up to 0.5.1 making a full copy in place, a
tool that copies onto the file, a restore over the live file, or your own ``WritableStorage/truncate(to:)`` below what a
``Snapshot`` reads while that snapshot is being read on another thread. A read through a cursor held since the last
reading, as below, is not held to the file's length again. Replace a file by a new one and a rename, never in place. The
same holds for a volume that goes away, and on iOS for a file whose data protection makes it unreadable while the device
is locked.

### A read through the root

`database.rootCursor` reads the root header to make the cursor, and every operation that starts at a root cursor, or at
a collection made from one, reads it again: the committed size, the file's length asked of the system, and the trailer
at that size, read and verified. That is three system calls by file calls and two through a map, since the committed
size, which every commit rewrites in place, is always a file call. A read that starts at the root, which is one such
reading and the step from the history down to its last moment, took about 0.08 µs longer in memory, 0.63 µs through a
map and 1.5 µs by file calls than the same read through a cursor held at the last moment, on the Mac, where a read
through a map takes 0.07 to 0.13 µs: through a map, six to ten times the read. In the container it took 0.08, 0.40 and
0.8 µs longer. It is the price of seeing the newest commit, so a reader that reads much pays it once for each commit it
wants to see. It keeps the history, asks it for the last moment, and reads that moment through the moment's cursor:

```swift
// One reading of the root for the newest moment, and none for what is read in it.
let history = try ArrayList(database.rootCursor)
let moment = try HashMap(history.cursor(at: -1)!)
let name = try moment.value(forKey: "name", as: String.self)
let age = try moment.value(forKey: "age", as: UInt64.self)
```

Making `history` reads the root twice, and `history.cursor(at: -1)` once. What is read through `moment` is that commit,
until the reader asks the history again, and through a map it makes no system call at all; by file calls it makes the
path's own. A ``Snapshot`` is the other way: ``Database/snapshot()`` reads the root once, and a read at the snapshot's
root reads none, since its commit is pinned (see <doc:ConcurrencyAndSnapshots>).

## See Also

- ``FileReading``
- <doc:Storage>
- <doc:ConcurrencyAndSnapshots>
- <doc:Compaction>
