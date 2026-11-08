# Compaction

Getting space back: a new database holding only what the latest moment reaches.

## Overview

A database only grows. A transaction appends what it changes, and nothing committed is ever removed, because an earlier
moment may still refer to it. So a file holds every earlier state of the database, whether or not you still want them.

Compaction writes a new database holding what the latest moment reaches, and nothing else. The source is not touched. In
one test, a history of 1,000 small moments took 1,025,632 bytes, and its compacted copy 10,634.

The examples use `sha256(_:)`, a helper that hashes a string: see <doc:BringYourOwnHashes>. They force-unwrap a lookup
where the value was just written; real code handles the `nil` that means it is not there. Where they use `database`, it is a
database with a history, as in <doc:MomentsAndHistory>.

### Compacting

``Database/compact(into:hashID:fileID:offsetMap:)`` takes a storage for the new database, and returns it:

```swift
// A new file, for the compacted database.
let target = try BufferedFileStorage(path: "compact.db", access: .truncate)

// Where the copy remembers what went where.
var offsets = MemoryOffsetMap()

let compacted = try database.compact(into: target, offsetMap: &offsets)

// The history is one moment long, and it is the latest.
let history = try ArrayList<ReadOnly>(compacted.rootCursor)
```

The new database takes this one's hash size, and its hash ID unless you give another. It gets a new random file ID unless
you give one, so it is a new file as far as replicas are concerned: see <doc:Replication>.

The source can be a ``SnapshotDatabase``, made over a ``Snapshot``, so that another task compacts the snapshot's commit while
the writer goes on committing. A snapshot of one collection, made with ``Snapshot/init(_:)``, is not a whole commit, and
compacting a ``SnapshotDatabase`` over one is refused with ``XitDBError/subCollectionSnapshot``.

### What is kept

What happens depends on the root:

- **A root that is an ``ArrayList``** is taken to be a history. Only its last moment survives, as the one element of a new
  list. The earlier moments are what compaction is there to discard.
- **A root that is anything else** is copied whole, a ``LinkedArrayList`` or a root set to nothing included.
- **An empty root** commits nothing, and you get an empty database.
- **An ``ArrayList`` at the root whose last element is empty is refused** with ``XitDBError/emptyLastMoment``, before
  anything is written to the target: a list with no elements, or a last element that was appended and never written, however
  many elements come before it, and whether you meant the list as a history or not. Compacting it would give you an empty
  database, with neither the list nor those elements in it, which is what the original does. A last element set to nothing,
  with `.slot(nil)`, is a moment, and compacts.

A value or a collection is copied once, however many slots point at it, so two keys that shared a value before share it
afterwards, and a cycle ends. The exception is the partly filled blocks at the end of an array list, which are copied for each
list that has them.

Only the top-level list is treated as a history. A list inside a moment is data, and it is copied whole with all its
elements, which you can use: see "Forgetting one thing" below.

### A target you opened yourself

``Database/compact(into:offsetMap:)`` takes a database you have already opened, and which keeps its own file ID and hash ID:

```swift
// A database you opened yourself, with its own file ID and hash ID.
let target = try Database(creating: MemoryStorage(), hashSize: 32, hashID: "sha2")
var offsets = MemoryOffsetMap()
try database.compact(into: target, offsetMap: &offsets)
```

Its root has to be empty and its hash size the same as the source's. Otherwise the call throws
``XitDBError/targetNotEmpty`` or ``XitDBError/invalidHashSize``. The first of these is also what stops you compacting a
database into itself.

A compaction is one ordinary transaction on the target. If it fails, what it wrote is discarded at once, as after any
transaction that fails, and nothing of it is reachable.

### The offset map

As it copies, a compaction has to remember where each object went, so that a second slot pointing at it is pointed at the
same copy and a cycle ends. That is an ``OffsetMap``. It is reset at the start, and it holds a mapping for every object
copied until the end, so one map can serve many compactions in turn.

