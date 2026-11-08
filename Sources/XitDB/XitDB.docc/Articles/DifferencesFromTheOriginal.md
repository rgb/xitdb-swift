# Where the port differs from the original

What this package does differently from xitdb in Zig, and what it does the same even where that is a hazard.

## Overview

The port's first rule is that it writes the same bytes: given the same file ID, the same commit IDs and the same operations, it
produces the same file as the original. That is checked with 226 conformance scripts. In 128 the file must match byte for byte
the one the original writes, or, for the few operations the port deliberately does differently, the one the original writes when
it is made to do the same. The other 98 must fail, as they do with the original: they check that a runner catches what is wrong.

The second rule is that where the original's behaviour looks wrong, the port does what is correct. The differences are of three
kinds: the port refuses with an error, or decides differently, what would damage data in the original; it gives an error or a
sensible result where the original crashes or disagrees with itself; and it recovers, when asked, a file the original cannot
open. A refusal reaches no file: it comes before the write, and where an operation had already written, the transaction can no
longer commit. So it narrows which sequences of operations the port accepts and leaves the files alone: the port reads every
file the original writes. Two of the differences change the bytes of operations that are valid in both: the operations
after a join in the same transaction, and ``Cursor/writeIfEmpty(_:)``. Each of those was made in a branch of the original first,
and the port's files are compared with that branch's.

### Where the original lets data be damaged

- **A cursor kept from an earlier transaction.** In the original, a write through it changes committed bytes in place, so an
  earlier moment changes, and if the transaction then rolls back, a committed slot can point past the end of the file. The port
  refuses the write with ``XitDBError/staleCursor``.
- **A cursor or collection held across a freeze or a join.** In the original a write through it goes in place into what is now
  shared, which loses writes or leaves two headers over one tree, and a later write can crash. Making a collection again from it
  writes its slot in place too, so a copy of anything that contains the slot changes with it, and once anything has copied the
  record the slot is in, the write is lost. The port refuses every write through it with ``XitDBError/staleCursor``, making a
  collection included, and freezes after a join rather than before it. The one thing allowed is making a collection from the
  cursor the transaction's body was given, or from another cursor at its slot, which is the way on: see
  <doc:CloningFreezeAndStaleHandles>.
- **A cursor from a transaction that did not commit.** In the original, a read through it gets whatever the next transaction wrote
  at the same offsets. The port refuses the read with ``XitDBError/staleCursor``.
- **An operation that fails partway.** In the original, a body that catches the error commits what the operation had already
  written, such as an entry without its value or a count one too high. In the port the transaction can no longer commit, and every
  later write in it and the commit throw ``XitDBError/poisonedTransaction``: see <doc:Transactions>.
- **``Cursor/writeIfEmpty(_:)``.** The original goes by the cursor's copy of the slot, so it can overwrite a value written since
  through another cursor. The port goes by the slot as it is now.
- **A slot that belongs to a tree, written as a value.** In the original that builds a tree it cannot read, or panics at a hash size
  of 64. The port refuses it with ``XitDBError/structuralSlot``.
- **A sorted map's key.** The original lets a key be overwritten through the key cursor of an entry, which leaves the map out of
  order. In the port an ``Entry`` is read-only, and the engine refuses the write as well.
- **Compacting an array list at the root whose last element is empty.** The original gives an empty database, losing the list
  and every element before the empty one. The port refuses with ``XitDBError/emptyLastMoment``, before writing anything: see
  <doc:Compaction>.

### An error or a sensible result where the original crashes or disagrees

- **An offset past any a file can have** aborts the original's process. The port throws an error.
- **A tree whose header disagrees with its nodes**, which a damaged file or the original's freeze hazards produce, can crash the
  original. The port throws an error where it comes across one, and never traps: see <doc:Errors>.
- **The key and value slots of a hashed entry** are read without checking their tags in the original. The port checks them.
- **With 64-byte hashes**, the original's depth counter overflows at 64 levels. The port goes as deep as the hash allows, and then
  throws ``XitDBError/keyOffsetExceeded``.
- **A slot set to nothing, read as bytes**, gives an empty value from one of the original's calls and `EndOfStream` from the other.
  The port gives no bytes from both.
- **A slot set to nothing, streamed,** gives `UnexpectedTag` in the original. The port gives an empty stream.
- **A short value, streamed,** fails in the original for a slot without a position, and otherwise reads from the file, so it
  returns other bytes once the slot has been overwritten. The port reads the cursor's own slot, as every other read does.
- **An array list's iterator after a slice** can give an element past the end of the list in the original. The port's stops at the
  list's size, agreeing with a lookup.
- **A gap left by a write past the end** reads as an error in the original's buffered file until it is flushed, and as zeros
  everywhere else. The port reads zeros on every storage.
- **Setting a storage's length larger** is refused in memory and allowed for a file in the original. The port's
  ``WritableStorage/truncate(to:)`` only shortens, on every storage.
- **A read-only file** fails at the first write in the original's plain file kind, and only at the commit in its buffered kind.
  The port fails at once on both.
- **Parts of a path after a remove** are ignored by the original. The port's path API refuses them, and since that API is internal,
  only the package's own code can meet this.
- **The original syncs after every write outside a transaction**, including ones that commit nothing. The port syncs after a
  commit.
- **Reading committed bytes into a writer with no buffer** panics on the original's buffered file. The port has no such writer:
  a ``ByteSink`` is handed the bytes, a part at a time.

### On the disk

- **On macOS the original commits with plain `fsync`**, which promises neither order nor a flush, so after a power loss its root
  header can be ahead of its data. The port's ``Durability`` uses `F_BARRIERFSYNC` and `F_FULLFSYNC`: see <doc:Transactions>.
- **A file whose root header or last trailer is damaged** does not open in the original, even though every commit before it is
  intact. The port's opening names the end of the last commit that verifies, with
  ``XitDBError/untrustedRootHeader(lastVerified:)``, and ``Database/recover(_:)`` cuts the file back to it, which can lose a
  commit and is never done without being asked: see <doc:Recovery>.

### The same as the original

- **A copy made within a transaction** is a second name for something still mutable, until a freeze. That is the original's
  design, and the port keeps it: see <doc:CloningFreezeAndStaleHandles>.
- **A freeze of one cursor**, ``Cursor/freeze()``, protects the data from writes through that cursor and from nothing else. The
  port does what the original does, except that where the original can crash it throws an error. Whether it should do more is not
  decided.
- **Writing a slot set to nothing** writes the value bits it carries, which mean nothing, in both. A client of the port cannot
  make a slot, so it cannot choose them.
- **Two of the original's hazards need its raw path API**, which the port does not make public: a path that skips a collection's
  initialiser, which writes into committed data, and a freeze inside a callback, which does not carry out of it. The port's own
  path API refuses the write into committed data with ``XitDBError/immutableBytes``: a second check, by position, under the one
  on handles. A third, a sorted lookup in a write path that turns a set's key-only entry into a pair, is wasteful and not wrong,
  and it stays, since changing it would change bytes.

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
  ``Slot``, ``Bytes`` and ``XitDBError`` are `Sendable`, and so is a ``Snapshot`` of one commit, which is how another task reads a
  database: see <doc:ConcurrencyAndSnapshots>.

Every operation of the original is here, and read snapshots beyond it. Planned, and not here yet: a target with ready-made hashes,
and a layer with string keys and typed values, whose handles take themselves again after a freeze, so that a clone is safe without
one.

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
- <doc:CloningFreezeAndStaleHandles>
- <doc:Recovery>
- <doc:Transactions>
- <doc:CursorsAndValues>
