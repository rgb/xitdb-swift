# ``XitDBHashing``

SHA-256 and SHA-1 under CryptoKit's names on every platform, and SipHash-128, as the hashes of a store's keys.

## Overview

A store hashes each key it is given, with the hash it was made with, and a faithful map takes a hash that you compute.
`XitDBHashing` has three hashes for either, each a `KeyHashing`: ``SHA256``, the default, ``Insecure/SHA1``, for files
whose keys are hashed with SHA-1, as they are in the original's tests and by default in a xit repository, and
``SipHash128``, a fast hash for keys your program makes itself.
<doc:Hashing> says which to choose.

The store re-exports this module, so a program that imports `XitDBStore` has it already. One that uses only the faithful
layer imports it beside `XitDB`.

## Topics

### Essentials

- <doc:Hashing>

### The hashes

- ``SHA256``
- ``Insecure``
- ``SipHash128``

### Their digests

- ``SHA256Digest``
- ``SipHash128Digest``
