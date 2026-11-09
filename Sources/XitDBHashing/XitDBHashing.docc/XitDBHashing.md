# ``XitDBHashing``

SHA-256, SHA-1 and SipHash-128, under CryptoKit's names on every platform, as the hashes of a store's keys.

## Overview

A store hashes each key it is given, with the hash it was made with, and a faithful map takes a hash that you compute.
`XitDBHashing` has three hashes for either, each a `KeyHashing`: ``SHA256``, the default, ``Insecure/SHA1``, for files
the original made in its default configuration, and ``SipHash128``, a fast hash for keys your program makes itself.
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
