# Iterating

Going through a collection: by its cursors, by its entries or its elements read as a type, and by a closure to the end.

## Overview

Every collection has an iterator, such as ``ArrayList/iterator()``. It gives a ``CollectionIterator``, whose
``CollectionIterator/next()`` gives a read-only cursor, or `nil` at the end. It is not a Swift `Sequence`, because
reading the next element can fail, so `while let` is the shape. A list gives its elements in order, a sorted map or set
its entries in the order of their keys, and a hash map or set in the order of their hashes, which looks random. For a
map or a set, each cursor is at an entry, which ``Cursor/readEntry()`` turns into an ``Entry``, with a cursor for its
key and one for its value. In the examples `moment` is a ``HashMap`` that is one moment of a history, keyed by `SHA256`,
`list` an ``ArrayList`` of 1, 2 and 3, and `describe(_:)` the function in <doc:CursorsAndValues> that says what a cursor
holds.

**A map's entry has a key only where one was stored.** A put stores the value under the hash of its key. A put or a put
cursor stores the key beside it only when given `storingKey: true`, and ``HashMap/putKey(_:)`` stores it on its own (see
<doc:TheCollections>); a hash cannot be turned back into its key. Here `"name"` was put with the argument and `"age"`
without, so the second entry has no key:

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

That prints `name Alice` and `a value stored under its hash alone: 25`, in the order the map keeps. Where no key was
stored, the entry's key is a slot never written, which a cursor reads as empty bytes, with no error, so check
``Slot/isEmpty`` before taking it for a name. A set's member is its key, which ``HashSet/insert(_:)`` stores. An
``Entry`` is read-only whatever the collection was; ``Entry/hash`` gives its hash as a new array, and
``Entry/withHash(_:)`` lets you look at it without one.

### Entries, and elements as a type

Every map and set has an `entries()`, such as ``HashMap/entries()``, which gives an ``EntryIterator``: its
``EntryIterator/next()`` gives the ``Entry`` itself. The two lists have an `elements(as:)`, such as
``ArrayList/elements(as:)``, which gives an ``ElementIterator``: its ``ElementIterator/next()`` gives each element read
as the type. Neither is a `Sequence`, for the same reason, and a loop over either stops where it likes:

```swift
var names: [String] = []
var entries = try moment.entries()
while let entry = try entries.next() {
    if try entry.key.slot.isEmpty { continue }
    names.append(try entry.key.read(String.self))
}
```

```swift
var total: UInt64 = 0
var numbers = try list.elements(as: UInt64.self)
while let number = try numbers.next() {
    total += number
}
```

Every element read this way is read as the type, as ``Cursor/read(_:)`` reads it. One of another kind ends the loop with
``XitDBError/unexpectedTag``, after the ones before it were given. So does an element that was appended and never
written, which is a slot set to nothing, for a number; a `String`, a `[UInt8]` or ``Bytes`` reads it as empty, with no
error. A list that holds several kinds, or elements that may never have been written, is gone through by its cursors.
Every collection also says whether it holds anything, by an `isEmpty`, such as ``HashMap/isEmpty``. A hash map and a
hash set keep no count, so theirs reads down to the first entry and no further: it does not walk the map, and may be
asked in a loop.

### A walk to the end

A map or a set has a `forEachEntry(_:)`, such as ``HashMap/forEachEntry(_:)``; a list has a `forEachElement(_:)`, which
gives each element's cursor, and a second that gives each element read as a type, such as
``ArrayList/forEachElement(as:_:)``:

```swift
var sum: UInt64 = 0
try list.forEachElement(as: UInt64.self) { number in
    sum += number
}
```

```swift
var values: [String] = []
try moment.forEachEntry { entry in
    values.append(try describe(entry.value))
}
```

Such a walk ends early only by an error: the closure's, which comes out of the call as itself, so that these calls throw
`any Error`, as a transaction does, or for the typed walk a read's, as above. Where the library's error is declared,
they are made inside ``XitDBError/carrying(_:)``: see <doc:Errors>. A loop that is to stop where it likes takes one of
the iterators. The calls are not named `forEach`: `swift format`, with its default rules, takes any call of that name
with a closure for a sequence's, and says to write a `for` loop, of which there is none to write.

### While the collection changes

Iterate over a collection that is not being changed. An iterator goes through the collection as it was when the iterator
was made, unless the collection is changed in place during the same transaction. Then it can give a mix of old and new
elements, or throw an error; it does not stop the program. An iterator made through a cursor from a transaction that did
not commit is refused with ``XitDBError/staleCursor``, as the cursor is. An iterator stays with its database's thread or
task: another task reads a ``Snapshot``. Lists and sorted collections can also start at an index, and a sorted one at a
key: see <doc:SortingAndPaginating>.

## See Also

- ``CollectionIterator``
- ``EntryIterator``
- ``ElementIterator``
