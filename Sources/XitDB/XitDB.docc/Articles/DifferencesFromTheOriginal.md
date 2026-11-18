# Where the port differs from the original

What this package does differently from xitdb in Zig, and what it does the same even where that is a hazard.

## Overview

The port's first rule is that it writes the same bytes: given the same file ID, the same commit IDs and the same operations, it
produces the same file as the original. The original here is xitdb at the commit the port follows, `274418f`. That is checked
with 258 conformance scripts. In 160 the file must match byte for byte the one the original writes, or, for the few operations
the port deliberately does differently, the one the original writes when it is made to do the same. The other 98 must fail, as
they do with the original: they check that a runner catches what is wrong.

The second rule is that where the original's behaviour looks wrong, the port does what is correct. The differences are of four
kinds: the port refuses with an error, or decides differently, what would damage data in the original; it gives an error or a
sensible result where the original crashes or disagrees with itself, and goes past limits the original has; it holds a read to
what the file can hold, which the original does not; and on the disk it syncs and locks in its own way, and recovers, when
asked, a file the original cannot open. A refusal reaches no file: it comes before the write, and where an operation had already
written, the transaction can no longer commit. So it narrows which sequences of operations the port accepts and leaves the files
alone: the port reads every file the original writes. Two of the differences change the bytes of operations that are valid in
both: the operations after a join in the same transaction, and ``Cursor/writeIfEmpty(_:)``. For each, the port's authors changed
the original the same way, on a branch of their own, which the original does not have, and these two are the places where the
port's files match byte for byte that branch's and not the original's. That branch is `fix-findings-v3` of the fork
[`rgb/xitdb`](https://github.com/rgb/xitdb/tree/fix-findings-v3), at `6b48d2d`, on `274418f`.

### Where the original lets data be damaged

- **A cursor kept from an earlier transaction.** In the original, a write through it changes committed bytes in place, so an
  earlier moment changes, and if the transaction then rolls back, a committed slot can point past the end of the file. The port
  refuses the write with ``XitDBError/staleCursor``.
- **A cursor or collection held across a freeze or a join.** In the original a write through it goes in place into what is now
  shared, which loses writes or leaves two headers over one tree, and a later write can crash. Making a collection again from it
  writes its slot in place too, so a copy of anything that contains the slot changes with it, and once anything has copied the
  record the slot is in, the write is lost. The port refuses every write through it with ``XitDBError/staleCursor``, making a
  collection included, and freezes after a join rather than before it. What is allowed is making a collection, or writing a
  value, through the cursor the transaction's body was given, or another cursor at its slot, which is the way on: see
  <doc:CloningFreezeAndStaleHandles>.
  - **The original README's note on freezing globally** holds a map across a freeze. Its cloning example says the cursor's
    freeze can be replaced by `cursor.db.freeze()`, called before `putCursor` makes the cities cursor, and the example makes
    that cursor through the map it made before the freeze. The original gives the four cities and two big cities it expects and
    damages nothing, and the port refuses that `putCursor` all the same, with ``XitDBError/staleCursor``, as it does every write
    through a handle made before a freeze. Make the map again after the freeze, from the cursor the body was given, and the port
    gives the same lists.
- **A cursor from a transaction that did not commit.** In the original, a read through it gets whatever the next transaction wrote
  at the same offsets. The port refuses the read with ``XitDBError/staleCursor``.
- **An operation that fails partway.** In the original, a body that catches the error commits what the operation had already
  written, such as an entry without its value or a count one too high. In the port the transaction can no longer commit, and every
  later write in it and the commit throw ``XitDBError/poisonedTransaction``: see <doc:Transactions>.
- **``Cursor/writeIfEmpty(_:)``.** The original goes by the cursor's copy of the slot, so it can overwrite a value written since
  through another cursor. The port goes by the slot as it is now: it writes when the slot is empty, or set to nothing while the
  cursor's own copy is empty, as the cursor of an element just appended has, and it keeps any value.
- **A slot that belongs to a tree, written as a value.** In the original that builds a tree it cannot read, or panics at a hash size
  of 64. The port refuses it with ``XitDBError/structuralSlot``.
- **A sorted map's key.** The original lets a key be overwritten through the key cursor of an entry, which leaves the map out of
  order. In the port an ``Entry`` is read-only, and the engine refuses the write as well.
- **Compacting an array list at the root whose last element is empty**: a list with no elements, or one whose last element
  was appended and never written before 0.3.0, or by the original before `89da8e7`. The original gives an
  empty database, losing the list and every element before the empty one. The port refuses with
  ``XitDBError/emptyLastMoment``, before writing anything. An element appended and never written since then is a slot set to
  nothing, and both compact it, to one moment set to nothing: see <doc:Compaction>.

### An error or a sensible result where the original crashes or disagrees

- **An offset past any a file can have** aborts the original's process. The port throws an error.
- **A tree whose header disagrees with its nodes**, which a damaged file or the original's freeze hazards produce, can crash the
  original. The port throws an error where a read or a write is led where the tree has nothing, and never traps: see
  <doc:Errors>. Within what a read is held to (below), it otherwise reads such a tree as the original does, by its size and
  counts as they are, and one read differs even so: **an iterator started at a key whose place is past the size**, in a tree
  that holds more than its size says, runs on to the tree's end in the original. The port gives nothing.
- **The key and value slots of a hashed entry** are read without checking their tags in the original. The port checks them.
- **With 64-byte hashes**, the original's depth counter overflows at 64 levels. The port goes as deep as the hash allows, and then
  throws ``XitDBError/keyOffsetExceeded``.
- **Hashes longer than 8,191 bytes** cannot be named in the original, which takes a hash as an integer type as wide as the hash,
  and Zig's integer types stop at 65,535 bits. The port creates and opens databases with hashes of up to 65,535 bytes, and no
  program built on the original can open one whose hashes are longer than 8,191: see <doc:Hashing>.
- **A slot set to nothing, read as bytes**, gives an empty value from one of the original's calls and `EndOfStream` from the other.
  The port gives no bytes from both.
- **A slot set to nothing, streamed,** gives `UnexpectedTag` in the original. The port gives an empty stream.
- **A short value, streamed,** fails in the original with `ExpectedSlotPosition` when its cursor has no position in the file:
  a key reached by a raw path to it, or a set's key in the pair that `getKeyValuePair` gives on a sorted map made over the set,
  read-only or writable. Otherwise the original takes the length from the cursor and the bytes from the slot's position in the
  file, so once the slot has been overwritten it streams other bytes. The port reads the cursor's own slot, as every other
  read does.
- **An array list's iterator after a slice** can give an element past the end of the list in the original, where an element
  appended and never written before 0.3.0, or by the original before `89da8e7`, lies inside the list's size. The port's stops
  at the list's size, agreeing with a lookup. For elements appended since, the two agree.
- **A gap left by a write past the end** reads as an error in the original's buffered file until it is flushed, and as zeros
  everywhere else. The port reads zeros on every storage.
- **Setting a storage's length larger** is refused in memory and allowed for a file in the original. The port's
  ``WritableStorage/truncate(to:)`` only shortens, on every storage.
- **A read-only file** fails at the first write in the original's plain file kind, and only at the commit in its buffered kind.
  In the port a write through a file opened to be read does not compile (see the differences that are only the API, below);
  the engine underneath, which the conformance suite holds to the original's behaviour on such a file, fails at once on both.
- **Parts of a path after a remove** are ignored by the original. The port's path API refuses them, and since that API is internal,
  only the package's own code can meet this.
- **The original syncs after every write outside a transaction**, including ones that commit nothing. The port syncs after a
  commit.
- **Reading committed bytes into a writer with no buffer** panics on the original's buffered file. The port has no such writer:
  a ``ByteSink`` is handed the bytes, a part at a time.

### What a read is held to that the original's is not

The port holds four things a read takes from a file to what the file can be, so that no file leads a read outside the file's
data, or into a walk without end. The original holds none of them; it bounds its reads by depth, as the port does too.

- **A size the file has no room for** is refused by every read of the collection that takes it, with
  ``XitDBError/invalidCount``: an array list's or a sorted map's or set's, at nine bytes for each element, and a counted hash
  map's or set's count, at the hash and eighteen bytes for each entry. A linked array list's size is held to nothing, since a
  list joined to itself holds its nodes many times over: a walk of one is not held to the file's length, and gives the elements
  its tree holds, at most as many as its size says. No write checks a size this way.
- **No read takes bytes from before where data starts**, 32 bytes into the file, or 37 in a version 1 file: a slot, a header, a
  block, a node, a pair or a byte array whose bytes would come from the file's own headers is refused with
  ``XitDBError/endOfStream``, as one beyond the end is.
- **A walk of a hash map or set** enters no more blocks than the file has room for, at 144 bytes a block, and ends with
  ``XitDBError/keyOffsetExceeded`` when it would enter more, so a block that many slots lead to can give its entries more than
  once before then. The original's walk has no bound but its stack's depth: such a block is entered once for each slot that
  leads to it, which can come to sixteen to the power of that depth, and blocks that lead back up end it with an error when the
  stack is full.
- **A walk of a tree** enters no more nodes than its file or its elements allow, and then ends with
  ``XitDBError/invalidBTreeNode``: a sorted map's or set's no more than the file has room for, at 146 bytes a node, and a linked
  array list's no more than 65 for each element it has given and for the next.

None of the four holds a size or a count against the tree under it. A position, a rank and a walk answer from the counts as they
are, as in the original but for the two iterator starts above, so a size or a branch's count that is wrong but fits the file is
read as it is, with no error, and what is answered from it can be wrong.

### On the disk

- **On macOS the original commits with plain `fsync`**, which promises neither order nor a flush, so after a power loss its root
  header can be ahead of its data. The port's ``Durability`` uses `F_BARRIERFSYNC` and `F_FULLFSYNC`: see <doc:Transactions>.
- **A file whose root header or last trailer is damaged** does not open in the original, even though every commit before it is
  intact. The port's opening names the end of the last commit that verifies, with
  ``XitDBError/untrustedRootHeader(lastVerified:)``, and ``Database/recover(_:ignoringRootHeader:)`` cuts the file back to it, which can lose a
  commit and is never done without being asked: see <doc:Recovery>. In the original a committed size of zero is not damage: it is
  a database without a first commit, which a creation or a full copy that did not finish leaves. The port opens such a full
  copy, and creates over such a creation, which its opening refuses: see <doc:Storage>.
- **A lock is never waited for.** The original takes no lock itself, and the writer in its README takes an exclusive one with
  Zig's `File.lock`, which waits while another process holds one that conflicts. A ``FileLock`` is had at once or not at all:
  when it cannot be, opening fails with ``XitDBError/storageFailure(errno:)`` carrying `EWOULDBLOCK`. Both are `flock` locks, so
  each side's keeps out the other's, and a reader's ``FileLock/shared`` lock stands the README's writer still while it is held:
  see <doc:Storage>.

### The same as the original

Keys and typed values bring three of the original's ways to a level the original does not have, and keep them there,
where the Go, Java and TypeScript ports chose otherwise for their keys:

- **A put or a put cursor does not store the key unless asked.** A keyed put writes what the original's
  `put(hashInt(key), data)` writes, the value under the hash, and ``HashMap/putKey(_:)`` stores the key, as `putKey`
  does. Given `storingKey: true` the put and the put cursor store the key too, a convenience over the original's two
  calls, `putKey` and then `put` or `putCursor`: in one walk to the entry, each writes what its two calls write in one
  transaction. The other ports' keyed put and put cursor always store the key, and the Go port's put writes it, if the
  entry has none, and then the value in one walk, as the argument does. A set's ``HashSet/insert(_:)`` stores the
  member, as the original's set `put` does.
- **A number says its kind**, as the original's `.uint`, `.int` and `.float` do: `UInt64`, `Int64` or `Double`. `Int` is
  not a value, so an integer whose kind is not said does not compile.
- **A slot set to nothing reads as no bytes**, as the original's `readBytesAlloc` reads it, and a number read from it is
  refused, as the original's `readUint` refuses any tag but its own.

And these of the original's ways stay as they are, hazards included:

- **A copy made within a transaction** is a second name for something still mutable, until a freeze. That is the original's
  design, and the port keeps it: see <doc:CloningFreezeAndStaleHandles>.
- **A freeze of one cursor**, ``Cursor/freeze()``, protects the data from writes through that cursor and from nothing else. The
  port does what the original does, except that where the original can crash it throws an error, and in the two iterator starts
  under "A tree whose header disagrees with its nodes" above.
- **Writing a slot set to nothing** writes the value bits it carries, which mean nothing, in both. A client of the port cannot
  make a slot, so it cannot choose them.
- **Two of the original's hazards need its raw path API**, which the port does not make public: a path that skips a collection's
  initialiser, which writes into committed data, and a freeze inside a callback, which does not carry out of it. The port's own
  path API refuses the write into committed data with ``XitDBError/immutableBytes``: a second check, by position, under the one
  on handles. A third, a sorted lookup in a write path that turns a set's key-only entry into a pair, is wasteful and not wrong,
  and it stays, since changing it would change bytes.

### Differences that are only the API

The file format and the operations are the same, and the API follows Swift:

- **The hasher is a value, not a type parameter.** The original's database is generic over the integer its hashes are,
  and the caller hashes each key. Here a database is given a hasher, a ``KeyHashing`` type passed as a value, or a hash
  size alone, and ``Database`` is not generic. The collections take a key beside a hash: an untyped keyed call is its
  call by hash with the hash computed for it, a put or a put cursor that stores its key the two calls by hash in one
  walk, and a typed one writes what the same value written by hash writes (see <doc:Hashing>).
- **The storage is a value too.** ``Database`` is not generic over it either, and any ``WritableStorage`` will do.
- **Opening and creating are separate calls**, and a file's access mode has no default: see <doc:Storage>. The original's one
  call creates over what a creation that did not finish left; here creating does, and opening refuses it.
- **A file opened to be read is a type of its own.** The original has one database type, and so have its Go, Java and
  TypeScript ports: a read-only file is opened with the same call, and a write through it fails when the program runs.
  Here a reader opens a ``ReadOnlyFileStorage`` and a ``ReadOnlyDatabase`` over it, and a transaction, a recovery or a
  sync onto it does not compile. No file is read or written differently, and everything that succeeds on a read-only
  file in the original has its twin: reads, a snapshot, the reading side of replication, a compaction from it. The step
  is along a line the family draws already. Read-only against read-write is a matter for the compiler on the original's
  collections (`DB.HashMap(.read_only)`) and on the ports' cursors (`ReadCursor` and `WriteCursor`); the Java port has a
  read-only file of its own, `CoreReadOnlyFile`; and the Go and Java READMEs tell a process that only reads to open its
  file read-only. The price is two types where a program decides while it runs whether it only reads: it holds
  `any ReadableStorage`, as <doc:Storage> shows.
- **A storage opens its file and closes it.** The original is given a file its caller opened, and the caller closes it
  (`defer file.close(io)` in its README). Here a storage owns its file: it is closed when the storage and the last
  snapshot of a database in it have gone, or when the program says so with `close()` on a file storage, as the Java
  port's file cores have one; whatever reads or writes through a closed storage throws ``XitDBError/storageClosed``.
- **Values are Swift types** beside ``WritableData``: `UInt64`, `Int64`, `Double`, `String`, `[UInt8]`, ``Bytes``, and any
  ``StorableValue`` of your own, each written as the format's own slot: see <doc:CursorsAndValues>.
- **A byte writer is a closure**, ``Cursor/writeBytes(formatTag:_:)``. There is no `finish` to forget.
- **The path API is not public.** Only the collections and cursors are, so the original's hazards that need a raw path cannot be reached.
- **``Entry`` is read-only**, so a sorted map's key cannot be overwritten through one, and a client cannot make a ``Slot``.
- **Nothing that reads or writes a database is `Sendable`**: ``Database``, ``Cursor``, the collections, the storages, ``ByteReader`` and
  ``ByteWriter``. A database belongs to one thread or task at a time, and in Swift 6 mode the compiler enforces it. Plain values such as
  ``Slot``, ``Bytes`` and ``XitDBError`` are `Sendable`, and so is a ``Snapshot`` of one commit, which is how another task reads a
  database: see <doc:ConcurrencyAndSnapshots>.

Every operation of the original is here, and keys, typed values and read snapshots beyond it.

### The names

The other ports keep the original's names. This one follows the Swift API Design Guidelines, knowingly trading that familiarity for code
that reads as Swift. If you are coming from the original's documentation:

| The original | The port |
|---|---|
| `db.rootCursor()` | ``Database/rootCursor`` |
| `db.runContext(ctx)` | ``Database/withTransaction(_:)`` |
| `list.appendContext(data, ctx)` | ``ArrayList/append(_:_:)`` |
| `list.getCursor(i)`, `list.getSlot(i)` | ``ArrayList/cursor(at:)``, ``ArrayList/slot(at:)`` |
| `HashInt`, `hashInt(key)` | A hasher given to the database, ``Database/init(creating:hashing:hashID:fileID:)``; a hash by hand, ``KeyHashing/keyHash(of:)`` |
| `map.getCursor(hash)`, `map.put(hash, data)` | ``HashMap/cursor(forHash:)-(Sequence<UInt8>)``, ``HashMap/put(_:forHash:)-(_,Sequence<UInt8>)`` |
| `map.getCursor(hashInt(key))`, `map.put(hashInt(key), data)` | ``HashMap/cursor(forKey:)``, ``HashMap/put(_:forKey:storingKey:)-(WritableData,_,_)``, or with a typed value ``HashMap/put(_:forKey:storingKey:)-(StorableValue,_,_)`` |
| `map.putKey(hash, data)` | ``HashMap/putKey(_:forHash:)-(_,Sequence<UInt8>)``, or by key ``HashMap/putKey(_:)`` |
| `set.put(hash, data)`, `sorted_set.put(key)` | ``HashSet/insert(_:forHash:)-(_,Sequence<UInt8>)``, ``HashSet/insert(_:)``, ``SortedSet/insert(_:)-(KeyRepresentable)`` |
| `list.concat(slot)`, `list.slice(offset, size)` | ``LinkedArrayList/append(contentsOf:)-(LinkedArrayList<CursorAccess>)``, ``LinkedArrayList/formSlice(offset:count:)`` |
| `sorted.iteratorFrom(key)`, `sorted.iteratorFromIndex(i)` | ``SortedMap/iterator(fromKey:)-(KeyRepresentable)``, ``SortedMap/iterator(fromIndex:)`` |
| `cursor.readUint()`, `cursor.readInt()`, `cursor.readFloat()` | ``Cursor/readUInt64()``, ``Cursor/readInt64()``, ``Cursor/readDouble()``, or ``Cursor/read(_:)`` with `UInt64`, `Int64`, `Double` |
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
