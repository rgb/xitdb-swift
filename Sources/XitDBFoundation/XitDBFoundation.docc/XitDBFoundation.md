# ``XitDBFoundation``

XitDB for a program that has Foundation: an error that says something to a person, a file opened by its URL, and `Data` as a
value and as a key.

## Overview

XitDB imports no Foundation, so that it builds wherever Swift does and brings nothing a program did not ask for. An app has
Foundation already: it holds a `URL` for its file, shows `error.localizedDescription`, and has its bytes as `Data`. This
module is those three things and nothing else. It adds no type of its own, only members and conformances on XitDB's types and
on `Data`, and XitDB itself is the same with it or without: a program whose target depends on the product `XitDB` alone
does not compile this module and links no Foundation for XitDB's sake.

```swift
import XitDB
import XitDBFoundation

let storage = try BufferedFileStorage(url: folder.appending(path: "project.db"), access: .create)
```

### An error a person can read

`XitDBError` conforms to `LocalizedError` here. Without that, an error of the library's caught as `any Error` describes itself
to Foundation as "The operation couldn't be completed", with the type's name and a number. With it, `localizedDescription`
is the error's own line, and for a failure of the storage the system's words for its number come after it:

```swift
do {
    _ = try ReadOnlyFileStorage(url: folder.appending(path: "nothing-here.db"))
} catch {
    // "the storage failed with system error 2: No such file or directory"
    show(error.localizedDescription)
}
```

An error of your own that the library carries (`callerError`) gives its own words for a person after the library's,
where it has some: a `LocalizedError` that gives an `errorDescription`, or an error of Foundation's own, such as a
`CocoaError`, a `URLError` or any `NSError`. Any other is given as the library's line gives it, by its description as Swift
prints it, and not by Foundation's stock sentence. The text is English and is not localized: it is for a log, or for a
message your own words lead up to. What a program does about an error it decides by the error's `code` and `kind`, never by
its text.

A program that wrote this conformance itself takes its own out when it adopts this module, since a type conforms to a
protocol once.

### A file by its URL

`FileStorage`, `BufferedFileStorage` and `ReadOnlyFileStorage` are opened by a URL, with the arguments their
initialisers that take a path have. The URL has to be a file's; another is refused with `storageFailure(errno:)` carrying `EINVAL`, before anything
is opened. The path is taken from the URL without percent-encoding, so a name with a space or a letter outside ASCII opens
the file of that name. Access to a folder the app was granted (a security-scoped URL) is yours to start and to stop around
the storage's life.

On Apple's platforms the three are opened by a `FilePath` as well. The type is the System framework's there; on Linux it is
the swift-system package's, a dependency this package does not take, so those three initialisers are Apple's platforms' only.
A path written as a string literal is a `String`'s with this module imported as without it.

### Data

`Data` is a value and a key: it conforms to `StorableValue` and to `KeyRepresentable`.

```swift
let avatar: Data = try loadAvatar()
try people.put(avatar, forKey: "avatar")
let stored = try people.value(forKey: "avatar", as: Data.self)
```

It is written as the format's byte array, exactly what `[UInt8]` of the same bytes writes: the file is the same byte for
byte, so what was put as `Data` reads back as `[UInt8]`, as `Bytes` or, where it is text, as a `String`, here and in the
original, and the reverse. A `Data` key is the key of the `[UInt8]` of the same bytes. A slice of a `Data` is its own bytes,
wherever in its buffer it starts. A `Data` costs one copy more than a `[UInt8]` in each direction, into an array to be
written and out of one when it is read: where that matters, as for megabytes, hold the bytes as `[UInt8]`, or write and read
them in pieces with XitDB's `ByteWriter` and `ByteReader`.

### What is not here

`Date`, `UUID` and the like are no values: the format has no kind for them, and a convention for one would be the package
deciding an app's schema. Write the conformance with your own convention, as XitDB's page on `StorableValue` shows for a
record. There is no `Codable` mapping and nothing asynchronous; XitDB's article on concurrency says how a database is used
from tasks.

## Topics

### An error a person can read

- ``XitDB/XitDBError/errorDescription``

### Opening a file by its URL

- ``XitDB/FileStorage/init(url:access:durability:lock:reading:)``
- ``XitDB/BufferedFileStorage/init(url:access:durability:lock:reading:bufferLimit:)``
- ``XitDB/ReadOnlyFileStorage/init(url:lock:reading:)``

<!-- The members this module gives `Data` are not listed here by name: a link to them names the module `Data` is declared
in, which is Foundation on Apple's platforms and FoundationEssentials on Linux, and a link that resolves on one fails the
documentation build on the other. DocC lists them itself, under Extended Modules. -->
