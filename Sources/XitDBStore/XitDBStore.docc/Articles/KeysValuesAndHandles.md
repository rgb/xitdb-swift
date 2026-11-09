# Keys, values and handles

The store and its moments, handles that name a place, keys as Swift values and values as Swift types, and what the
layer costs.

## Overview

`XitDBStore` is the package's Swift layer. Its keys are Swift values, its values are Swift types, and a ``Handle``
names a place, not a thing: it holds the path to the place from a moment's root, a key through each map and an index
through each list, and looks the path up each time it is used.

The `XitDB` module, the faithful layer, mirrors the original call for call. You hash your own keys, write slots, and
make each collection from a cursor. That is what lets it be held to the original byte for byte, and it stays as it is.
The store is where Swift's types do the work. It writes through the faithful calls, and writes what they would write:
the conformance scripts that need nothing the store lacks, seven of them, give the original's files byte for byte when
they run through it.

A program that uses the store imports it alone:

```swift
import XitDBStore

let database = try Database(creating: MemoryStorage(), hashSize: 32)
let store = try Store(database, hashing: SHA256.self)

try store.transaction { moment in
    try moment["name"].set("Alice")
    try moment["age"].set(UInt64(25))
}

let name = try store.latest["name"].value(String.self)  // "Alice"
```

The store re-exports `XitDB` and `XitDBHashing`, so `Database`, the storages and `SHA256` come with it. Both `XitDB`
and the store have a `SortedMap`, a `SortedSet` and an `Entry`. In a file that imports only the store, those names are
the store's; a file that imports `XitDB` as well has to tell them apart by the module's name. So import the store
alone.

### A store and its moments

A ``Store`` stands over a `Database`, with the hash its keys are hashed by: `SHA256` for most, and the hashing article
in `XitDBHashing` has the others. The database's header records the size of its hashes, and a store whose hash has
another size is refused with `XitDBError.hashSizeMismatch` before anything is read or written.

The database's root is the history, a list with one ``Moment`` per transaction, each a map, in the shape the faithful
articles use. ``Store/transaction(_:)`` appends a moment that starts as a clone of the latest and runs the body with it.
The moment is writable while the body runs, and commits when the body returns. If the body throws, the moment rolls
back, and the error comes out of the call. A transaction while another is running is refused with
`XitDBError.nestedTopLevelWrite`.

``Store/latest`` is the last committed moment, and ``Store/moment(at:)`` any other, counted from the end when the index
is negative. Both are read-only: a write through them is refused with `XitDBError.expectedTxStart`. Inside a transaction
the database's root reads the last commit, so there `latest` is the commit the new moment was cloned from, and
``Store/momentCount`` does not count the moment being written.

A store belongs to one thread or task, as its database does. Another task reads a ``Store/snapshot()``: it makes a
`SnapshotDatabase` of it and takes its moment with ``Moment/init(reading:hashing:)``.

```swift
// The writer hands the last commit to a reader on another task.
let snapshot = try store.snapshot()
let reader = Task.detached {
    let reading = SnapshotDatabase(snapshot)
    let moment = try Moment(reading: reading, hashing: SHA256.self)
    return try moment["name"].value(String.self)
}
try store.transaction { moment in
    try moment["name"].set("Bob")
}
let read = try await reader.value  // "Alice", whatever the writer did meanwhile
```

The reader reads the commit the snapshot was taken of. ``Moment/init(reading:hashing:)`` also takes a `Database`, for
its last commit, and it checks the hash's size as the store does. What a snapshot holds and costs is in the `XitDB`
article on concurrency and snapshots.

### Handles

A moment's subscript gives a ``Handle``, and a handle's subscripts give the handles below it: `moment["users"]["alice"]`
names the entry for `"alice"` in the map at `"users"`. ``Handle/subscript(index:)`` goes down through a list, counting
from the end when the index is negative. Its label tells it from a key that is an integer: `handle[index: 0]` is a
list's first element, and `handle[0]` a map's entry for the key 0.

Making a handle reads nothing. Using one looks its path up:

- ``Handle/value(_:)`` reads the value at the place as a type, or gives `nil` if nothing is there;
- ``Handle/set(_:)`` writes a value in place of whatever was there, making the maps and lists on the way if they are
  empty;
- ``Handle/clear()`` leaves the place empty;
- ``Handle/exists`` says whether anything is there.

Because a handle names the place, a handle kept across writes is never stale. When what is at its place is replaced, it
finds the new thing:

