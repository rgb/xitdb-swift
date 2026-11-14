# ``XitDBHashing``

SHA-256 and SHA-1 under CryptoKit's names on every platform, as hashers a database can be given.

## Overview

XitDB has no hash function of its own. A database is given a hasher, a type that conforms to XitDB's `KeyHashing`,
and its hash maps and sets hash their keys with it. This module has two, ``SHA256`` and ``Insecure/SHA1``, named and
spelled as CryptoKit names and spells them, so code that hashes is the same on every platform:

```swift
import XitDB
import XitDBHashing

let database = try Database(creating: MemoryStorage(), hashing: SHA256.self, hashID: "sha2")
```

| Hasher | Bytes | For |
|---|---|---|
| ``SHA256`` | 32 | The one to choose when you have no reason to choose. |
| ``Insecure/SHA1`` | 20 | Files whose keys were hashed with SHA-1, as the original's tests' are. Keys you make yourself. |

SHA-1's collisions have been published: someone who chooses your keys and has the computing power can make two collide,
and two keys with one hash name one entry. The hasher's size is the database's hash size, and nothing else of it is
written or checked, so say which hash it is in the `hashID` of a new database, `"sha2"` or `"sha1"`. XitDB's article
"Hashing" says how a database is given its hasher, how to choose one by a file's header, and what happens when two keys
share a hash.

### Where the hashes are computed

Where CryptoKit exists, ``SHA256`` and ``Insecure/SHA1`` forward to it, and their digests are CryptoKit's own types.
Where it does not, on Linux, the package computes them itself. Its implementations are tested on every platform against
published test vectors, and against CryptoKit where both exist. The names are CryptoKit's, so code that hashes with
`SHA256.hash(data:)` is the same on every platform, and the package takes no dependency for it.

A digest is a sequence of its bytes, so `Array(digest)` gives them, and a call that takes a hash takes a digest as it is:

```swift
let digest = SHA256.hash(data: Array("alice".utf8))
let bytes = Array(digest)  // 32 of them
```

`XitDBHashing` does not re-export CryptoKit. Where the digest is CryptoKit's type, its members beyond its bytes are
CryptoKit's, and a file that uses them imports CryptoKit.

### A hasher of your own

Any type that conforms to `KeyHashing` is a hasher: its `size`, the number of bytes in every digest, and its `hash(_:)`,
which returns the digest of a key's bytes. A SHA-512, or a hash of your keys' own, goes in as these two do.

## Topics

### The hashers

- ``SHA256``
- ``Insecure``

### Their digests

- ``SHA256Digest``
