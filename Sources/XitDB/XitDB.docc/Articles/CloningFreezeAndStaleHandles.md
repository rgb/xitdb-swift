# Cloning, freeze and stale handles

How to copy a collection, why a copy of something made in the same transaction needs a freeze, and how to go on writing
after one.

## Overview

Copying a slot copies none of what it points at. The two slots then share it, and a later write through either one copies
what it changes, which leaves the other as it was. That is cloning: whatever the size of what is shared, the copy is one slot.

It works because committed data never changes in place. Data that the running transaction made itself is different: the
transaction changes it in place, because nothing committed can refer to it yet, and that is what makes a large transaction
affordable. A copy of such data is a second name for one mutable thing. ``Database/freeze()`` turns that data into the
committed kind for the rest of the transaction, so a copy made before the freeze stays as it was.

A freeze also changes the handles you hold. Every cursor and collection made before it can still read, and is refused if it
tries to write, even to make a collection again from it. The one exception is making a collection from the cursor the
transaction's body was given, or from another cursor at its slot, and the way on starts there. The rest of this article is
about why.

### A copy of committed data

The examples in this article start from a history whose first moment has a list of fruits:

```swift
let database = try Database(creating: MemoryStorage(), hashSize: 32)
let history = try ArrayList<ReadWrite>(database.rootCursor)
try history.append(.slot(try history.slot(at: -1))) { cursor in
    let moment = try HashMap<ReadWrite>(cursor)
    let fruits = try ArrayList<ReadWrite>(moment.putCursor(forHash: sha256("fruits")))
    try fruits.append(.bytes(Array("apple".utf8)))
    try fruits.append(.bytes(Array("pear".utf8)))
}
```

A later transaction can make a new list from that one by copying its slot, and change the copy freely:

```swift
try history.append(.slot(try history.slot(at: -1))) { cursor in
    let moment = try HashMap<ReadWrite>(cursor)

    // "food" starts as a copy of "fruits", which an earlier transaction made.
    let fruits = try moment.slot(forHash: sha256("fruits"))
    try moment.put(.slot(fruits), forHash: sha256("food"))
    let food = try ArrayList<ReadWrite>(moment.putCursor(forHash: sha256("food")))
    try food.append(.bytes(Array("rice".utf8)))
}
```

Afterwards "food" has three elements and "fruits" still has two. The copy took a new entry in the map, 50 bytes. Making the
list from it copied the list's header and its block, 160 bytes, and the append then wrote in place.

### A copy of data from the same transaction

The same copy of a list that the transaction has just made does not work:

```swift
try history.append(.slot(try history.slot(at: -1))) { cursor in
    let moment = try HashMap<ReadWrite>(cursor)
    let bigCities = try ArrayList<ReadWrite>(
        moment.putCursor(forHash: sha256("big-cities")))
    try bigCities.append(.bytes(Array("New York, NY".utf8)))
    try bigCities.append(.bytes(Array("Los Angeles, CA".utf8)))

    // "cities" starts as a copy of "big-cities", which this transaction made.
    try moment.put(.slot(try bigCities.slot), forHash: sha256("cities"))
    let cities = try ArrayList<ReadWrite>(moment.putCursor(forHash: sha256("cities")))
    try cities.append(.bytes(Array("Charleston, SC".utf8)))
}
```

Both lists now have three elements, because they are one list. Nothing reports it: the database cannot tell a copy that
was meant from one that was not.

### The copy done right

Freeze after the copy, and take the collections again from the cursor the transaction's body was given:

