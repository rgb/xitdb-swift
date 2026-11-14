# ``XitDBHashing``

SHA-256 and SHA-1 on every platform, as hashers a database can be given.

## Overview

XitDB has no hash function of its own. A database can be given a hasher, a type that conforms to XitDB's `KeyHashing`,
and its hash maps and sets then hash their keys with it; one made with a hash size alone takes hashes. This module has
two, ``SHA256`` and ``Insecure/SHA1``, the same on every platform:

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

### What a hasher offers

Each hasher has a `size`, the number of bytes in every hash, and a `hash(_:into:)`, which appends the hash of some bytes
where the database holds it: what `KeyHashing` asks for, and all the database calls. A hash by hand, for the calls that
take a hash, is `keyHash(of:)`, which XitDB gives every hasher: an array of `size` bytes, the hash that a database given
the hasher computes for the key.

```swift
let hash = SHA256.keyHash(of: "alice")  // 32 bytes
```

The module hashes keys and offers nothing more: a digest of data for its own sake is CryptoKit's, or another library's.
CryptoKit has types named `SHA256` and `Insecure` as well. In a file that imports both modules a bare `SHA256` is
neither and does not compile: this module's is `XitDBHashing.SHA256` there, and CryptoKit's `CryptoKit.SHA256`.

### Where the hashes are computed

The module computes both hashes with its own code, which needs only the standard library: a key, or any short input, on
every platform. On Apple platforms longer input goes to CryptoKit, which computes it faster there; the hash is the same
either way, and the package takes no dependency for it. The code is tested against the published test vectors and the
lengths where the padding changes shape on every platform, and against CryptoKit where CryptoKit exists.

### A hasher of your own

Any type that conforms to `KeyHashing` is a hasher, with its `size` and its `hash(_:into:)`. XitDB's article "Hashing"
has one of a single byte; a SHA-512 that you already have, or a hash of your keys' own, goes in the same way.

## Topics

### The hashers

- ``SHA256``
- ``Insecure``