```swift
try store.transaction { moment in
    let today = moment["notes"]["today"]
    try today.set("Buy bread")

    // The map at "notes" goes, and the handle still names its place.
    try moment["notes"].clear()
    let there = try today.exists  // false
    try today.set("Buy milk")  // and makes the map at "notes" again
}
```

How often a handle looks depends on the moment. A read-only moment's bytes are committed, and nothing moves them, so its
handle keeps the cursor it found the first time, for good. While you write, a handle always looks: in a writable moment,
everything below the moment's map is looked up again at each use. The moment's map itself is kept, shared by the
moment's handles, until a freeze in the transaction moves it.

A handle belongs to its moment. One kept from a transaction after its body has returned reads the moment as it was
committed, and a write through it is refused, with `XitDBError.expectedTxStart` outside any transaction and
`XitDBError.staleCursor` inside a later one.

The moment's own place, ``Moment/root``, is its map. ``Handle/set(_:)`` there is refused with
`XitDBError.unexpectedTag`, and so is every collection but a ``Map``, while ``Handle/clear()`` there empties the
moment.

### Keys

A key is a ``KeyRepresentable``: a type that gives its bytes as ``KeyRepresentable/keyBytes`` and comes back from them
through ``KeyRepresentable/init(keyBytes:)``, which gives `nil` for bytes that are no value of the type, such as the
wrong number of them. A hash map stores an entry by the hash of the bytes. A sorted map or set stores the bytes
themselves, and keeps them in byte order.

- `String` and `Substring` are their UTF-8.
- The integers are big-endian, and the signed ones have their sign bit flipped, so that their bytes sort as their
  values do and mean the same key on every machine. `Int` and `UInt` are eight bytes on every machine.
- `[UInt8]` and `Bytes` are themselves.
- An enum with a raw value of one of these types is a key once it declares the conformance, which goes through the raw
  value:

```swift
enum Role: String {
    case admin, guest
}

extension Role: KeyRepresentable {}
```

A type of your own gives its bytes. The store invents no encoding for tuples, so a key of several parts is a struct whose
bytes are its parts, each with a separator or its length in front.

Because the integers sort, a sorted map keyed by them is in numeric order, the negative numbers first:

```swift
try store.transaction { moment in
    let readings = moment["readings"].sortedMap(Int.self, String.self)
    try readings.put("mild", forKey: 12)
    try readings.put("cold", forKey: -5)
    try readings.put("freezing", forKey: -20)
}

let readings = try store.latest["readings"].sortedMap(Int.self, String.self)
var entries = try readings.entries()
while let entry = try entries.next() {
    print(entry.key, entry.value)  // -20 freezing, then -5 cold, then 12 mild
}
```

A collection's elements come out of a ``ValueIterator``: ``Map/values()``, ``List/elements()``,
``SortedMap/entries(from:)``, and the keys of the sets. Reading the next element can fail, so the iterator's
``ValueIterator/next()`` throws, and the iterator is not a `Sequence` and has no `for` loop. `while let` is the shape, as
above. After an error the iterator is done. An iterator in a writable moment can give a mix of old and new elements if the
collection changes while it runs, as the faithful one can.

### Values

A value is a ``StorableValue``: a type that reads itself from a faithful read-only cursor and writes itself through a
read-write one. The format has unsigned and signed integers, doubles and byte arrays, and the conformances are those:

- `UInt64`, `Int64` and `Double` are the format's scalars.
- `String` is its UTF-8, as a byte array, and `[UInt8]` is a byte array as it is.
- `Bool` is an unsigned integer, 1 or 0, and reads back as `true` from any but 0.
- An `Optional` writes nothing for `nil`, and reads as `nil` from a place that holds nothing.

`Int` is not one of them: say which of the format's integers you mean, with `Int64(count)` or `UInt64(count)`. Reading
a value of another kind than the one at the place throws `XitDBError.unexpectedTag`. A record, a struct of fields, is a
map of them: see <doc:CodableRecords>.

Reads throw, and a Swift subscript can throw only when it is read, never when it is set. So a collection's subscript is a
throwing getter, and its writes are methods, ``Map/put(_:forKey:)`` and ``List/append(_:)`` among them:

```swift
try store.transaction { moment in
    let ages = moment["ages"].map(String.self, UInt64.self)
    try ages.put(25, forKey: "alice")
}

let ages = try store.latest["ages"].map(String.self, UInt64.self)
let age = try ages["alice"]  // 25
```

