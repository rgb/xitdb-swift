# ``XitDB``

An immutable, append-only embedded database, compatible with the files of the original xitdb.

## Overview

XitDB is a Swift port of [xitdb](https://github.com/xit-vcs/xitdb). It is in development and cannot open a
database yet. What exists so far is the format layer: the values a database is made of on disk.

Every value in a database lives behind a ``Slot``, nine bytes that hold either a small value directly or the
offset of a larger record. A slot's ``Tag`` says which. A file starts with a ``DatabaseHeader``.

## Topics

### Values on disk

- ``Slot``
- ``Tag``

### The file header

- ``DatabaseHeader``
- ``HashID``

### Errors

- ``XitDBError``
