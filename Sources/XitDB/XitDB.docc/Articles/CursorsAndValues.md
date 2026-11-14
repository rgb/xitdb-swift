# Cursors and values

What a slot holds, how a value is written and read as a Swift type, and how a cursor reads and writes one.

## Overview

Every value in a database lives behind a ``Slot``: nine bytes, one saying what kind of thing it holds and eight
that hold either the value itself or the offset of a record with the value in it. A ``Cursor`` is a position in
the database, at one slot. Everything is read and written through a cursor, and the collections are views over
one.

Where the examples use `moment`, it is a ``HashMap`` that is one moment of a history, as in <doc:MomentsAndHistory>, in
a database given `SHA256` as the hasher of its keys (see <doc:Hashing>): a read-write one in a transaction's body, and a
read-only one to read through. They force-unwrap a lookup where the value was just written; real code handles the `nil`
that means it is not there.

### Values

The library's values are six Swift types, each written as a slot the format has, so that a program in any language reads
it back:

| Type | Written as | The slot's tag |
|---|---|---|
| `UInt64` | an unsigned integer | ``Slot/Tag/uint`` |
| `Int64` | a signed integer | ``Slot/Tag/int`` |
| `Double` | a float, bit for bit | ``Slot/Tag/float`` |
| `String` | its UTF-8, as a byte array | ``Slot/Tag/shortBytes`` or ``Slot/Tag/bytes`` |
| `[UInt8]` | a byte array | the same |
| ``Bytes`` | a byte array, with its format tag if it has one | the same |

A map puts a value under a key, and gives it back as the type it is asked for, given with `as:` or left to what the
result is assigned to:

```swift
try moment.put(UInt64(42), forKey: "unsigned")
try moment.put(-42 as Int64, forKey: "signed")
try moment.put(2.5, forKey: "double")
try moment.put("hello", forKey: "greeting")

let unsigned = try moment.value(forKey: "unsigned", as: UInt64.self)
let signed: Int64? = try moment.value(forKey: "signed")
let greeting = try moment.value(forKey: "greeting", as: String.self)
```

A list does the same by index, with ``ArrayList/append(_:)-(StorableValue)`` and ``ArrayList/value(at:as:)``, and a
cursor with ``Cursor/read(_:)`` and ``Cursor/write(_:)-(StorableValue)``. They add nothing to the file:
`put(UInt64(42), forKey:)` writes what `put(.uint(42), forKey:)` writes, and ``Cursor/readUInt64()`` reads it back.
``WritableData`` is the format's own form of a value, and the one to write a slot or nothing with.

**A number says its kind.** The format keeps unsigned integers, signed integers and floats apart, and so does the
original, whose programs write `.{ .uint = 25 }` or `.{ .int = 25 }`. `Int` is not a value: `put(25, forKey: "age")`
does not compile, nor does an `Int` variable or a read `as: Int.self`, and the compiler says what to write instead,
"an integer's kind is spelled: UInt64 or Int64, or .uint(25) and .int(25)". A literal with a fraction, such as `2.5`,
is a `Double`, the format's float.

**A read is strict about the kind**, as the original's reads are. Reading a `UInt64` from a signed integer, any number
from bytes, or a `String` from a number or a collection throws ``XitDBError/unexpectedTag``. A `String` and a
`[UInt8]` read a byte array whatever its format tag. A `String` reads the bytes as UTF-8, and bytes that are not valid
UTF-8 throw ``XitDBError/invalidUTF8``: nothing is repaired, and `[UInt8]` reads them.

Numbers and short byte arrays cost nothing beyond their slot: a byte array of at most eight bytes with no zero byte in
it, or six with a format tag, is stored in the slot, as ``Bytes/isShort`` says. Any other has a record of its own, with
an eight-byte length in front, as does one written a part at a time (<doc:LargeByteArrays>).

A value that could be of several kinds is read by looking at the tag first:

```swift
func describe(_ cursor: Cursor<ReadOnly>) throws -> String {
    switch try cursor.slot.tag {
    case .uint: "\(try cursor.read(UInt64.self))"
    case .int: "\(try cursor.read(Int64.self))"
    case .float: "\(try cursor.read(Double.self))"
    case .bytes, .shortBytes: String(decoding: try cursor.read([UInt8].self), as: UTF8.self)
    case .none: "nothing"
    default: "a collection"
    }
}
```

### No value, and nothing