``MemoryOffsetMap`` is the one to use unless the mappings will not fit in memory. It needs room for two 64-bit numbers per
object, with at least as much again free. If that is too much, keep the offsets on disk, in another database:

```swift
// A scratch database holds the offsets, with hashes of eight bytes.
struct DiskOffsets: OffsetMap {
    var map: HashMap<ReadWrite>

    private func hash(_ offset: UInt64) -> [UInt8] {
        withUnsafeBytes(of: offset.bigEndian) { Array($0) }
    }

    mutating func reset() throws {
        var cursor = map.cursor
        try cursor.write(.slot(nil))
        map = try HashMap<ReadWrite>(cursor)
    }

    mutating func get(_ sourceOffset: UInt64) throws -> UInt64? {
        try map.cursor(forHash: hash(sourceOffset))?.readUInt64()
    }

    mutating func put(_ sourceOffset: UInt64, _ targetOffset: UInt64) throws {
        try map.put(.uint(targetOffset), forHash: hash(sourceOffset))
    }
}

// Nothing here needs to survive a crash, so nothing is synced.
let scratchStorage = try FileStorage(
    path: "offsets.db", access: .truncate, durability: .none)
let offsetsDatabase = try Database(creating: scratchStorage, hashSize: 8)
let target = try BufferedFileStorage(path: "compact.db", access: .truncate)

// One transaction around the whole compaction, so that the offsets
// are not each committed on their own.
let compacted = try offsetsDatabase.withTransaction { cursor in
    var offsets = DiskOffsets(map: try HashMap<ReadWrite>(cursor))
    return try database.compact(into: target, offsetMap: &offsets)
}
```

An error thrown by your own map comes out of the compaction as ``XitDBError/callerError(_:)``, with your error inside it.

### What to do with the old file

That is up to you. Compaction leaves the source as it was, and the new database in another file. Anything committed to the
source after the compaction started is not in the new one, so stop writing first. Then, to replace the old file:

```swift
// Once nothing is writing to the old file, put the new one in its place.
_ = try FileManager.default.replaceItemAt(
    URL(fileURLWithPath: "main.db"),
    withItemAt: URL(fileURLWithPath: "compact.db"))
```

Other processes need to open the file again: one that has the old file open goes on reading the old file. So does a
``Snapshot`` taken before the replacement. It reads through the file it was taken from, which stays open while the snapshot
lives, so it goes on reading the old bytes and is not affected.

### Forgetting one thing

Removing something from the latest moment and compacting does remove its bytes, and it also discards the history of
everything else. To evict one person's data and keep everyone else's history, keep the history you care about inside the
moment, where compaction will not discard it.

The top-level list is the only history that compaction discards. Here each person is a list of that person's versions, and a
`versions` list says which version of each person each global version had, by index:

```json
{
  "people": [
    ["Alice, 25"],
    ["Bob, 42", "Bob, 43"]
  ],
  "versions": [
    [0, 0],
    [0, 1]
  ]
}
```

A compaction cannot follow an integer, so `people` is the only way to reach Alice. To evict her, clear her slot in a new moment
and compact:

```swift
// Alice asks to be forgotten: clear her slot, and compact.
try history.append(.slot(try history.slot(at: -1))) { cursor in
    let moment = try HashMap<ReadWrite>(cursor)
    let people = try ArrayList<ReadWrite>(moment.putCursor(forHash: sha256("people")))
    try people.put(.slot(nil), at: 0)
}

let target = MemoryStorage()
var offsets = MemoryOffsetMap()
let compacted = try database.compact(into: target, offsetMap: &offsets)
```

The bytes of "Alice, 25" are in the old file and not in the new one, and both of Bob's versions are in the new one. Your code then
has to deal with integers in `versions` that no longer lead anywhere. The old file still holds Alice until you delete it.

## See Also

- <doc:/tutorials/XitDB/KeepingAReplicaInStep>
- ``OffsetMap``
- ``MemoryOffsetMap``
- <doc:MomentsAndHistory>
- <doc:Replication>
