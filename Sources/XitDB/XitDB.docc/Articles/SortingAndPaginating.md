# Sorting and paginating

Keeping an index of your own in a sorted map, and walking it a page at a time.

## Overview

The hash collections are good for finding a value by key, but they hold their entries in hash order, which means
nothing to anyone reading a screen. A program that shows a list of users alphabetically, a page at a time, needs
something that keeps an order.

A relational database gives you that with `CREATE INDEX` and `ORDER BY`, and a query planner maintains the index. XitDB
has no planner and no built-in indexes. An index is a data structure you write yourself: a ``SortedMap`` whose keys sort the
way you want, written in the same transaction as the data it indexes. That takes more code, on every write that changes a
key. Every query is a walk you write, so what it costs is what that code does.

An ``ArrayList`` is no use for this. It keeps things in the order they were written, and as soon as you want any other
order you need a structure that stays sorted by a key.

The examples use `sha256(_:)`, a helper that hashes a string: see <doc:BringYourOwnHashes>. They force-unwrap a lookup where
the value was just written; real code handles the `nil` that means it is not there.

### A primary store and an index

Take a directory of users that are looked up by ID and listed by username:

```swift
struct User {
    let id: String
    let username: String
    let name: String
}
```

The primary store is a ``HashMap`` from the ID to the user's fields, like a row keyed by its primary key. The index is a
``SortedMap`` from the username to the ID. The moment goes in a `history` like the one in <doc:MomentsAndHistory>:

```swift
// Inserted in no particular order; the index puts them in order.
let users = [
    User(id: "user000000000001", username: "dave", name: "Dave Smith"),
    User(id: "user000000000002", username: "alice", name: "Alice Jones"),
    User(id: "user000000000003", username: "carol", name: "Carol White"),
    User(id: "user000000000004", username: "dan", name: "Dan Brown"),
    User(id: "user000000000005", username: "bob", name: "Bob Lee"),
    User(id: "user000000000006", username: "eve", name: "Eve Adams"),
]

try history.append(.slot(try history.slot(at: -1))) { cursor in
    let moment = try HashMap<ReadWrite>(cursor)

    // The primary store: from a user's ID to the user's fields.
    let idToUser = try HashMap<ReadWrite>(
        moment.putCursor(forHash: sha256("id->user")))

    // The index: from a username to the user's ID, in username order.
    let usernameToID = try SortedMap<ReadWrite>(
        moment.putCursor(forHash: sha256("username->id")))

    for user in users {
        let fields = try HashMap<ReadWrite>(
            idToUser.putCursor(forHash: sha256(user.id)))
        try fields.put(.bytes(Array(user.username.utf8)), forHash: sha256("username"))
        try fields.put(.bytes(Array(user.name.utf8)), forHash: sha256("name"))

        // Both in one transaction, so that they cannot disagree.
        try usernameToID.put(.bytes(Array(user.id.utf8)), forKey: user.username.utf8)
    }
}
```

Keeping the two in step is your job, not the database's. The transaction is what makes it possible: no moment has one
without the other.

### A page

A page is an offset and a size, as in `ORDER BY username LIMIT 2 OFFSET 2`. ``SortedMap/iterator(fromIndex:)`` starts at a
position, and you walk forward as far as the page goes:

```swift
let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
let idToUser = try HashMap<ReadOnly>(moment.cursor(forHash: sha256("id->user"))!)
let usernameToID = try SortedMap<ReadOnly>(
    moment.cursor(forHash: sha256("username->id"))!)

// ORDER BY username LIMIT 2 OFFSET 2
let pageSize = 2
let offset = 2

var names: [String] = []
var iterator = try usernameToID.iterator(fromIndex: offset)
while names.count < pageSize, let cursor = try iterator.next() {
    let entry = try cursor.readEntry()
    let id = String(decoding: try entry.value.readBytes(), as: UTF8.self)

    let fields = try HashMap<ReadOnly>(idToUser.cursor(forHash: sha256(id))!)
    let name = try fields.cursor(forHash: sha256("name"))!.readBytes()
    names.append(String(decoding: name, as: UTF8.self))
}
```

That gives Carol White and Dan Brown. The tree's branches count what is beneath them, so finding a position takes
logarithmic time and skips nothing by walking over it: a page near the end of an index of 10,000 entries took about as many
reads as the first. ``SortedMap/count`` gives the total
for the page count, and it reads only a header.

### Seeking to a key

An index can also seek to a key, which is what a list can never do. ``SortedMap/iterator(fromKey:)-(Sequence<UInt8>)`` starts
at the first key that is not below the one you give, and that key does not have to exist. This is a type-ahead search:

```swift
// Everyone whose username starts with "da".
let prefix = Array("da".utf8)

var usernames: [String] = []
var iterator = try usernameToID.iterator(fromKey: prefix)
while let cursor = try iterator.next() {
    let key = try cursor.readEntry().key.readBytes()
    guard key.starts(with: prefix) else { break }
    usernames.append(String(decoding: key, as: UTF8.self))
}
```

