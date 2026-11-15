# The collections

The eight collections, when to use which, and what they have in common at the call site.

## Overview

A database is a tree of collections. An element of a list and a value of a map can be anything, another collection
included. A collection is a value you make from a cursor, and it reads and writes the slot that cursor is at.

Unless one makes its own, the examples are in a database given `SHA256` as the hasher of its keys (see <doc:Hashing>).
They force-unwrap a lookup where the value was just written; real code handles the `nil` that means it is not there.
Where they use `moment`, it is a ``HashMap`` in a transaction's body, as in <doc:MomentsAndHistory>. The values, reading
them and iterating over a collection are in <doc:CursorsAndValues>.

### When to use which

| Collection | What it holds | Use it for |
|---|---|---|
| ``ArrayList`` | Elements by position. Appends at the end, cuts from the end. | A history; a log; any list that mostly grows. |
| ``LinkedArrayList`` | Elements by position. Inserts and removes anywhere; joins and cuts without going through the list. | A list you edit in the middle; lists joined or split often. |
| ``HashMap`` | Values, each under the hash of its key. | Looking things up by key. The first choice for a map. |
| ``CountedHashMap`` | The same, and it knows how many. | A map whose size you ask for. |
| ``HashSet`` | Keys, each under its hash. | Membership. |
| ``CountedHashSet`` | The same, and it knows how many. | A set whose size you ask for. |
| ``SortedMap`` | Values under keys of text or bytes, in the order of the bytes. | An index: sorting, paging, searching by prefix. |
| ``SortedSet`` | Keys of text or bytes, in order. | An index with no values. |

Prefer ``ArrayList`` to ``LinkedArrayList`` and a hash map to a sorted map unless you need what the other one adds.
The trie behind the first of each pair is simpler, and a lookup in it reads less. ``LinkedArrayList`` and
``SortedMap`` are trees whose branches carry counts, so that they can find a position in logarithmic time, and are larger
for it.

Each is a view of one slot, and they nest. A value that is a collection is written by asking for a cursor at the
slot and making the collection there:

```swift
let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
let history = try ArrayList<ReadWrite>(database.rootCursor)

try history.append(.slot(try history.slot(at: -1))) { cursor in
    let moment = try HashMap<ReadWrite>(cursor)
    let people = try ArrayList<ReadWrite>(moment.putCursor(forKey: "people"))
    let alice = try HashMap<ReadWrite>(people.appendCursor())
    let scores = try SortedSet<ReadWrite>(alice.putCursor(forKey: "scores"))
    try scores.insert("high")
}
```

And read the same way, one level at a time:

```swift
let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
let people = try ArrayList<ReadOnly>(moment.cursor(forKey: "people")!)
let alice = try HashMap<ReadOnly>(people.cursor(at: 0)!)
let scores = try SortedSet<ReadOnly>(alice.cursor(forKey: "scores")!)
```

### The read-only and read-write forms

Every collection is generic over its access, as a cursor is, and the two forms do different things when they are
made:

- **An ``ArrayList`` of ``ReadOnly`` access** checks that the slot holds a list or nothing, and writes nothing. A slot
  holding nothing reads as an empty collection. It can be made from a cursor of either access, so a reader can pass
  ``Database/rootCursor`` straight to it, and ``ArrayList/readOnly`` gives it from a read-write list.
- **An ``ArrayList`` of ``ReadWrite`` access** makes the slot a list if it holds nothing. If the list is from an earlier
  transaction, it readies it for this one by copying its header and first block, so that writing leaves earlier moments
  as they were. That is why it needs a read-write cursor, and a transaction unless the cursor is at the root. On a list
  at the root it writes nothing new, since each transaction there does that copying when it starts. It does discard any
  bytes past the committed size, which are another writer's transaction if one is running without the lock: see
  <doc:Storage>.

Either form throws ``XitDBError/unexpectedTag`` for a slot that holds another kind of thing. A hash map and a hash set
are one kind here, and so are a sorted map and a sorted set: a read-only view of either reads the same entries, and
making the read-write form changes the slot's tag to its own, keeping the entries. A counted collection and an uncounted
one are different kinds.

