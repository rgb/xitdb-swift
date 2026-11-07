# ``XitDB``

An immutable, append-only embedded database, compatible with the files of the original xitdb.

## Overview

XitDB is a Swift port of [xitdb](https://github.com/xit-vcs/xitdb), complete to the surface of the original:
a ``Database`` can be created and opened; every collection of the original can be built in it, read, written
and iterated over; values can be read and written through a ``Cursor``, including byte arrays read and
written a part at a time; a database can be compacted, and replicated by copying the bytes a replica lacks.

A database keeps its bytes in a storage. ``BufferedFileStorage`` keeps them in a file and is the one to use
for a database on disk. ``MemoryStorage`` keeps them in memory. ``FileStorage`` reads and writes a file
without buffering.

Reading and writing start at ``Database/rootCursor``. A ``Cursor`` is a position in the database: it reads
the value there, and inside a transaction it writes one. ``Database/withTransaction(_:)`` runs a transaction.

The collections are views of a cursor's slot. ``ArrayList`` is a list indexed by position.
``LinkedArrayList`` is a list that can also be changed anywhere: elements inserted and removed at any
position, and lists joined and cut in logarithmic time. ``HashMap`` and ``HashSet`` hold values and keys
under hashes that the caller computes; ``CountedHashMap`` and ``CountedHashSet`` also keep the number of
their entries. ``SortedMap`` and ``SortedSet`` hold values and keys under byte strings in their own order,
and give them in that order from the start, from a key or from a position, and the position of any key:
what an index that sorts and paginates needs. Each comes in a read-only and a read-write form, like a
cursor. A database's history is usually an ``ArrayList`` at the root with one element per transaction, each
a ``HashMap`` of that moment's state, so that every earlier moment stays readable.

Every value lives behind a ``Slot``, nine bytes that hold either a small value directly or the offset of a
larger record. A slot's ``Slot/Tag`` says which. A file starts with a ``DatabaseHeader``.

A database whose last commit is damaged does not open: ``Database/init(opening:hashSize:)`` fails with
``XitDBError/untrustedRootHeader(lastVerified:)``, naming the last commit that verifies, and
``Database/recover(_:)`` cuts the storage back to it, the one call that can lose a commit.

A database only grows, since every transaction appends. ``Database/compact(into:offsetMap:)`` writes a new
one that holds what the latest moment reaches and nothing else, every object once however many slots point
at it. The copy remembers where things went in an ``OffsetMap``; ``MemoryOffsetMap`` keeps that in memory.

Committed bytes never change except for the root header, so a replica is brought up to date by copying the
bytes it does not have. A replica describes itself with a ``ReplicaState``; the source answers with
``Database/replicationStart(for:)``, sends with ``Database/readCommitted(from:to:into:)-(_,_,Sink)`` into a ``ByteSink``,
and the replica takes the bytes with ``Database/applyReplicated(at:from:count:)`` from a ``ByteSource``.

## Topics

### Databases

- ``Database``
- ``DatabaseHeader``
- ``HashID``

### Collections

- ``ArrayList``
- ``LinkedArrayList``
- ``HashMap``
- ``HashSet``
- ``CountedHashMap``
- ``CountedHashSet``
- ``SortedMap``
- ``SortedSet``

### Reading and writing

- ``Cursor``
- ``ReadOnly``
- ``ReadWrite``
- ``CursorAccess``
- ``Entry``
- ``CollectionIterator``
- ``WritableData``
- ``Bytes``
- ``ByteReader``
- ``ByteWriter``

### Compaction

- ``OffsetMap``
- ``MemoryOffsetMap``

### Replication

- ``ReplicaState``
- ``ByteSink``
- ``ByteSource``
- ``ArrayByteSink``
- ``ArrayByteSource``

### Storage

- ``BufferedFileStorage``
- ``FileStorage``
- ``MemoryStorage``
- ``WritableStorage``
- ``ReadableStorage``
- ``SyncPoint``

### Opening a file

- ``FileAccess``
- ``Durability``
- ``FileLock``

### Values on disk

- ``Slot``
- ``Slot/Tag``

### Errors

- ``XitDBError``
