# Cursors and values

What a slot is, the values it can hold, and how a cursor reads and writes them.

## Overview

Every value in a database lives behind a ``Slot``: nine bytes, one saying what kind of thing it holds and eight
that hold either the value itself or the offset of a record with the value in it. A ``Cursor`` is a position in
the database, at one slot. Everything is read and written through a cursor, and the collections are views over
one.

The examples use `sha256(_:)`, a helper that hashes a string: see <doc:BringYourOwnHashes>. They force-unwrap a
lookup where the value was just written; real code handles the `nil` that means it is not there. Where they use `moment`,
it is a ``HashMap`` that is one moment of a history, as in <doc:MomentsAndHistory>: a read-only one to read through, and
to write through a read-write one in a transaction's body.

### The values

A value is written as a ``WritableData``, and a slot's ``Slot/tag`` says afterwards what it holds:

| Written as | The slot's tag | Read with |
|---|---|---|
| ``WritableData/uint(_:)`` | ``Slot/Tag/uint`` | ``Cursor/readUInt64()`` |
| ``WritableData/int(_:)`` | ``Slot/Tag/int`` | ``Cursor/readInt64()`` |
| ``WritableData/double(_:)`` | ``Slot/Tag/float`` | ``Cursor/readDouble()`` |
| ``WritableData/bytes(_:formatTag:)`` | ``Slot/Tag/shortBytes`` or ``Slot/Tag/bytes`` | ``Cursor/readBytes(maxCount:)`` |
| ``WritableData/slot(_:)`` | whatever that slot's is | what that slot's tag calls for |

```swift
let unsigned = try moment.cursor(forHash: sha256("unsigned"))!.readUInt64()
let signed = try moment.cursor(forHash: sha256("signed"))!.readInt64()
let double = try moment.cursor(forHash: sha256("double"))!.readDouble()
let long = try moment.cursor(forHash: sha256("long"))!.readBytes()
```

There is no string type in a database, and no conversion: a string is its bytes, `.bytes(Array("hello".utf8))`,
read back with `String(decoding:as:)`. A read of the wrong kind throws ``XitDBError/unexpectedTag``, and that
includes reading a ``Slot/Tag/int`` as a ``Slot/Tag/uint``.

Numbers and short byte arrays cost nothing beyond their slot. A byte array of at most eight bytes with no zero
byte in it, or six with a format tag, is stored in the slot; ``Bytes/isShort`` says whether one would be. A longer
one gets a record of its own, with an eight-byte length in front, and so does one written a part at a time
(<doc:LargeByteArrays>).

A value that could be of several kinds is read by looking at the tag first:

```swift
func describe(_ cursor: Cursor<ReadOnly>) throws -> String {
    switch try cursor.slot.tag {
    case .uint: "\(try cursor.readUInt64())"
    case .int: "\(try cursor.readInt64())"
    case .float: "\(try cursor.readDouble())"
    case .bytes, .shortBytes: String(decoding: try cursor.readBytes(), as: UTF8.self)
    case .none: "nothing"
    default: "a collection"
    }
}
```

### Format tags

A byte array can carry a ``FormatTag``, two bytes that say how to read it. XitDB does not interpret them; they
are for whoever reads the value. Here a date stored as text says so:

```swift
// A date, stored as text, with a tag that says how to read it.
let date = Array("2026-11-07T09:47:00Z".utf8)
try moment.put(.bytes(date, formatTag: "dt"), forHash: sha256("created"))
```

```swift
let created = try moment.cursor(forHash: sha256("created"))!.readBytesWithFormatTag()
```

The result is a ``Bytes``, with the value in ``Bytes/value`` and the tag in ``Bytes/formatTag``. A tag can be any
two bytes, so there are 65,536 of them. It is a good way to store your own types: serialise them however you
like, and tag what you stored.

### Cursors

A cursor is generic over what it can do. A cursor of ``ReadOnly`` access has only the reading methods, and
one of ``ReadWrite`` access has the writing ones as well, so writing through a read-only cursor does not compile.
``Cursor/readOnly`` gives a read-only cursor from a read-write one. Every lookup on a collection gives a read-only
cursor, so a read cannot change anything by mistake.

A read-write cursor comes from the methods that make room for a value, inside a transaction:

```swift
var cursor = try moment.putCursor(forHash: sha256("counter"))
try cursor.write(.uint(1))
```

Do this in a transaction's body. On a collection at the root those methods are transactions of their own, which have
committed by the time they return: the entry is there without a value, and with no transaction running, a write
through the cursor throws ``XitDBError/expectedTxStart``. Do not keep such a cursor for a later transaction, as
<doc:Transactions> explains.

``Cursor/writeIfEmpty(_:)`` writes only if the slot is empty, for a value that should be set once. It decides by the
slot as it is now, not by the cursor's snapshot of it, so a value written through another cursor since is kept.

<!-- Pinned by `writeIfEmptyGoesByTheSlot` in XitDBExamples: the sentence and the test change together. -->

```swift
var maybe = try moment.putCursor(forHash: sha256("once"))
try maybe.writeIfEmpty(.uint(1))
try maybe.writeIfEmpty(.uint(2))
```