Lookups give read-only cursors on both forms, and a lookup of something that is not there gives `nil`.

### The lists

``ArrayList`` appends, writes by index, and cuts from the end:

```swift
let list = try ArrayList<ReadWrite>(database.rootCursor)

try list.append(UInt64(1))
try list.append(UInt64(2))
try list.append(UInt64(3))
try list.put(UInt64(20), at: 1)
try list.truncate(to: 2)
```

``ArrayList/append(_:_:)`` appends and then runs a body at the new element, giving back what the body returns. On a
list at the root that is a transaction, as <doc:MomentsAndHistory> shows.

``LinkedArrayList`` can also change anywhere:

```swift
let tasks = try LinkedArrayList<ReadWrite>(moment.putCursor(forKey: "tasks"))
try tasks.append(UInt64(1))
try tasks.append(UInt64(3))
try tasks.insert(UInt64(2), at: 1)  // before the element at index 1
try tasks.remove(at: 0)

let more = try LinkedArrayList<ReadWrite>(moment.putCursor(forKey: "more"))
try more.append(UInt64(4))
try more.append(UInt64(5))

// Joins in logarithmic time, sharing what it can with both lists.
// The join freezes the transaction, so the list is made again
// from the transaction's cursor before it is written to.
try tasks.append(contentsOf: more)
let joined = try LinkedArrayList<ReadWrite>(HashMap<ReadWrite>(cursor).putCursor(forKey: "tasks"))
```

```swift
// Keeps two elements from index 1 on.
try joined.formSlice(offset: 1, count: 2)
```

Neither goes through the list. A join freezes the transaction, so every collection you made before it is stale, the list
that joined included, and a write through one is refused with ``XitDBError/staleCursor``. Take the list again from the
transaction's cursor, the one its body was given, as the example does with `joined`. Making it again from the list's own
cursor is refused too: see <doc:CloningFreezeAndStaleHandles>.

``LinkedArrayList/insert(_:at:)-(StorableValue,_)`` needs an element to insert before, so an index equal to the count
throws ``XitDBError/indexOutOfRange``. Use ``LinkedArrayList/append(_:)-(StorableValue)`` to add at the end.

### The hash maps and sets

```swift
let map = try HashMap<ReadWrite>(database.rootCursor)

try map.put(UInt64(25), forKey: "age", storingKey: true)
```

