# Where the port differs from the original

What this package does differently from xitdb in Zig, and what it does the same even where that is a hazard.

## Overview

The port's first rule is that it writes the same bytes: given the same file ID, the same commit IDs and the same operations, it
produces the same file as the original. That is checked with 209 conformance scripts: in 111 the file must match the original's
byte for byte, and in the other 98 the script must fail where the original fails.

The second rule is that where the original's behaviour looks wrong, the port does what is correct, as long as the bytes of an
operation that is valid in both stay the same. The differences are therefore all of one kind: the port gives an error, or a
sensible result, where the original crashes, misbehaves, or depends on which kind of storage it has.

### What the port does differently today

| In the original | In the port |
|---|---|
| On macOS, a commit uses plain `fsync`, which promises neither order nor a flush. After a power loss the root header can be ahead of its data, and the file does not open. | ``Durability`` uses `F_BARRIERFSYNC` and `F_FULLFSYNC`. See <doc:Transactions>. |
| An out-of-range offset aborts the process, and a tree whose header disagrees with its nodes crashes it. | An error where the code comes across it: see <doc:Errors>. |
| Reading a slot set to nothing as bytes gives an empty value from one call, and `EndOfStream` from the other unless the buffer is empty. | No bytes, from both. |
| Streaming a slot set to nothing gives `UnexpectedTag`. | An empty stream. |
| Streaming a short value fails for a slot with no position, and otherwise reads from the file, so it returns other bytes after the slot is overwritten. | It reads the cursor's own slot, like every other read. |
| An array list's iterator can give an element past the end of the list after a slice. | It stops at the list's size, agreeing with a lookup. |
| A gap left by a write past the end reads as an error in a buffered file until it is flushed, and as zeros otherwise. | Zeros, on every storage. |
| Setting a storage's length larger is rejected in memory and allowed for a file. | ``WritableStorage/truncate(to:)`` only shortens, on every storage. |
| On a read-only file, an unbuffered write fails at once, and a buffered one only at commit. | At once, on both. |
| With 64-byte hashes, the trie's depth counter overflows at 64 levels. | It works to the depth the hash allows. |
| It syncs after every write outside a transaction, including ones that commit nothing. | It syncs after a commit. |

### What it does the same, for now

The port matches the original on these, so that its conformance scripts prove the same bytes, and they are worth knowing because
each is a hazard. The next version of the package changes each of them. Until then, these are the things not to do, and what the
next version does instead:

- **Do not keep a cursor for a later transaction.** Used during a later one, it writes into committed bytes in place, which changes
  earlier moments and which a rollback does not undo. Make a new one from the root. The next version refuses the write with an
  error, `staleCursor`.
- **Do not read through a cursor from a transaction that failed.** Its bytes were cut off, and the next transaction reuses their
  offsets, so it reads whatever that wrote. The next version refuses the read with the same error. A cursor from a transaction
  that committed stays readable.
- **Do not carry on after an error in a transaction's body.** What the failed operation had already written is committed along with
  the rest. Let the error leave the body. In the next version, a write that fails after writing something makes the transaction
  unable to commit, with an error, `poisonedTransaction`.
- **Do not write the slot of an entry as a value.** The slot of a cursor from a map's iterator is the entry's own. Written
  somewhere else, it can only be read as an entry. Read the entry, and write the slot of its ``Entry/value``. The next version
  refuses it with an error, `structuralSlot`.
- **After a join or a freeze, run the initialiser again on the cursor you hold.**
  ``LinkedArrayList/append(contentsOf:)-(LinkedArrayList<CursorAccess>)`` and ``Database/freeze()`` affect the collections made before
  them, other than the list that joined, and one written through without that can lose writes. In the original this can crash; in the port it gives an error or a
  wrong result, and never a crash. In the next version a join leaves the list that called it ready to use, and a write through any
  other collection held across it is the stale cursor's error.
- **``Cursor/writeIfEmpty(_:)`` goes by the cursor's snapshot.** If the slot was written through another cursor since, the value there
  is overwritten. The next version decides by the slot as it is now.