```swift
try history.append(.slot(try history.slot(at: -1))) { cursor in
    let moment = try HashMap<ReadWrite>(cursor)
    let bigCities = try ArrayList<ReadWrite>(
        moment.putCursor(forHash: sha256("big-cities")))
    try bigCities.append(.bytes(Array("New York, NY".utf8)))
    try bigCities.append(.bytes(Array("Los Angeles, CA".utf8)))

    // 1. Copy the slot.
    try moment.put(.slot(try bigCities.slot), forHash: sha256("cities"))

    // 2. Freeze: nothing written so far in this transaction changes in place any more.
    try cursor.database.freeze()

    // 3. Take the collections again, from the cursor the body was given.
    let again = try HashMap<ReadWrite>(cursor)
    let cities = try ArrayList<ReadWrite>(again.putCursor(forHash: sha256("cities")))
    try cities.append(.bytes(Array("Charleston, SC".utf8)))
}
```

"cities" has three elements and "big-cities" two. Step 3 is not optional: `moment` and `bigCities` were made before the
freeze, and a write through either is refused, and so is making `bigCities` again from its own cursor.

### What a freeze does to the handles you hold

After ``Database/freeze()``, every cursor and collection made before it in the transaction is stale, with one exception,
the cursor the transaction's body was given, described below:

- **A write through it is refused** with ``XitDBError/staleCursor``: a value, an append, a
  ``HashMap/putCursor(forHash:)-(Sequence<UInt8>)``, a byte array, and making a collection again from its cursor. The guard runs
  before anything is written, so the transaction is not poisoned (see <doc:Transactions>) and goes on.
- **A read through it works**, and reads what the handle points at, which the freeze keeps as it is. It does not see what
  fresh handles write afterwards, since they write copies.
- **The cursor the body was given goes on.** Its slot is in a record the engine keeps for the transaction, the copy of
  the root slot, or in ``ArrayList/append(_:_:)`` on a history the new element's slot in the history's block, and nothing in
  the transaction can copy that record. So making a collection from it is allowed after a freeze, and so is a write of a
  value through it, ``Cursor/write(_:)`` and ``Cursor/writeIfEmpty(_:)`` and a path that begins with a write, which rewrite
  that slot in place as the original does; the cursors and collections that gives are fresh. A byte writer through it is
  refused like any other write. The engine goes by the slot, so the cursor of a collection made from it, such as
  `moment.cursor`, can make a collection too, whenever the collection was made. Writes through the collection itself are
  refused all the same.

The way on is the one in step 3: start from the cursor the body was given, which is at the top of everything the transaction
writes, and make each collection again on the way down to where you write.

A cursor from an earlier transaction is refused for every write, making a collection included, with no exception. Take a new
one from the root: see <doc:Transactions>. What reads through such a cursor give is in <doc:ConcurrencyAndSnapshots>.

### Why a held cursor cannot start again

Making the collection again from the cursor you already hold would be shorter, `ArrayList<ReadWrite>(stock.cursor)`, and the
original allows it. The port refuses it, because of what the initialiser does: it writes the cursor's own slot, in place, to
point at the copy it makes. That slot is in a record made before the freeze, and anything else that shares the record would
change with it: a copy of a collection that contains the slot, whether the copy was made before the freeze or after. And once
anything has copied that record since the freeze, as a second handle taken from the root does on its way down, the root no
longer reaches the record the slot is in, and the write is lost at the commit without an error.

Here a whole map is copied, and a list inside it is then written through a cursor held from before the freeze:

```swift
let shop = try HashMap<ReadWrite>(root.putCursor(forHash: sha256("shop")))
let stock = try ArrayList<ReadWrite>(shop.putCursor(forHash: sha256("stock")))
try stock.append(.uint(1))

// A copy of the whole shop, and a freeze to keep it as it is.
try root.put(.slot(try shop.slot), forHash: sha256("yesterday"))
try cursor.database.freeze()
```

```swift
// Refused with staleCursor: it would write the list's slot in place,
// in a record the copy shares.
try ArrayList<ReadWrite>(stock.cursor).append(.uint(2))
```

In the original that append goes through, and after the commit both "shop" and "yesterday" have a stock of two: the copy shares
the map's entries, and the list's slot is in one of them. Taken again from the body's cursor, the same append leaves "yesterday"
with a stock of one:

```swift
let rootAgain = try HashMap<ReadWrite>(cursor)
let shopAgain = try HashMap<ReadWrite>(rootAgain.putCursor(forHash: sha256("shop")))
try ArrayList<ReadWrite>(shopAgain.putCursor(forHash: sha256("stock")))
    .append(.uint(2))
```

Some held cursors would be safe to start again from, such as one at the copied collection itself while nothing has copied the
record its slot is in. The engine cannot tell those from the rest without following every copy, so it refuses them all. The
body's cursor is the exception because its slot is in the one record that no copy can share.

### A join freezes too

``LinkedArrayList/append(contentsOf:)-(LinkedArrayList<CursorAccess>)`` joins two lists by sharing nodes with both, so it
freezes the transaction as ``Database/freeze()`` does. Every collection made before the join is stale afterwards, the list that
called it included, and a write through one is refused. To go on, take the list again from the body's cursor:

```swift
try tasks.append(contentsOf: more)
// The list that joined is stale too. Take it again from the body's cursor.
let joined = try LinkedArrayList<ReadWrite>(
    HashMap<ReadWrite>(cursor).putCursor(forHash: sha256("tasks")))
try joined.append(.uint(3))
```

A join on one list stales the handles of every other in the transaction, since the freeze is the database's.

### The original's pattern, with a cursor's freeze

The original's documentation clones with ``Cursor/freeze()``, on the cursor of the copy, before making the collection:

```swift
// The original's pattern: copy the slot, freeze the cursor, make the list.
var citiesCursor = try moment.putCursor(forHash: sha256("cities"))
try citiesCursor.write(.slot(try bigCities.slot))
try citiesCursor.freeze()
let cities = try ArrayList<ReadWrite>(citiesCursor)
```

A cursor's freeze protects what the copy points at from writes through that cursor, and through what is made from it, and from
nothing else. Writes through the copy leave the original alone. Writes through the original still change shared data in place,
and the copy sees them: with a list of 300, a value written at index 200 through `bigCities` reads back through `cities`. In a
linked list or a sorted map or set, the copy's header ends up disagreeing with its tree: a sorted map of 40 copied this way,
after ten removes through the original and one put through the copy, counts 41 entries and holds 31. A read or a write that
runs into the difference throws an error such as ``XitDBError/invalidBTreeNode``. The original can crash there; the port gives
the error.

So use ``Database/freeze()`` whenever both sides may be written in the same transaction. A cursor's freeze makes no handle
stale, and the guard does not count it. The port does what the original does here; whether it should do more is not decided.

### What a freeze costs

A freeze writes nothing. Its cost comes at the first write after it, which copies what lies on the way to the place it changes,
as a write to committed data does. Writes after that, to places already copied, are in place again.

The numbers depend on the shape. Here it is two linked lists of 1,000 elements, made in the same transaction in a map at the
root, and then joined. The join appended 822 bytes to the file. Taking the list again from the body's cursor appended 210: the
map's block, 144 bytes, when the map was made again, the list's entry, 50, at the `putCursor`, and the list's header, 16, when
the list was made again. The first append after that appended 1,114, copying the nodes on its way down to the end of the list, and the
second appended nothing: it wrote in place, as writes to what the transaction has made since the freeze do. With lists of 10,000
elements the join appended 274, taking the list again the same 210, and the first append 1,388. The path, and so the cost of the
first append, grows with the logarithm of the size.

### Where this is going

The `XitDBStore` layer's handles do this: a handle remembers its path from the moment's root and resolves it again on
every use, so that freezing and joining need nothing from you, and a clone is safe without one. See
<doc:DifferencesFromTheOriginal> for the rest of what the layer adds.

## See Also

- <doc:MomentsAndHistory>
- <doc:Transactions>
- <doc:TheCollections>
- <doc:ConcurrencyAndSnapshots>
- ``Database/freeze()``
- ``Cursor/freeze()``
- ``XitDBError/staleCursor``
