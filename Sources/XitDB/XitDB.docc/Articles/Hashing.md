# Hashing

How a hash map finds a key, which hasher a database is given, and what happens when two keys share a hash.

## Overview

A hash map or set keeps each entry under the hash of its key, and finds it by that hash. XitDB has no hash function of
its own. A database is given one, a ``KeyHashing`` type, when it is created or opened, and the calls that take a key
hash the key with it:

```swift
import XitDB
import XitDBHashing

let database = try Database(creating: MemoryStorage(), hashing: SHA256.self, hashID: "sha2")
let users = try HashMap<ReadWrite>(database.rootCursor)

try users.put("Alice", forKey: "alice")
```

<!-- Pinned by `aDatabaseIsGivenItsHasher` in XitDBExamples: the two puts, on two databases with the same IDs, leave the same file. -->

A keyed call is its call by hash with the hash computed for it, and writes nothing more: that put writes what
`users.put(.bytes(Array("Alice".utf8)), forHash: SHA256.keyHash(of: "alice"))` writes, which is what a Zig program
writes with `put` and a `hashInt` that is SHA-256 (the original's README makes its `hashInt` SHA-1). Neither stores the
key. A put or a put cursor given `storingKey: true` is two calls by hash in one walk: it writes what
``HashMap/putKey(_:forHash:)-(_,Span<UInt8>)`` and then the same call without the argument write in one transaction, and
stores the key as ``HashMap/putKey(_:)`` does (see <doc:TheCollections>). A keyed call costs its call by hash and the
hash of the key. On Apple silicon the hash of a short key is a fraction of the call: in memory a keyed call costs
somewhat more than its call by hash, and on a file a few percent more. On Linux, where portable code computes the hash,
more of the call is the hash. A loop that uses one key many times can hash it once with ``KeyHashing/keyHash(of:)`` and
go by `forHash:`.

With keys of about nine bytes, on Apple silicon, a put that stores its key costs less than ``HashMap/putKey(_:)`` and
then the put, and more than a put that stores none: nearly twice as much in memory, and somewhat more on a file. A
stored key that fits the key's slot that every entry has, at most eight bytes with no zero byte or six with a format
tag, takes no room in the file; any other takes a record of its own, with an eight-byte length in front (see
<doc:CursorsAndValues>). A read by key costs the same with stored keys and without.

What is hashed is the key's bytes. A `String` is its UTF-8, with nothing added and nothing normalised, so the hash is
the one a program in any language computes over the same text, and a file is shared with a Zig program that hashes the
same text. A `[UInt8]` is itself, and a ``Bytes`` its value without its format tag; any other type that gives its bytes
is a ``KeyRepresentable``.

The package's `XitDBHashing` module has two hashers, `SHA256` and `Insecure.SHA1`. A hasher of your own gives a
``KeyHashing/size``, the number of bytes in every hash, and a ``KeyHashing/hash(_:into:)`` that appends the hash of some
bytes where the database holds it: the last section has one. Any hasher's ``KeyHashing/keyHash(of:)`` gives a key's hash
by hand.

### Which hash

The hasher's size is the database's hash size, written in its header when the database is created, from 1 to 65,535
bytes. A replica has the size of its source. Each entry of a map stores its hash, and takes that many bytes and eighteen
more.

| Bytes | Hash | When |
|---|---|---|
| 32 | SHA-256 | The choice to make if you have no reason to choose. |
| 20 | SHA-1 | The original's tests and a xit repository use it, unless told otherwise. Keys you make yourself. |
| 64 | SHA-512 | If you already have one, as a hasher of your own. |
| 8 | Your own 64-bit IDs | Keys that are unique already: see below. |

Nobody knows how to make two SHA-256 hashes collide. SHA-1 is broken: someone who chooses your keys and has the computing
power can make two collide on purpose.

### Only the size is checked

``Database/init(opening:hashing:)`` checks the hasher's size against the header's, once the header is read and before
anything else is, and refuses another with ``XitDBError/invalidHashSize``, the original's one error for it.
``Database/recover(_:hashing:ignoringRootHeader:)`` checks it before it cuts anything. Nothing else is checked. The header's hash ID is not
compared with the hasher, and the hasher gives none: created with one and no `hashID:`, a database has a hash ID of
zeros. So a file opened with the wrong hasher of the right size opens, and its keyed lookups find nothing.

A snapshot carries the hasher of its database, and a database that a compaction opens over a storage takes its source's;
a target you opened yourself keeps its own. A database given no hasher, created with a hash size or opened without a
hasher, has only the calls that take a hash: a keyed call on it throws ``XitDBError/noKeyHashing``, before anything else
about the call is looked at.

### Choosing the hasher by the file

The header has four bytes to say which function made the hashes, a ``HashID``, since every reader of a file has to use
the one its writer used. The creator of the database writes it and XitDB never interprets it. A compaction copies it
into a new target unless given another, and a sync at 0, which takes its source's header whole, replaces it. The
original's advice is `"sha1"` for SHA-1 and `"sha2"` for the SHA-2 family, with the size telling SHA-256 from SHA-512. A
program that opens files it did not make reads the header first, with ``DatabaseHeader/init(reading:)``, and chooses the
hasher by it:

```swift
let header = try DatabaseHeader(reading: storage)
let hashing: (any KeyHashing.Type)? =
    switch (header.hashID, header.hashSize) {
    case ("sha1", 20): Insecure.SHA1.self
    case ("sha2", 32): SHA256.self
    default: nil
    }
if let hashing {
    let database = try Database(opening: storage, hashing: hashing)
}
```

That reads the header's twenty bytes and nothing else, so a header that reads says nothing of whether the database
opens. A hash ID is a string literal of exactly four bytes where one is expected, and a wrong literal stops the
program; ``HashID/init(string:)`` gives `nil` instead, for a string computed at run time.

### A key that is a hash already

A key that is a hash already goes in by `forHash:` as it is, on any database, given a hasher or not. A hash is any
sequence of bytes, an array or a CryptoKit digest as it is, of the database's size: one of another size throws
``XitDBError/invalidHashSize`` as soon as there is a map to look in. Keys that are unique already, such as 64-bit IDs,
can be their own hash, which costs nothing to compute, in a database of 8-byte hashes, in big-endian:

```swift
// Keys that are already unique, such as 64-bit IDs, can be their own
// hash: the bytes in big-endian order.
func hash(_ id: UInt64) -> [UInt8] {
    withUnsafeBytes(of: id.bigEndian) { Array($0) }
}

let database = try Database(creating: MemoryStorage(), hashSize: 8)
let users = try HashMap<ReadWrite>(database.rootCursor)
try users.put(.bytes(Array("Alice".utf8)), forHash: hash(1))
try users.put(.bytes(Array("Bob".utf8)), forHash: hash(2))
```

The order matters because the map's trie takes four bits per level, starting from the low bits of the *last* byte of the
hash. With 1,000 sequential IDs, changing one value appended 492 bytes in big-endian, three blocks on the way down, and
2,364 in little-endian, sixteen blocks, which a lookup reads too. For keys of any length that you want in order, use a
``SortedMap``, which takes the bytes themselves and no hash: see <doc:SortingAndPaginating>.

### Two keys, one hash

If two keys have the same hash, they are the same key. The map compares hashes and nothing else, so the second put
replaces the first without an error. A hasher of your own, of one byte, shows it:

```swift
// A hash of one byte, the sum of the key's: "ab" and "ba" collide.
enum ByteSum: KeyHashing {
    static var size: Int { 1 }
    static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
        var sum: UInt8 = 0
        for index in bytes.indices { sum &+= bytes[index] }
        output.append(sum)
    }
}

let database = try Database(creating: MemoryStorage(), hashing: ByteSum.self)
let map = try HashMap<ReadWrite>(database.rootCursor)
try map.put("first", forKey: "ab")
try map.put("second", forKey: "ba")

// One entry: the second put replaced the first without a word.
let value = try map.value(forKey: "ab", as: String.self)
```

With a good hash of 20 bytes or more this does not happen by accident. Whether it can happen on purpose is the question
to ask when your keys come from someone else, and it is why 32 bytes is the default to reach for.

## See Also

- <doc:TheCollections>
- <doc:SortingAndPaginating>
- ``KeyHashing``
- ``KeyRepresentable``
- ``DatabaseHeader``
- ``HashID``
