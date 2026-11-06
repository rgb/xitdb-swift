# ``XitDB``

An immutable, append-only embedded database, compatible with the files of the original xitdb.

## Overview

XitDB is a Swift port of [xitdb](https://github.com/xit-vcs/xitdb). It is in development. What exists so far
is the engine: a ``Database`` can be created and opened, and values can be written and read through a
``Cursor``. The collection types that make a database convenient to use, such as maps and lists, are not
there yet.

A database keeps its bytes in a storage. ``BufferedFileStorage`` keeps them in a file and is the one to use
for a database on disk. ``MemoryStorage`` keeps them in memory. ``FileStorage`` reads and writes a file
without buffering.

Reading and writing start at ``Database/rootCursor()``. A ``Cursor`` is a position in the database: it reads
the value there, and inside a transaction it writes one. ``Database/runContext(_:)`` runs a transaction.

Every value lives behind a ``Slot``, nine bytes that hold either a small value directly or the offset of a
larger record. A slot's ``Tag`` says which. A file starts with a ``DatabaseHeader``.

## Topics

### Databases

- ``Database``
- ``DatabaseHeader``
- ``HashID``

### Reading and writing

- ``Cursor``
- ``ReadOnly``
- ``ReadWrite``
- ``CursorAccess``
- ``KeyValuePairCursor``
- ``WriteableData``
- ``Bytes``
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
