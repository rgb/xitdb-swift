# ``XitDB``

An immutable, append-only embedded database, compatible with the files of the original xitdb.

## Overview

XitDB is a Swift port of [xitdb](https://github.com/xit-vcs/xitdb). It is in development and cannot open a
database yet. What exists so far is the format layer, which describes the values a database is made of on
disk, and the storage layer, which is where a database's bytes are kept.

Every value in a database lives behind a ``Slot``, nine bytes that hold either a small value directly or the
offset of a larger record. A slot's ``Tag`` says which. A file starts with a ``DatabaseHeader``.

A database reads and writes its bytes through a storage. ``BufferedFileStorage`` keeps them in a file and is
the one to use for a database on disk. ``MemoryStorage`` keeps them in memory. ``FileStorage`` reads and
writes a file without buffering.

## Topics

### Values on disk

- ``Slot``
- ``Tag``

### The file header

- ``DatabaseHeader``
- ``HashID``

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

### Errors

- ``XitDBError``
