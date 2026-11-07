# Bring your own hashes

Why a map takes a hash and not a key, which hash to use, and what happens when two keys share one.

## Overview

XitDB never hashes anything. ``HashMap``, ``HashSet`` and their counted forms store and find their entries by the
bytes you give them, and those bytes are a hash that you computed, with any function you like. The database only
knows how many bytes a hash has. It keeps the number in its header, and every hash must have exactly that many.

The examples in this documentation use a helper of three lines:

```swift
func sha256(_ key: String) -> [UInt8] {
    Array(SHA256.hash(data: Array(key.utf8)))
}
```

A small `XitDBHashing` target with ready-made hashes is planned, along with a layer that takes string keys. Neither
exists yet.

### Giving the hash

A hash goes in wherever a map asks for one, and it has to have the database's size:

```swift
// The hash is the caller's. It only has to have the right size.
try map.put(.uint(1), forHash: Array(SHA256.hash(data: Array("alice".utf8))))
```

Anything else throws ``XitDBError/invalidHashSize``. That includes a SHA-1 hash in a database of SHA-256 hashes.

A CryptoKit digest has to go in as an array, as above. It is a `Sequence` of bytes and not a `Collection`, which is
what the map asks for:

```swift
// `SHA256Digest` is a sequence of bytes, not a collection, so it goes
// in as an array. A helper keeps that out of every call.
let digest = SHA256.hash(data: Array("alice".utf8))
try map.put(.uint(1), forHash: Array(digest))
```

### Which size to pick

The size is fixed when the database is created, by ``Database/init(creating:hashSize:hashID:fileID:)``. An entry of a
map stores its hash, so each entry takes that many bytes and eighteen more.

| Bytes | Hash | When |
|---|---|---|
| 32 | SHA-256 | The choice to make if you have no reason to choose. Nobody knows how to make two keys collide. |
| 20 | SHA-1 | What the original's own tests use, and 12 bytes less per entry. It is broken: someone who chooses your keys and has the computing power can make two collide on purpose. Fine for keys you make yourself. |
| 64 | SHA-512 | If you already have one. |
| 8 | Your own 64-bit IDs | Keys that are unique already: see below. |

### Two keys, one hash

If two keys have the same hash, they are the same key. The database compares hashes and nothing else, so the second
`put` replaces the first without an error. To show it, here is a hash of one byte that collides easily:

```swift
// A hash of one byte, the sum of the key's: "ab" and "ba" collide.
func weakHash(_ key: String) -> [UInt8] {
    [key.utf8.reduce(0, &+)]
}

try map.put(.bytes(Array("first".utf8)), forHash: weakHash("ab"))
try map.put(.bytes(Array("second".utf8)), forHash: weakHash("ba"))

// One entry: the second put replaced the first without a word.
let value = try map.cursor(forHash: weakHash("ab"))!.readBytes()
```

With a good hash of 20 bytes or more, this does not happen by accident. Whether it can happen on purpose is the
question to ask when your keys come from someone else, and it is why 32 bytes is the default to reach for.

If you use a shorter hash and need to know, store each key with ``HashMap/putKey(_:forHash:)-(_,Collection<UInt8>)``.
It writes only once, so what you read back is the first key that had that hash, and you can compare:

```swift
try map.putKey(.bytes(Array("ab".utf8)), forHash: weakHash("ab"))

// `putKey` writes once, so the stored key is the first one.
try map.putKey(.bytes(Array("ba".utf8)), forHash: weakHash("ba"))
let stored = try map.keyCursor(forHash: weakHash("ba"))!.readBytes()
let collided = stored != Array("ba".utf8)
```

### A hash need not be cryptographic

Keys that are unique already can be their own hash, which costs nothing to compute and is what a hash size of 8 is
for. The bytes have to go in big-endian:

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

The order matters because the map's trie takes four bits per level, starting from the low bits of the *last* byte of
the hash. A cryptographic hash is uniform everywhere, so it makes no difference there. With 1,000 sequential IDs in
big-endian, changing one value in a later transaction appended 492 bytes. In little-endian, whose last bytes are all
zero, the trie is a long chain down to where the IDs start to differ, and the same change appended 2,364, because a
change copies every block on the way down. A lookup reads all of them too.

A key of exactly the right size can be passed as it is, including a string's `utf8`:

```swift
let database = try Database(creating: MemoryStorage(), hashSize: 5)
let map = try HashMap<ReadWrite>(database.rootCursor)

try map.put(.uint(1), forHash: "alice".utf8)
```

In practice that suits fixed-size IDs and not names, since `"bob".utf8` in that map throws
``XitDBError/invalidHashSize``. For keys of any length that you want in order, use a ``SortedMap``, which takes the
bytes themselves and no hash: see <doc:SortingAndPaginating>.

### Recording the algorithm

The size alone does not say which function made the hashes, and every reader of the file has to use the same one. A
database's header has four bytes for that, a ``HashID``, which XitDB records and never looks at. It is written once,
when the database is created:

```swift
let created = try Database(creating: storage, hashSize: 32, hashID: "sha2")
```

The original's advice is to use `"sha1"` for SHA-1 and `"sha2"` for the SHA-2 family, and to tell SHA-256 from
SHA-512 by the size.

Opened without a size, a database takes whatever its header says, so you do not need to know the size to read the
header. Stating a size that is not the file's throws ``XitDBError/invalidHashSize``. A program that opens files made
elsewhere can then choose its hash:

```swift
// Opened without a size, a database takes the one it records, and the
// header says what the hash is.
let database = try Database(opening: storage)
let header = database.header
```

```swift
enum HashAlgorithm { case sha1, sha256, sha512 }

let algorithm: HashAlgorithm? =
    switch (header.hashID, header.hashSize) {
    case ("sha1", 20): .sha1
    case ("sha2", 32): .sha256
    case ("sha2", 64): .sha512
    default: nil
    }
```

A hash ID is a string literal of exactly four bytes where one is expected, and a wrong literal stops the program. For
a string computed at run time, ``HashID/init(string:)`` gives `nil` instead.

## See Also

- ``HashMap``
- ``HashSet``
- ``HashID``
- ``DatabaseHeader``
