# Bring your own hashes

Why a map takes a hash and not a key, which hash to use, and what happens when two keys share one.

## Overview

XitDB never hashes anything. ``HashMap``, ``HashSet`` and their counted forms store and find their entries by the
bytes you give them, and those bytes are a hash that you computed, with any function you like. The database only
knows how many bytes a hash has. It keeps the number in its header, and every hash must have exactly that many.

The examples in this documentation use a helper of three lines:

```swift
import CryptoKit

func sha256(_ key: String) -> SHA256Digest {
    SHA256.hash(data: Array(key.utf8))
}
```

A small `XitDBHashing` target with ready-made hashes is planned, along with a layer that takes string keys. Neither
exists yet. On Linux, where there is no CryptoKit, swift-crypto's `import Crypto` is the same API until then.

### Giving the hash

A hash goes in wherever a map asks for one, and it has to have the database's size:

```swift
let database = try Database(creating: MemoryStorage(), hashSize: 32)
let map = try HashMap<ReadWrite>(database.rootCursor)

// The hash is the caller's. It only has to have the right size.
try map.put(.uint(1), forHash: SHA256.hash(data: Array("alice".utf8)))
```

A hash parameter takes any sequence of bytes: a digest as it is, an array, a slice, `Data`, or a string's `utf8` if it
happens to have the right length. Each one is made into an array for the call, which for an array costs nothing and for
anything else is a copy of the hash. Every method also has an overload that takes a `Span<UInt8>`, which allocates nothing for a hash of up
to 64 bytes: see <doc:TheCollections>.

A hash of any other size throws ``XitDBError/invalidHashSize`` as soon as there is a map to look in. That includes a
SHA-1 hash in a database of SHA-256 hashes.

### Which size to pick

The size is fixed when the database is created, by ``Database/init(creating:hashSize:hashID:fileID:)``, and can be from
1 to 65,535 bytes. A replica has to have the size of its source. An entry of a map stores its hash, so each entry takes that
many bytes and eighteen more.

| Bytes | Hash | When |
|---|---|---|
| 32 | SHA-256 | The choice to make if you have no reason to choose. |
| 20 | SHA-1 | Keys you make yourself, for 12 bytes less per entry. |
| 64 | SHA-512 | If you already have one. |
| 8 | Your own 64-bit IDs | Keys that are unique already: see below. |

Nobody knows how to make two SHA-256 hashes collide. SHA-1, which the original's own tests use, is broken: someone who
chooses your keys and has the computing power can make two collide on purpose, so keep it for keys you make yourself.

### Two keys, one hash

If two keys have the same hash, they are the same key. The database compares hashes and nothing else, so the second
``HashMap/put(_:forHash:)-(_,Sequence<UInt8>)`` replaces the first without an error. To show it, here is a database with a hash size of 1, and a hash that collides easily:

```swift
let database = try Database(creating: MemoryStorage(), hashSize: 1)
let map = try HashMap<ReadWrite>(database.rootCursor)

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

If you use a shorter hash and need to know, store each key with ``HashMap/putKey(_:forHash:)-(_,Sequence<UInt8>)``.
It writes only once, so what you read back is the first key that had that hash, and you can compare:

```swift
try map.putKey(.bytes(Array("ab".utf8)), forHash: weakHash("ab"))

// putKey writes once, so the stored key is the first one.
try map.putKey(.bytes(Array("ba".utf8)), forHash: weakHash("ba"))
let stored = try map.keyCursor(forHash: weakHash("ba"))!.readBytes()
let collided = stored != Array("ba".utf8)
```

### A hash need not be cryptographic

Keys that are unique already can be their own hash, which costs nothing to compute and is what a hash size of 8 is
for. The bytes should go in big-endian:

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
the hash. A cryptographic hash is uniform everywhere, so it makes no difference there. With 1,000 sequential IDs in a map at
the root of a database with these 8-byte hashes, changing one value appended 492 bytes in big-endian: three blocks of 144 on
the way down, the 26-byte entry, and the 34 that any transaction costs. In little-endian, whose last bytes are all zero, the
trie is a long chain down to where the IDs start to differ, and the same change appended 2,364: sixteen blocks. A lookup reads
all of them too. (<doc:MomentsAndHistory> quotes 676 bytes for a similar change. That is also three blocks, with hashes of
32 bytes and in a history, which also copies its list.)

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
database's header has four bytes for that, a ``HashID``, which XitDB records and never looks at. It is written when the
database is created, and only a sync at 0, which replaces the whole header with its source's, changes it:

```swift
let storage = MemoryStorage()

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

- <doc:TheCollections>
- <doc:SortingAndPaginating>
- <doc:Replication>
- ``HashMap``
- ``HashSet``
- ``HashID``
- ``DatabaseHeader``
