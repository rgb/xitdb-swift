# Hashing

The three hashes a store's keys can be hashed by, which one to choose, and where they are computed.

## Overview

A hash map finds an entry by the hash of its key, and a database records only how many bytes its hashes have.
`XitDBHashing` has three hashes, each a `KeyHashing`, the protocol `XitDB` defines for them: ``SHA256``,
``Insecure/SHA1`` and ``SipHash128``. A store takes one by its type:

```swift
import XitDBStore

let database = try Database(creating: MemoryStorage(), hashSize: 32)
let store = try Store(database, hashing: SHA256.self)
```

| Hash | Bytes | For |
|---|---|---|
| ``SHA256`` | 32 | The default, and the one to choose when you have no reason to choose. |
| ``Insecure/SHA1`` | 20 | Files made by the original in its default configuration, which hashes with SHA-1. |
| ``SipHash128`` | 16 | Speed, for keys your program makes itself. |

The database's header records the hash size, and a `Store` whose hash has another size is refused with
`XitDBError.hashSizeMismatch` before anything is read or written. So is a `Moment` made with `init(reading:hashing:)`:

```swift
// A database of 32-byte hashes refuses a hash of 20 bytes.
do {
    _ = try Store(database, hashing: Insecure.SHA1.self)
} catch XitDBError.hashSizeMismatch {
    print("the database's hashes are of another size")
}
```

The header's hash ID is not checked. It is a label of four bytes that the creator of a database chooses, and the format
does not interpret it.

### SipHash-128

``SipHash128`` is SipHash-2-4 with a 128-bit result and a fixed key, the reference implementation's test key, so every
program that opens a file computes the same hashes. It is fast, and it is not cryptographic: SipHash resists collisions
made to order only while its key is secret, and this key is public. Two keys with one hash name one entry, so a collision
here is data loss. Use it for keys your program makes itself, and never for keys that come from users or the network.

```swift
let database = try Database(creating: MemoryStorage(), hashSize: 16)
let store = try Store(database, hashing: SipHash128.self)
```

### Where the hashes are computed

Where CryptoKit exists, ``SHA256`` and ``Insecure/SHA1`` forward to it, and their digests are CryptoKit's own types.
Where it does not, on Linux, the package computes them itself. Its implementations are tested on every platform against
published test vectors, and against CryptoKit where both exist. ``SipHash128`` is the package's own everywhere, tested
against the reference implementation's vectors. The names are CryptoKit's, so code that hashes with
`SHA256.hash(data:)` is the same on every platform, and the package takes no dependency for it.

A digest is a sequence of its bytes, so `Array(digest)` gives them, and a faithful map takes a digest as its hash as it
is:

```swift
let digest = SHA256.hash(data: Array("alice".utf8))
let bytes = Array(digest)  // 32 of them
```

`XitDBHashing` does not re-export CryptoKit. Where the digest is CryptoKit's type, its members beyond its bytes are
CryptoKit's, and a file that uses them imports CryptoKit.

### A hash of your own

A hash of your own is a type that conforms to `KeyHashing`: its `size`, the number of bytes in every digest, and its
`hash(_:)`, which returns the digest of a key's bytes. A store takes it as it takes these three, and the size has to be the
database's. `XitDB`'s article on bringing your own hashes says how the size is chosen, and what happens when two keys share
a hash.

## See Also

- ``SHA256``
- ``Insecure/SHA1``
- ``SipHash128``
