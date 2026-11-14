# Hashing

## Overview

A hash map finds an entry by the hash of its key, and a database records only how many bytes its hashes have.

| Hash | Bytes | For |
|---|---|---|
| ``SHA256`` | 32 | The one to choose when you have no reason to choose. |
| ``Insecure/SHA1`` | 20 | Files whose keys are hashed with SHA-1, as they are in the original's tests and by default in a xit repository. |

The header's hash ID is not checked. It is a label of four bytes that the creator of a database chooses, and the format
does not interpret it.

### Where the hashes are computed

Where CryptoKit exists, ``SHA256`` and ``Insecure/SHA1`` forward to it, and their digests are CryptoKit's own types.
Where it does not, on Linux, the package computes them itself. Its implementations are tested on every platform against
published test vectors, and against CryptoKit where both exist. The names are CryptoKit's, so code that hashes with
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
`hash(_:)`, which returns the digest of a key's bytes. `XitDB`'s article on bringing your own hashes says how the size is chosen, and what happens when two keys share
a hash.

## See Also

- ``SHA256``
- ``Insecure/SHA1``
