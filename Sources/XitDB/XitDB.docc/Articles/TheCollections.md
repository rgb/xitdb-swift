# The collections

The eight collections, when to use which, and what they have in common at the call site.

## Overview

A database is a tree of collections. An element of a list and a value of a map can be anything, another collection
included. A collection is a value you make from a cursor, and it reads and writes the slot that cursor is at.

The examples use `sha256(_:)`, a helper that hashes a string: see <doc:BringYourOwnHashes>. They force-unwrap a
lookup where the value was just written; real code handles the `nil` that means it is not there. Where they use `moment`,
it is a ``HashMap`` in a transaction's body, as in <doc:MomentsAndHistory>. Reading a value and iterating over a collection
are in <doc:CursorsAndValues>.

### When to use which

| Collection | What it holds | Use it for |
|---|---|---|
| ``ArrayList`` | Elements by position. Appends at the end, cuts from the end. | A history; a log; any list that mostly grows. |
| ``LinkedArrayList`` | Elements by position. Inserts and removes anywhere; joins and cuts without going through the list. | A list you edit in the middle; lists joined or split often. |
| ``HashMap`` | Values under a hash you compute. | Looking things up by key. The first choice for a map. |
| ``CountedHashMap`` | The same, and it knows how many. | A map whose size you ask for. |
| ``HashSet`` | Keys under a hash you compute. | Membership. |
| ``CountedHashSet`` | The same, and it knows how many. | A set whose size you ask for. |
| ``SortedMap`` | Values under byte strings, in the order of the bytes. | An index: sorting, paging, searching by prefix. |
| ``SortedSet`` | Byte strings, in order. | An index with no values. |

Prefer ``ArrayList`` to ``LinkedArrayList`` and a hash map to a sorted map unless you need what the other one adds.
The trie behind the first of each pair is simpler, and a lookup in it reads less. ``LinkedArrayList`` and
``SortedMap`` are trees whose branches carry counts, so that they can find a position in logarithmic time, and are larger
for it. A leaf of either is 146 bytes, and a branch is 274 in a linked array list and 418 in a sorted collection, which also
holds a separator key for each child, against the 144 of a block of the trie.

Each is a view of one slot, and they nest. A value that is a collection is written by asking for a cursor at the
slot and making the collection there:

```swift
let database = try Database(creating: MemoryStorage(), hashSize: 32)
let history = try ArrayList<ReadWrite>(database.rootCursor)

try history.append(.slot(try history.slot(at: -1))) { cursor in
    let moment = try HashMap<ReadWrite>(cursor)
    let people = try ArrayList<ReadWrite>(moment.putCursor(forHash: sha256("people")))
    let alice = try HashMap<ReadWrite>(people.appendCursor())
    let scores = try SortedSet<ReadWrite>(alice.putCursor(forHash: sha256("scores")))
    try scores.insert("high".utf8)
}
```

And read the same way, one level at a time:

```swift
let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
let people = try ArrayList<ReadOnly>(moment.cursor(forHash: sha256("people"))!)
let alice = try HashMap<ReadOnly>(people.cursor(at: 0)!)
let scores = try SortedSet<ReadOnly>(alice.cursor(forHash: sha256("scores"))!)
```

### The read-only and read-write forms

Every collection is generic over its access, as a cursor is, and the two forms do different things when they are
made:

- **An ``ArrayList`` of ``ReadOnly`` access** checks that the slot holds a list or nothing, and writes nothing. A slot holding nothing
  reads as an empty collection. It can be made from a cursor of either access, so a reader can pass
  ``Database/rootCursor`` straight to it.
- **An ``ArrayList`` of ``ReadWrite`` access** makes the slot a list if it holds nothing. If the list is from an earlier transaction, it
  readies it for this one by copying its header and first block, so that writing leaves earlier moments as they
  were. That is why it needs a read-write cursor, and a transaction unless the cursor is at the root. On a list at the
  root it writes nothing new, since each transaction there does that copying when it starts. It does discard any bytes
  past the committed size, which are another writer's transaction if one is running without the lock: see <doc:Storage>.

```swift
// The read-write form makes the collection if it is not there yet.
let writable = try ArrayList<ReadWrite>(database.rootCursor)
try writable.append(.uint(1))

// These are the same list. The read-only forms cannot write: `append`
// is not a method of them.
let viaProperty: ArrayList<ReadOnly> = writable.readOnly
let viaCursor = try ArrayList<ReadOnly>(database.rootCursor)
```

Either form throws ``XitDBError/unexpectedTag`` for a slot that holds another kind of thing. A hash map and a hash set
are one kind here, and so are a sorted map and a sorted set: a read-only view of either reads the same entries, and
making the read-write form changes the slot's tag to its own, keeping the entries. A counted collection and an uncounted
one are different kinds.

Lookups give read-only cursors on both forms, and a lookup of something that is not there gives `nil`.

### The lists

``ArrayList`` appends, writes by index, and cuts from the end:

```swift
let list = try ArrayList<ReadWrite>(database.rootCursor)

try list.append(.uint(1))
try list.append(.uint(2))
try list.append(.uint(3))
try list.put(.uint(20), at: 1)
try list.truncate(to: 2)
```

``ArrayList/append(_:_:)`` appends and then runs a body at the new element, giving back what the body returns. On a
list at the root that is a transaction, as <doc:MomentsAndHistory> shows.

``LinkedArrayList`` can also change anywhere:

```swift
var tasks = try LinkedArrayList<ReadWrite>(moment.putCursor(forHash: sha256("tasks")))
try tasks.append(.uint(1))
try tasks.append(.uint(3))
try tasks.insert(.uint(2), at: 1)  // before the element at index 1
try tasks.remove(at: 0)

let more = try LinkedArrayList<ReadWrite>(moment.putCursor(forHash: sha256("more")))
try more.append(.uint(4))
try more.append(.uint(5))

// Joins in logarithmic time, sharing what it can with both lists.
try tasks.append(contentsOf: more)
```

```swift
// Keeps two elements from index 1 on.
try tasks.formSlice(offset: 1, count: 2)
```

Neither goes through the list. Today, with two lists of 4,096 elements in a map, a join in a transaction of its own did 31
reads and appended 494 bytes: 274 for the one new branch, and 220 for what any transaction reaching that list copies. Cutting
out the middle of the result did 108 reads and appended 8,584: the same 220, and new nodes for the edges of the tree at every
level. The next version's join changes these numbers: see <doc:DifferencesFromTheOriginal>.

<!-- Pinned by `whatAJoinAndACutCost` in XitDBExamples: the numbers and the test change together. -->

A join is `mutating`, so the list has to be a `var`. It also freezes the transaction, as
``LinkedArrayList/append(contentsOf:)-(LinkedArrayList<CursorAccess>)`` explains: to go on writing through another
collection you made before it, run the initialiser again on the cursor you hold.

``LinkedArrayList/insert(_:at:)`` needs an element to insert before, so an index equal to the count throws
``XitDBError/indexOutOfRange``. Use ``LinkedArrayList/append(_:)`` to add at the end.

### The hash maps and sets

```swift
let map = try HashMap<ReadWrite>(database.rootCursor)

try map.put(.uint(25), forHash: sha256("age"))
try map.putKey(.bytes(Array("age".utf8)), forHash: sha256("age"))
```

A map stores the value under the hash and, unless you ask, not the key. ``HashMap/putKey(_:forHash:)-(_,Collection<UInt8>)``
stores the key beside it, and is what makes keys readable when you iterate. ``HashMap/remove(forHash:)-(Collection<UInt8>)``
returns whether there was an entry to remove, and the result may be ignored.

A set holds keys:

```swift
let tags = try HashSet<ReadWrite>(database.rootCursor)

try tags.insert(.bytes(Array("swift".utf8)), forHash: sha256("swift"))
```

and answers ``HashSet/contains(hash:)-(Collection<UInt8>)``.

### The counted forms

``CountedHashMap`` and ``CountedHashSet`` are a map and a set that keep the number of their entries, so that
``CountedHashMap/count`` does not have to go through them. A plain ``HashMap`` and ``HashSet`` have no count at all. The
count sits in front of the first block, so a counted form costs eight bytes more each time that block is copied, and one
more write for each entry added or removed. Writing to a key that exists does not change the count:

```swift
let visits = try CountedHashMap<ReadWrite>(moment.putCursor(forHash: sha256("visits")))
try visits.put(.uint(1), forHash: sha256("alice"))
try visits.put(.uint(2), forHash: sha256("alice"))
try visits.put(.uint(1), forHash: sha256("bob"))
```

That map's count is 2. The lists and the sorted collections always know their count.

### Indices

A list's index, or a sorted collection's position, can be negative, which counts from the end. `-1` is the last
element:

```swift
let list = try ArrayList<ReadWrite>(database.rootCursor)
for value: UInt64 in [10, 20, 30] {
    try list.append(.uint(value))
}

let last = try list.cursor(at: -1)!.readUInt64()
let first = try list.cursor(at: -3)!.readUInt64()
let tooFar = try list.cursor(at: -4)
```

A lookup of an index that names nothing gives `nil`, an iterator from one gives nothing, and a write throws
``XitDBError/indexOutOfRange``.

An index is `some BinaryInteger`, so an `Int`, a `UInt64` and a `UInt8` all work without a conversion, and a loop
over `0..<(try list.count)` passes straight in. Counts are `UInt64`, and so are the counts and offsets that
``ArrayList/truncate(to:)`` and ``LinkedArrayList/formSlice(offset:count:)`` take. An index that does not fit in an
`Int64` names no element: a lookup gives `nil`, and a write or an iterator throws ``XitDBError/indexOutOfRange``.

```swift
// An `Int`, a `UInt64` and a `UInt8` are all indices.
let index: Int = 0
let count: UInt64 = try list.count
let byte: UInt8 = 0
```

### Hashes and keys

A hash, or a sorted collection's key, is `some Collection<UInt8>` at the call site today: an array, a slice, a string's
`utf8`, or Foundation's `Data`. The next version takes `some Sequence<UInt8>`. Each method also has an overload taking a
`Span<UInt8>`, for bytes you already have borrowed, which saves making an array:

```swift
let sorted = try SortedMap<ReadWrite>(database.rootCursor)

try sorted.put(.uint(1), forKey: Array("apple".utf8))
try sorted.put(.uint(2), forKey: "pear".utf8)
```

```swift
let hash = sha256("anything")
let map = try Database(creating: MemoryStorage(), hashSize: 32)
let hashed = try HashMap<ReadWrite>(map.rootCursor)
try hashed.put(.uint(1), forHash: hash)
try hashed.put(.uint(2), forHash: hash[...])
try hashed.put(.uint(3), forHash: hash.span)
```

A CryptoKit digest is a sequence and not a collection, so today it goes in as `Array(digest)`:
see <doc:BringYourOwnHashes>.

## See Also

- <doc:CursorsAndValues>
- <doc:MomentsAndHistory>
- <doc:BringYourOwnHashes>
- <doc:SortingAndPaginating>
- <doc:LargeByteArrays>
