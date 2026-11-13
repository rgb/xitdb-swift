# ``XitDBStore``

The Swift layer over XitDB: keys as Swift values, values as Swift types, and handles that name a place in a moment.

## Overview

`XitDBStore` sits over the `XitDB` module, which mirrors the original xitdb call for call. Through the store you do not
hash your own keys or make collections from cursors. A key is a string, an integer or bytes, a value is a Swift type,
a record is a `Codable` type, and a ``Handle`` names a place in a moment, by its path from the moment's root:

```swift
import XitDBStore

let database = try Database(creating: MemoryStorage(), hashSize: 32)
let store = try Store(database, hashing: SHA256.self)

try store.transaction { moment in
    try moment["name"].set("Alice")
    try moment["age"].set(UInt64(25))
}

let name = try store.latest["name"].value(String.self)  // "Alice"
```

The store writes through the faithful calls, and the files it writes are the files they write. Importing the store
alone is enough: it re-exports `XitDB`, with the database and its storages, and `XitDBHashing`, with the hashes.

To start, read <doc:KeysValuesAndHandles>.

## Topics

### Essentials

- <doc:KeysValuesAndHandles>

### The store

A store stands over a database, and its history is a list of moments, each a map.

- ``Store``
- ``Moment``

### Places

A handle names a place in a moment, and is looked up when it is used.

- ``Handle``
- ``CollectionKind``

### Keys and values

- ``KeyRepresentable``
- ``StorableValue``

### Collections

The faithful layer's eight collections, at a handle, with keys and values as Swift types.

- ``Map``
- ``CountedMap``
- ``KeySet``
- ``CountedKeySet``
- ``List``
- ``LinkedList``
- ``SortedMap-4xtdk``
- ``SortedSet-5dn9y``
- ``ValueIterator``
- ``Entry-1uyhm``

### Codable records

A record stored as a map, a field at a time.

- <doc:CodableRecords>
- ``XitDBEncoder``
- ``XitDBDecoder``
- ``DateCodingStrategy``
- ``DataCodingStrategy``
- ``URLCodingStrategy``

### From XitDB and XitDBHashing

The store re-exports both modules, so their types come with `import XitDBStore`. Their articles are in those modules'
own documentation.

- ``Database``
- ``Snapshot``
- ``SnapshotDatabase``
- ``ReadableDatabase``
- ``BufferedFileStorage``
- ``MemoryStorage``
- ``FileStorage``
- ``FileAccess``
- ``FileLock``
- ``Durability``
- ``DatabaseHeader``
- ``HashID``
- ``XitDBError``
- ``Cursor``
- ``ReadOnly``
- ``ReadWrite``
- ``CursorAccess``
- ``WritableData``
- ``Slot``
- ``Entry-4wbdr``
- ``CollectionIterator``
- ``ArrayList``
- ``LinkedArrayList``
- ``HashMap``
- ``HashSet``
- ``CountedHashMap``
- ``CountedHashSet``
- ``SortedMap-4sqyh``
- ``SortedSet-2g2rf``
- ``Bytes``
- ``FormatTag``
- ``ByteWriter``
- ``ByteReader``
- ``OffsetMap``
- ``MemoryOffsetMap``
- ``ReplicaState``
- ``ByteSink``
- ``ByteSource``
- ``ArrayByteSink``
- ``ArrayByteSource``
- ``WritableStorage``
- ``ReadableStorage``
- ``SyncPoint``
- ``KeyHashing``
- ``SHA256``
- ``SHA256Digest``
- ``Insecure``
- ``SipHash128``
- ``SipHash128Digest``