**A map stores the value under the key's hash, and the key only when asked.** Given `storingKey: true`, a put stores the
key beside the value, in the one walk to the entry, and writes what ``HashMap/putKey(_:)`` and then the put write in one
transaction. Without it the map has the hash alone, as in the original, and a hash cannot be turned back into its key.
Store the keys of a map that is to be listed: a program that lists the map, another port's or xitdb-dump, sees hashes
and not names. Store them too in a file that programs in the other ports write: their keyed put always stores the key,
so a map put here without it becomes one where some entries have a key and some have none, though a read by key finds
them all. The argument is given put by put: an entry put without it has a key that reads as empty, with no error (see
<doc:CursorsAndValues>). On an entry that has its key, the argument writes nothing more. The number is `UInt64(25)`,
since `25` does not compile: a number says which of the format's kinds it is. Each untyped keyed call has a twin by
hash, `forHash:` (`hash:` for a set's `contains`), which it is with the hash computed, and a put that stores its key is
the twins of `putKey` and then `put` (see <doc:Hashing>); the typed calls have none, so by hash a value is put as
`.uint(25)` and read with `cursor(forHash:)?.read(UInt64.self)`.

**A set stores its members.** A member is a key, so ``HashSet/insert(_:)`` writes its bytes, with a ``Bytes`` key's
format tag, as the original's set does, and iterating gives them back:

```swift
let tags = try HashSet<ReadWrite>(database.rootCursor)

try tags.insert("swift")
let hasSwift = try tags.contains("swift")
```

### The counted forms

``CountedHashMap`` and ``CountedHashSet`` are a map and a set that keep the number of their entries, so that
``CountedHashMap/count`` does not have to go through them. A plain ``HashMap`` and ``HashSet`` have no count at all. The
count sits in front of the first block, so a counted form costs eight bytes more each time that block is copied, and one
more write for each entry added or removed. Writing to a key that exists does not change the count:

```swift
let visits = try CountedHashMap<ReadWrite>(moment.putCursor(forKey: "visits"))
try visits.put(UInt64(1), forKey: "alice")
try visits.put(UInt64(2), forKey: "alice")
try visits.put(UInt64(1), forKey: "bob")
```

That map's count is 2. The lists and the sorted collections always know their count.

### Indices

A list's index, or a sorted collection's position, can be negative, which counts from the end. `-1` is the last element:

```swift
let list = try ArrayList<ReadWrite>(database.rootCursor)
for value: UInt64 in [10, 20, 30] {
    try list.append(value)
}

let last = try list.value(at: -1, as: UInt64.self)
let first = try list.value(at: -3, as: UInt64.self)
let tooFar = try list.value(at: -4, as: UInt64.self)
```

A lookup of an index that names nothing gives `nil`, an iterator from one gives nothing, and a write throws
``XitDBError/indexOutOfRange``.

An index is `some BinaryInteger`, so an `Int`, a `UInt64` and a `UInt8` all work without a conversion, though an `Int`
is not a value, and a loop over `0..<(try list.count)` passes straight in. Counts are `UInt64`, and so are the counts
and offsets that ``ArrayList/truncate(to:)`` and ``LinkedArrayList/formSlice(offset:count:)`` take. An index that does
not fit in an `Int64` names no element: a lookup gives `nil`, and a write or an iterator throws
``XitDBError/indexOutOfRange``.

### Hashes and keys

A key is any ``KeyRepresentable`` on the six collections that take keys, all but the lists: a `String` or a `Substring`,
as its UTF-8; a `[UInt8]`; a ``Bytes``; or a type of your own that gives its bytes. Two keys with the same bytes are one
key. A type whose raw value is a string is a key once it says so, which keeps the names of a record's fields in one
place, here in `person`, a map of one person's fields:

```swift
enum Field: String, KeyRepresentable {
    case name, age
}
try person.put(UInt64(25), forKey: Field.age)
```

A hash map or set hashes the key with the database's hasher and keeps the hash; a ``Bytes`` key is hashed without its
format tag, which ``HashSet/insert(_:)``, ``HashMap/putKey(_:)`` and a put that stores its key keep. A sorted map or set
hashes nothing: it keeps the key's bytes, in their order, without a ``Bytes`` key's tag, and needs no hasher:

```swift
let sorted = try SortedMap<ReadWrite>(database.rootCursor)

try sorted.put(UInt64(1), forKey: "apple")
try sorted.put(UInt64(2), forKey: Array("pear".utf8))
```

A sorted collection's untyped calls also take a key as a `Span<UInt8>`; to its typed calls a slice, a string's `utf8` or
`Data` goes in as `Array(…)`. A hash by `forHash:` is `some Sequence<UInt8>`, a CryptoKit digest, an array, a slice or
`Data`, made into an array, free for an array; or a `Span<UInt8>`, with no allocation up to 64 bytes:

```swift
let hashes = try Database(creating: MemoryStorage(), hashSize: 32)
let hashed = try HashMap<ReadWrite>(hashes.rootCursor)

let bytes = [UInt8](repeating: 7, count: 32)
try hashed.put(.uint(1), forHash: SHA256.keyHash(of: "anything"))
try hashed.put(.uint(2), forHash: bytes)
try hashed.put(.uint(3), forHash: bytes[...])
try hashed.put(.uint(4), forHash: bytes.span)
```

## See Also

- <doc:CursorsAndValues>
- <doc:MomentsAndHistory>
- <doc:Hashing>
- <doc:SortingAndPaginating>
- <doc:LargeByteArrays>