### Positions

A sorted collection can answer in both directions between keys and positions. ``SortedMap/rank(of:)-(Sequence<UInt8>)``
gives the number of keys below a key, which is the position it has or would have. ``SortedMap/entry(at:)`` gives the entry at
a position, and a negative position counts from the end:

```swift
// alice bob carol dan dave eve
let carol = try usernameToID.rank(of: "carol".utf8)  // 2
let notThere = try usernameToID.rank(of: "david".utf8)  // 5: it would come before eve
let third = try usernameToID.entry(at: 2)!.key.readBytes()  // carol
let last = try usernameToID.entry(at: -1)!.key.readBytes()  // eve
```

There is no reverse iterator. To go backwards, ask for positions from the end, each of which costs a descent from the root:

```swift
// There is no reverse iterator. A position counts from either end.
var usernames: [String] = []
for index in 1...2 {
    let key = try usernameToID.entry(at: -index)!.key.readBytes()
    usernames.append(String(decoding: key, as: UTF8.self))
}
```

If you mostly read an index backwards, store its keys so that they sort the other way round.

### Keys are bytes

Keys compare as unsigned bytes from the first, and a key that is a prefix of another comes before it. That is the whole of
what the collection knows about order, and it has consequences:

```swift
let words = try SortedSet<ReadWrite>(database.rootCursor)

for word in ["apple", "Zebra", "app", "éclair", "10", "9"] {
    try words.insert(word.utf8)
}
```

Those come back as `10`, `9`, `Zebra`, `app`, `apple`, `éclair`: digits before capitals before lower case before anything
accented, and `10` before `9`. That is UTF-8 order, not any language's. If you need an order for people, compute a sort key
that has it, and index by that.

Numbers need encoding so that their bytes sort as they do. An unsigned number in big-endian is already right. When a sort
key is not unique, append something that is, or two entries with the same key will be one:

```swift
// A key that sorts by score. Big-endian makes byte order match numeric
// order, and the user's ID keeps two equal scores apart.
func scoreKey(score: UInt64, userID: [UInt8]) -> [UInt8] {
    withUnsafeBytes(of: score.bigEndian) { Array($0) } + userID
}
```

A signed number needs its top bit flipped, so that the negative numbers come first:

```swift
// A signed number sorts in order once its top bit is flipped.
func signedKey(_ value: Int64) -> [UInt8] {
    let flipped = UInt64(bitPattern: value) ^ (1 << 63)
    return withUnsafeBytes(of: flipped.bigEndian) { Array($0) }
}
```

A key costs little if it is short. One of up to eight bytes with no zero byte is held in a slot, and a longer one is a record of
its own. In a set that slot is the entry, and in a map it is in an 18-byte record with the value. An entry in a sorted map or set
has no hash, and ``Entry/hash`` gives zeros for it.

### Keeping an index in step

A key cannot be changed, only replaced, because its place in the tree depends on it. A change to what an index is keyed by is
a remove and a put, in the same transaction as the change to the data:

```swift
// A rename: the index entry moves, in the same transaction as the
// user's field, so that no moment has one without the other.
try history.append(.slot(try history.slot(at: -1))) { cursor in
    let moment = try HashMap<ReadWrite>(cursor)
    let idToUser = try HashMap<ReadWrite>(
        moment.putCursor(forHash: sha256("id->user")))
    let usernameToID = try SortedMap<ReadWrite>(
        moment.putCursor(forHash: sha256("username->id")))

    let fields = try HashMap<ReadWrite>(
        idToUser.putCursor(forHash: sha256("user000000000003")))
    try fields.put(.bytes(Array("caroline".utf8)), forHash: sha256("username"))
    try usernameToID.remove(forKey: "carol".utf8)
    try usernameToID.put(
        .bytes(Array("user000000000003".utf8)), forKey: "caroline".utf8)
}
```

A remove leaves an empty place in its leaf and does not rebalance the tree. Positions and counts stay right.

### Several indexes, and sets

You can keep as many indexes over one primary store as you have orders to show, each a ``SortedMap`` in the moment, each
written in the same transactions. An index that holds no value is a ``SortedSet``, which has the same iterators, positions and
ranks, and ``SortedSet/contains(_:)-(Sequence<UInt8>)``:

```swift
let usernames = try SortedSet<ReadWrite>(database.rootCursor)

try usernames.insert("alice".utf8)
try usernames.insert("bob".utf8)
try usernames.insert("alice".utf8)
```

That set has two keys. Inserting a key that is there already changes nothing.

## See Also

- ``SortedMap``
- ``SortedSet``
- <doc:TheCollections>
- <doc:BringYourOwnHashes>