### The collections

A handle's place can be read and written as one of eight collections, the faithful layer's eight under the store's
names:

| The store | The faithful layer | What it holds |
|---|---|---|
| ``Map`` | `HashMap` | Values, by the hash of their keys. |
| ``CountedMap`` | `CountedHashMap` | The same, with its count. |
| ``KeySet`` | `HashSet` | Keys, each stored as its bytes under its hash. |
| ``CountedKeySet`` | `CountedHashSet` | The same, with its count. |
| ``List`` | `ArrayList` | Values, by position. |
| ``LinkedList`` | `LinkedArrayList` | Values, by position, inserted and removed anywhere, joined and sliced by sharing. |
| ``SortedMap-4xtdk`` | `SortedMap` | Values, by the bytes of their keys, in byte order. |
| ``SortedSet-5dn9y`` | `SortedSet` | Keys, in byte order. |

A handle gives one when it is told the types: `moment["ages"].map(String.self, UInt64.self)`, as above. That reads and
writes nothing. The collection is made by its first write, and a read of one that does not exist yet finds nothing. A
``Map`` gives back values and not keys, since it stores only the keys' hashes, and two keys with one hash name one entry,
as in the original. For the keys, use a ``KeySet``, or keep the key in the value.

A collection is not a value. It is reached through a handle, and never stored as a value. A collection inside a
collection is the handle one level down: `handle[key]`, or ``Map/subscript(handleFor:)`` on a map and
``List/subscript(handleAt:)`` on a list. ``List/append()`` adds an empty element at the end of a list and gives its
handle:

```swift
try store.transaction { moment in
    let alice = moment["users"]["alice"]
    try alice["email"].set("alice@example.com")
    try alice["roles"].keySet(Role.self).insert(.admin)

    // A list of lists: append() gives the handle of a new, empty element.
    let rounds = moment["rounds"].list(UInt64.self)
    let first = try rounds.append().list(UInt64.self)
    try first.append(3)
}
```

The outer list's type is that of the values it holds itself. An element that is a collection is read through its handle,
`rounds[handleAt: 0]`.

Going down through a handle's subscripts treats the place as a plain map or array list, and makes one if the place is
empty. Through a counted map or a linked list, go down from the typed collection, with
``CountedMap/subscript(handleFor:)`` or ``LinkedList/subscript(handleAt:)``, which make their own kind.

A collection that has to exist while it is empty, such as a record's list with no elements yet, is made by
``Handle/make(_:)``, with its ``CollectionKind``. It works as the format's own initialisers do: a place that holds nothing
gets the collection, one that holds a collection of that kind keeps it as it is, and one that holds anything else is
refused with `XitDBError.unexpectedTag`.

```swift
try store.transaction { moment in
    // A list that has to exist before it has elements.
    try moment["queue"].make(.list)
}
let made = try store.latest["queue"].exists  // true
```

``LinkedList/join(_:)`` appends another linked list's elements by sharing them. In the faithful layer a join makes every
cursor and collection from before it stale, as the `XitDB` article on cloning and freezes explains. A handle holds no
cursor across it, so nothing goes stale, and the handles go on.

``Store/database`` is the `Database` underneath, for the faithful calls the store has no words for, such as compaction
and replication.

### What the layer costs

A store's lookups take time that the faithful calls do not spend. The package measured it at 0.2.0, in a release
build, with the store's map one level under the moment's root, as application code has it, against the faithful calls
on a map at the root:

| | In memory | Buffered file | File |
|---|---|---|---|
| A put | 2.25 times | 2.03 times | 1.48 times |
| A get through one handle | 1.61 times | 1.06 times | 1.06 times |
| Going through the values | 0.83 times | 0.91 times | 0.99 times |

In memory, 100,000 puts took 42.6 ms against the faithful calls' 18.9. The costs are those of the layer's lookups, not of
the engine. A put looks up its path below the moment's map again, where the faithful call writes through a map it already
holds.

A get costs what it does because a read-only handle keeps what it found. A new moment and handle for each read took 95 ms
for the same 100,000 reads in memory, against 19.7 through one handle. So keep a handle, or a collection taken from one, for
the reads you repeat, rather than taking ``Store/latest`` again for each.

These are the package's measurements, on one machine. Yours will differ with the machine.

## See Also

- <doc:CodableRecords>
- <doc:/tutorials/XitDBStore>
- ``Store``
- ``Moment``
- ``Handle``