A helper given only a cursor can reach its database through its `database`, a ``Database`` on a read-write cursor and
`any ReadableDatabase` on a read-only one; a helper over a cursor of any access goes through ``Cursor/readOnly`` first.

### A cursor holds a snapshot

A cursor remembers what its slot held when it was made, and reads go by that. A write through another cursor does
not show:

```swift
let database = try Database(creating: MemoryStorage(), hashSize: 32)
let list = try ArrayList<ReadWrite>(database.rootCursor)
try list.append(.uint(1))

// A cursor below the root keeps what it saw.
let element = try list.cursor(at: 0)!
try list.put(.uint(2), at: 0)
```

Here `element` still reads 1, and a new lookup reads 2. The exception is a cursor at the root of the database,
from ``Database/rootCursor``, which reads the last commit every time, so it does see later transactions. That is
why a collection made from it can be kept from one transaction to the next:

```swift
// A cursor at the root reads the last commit every time.
let root = database.rootCursor
let countBefore = try root.count
try list.append(.uint(3))
```

After that, `countBefore` is 1 and `root.count` is 2.

Only the slot is a snapshot. What it points at is read when you ask for it, so a cursor held on a list changed in place
in the same transaction reports the list's new count.

### Iterating

Every collection has an iterator, such as ``ArrayList/iterator()``. It gives a ``CollectionIterator``, whose ``CollectionIterator/next()`` gives
a read-only cursor, or `nil` at the end. It is not a Swift `Sequence`, because reading the next element can fail:

```swift
try list.append(.uint(1))
try list.append(.uint(2))
try list.append(.uint(3))

var values: [UInt64] = []
var iterator = try list.iterator()
while let element = try iterator.next() {
    values.append(try element.readUInt64())
}
```

For a map or a set, each cursor is at an entry, which ``Cursor/readEntry()`` turns into an ``Entry``, with a cursor
for its key and one for its value:

```swift
var keys: [String] = []
var iterator = try moment.iterator()
while let cursor = try iterator.next() {
    let entry = try cursor.readEntry()
    let key = String(decoding: try entry.key.readBytes(), as: UTF8.self)
    keys.append(key)
    switch try entry.value.slot.tag {
    case .uint:
        print(key, try entry.value.readUInt64())
    default:
        print(key, String(decoding: try entry.value.readBytes(), as: UTF8.self))
    }
}
```

A map only has a key to give if one was stored with ``HashMap/putKey(_:forHash:)-(_,Sequence<UInt8>)``; a value
alone is found by its hash, and a hash cannot be turned back into a key. An ``Entry`` is read-only whatever the
collection was, since a key is what the collection is ordered or indexed by. ``Entry/hash`` gives the entry's hash
as a new array, and ``Entry/withHash(_:)`` lets you look at it without one.

Iterate over a collection that is not being changed. An iterator goes through the collection as it was when the
iterator was made, unless the collection is changed in place during the same transaction. Then it can give a mix of old
and new elements, or throw an error; it does not stop the program.

### Nothing, and never written

There are two ways for a slot to hold no value, and they behave differently.

A slot that was **never written** is all zeros: ``Slot/isEmpty`` is true. A lookup gives `nil` for it, and an array
list's iterator passes over it. An element made with ``ArrayList/appendCursor()`` and not written is one of these.

A slot **set to nothing** with `.slot(nil)` has the tag ``Slot/Tag/none`` and is not empty. A lookup gives a cursor,
which reads as no bytes, and an iterator gives it:

```swift
let list = try ArrayList<ReadWrite>(database.rootCursor)
try list.append(.uint(1))
try list.append(.slot(nil))
_ = try list.appendCursor()

// Three elements: a value, a slot set to nothing, a slot never written.
```

That list has a ``ArrayList/count`` of 3. Its elements read as a ``Slot/Tag/uint``, as a slot with the tag ``Slot/Tag/none``, and as
`nil`, and its iterator gives only the first two. A ``LinkedArrayList`` has no slots that were never written: an element
it appends and nobody writes is set to nothing, so a lookup and its iterator both give it.

Setting a map's value to nothing is not removing the entry. The entry stays, and a counted map goes on counting it:

```swift
let map = try CountedHashMap<ReadWrite>(database.rootCursor)
try map.put(.uint(1), forHash: sha256("cleared"))
try map.put(.uint(2), forHash: sha256("removed"))

try map.put(.slot(nil), forHash: sha256("cleared"))
try map.remove(forHash: sha256("removed"))
```

That map's count is 1, and it still has an entry for `"cleared"`, with nothing in it.

### Copying a slot

``WritableData/slot(_:)`` writes a slot as it is, without copying what it points at. Both slots then share it, which is
how one moment starts from another without copying what it holds. A copy of something the same transaction made needs a
freeze: see <doc:CloningFreezeAndStaleHandles>. An empty slot is written as one set to nothing. A
client cannot make a slot; every slot it writes is one a database gave it, and it must have come from the same database.

It should also be a value. The slot of a cursor from a map's iterator is the entry's own, and writing it as a value is
refused with ``XitDBError/structuralSlot``, before anything is written. Read the entry, and write the slot of its
``Entry/value``.

## See Also

- <doc:TheCollections>
- <doc:Transactions>
- ``Cursor``
- ``Slot``