Where there is no value to give, the typed reads of a collection say which of two cases it is:

- **No value**: the map has no entry for the key, the list no element at the index, or the slot is one that was
  never written, all zeros, for which ``Slot/isEmpty`` is true. ``HashMap/value(forKey:as:)`` and
  ``ArrayList/value(at:as:)`` give `nil`.
- **Nothing**: the value was set to nothing with `.slot(nil)`, and the slot has the tag ``Slot/Tag/none``. It is
  there. Read as a `String`, a `[UInt8]` or ``Bytes`` it is empty, and read as a number it throws
  ``XitDBError/unexpectedTag``.

A cursor's own ``Cursor/read(_:)`` has no `nil` to give: at a slot never written it reads as at one set to nothing.

So an empty string and nothing read alike, as they do through the original's `readBytesAlloc`, which gives no bytes for
a slot set to nothing (its read into a buffer refuses one: see <doc:DifferencesFromTheOriginal>). A reader who must tell
them apart looks at the slot:

```swift
try moment.put("", forKey: "empty")
try moment.put(.slot(nil), forKey: "cleared")

let empty = try moment.value(forKey: "empty", as: String.self)  // ""
let cleared = try moment.value(forKey: "cleared", as: String.self)  // "" as well
let missing = try moment.value(forKey: "missing", as: String.self)  // nil
let wasCleared = try moment.slot(forKey: "cleared")?.tag == Slot.Tag.none  // true
```

An element of a list that was appended and never written is nothing too, so that a lookup and the iterator give it, as
in the original:

```swift
let list = try ArrayList<ReadWrite>(database.rootCursor)
try list.append(UInt64(1))
try list.append(.slot(nil))
_ = try list.appendCursor()

// Three elements: a value, a slot set to nothing, and one appended
// and never written.
```

That list has a ``ArrayList/count`` of 3, its iterator gives all three, and the last two read as `""` and throw as a
number. A ``LinkedArrayList`` does the same with an element it appends and nobody writes. In a file written before
0.3.0, or by the original before `89da8e7`, an array list's element appended and never written is a slot never written,
and reads as no value. Setting a map's value to nothing is not removing the entry either: the entry stays, and a counted
map goes on counting it.

### Format tags

A byte array can carry a ``FormatTag``, two bytes that say how to read it. XitDB does not interpret them; they are
for whoever reads the value. Here a date stored as text says so:

```swift
// A date, stored as text, with a tag that says how to read it.
let date = Bytes(Array("2026-11-07T09:47:00Z".utf8), formatTag: "dt")
try moment.put(date, forKey: "created")

let created = try moment.value(forKey: "created", as: Bytes.self)
```

The result has the value in ``Bytes/value`` and the tag in ``Bytes/formatTag``. A tag can be any two bytes, so there
are 65,536 of them.

### A type of your own

A type of your own is a value once it conforms to ``StorableValue``, by saying how it reads itself from a slot and
writes itself to one. A record is usually a map of its fields, which any reader of the format can read:

```swift
struct Person {
    var name: String
    var age: UInt64
}

extension Person: StorableValue {
    init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        let fields = try HashMap<ReadOnly>(cursor)
        guard let name = try fields.value(forKey: "name", as: String.self),
            let age = try fields.value(forKey: "age", as: UInt64.self)
        else { throw .keyNotFound }
        self.name = name
        self.age = age
    }

    func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        // Clear the slot first, so that the record takes the place of
        // whatever was there.
        try cursor.write(.slot(nil))
        let fields = try HashMap<ReadWrite>(cursor)
        try fields.put(name, forKey: "name")
        try fields.put(age, forKey: "age")
    }
}
```

The line that clears the slot matters. A map made from a cursor writes into the map that is already there, so without it
the record would keep the fields of an earlier one that it does not write, and a slot that holds a number would refuse
it with ``XitDBError/unexpectedTag``. Cleared, the slot takes the record in place of whatever it held. The record then
goes wherever a value goes. Through the cursor at the root of the database, though, every write is a transaction of its
own, so a record written there commits its cleared slot and each field one by one, and one that fails partway leaves
what it had written. Write a record in a transaction's body, or through a collection's typed call, which is one
transaction even at the root:

```swift
let people = try ArrayList<ReadWrite>(moment.putCursor(forKey: "people"))

try people.append(Person(name: "Alice", age: 25))
let first = try people.value(at: 0, as: Person.self)
```

### Cursors

