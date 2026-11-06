# ``XitDB``

An immutable, append-only embedded database, compatible with the files of the original xitdb.

## Overview

XitDB is a Swift port of [xitdb](https://github.com/xit-vcs/xitdb). It is in development. What exists so far:
a ``Database`` can be created and opened; hash maps and array lists can be built in it, read, written and
iterated over; and values can be read and written through a ``Cursor``, including byte arrays read and
written a part at a time. Linked array lists and sorted maps are not there yet.

A database keeps its bytes in a storage. ``BufferedFileStorage`` keeps them in a file and is the one to use
for a database on disk. ``MemoryStorage`` keeps them in memory. ``FileStorage`` reads and writes a file
without buffering.

Reading and writing start at ``Database/rootCursor()``. A ``Cursor`` is a position in the database: it reads
the value there, and inside a transaction it writes one. ``Database/runContext(_:)`` runs a transaction.

The collections are views of a cursor's slot. ``ArrayList`` is a list indexed by position. ``HashMap`` and
``HashSet`` hold values and keys under hashes that the caller computes; ``CountedHashMap`` and
``CountedHashSet`` also keep the number of their entries. Each comes in a read-only and a read-write form,
like a cursor. A database's history is usually an ``ArrayList`` at the root with one element per transaction,
each a ``HashMap`` of that moment's state, so that every earlier moment stays readable.

Every value lives behind a ``Slot``, nine bytes that hold either a small value directly or the offset of a
larger record. A slot's ``Tag`` says which. A file starts with a ``DatabaseHeader``.

## Topics

### Databases

- ``Database``
- ``DatabaseHeader``
- ``HashID``

### Collections

- ``ArrayList``
- ``HashMap``
- ``HashSet``
- ``CountedHashMap``
- ``CountedHashSet``

### Reading and writing

- ``Cursor``
- ``ReadOnly``
- ``ReadWrite``
- ``CursorAccess``
- ``KeyValuePairCursor``
- ``WriteableData``
- ``Bytes``
- ``ByteReader``
- ``ByteWriter``

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
- ``Tag``

### Errors

- ``XitDBError``
