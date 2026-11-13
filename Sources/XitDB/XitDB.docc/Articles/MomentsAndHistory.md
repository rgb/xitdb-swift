# Moments and history

How a database keeps every earlier state readable, and what that costs.

## Overview

A transaction does not change the database in place. It appends what it changes to the end of the storage and
then points the root at the new data. The old data stays where it was, and stays reachable from the old root.
If you keep a way to reach the old roots, every earlier state of the database stays readable.

The way to keep them is a list at the root, usually with one element per transaction. An element of that list is a
*moment*: one state of the database. The list is the *history*.

The examples use `sha256(_:)`, a helper that hashes a string: see <doc:BringYourOwnHashes>. They force-unwrap a
lookup where the value was just written; real code handles the `nil` that means it is not there.

### The root

Reading and writing start at ``Database/rootCursor``, a cursor at the slot that holds the root of the last
commit. A new database's root is empty, and it can hold anything. Making an ``ArrayList`` from the cursor makes
the root a list:

```swift
let database = try Database(creating: MemoryStorage(), hashSize: 32)

let history = try ArrayList<ReadWrite>(database.rootCursor)
```

That is a transaction of its own the first time. Once the root is a list, it writes nothing new. It does discard any
bytes past the committed size, as the start of a transaction would, which is why a second process must not do this:
see <doc:Storage>.

### One moment per transaction

``ArrayList/append(_:_:)`` on the list at the root runs a transaction. It appends an element, writes the value
it was given there, runs its body with a cursor at the element, and commits when the body returns:

```swift
for price: UInt64 in [10, 12, 15] {
    try history.append(.slot(try history.slot(at: -1))) { cursor in
        let moment = try HashMap<ReadWrite>(cursor)
        try moment.put(.uint(price), forHash: sha256("price"))
    }
}
```

The value is the point of the pattern. ``ArrayList/slot(at:)`` with `-1` is the slot of the last element, and
``WritableData/slot(_:)`` writes it as it is, so the new moment starts as the previous one, sharing everything
it holds. None of that has been copied. In the first transaction there is no last element, the slot is `nil`,
and `.slot(nil)` writes a slot set to nothing, which ``HashMap`` then makes into a new map.

Copying happens as the body changes things. Making the read-write ``HashMap`` copies the first block of the map
it was given, and each ``HashMap/put(_:forHash:)-(_,Sequence<UInt8>)`` copies the blocks on the way to the entry it changes. Everything else stays shared
with earlier moments:

![A history of three moments, each a map. The first holds apples at 120 and pears at 300. The second shares the pears with the first and has a new price for apples. The third shares the new price and has no pears.](history.svg)

So a moment keeps what it does not change:

```swift
try history.append(.slot(try history.slot(at: -1))) { cursor in
    let moment = try HashMap<ReadWrite>(cursor)
    try moment.put(.bytes(Array("widget".utf8)), forHash: sha256("name"))
    try moment.put(.uint(10), forHash: sha256("price"))
}

// The second moment starts as the first, so it still has the name.
try history.append(.slot(try history.slot(at: -1))) { cursor in
    try HashMap<ReadWrite>(cursor).put(.uint(12), forHash: sha256("price"))
}
```

### Reading an earlier moment

A moment is an element of the list, so any of them can be read by its index, and `-1` is the latest:

```swift
// Each commit is an element: the first holds 10, the last holds 15.
let first = try HashMap<ReadOnly>(history.cursor(at: 0)!)
let firstPrice = try first.cursor(forHash: sha256("price"))!.readUInt64()

let latest = try HashMap<ReadOnly>(history.cursor(at: -1)!)
let latestPrice = try latest.cursor(forHash: sha256("price"))!.readUInt64()
```

The history can be walked like any list:

```swift
// The whole history can be walked.
var prices: [UInt64] = []
var moments = try history.iterator()
while let cursor = try moments.next() {
    let moment = try HashMap<ReadOnly>(cursor)
    prices.append(try moment.cursor(forHash: sha256("price"))!.readUInt64())
}
```

Reading an old moment costs the same as reading the latest one. It is the same structure, reached from a
different slot.

### Going back

Undoing is appending an earlier moment. Nothing the moment holds is copied, so it costs what a moment that changes
nothing costs, however large the moment is:

```swift
// Back to the first moment. The history keeps growing: the moment we
// are undoing stays readable, as element 2.
try history.append(.slot(try history.slot(at: 0)))
```

### What immutable means here

A transaction leaves committed bytes as they are, with one exception: the committed size, eight bytes in the root header
near the start of the file, which every commit rewrites to point at itself. Rewriting it is what completes a transaction, as
<doc:Transactions> explains.

Three things follow that are easy to get wrong:

- **Data is not immutable while the transaction that made it is running.** A transaction changes in place what
  it made itself, because nothing committed can refer to it. That is what makes large transactions affordable.
  It also means that copying a slot within one transaction gives two names for one mutable thing:
  <doc:CloningFreezeAndStaleHandles> says what to do about that.
- **Removing something does not remove its bytes.** Removing a key from the latest moment leaves it in every
  earlier moment, and in the file. To get rid of data for good, remove it, compact the database, which also
  discards the history (``Database/compact(into:offsetMap:)``), and delete the old file.
- **A cursor belongs to its transaction.** A write through one kept from an earlier transaction is refused with
  ``XitDBError/staleCursor``, which is what keeps committed bytes, and every earlier moment, as they are. Make a new
  cursor in each transaction. A read through a kept cursor still works if its transaction committed, and reads what the
  cursor saw.

### What it costs

Every transaction appends, whether or not it changes anything. A new database is 57 bytes. After that, for a
database with 32-byte hashes:

| A moment that changes nothing, in a history of | Bytes appended |
|---|---|
| up to 16 moments | 194 |
| up to 256 moments | 338 |
| up to 4,096 moments | 482 |
| more | 626 |

The 194 are a 9-byte copy of the root slot, 160 bytes for a copy of the list's header and first block, and the
25-byte trailer that ends every transaction. A longer history adds a 144-byte block for each level of the list on
the way to its last element, and one more block, once, each time the list grows a level.

Changing a value adds to that a copy of each 144-byte block on the way to the entry, and a copy of the entry, which
is 50 bytes. How many blocks grows with the logarithm of the size of the map, in base 16. Changing one value in a map
of 1,000 entries, in a short history, appended 676 bytes for most keys, and from 532 to 964 for the rest, depending on
how deep the key lies.

So a file grows with the number of transactions and with the amount they change, not with the amount of data
they end up holding. Grouping writes into fewer transactions is the first answer to that, since a transaction
changes in place what it has already copied, so a block is copied once however many writes it takes. Compacting is the second: ``Database/compact(into:offsetMap:)`` writes a new file
holding only what the latest moment reaches.

### Doing without a history

A root does not have to be a list. If you do not need earlier states, make the root a map and write to it
directly:

```swift
let map = try HashMap<ReadWrite>(database.rootCursor)
try map.put(.uint(10), forHash: sha256("price"))
```

Each ``HashMap/put(_:forHash:)-(_,Sequence<UInt8>)`` is then a transaction of its own, unless you group them with ``Database/withTransaction(_:)``. The
bytes of earlier states are still in the file, with nothing in the database leading to them. The file still grows with
every transaction until you compact it, by 160 bytes less per transaction in a short history because there is no list to
copy, and 144 less for each level of a longer one.

## See Also

- <doc:Transactions>
- <doc:Compaction>
- <doc:CursorsAndValues>
- ``ArrayList``
