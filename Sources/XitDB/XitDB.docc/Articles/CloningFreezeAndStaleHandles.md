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
tries to write. The rest of this article is about what to do instead.

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
    try moment.put(.slot(try moment.slot(forHash: sha256("fruits"))), forHash: sha256("food"))
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
    let bigCities = try ArrayList<ReadWrite>(moment.putCursor(forHash: sha256("big-cities")))
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
    let bigCities = try ArrayList<ReadWrite>(moment.putCursor(forHash: sha256("big-cities")))
    try bigCities.append(.bytes(Array("New York, NY".utf8)))
    try bigCities.append(.bytes(Array("Los Angeles, CA".utf8)))

    // 1. Copy the slot.
    try moment.put(.slot(try bigCities.slot), forHash: sha256("cities"))

    // 2. Freeze: nothing this transaction has written so far changes in place any more.
    try cursor.database.freeze()

    // 3. Take the collections again, from the cursor the body was given.
    let again = try HashMap<ReadWrite>(cursor)
    let cities = try ArrayList<ReadWrite>(again.putCursor(forHash: sha256("cities")))
    try cities.append(.bytes(Array("Charleston, SC".utf8)))
}
```

"cities" has three elements and "big-cities" two. Step 3 is not optional: `moment` and `bigCities` were made before the
freeze, and a write through either is refused.

### What a freeze does to the handles you hold

After ``Database/freeze()``, every cursor and collection made before it in the transaction is stale:

- **A write through it is refused** with ``XitDBError/staleCursor``. The guard runs before anything is written, so the
  transaction is not harmed and goes on. That covers every write: a value, an append, a `putCursor`, a byte array.
- **A read through it works**, and reads what the handle points at, which the freeze keeps as it is. It does not see what
  fresh handles write afterwards, since they write copies.
- **A collection made again from it is fresh.** Making a collection runs its initialiser, which copies the collection's header,
  or its first block, into the transaction, and that is allowed through a stale cursor of the same transaction. The cursors
  and collections it gives are fresh.

The safe way on is the one in step 3: start from the cursor the body was given, which is at the top of everything the
transaction writes, and make each collection again on the way down to where you write.

A cursor from an earlier transaction is stale for writing in the same way, and stays so: no initialiser makes it fresh,
because there it would write into committed bytes. Take a new one from the root.

### A collection made again from a cursor you held

Making the collection again from the cursor you already hold also works, and is shorter: `ArrayList<ReadWrite>(stock.cursor)`.
What it costs is less obvious. The initialiser writes the cursor's own slot, in place, to point at the copy it makes. That slot
is in a record made before the freeze, and if a copy made before the freeze shares that record, the copy changes with it.

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
// Writes the list's slot in place, in a record the copy shares.
try ArrayList<ReadWrite>(stock.cursor).append(.uint(2))
```

After the commit, both "shop" and "yesterday" have a stock of two. The copy shares the map's entries, and the list's slot is in
one of them. Taken again from the root, the same append leaves "yesterday" with a stock of one:

```swift
let rootAgain = try HashMap<ReadWrite>(cursor)
let shopAgain = try HashMap<ReadWrite>(rootAgain.putCursor(forHash: sha256("shop")))
try ArrayList<ReadWrite>(shopAgain.putCursor(forHash: sha256("stock"))).append(.uint(2))
```

So a collection made again from a held cursor is safe in two cases: the cursor is at the copied collection itself, whose slot is
its own (making "shop" again from `shop.cursor` leaves "yesterday" alone), or nothing that contains its slot was copied in this
transaction. The engine cannot tell a shared record from one that is not, so nothing refuses the other case. When in doubt, go
from the root.

### A join freezes too

``LinkedArrayList/append(contentsOf:)-(LinkedArrayList<CursorAccess>)`` joins two lists by sharing nodes with both, so it
freezes the transaction as ``Database/freeze()`` does. The list that called it is the exception: it is refreshed by the call and
goes on working.

```swift
try tasks.append(contentsOf: more)
// The list that joined goes on working.
try tasks.append(.uint(3))
```

Every other collection made before the join, `more` included, is stale, and a write through it is refused. A join on one list
stales the handles of every other in the transaction, since the freeze is the database's.

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

Measured with two linked lists of 1,000 elements, made in the same transaction in a map at the root and then joined: the join
wrote 822 bytes. The first append after it copied 1,114 bytes, and the second wrote none. A hundred appends after the join wrote
3,688 bytes, against 2,172 for a hundred appends to a list of 2,000 that was never joined. With lists of 10,000, the first append
copied 1,388 bytes. The path, and so the cost, grows with the logarithm of the size.

### Where this is going

A layer of Swift-style handles is planned for the package, and not here yet. Its handles remember their path from the root and
take themselves again after a freeze, so that freezing and joining need nothing from you, and a clone is safe without one. See
<doc:DifferencesFromTheOriginal> for what else is planned.

## See Also

- <doc:MomentsAndHistory>
- <doc:Transactions>
- <doc:TheCollections>
- ``Database/freeze()``
- ``Cursor/freeze()``
- ``XitDBError/staleCursor``