A cursor is generic over what it can do. A cursor of ``ReadOnly`` access has only the reading methods, and one of
``ReadWrite`` access has the writing ones as well, so writing through a read-only cursor does not compile.
``Cursor/readOnly`` gives a read-only cursor from a read-write one. Every lookup on a collection gives a read-only
cursor, so a read cannot change anything by mistake.

A read-write cursor comes from the methods that make room for a value, inside a transaction:

```swift
var cursor = try moment.putCursor(forKey: "counter")
try cursor.write(UInt64(1))
```

Do this in a transaction's body. On a collection at the root those methods are transactions of their own, which have
committed by the time they return: the entry is there without a value, and with no transaction running, a write
through the cursor throws ``XitDBError/expectedTxStart``. Do not keep such a cursor for a later transaction, as
<doc:Transactions> explains.

``Cursor/writeIfEmpty(_:)`` writes only if no value has been written to the slot, for a value that should be set once. It
decides by the slot as it is now, not by the cursor's copy of it, so a value written through another cursor since is kept.
A slot set to nothing counts as unwritten when the cursor was made on an empty slot, since that is what an element just
appended with ``ArrayList/appendCursor()`` is, and so is written over too; a cursor made on a slot already set to nothing
writes nothing.

<!-- Pinned by `writeIfEmptyGoesByTheSlot` and `writeIfEmptyAndASlotSetToNothing` in XitDBExamples: the sentences and the tests change together. -->

```swift
var maybe = try moment.putCursor(forKey: "once")
try maybe.writeIfEmpty(.uint(1))
try maybe.writeIfEmpty(.uint(2))
```

### A cursor holds a copy of its slot

A cursor remembers what its slot held when it was made, and reads go by that. A write through another cursor does
not show:

```swift
let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
let list = try ArrayList<ReadWrite>(database.rootCursor)
try list.append(UInt64(1))

// A cursor below the root keeps what it saw.
let element = try list.cursor(at: 0)!
try list.put(UInt64(2), at: 0)
```

Here `element` still reads 1, and a new lookup reads 2. The exception is a cursor at the root of the database, from
``Database/rootCursor``, which reads the last commit every time, so it does see later transactions: its `count` read
before and after another append gives 1 and then 2. That is why a collection made from it can be kept from one
transaction to the next. Only the slot is copied. What it points at is read when you ask for it, so a cursor held on a
list changed in place in the same transaction reports the list's new count.

### Iterating

Every collection has an iterator, such as ``ArrayList/iterator()``. It gives a ``CollectionIterator``, whose
``CollectionIterator/next()`` gives a read-only cursor, or `nil` at the end. It is not a Swift `Sequence`, because
reading the next element can fail. For a map or a set, each cursor is at an entry, which ``Cursor/readEntry()`` turns
into an ``Entry``, with a cursor for its key and one for its value.

**A map's entry has a key only where one was stored.** A put stores the value under the hash of its key and does not
store the key, as in the original, and a hash cannot be turned back into its key. ``HashMap/putKey(_:)`` stores a key
beside its value. Here one entry has its key and the other does not:

```swift
try moment.putKey("name")
try moment.put("Alice", forKey: "name")
try moment.put(UInt64(25), forKey: "age")
```

```swift
var iterator = try moment.iterator()
while let cursor = try iterator.next() {
    let entry = try cursor.readEntry()
    if try entry.key.slot.isEmpty {
        print("a value stored under its hash alone:", try describe(entry.value))
    } else {
        print(try entry.key.read(String.self), try describe(entry.value))
    }
}
```

That prints `name Alice` and `a value stored under its hash alone: 25`, in the order the map keeps, which follows the
hashes and not the order of the puts. Where no key was stored, the entry's key is a slot never written, and a cursor
reads one as empty bytes, so check ``Slot/isEmpty`` before taking it for a name. A set is the other case: its member is
its key, so ``HashSet/insert(_:)`` stores it, and an entry's key is the member. An ``Entry`` is read-only whatever the
collection was, since a key is what the collection is ordered or indexed by. ``Entry/hash`` gives the entry's hash as a
new array, and ``Entry/withHash(_:)`` lets you look at it without one.

Iterate over a collection that is not being changed. An iterator goes through the collection as it was when the
iterator was made, unless the collection is changed in place during the same transaction. Then it can give a mix of old
and new elements, or throw an error; it does not stop the program.

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
- ``StorableValue``
- ``Cursor``
- ``Slot``