A file whose root header or last trailer is damaged does not open, even though the commits before it are intact. In the next version, opening it fails
with an error that names the last position that verifies, and a separate call truncates the file to it. Nothing is dropped silently.

Some of those fixes change the bytes of the operations they fix. Each of those is made in a branch of the original first, so that the
port still has something to compare with.

### Differences that are only the API

The file format and the operations are the same, and the API follows Swift:

- **The hash size is a value, not a type.** It comes from the file, or from you when you create one, so ``Database`` is not generic.
- **The storage is a value too.** ``Database`` is not generic over it either, and any ``WritableStorage`` will do.
- **Opening and creating are separate calls**, and a file's access mode has no default: see <doc:Storage>.
- **A byte writer is a closure**, ``Cursor/writeBytes(formatTag:_:)``. There is no `finish` to forget.
- **The path API is not public.** Only the collections and cursors are, so the original's hazards that need a raw path cannot be reached.
- **``Entry`` is read-only**, so a sorted map's key cannot be overwritten through one, and a client cannot make a ``Slot``.
- **Nothing that reads or writes a database is `Sendable`**: ``Database``, ``Cursor``, the collections, the storages, ``ByteReader`` and
  ``ByteWriter``. A database belongs to one thread or task at a time, and in Swift 6 mode the compiler enforces it. Plain values such as
  ``Slot``, ``Bytes`` and ``XitDBError`` are `Sendable`.

Every operation of the original is here. Planned beyond it, and not here yet: read snapshots that can be shared between threads and
tasks, a target with ready-made hashes, and a layer with string keys and typed values.

### The names

The other ports keep the original's names. This one follows the Swift API Design Guidelines, knowingly trading that familiarity for code
that reads as Swift. If you are coming from the original's documentation:

| The original | The port |
|---|---|
| `db.rootCursor()` | ``Database/rootCursor`` |
| `db.runContext(ctx)` | ``Database/withTransaction(_:)`` |
| `list.appendContext(data, ctx)` | ``ArrayList/append(_:_:)`` |
| `list.getCursor(i)`, `list.getSlot(i)` | ``ArrayList/cursor(at:)``, ``ArrayList/slot(at:)`` |
| `map.getCursor(hash)`, `map.put(hash, data)` | ``HashMap/cursor(forHash:)-(Sequence<UInt8>)``, ``HashMap/put(_:forHash:)-(_,Sequence<UInt8>)`` |
| `set.put(hash, data)`, `sorted_set.put(key)` | ``HashSet/insert(_:forHash:)-(_,Sequence<UInt8>)``, ``SortedSet/insert(_:)-(Sequence<UInt8>)`` |
| `list.concat(slot)`, `list.slice(offset, size)` | ``LinkedArrayList/append(contentsOf:)-(LinkedArrayList<CursorAccess>)``, ``LinkedArrayList/formSlice(offset:count:)`` |
| `sorted.iteratorFrom(key)`, `sorted.iteratorFromIndex(i)` | ``SortedMap/iterator(fromKey:)-(Sequence<UInt8>)``, ``SortedMap/iterator(fromIndex:)`` |
| `cursor.readUint()`, `cursor.readInt()`, `cursor.readFloat()` | ``Cursor/readUInt64()``, ``Cursor/readInt64()``, ``Cursor/readDouble()`` |
| `cursor.readBytesAlloc(allocator, max)` | ``Cursor/readBytes(maxCount:)`` |
| `cursor.readKeyValuePair()`, `kv.key_cursor`, `kv.value_cursor` | ``Cursor/readEntry()``, ``Entry/key``, ``Entry/value`` |
| `cursor.writer(buffer)`, `writer.finish()` | ``Cursor/writeBytes(formatTag:_:)`` |
| `.bytes_object`, `.float` | ``WritableData/bytes(_:formatTag:)``, ``WritableData/double(_:)`` |

## See Also

- <doc:Errors>
- <doc:Storage>
- <doc:Transactions>
- <doc:CursorsAndValues>
