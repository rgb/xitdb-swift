# Codable records

How a `Codable` type is stored: as maps and lists in the database, a field at a time, and not as bytes.

## Overview

A record is a map. ``Handle/set(encoding:)`` writes an `Encodable` value at a place, and ``Handle/value(decoding:)``
reads a `Decodable` one back, or gives `nil` if the place holds nothing:

```swift
struct Person: Codable {
    var name: String
    var age: Int
    var roles: [String]
}

let alice = Person(name: "Alice", age: 25, roles: ["admin"])
try store.transaction { moment in
    try moment["people"]["alice"].set(encoding: alice)
}

let read = try store.latest["people"]["alice"].value(decoding: Person.self)
```

The record is not encoded into bytes. Each field is an entry of the record's map, and the list of roles is a list, so a
field can be read or written on its own, as anything else in the database can:

```swift
// A field is an entry of its own, read without the rest of the record.
let age = try store.latest["people"]["alice"]["age"].value(Int64.self)  // 25
```

### The mapping

``XitDBEncoder`` writes `Codable`'s containers as the format's own structures, and ``XitDBDecoder`` reads them back:

- A keyed container, which is what a struct or a class encodes itself as, is a hash map, keyed by the coding keys'
  names hashed with the store's hash.
- An unkeyed container, which is what an array encodes itself as, is an array list.
- A single value is one of the format's values. Integers are its signed or unsigned 64-bit integers, `Float` and `Double`
  its doubles, `Bool` an unsigned integer, 1 or 0, and `String` its UTF-8 as a byte array. A `[UInt8]` is a byte array,
  where any other array is a list.
- A nested value is a nested map or list, and a class's superclass is encoded under the key `super`.

An integer comes back exactly or not at all: one that does not fit the type it is decoded as fails with
`DecodingError.dataCorrupted`. An optional that is `nil` leaves no entry, and a key with no entry decodes as `nil` for an
optional. A container is made when the type asks for it, so an empty array or dictionary is an empty list or map, and
comes back empty.

Encoding at a place replaces whatever was there, as ``Handle/set(_:)`` does: the place is cleared first. Encoding `nil`
leaves the place empty. At the moment's root only a keyed value can go, and anything else is refused with
`XitDBError.unexpectedTag`. If a write fails midway, the place holds what was written before the failure; let the error
out of the transaction's body, and the moment rolls back.

### Strategies

Three Foundation types have a better form in the format than the one they encode themselves as, and the encoder uses it
unless it is told to defer to the type:

| Type | The default | `deferred`, the type's own form |
|---|---|---|
| `Date` | ``DateCodingStrategy/secondsSince1970``: seconds since 1970, as a double | Seconds since 2001, as a double |
| `Data` | ``DataCodingStrategy/bytes``: a byte array | A list of 8-bit integers, one element each, which is slow and large |
| `URL` | ``URLCodingStrategy/string``: its absolute string | A map with the relative string and the base |

``Handle/set(encoding:)`` and ``Handle/value(decoding:)`` use the defaults. For others, make an encoder and a decoder with
them, and use ``XitDBEncoder/encode(_:at:)`` and ``XitDBDecoder/decode(_:at:)``. The decoder has to be given the
strategies the value was encoded with:

```swift
struct Launch: Codable {
    var name: String
    var at: Date
}

let launch = Launch(name: "first", at: Date(timeIntervalSince1970: 0))
try store.transaction { moment in
    try XitDBEncoder(dates: .deferred).encode(launch, at: moment["launch"])
}

let decoder = XitDBDecoder(dates: .deferred)
let decoded = try decoder.decode(Launch.self, at: store.latest["launch"])
```

The date is then stored as -978,307,200, the seconds from 2001 back to 1970. These strategies are the one thing the store
uses Foundation for, `FoundationEssentials` where it can. `XitDB` uses none.

### What a record costs

Each entry of a keyed container stores its key's name beside the key's hash. Decoding needs the names to list a
container's keys, which the decoders of enums with associated values and of dictionaries do, and a hash cannot give them
back. So a record costs its field names, once in each of its entries, and every record of a type stores them again. In
return, a dump of the file, or another implementation reading it, sees the field names, where a plain hashed map shows
only hashes.

A byte array is for what is bytes already, such as an image or a digest. A `[UInt8]` or `Data` field is stored as one.

### A map written by other means

A map written with ``Map/put(_:forKey:)`` stores no key names. A struct decodes from it all the same, since its decoder
asks for each key by name, and the decoder finds the entry by the name's hash:

```swift
struct Point: Codable {
    var x: Int64
    var y: Int64
}

try store.transaction { moment in
    let origin = moment["origin"].map(String.self, Int64.self)
    try origin.put(0, forKey: "x")
    try origin.put(0, forKey: "y")
}
let origin = try store.latest["origin"].value(decoding: Point.self)
```

A type that lists the keys finds none there. A dictionary decoded from that map comes back empty, and an enum with
associated values fails to decode.

### Errors

A shape or a value the type does not take fails with a `DecodingError`, as with any decoder:

- a key with no entry, for a field that is not optional, is `DecodingError.keyNotFound`;
- a value of another kind than the one asked for, a list where a struct is expected among them, is
  `DecodingError.typeMismatch`;
- an integer that does not fit is `DecodingError.dataCorrupted`.

```swift
do {
    _ = try store.latest["origin"].value(decoding: Person.self)
} catch DecodingError.keyNotFound(let key, _) {
    print("no entry for", key.stringValue)  // no entry for name
}
```

An error of a read itself, such as damage in the file, is the `XitDBError` the read threw. Encoding throws what the writes
throw, `XitDBError.expectedTxStart` in a read-only moment among them. Where `Codable`'s protocols let a step throw nothing,
such as making a container, the step's error is kept, and thrown when the encoding returns.

## See Also

- <doc:KeysValuesAndHandles>
- ``XitDBEncoder``
- ``XitDBDecoder``
