# Errors

What can go wrong, grouped by whose it is.

## Overview

The package throws one type, ``XitDBError``. Methods that run no closure of yours declare it, as `throws(XitDBError)`, so
their errors arrive typed. Methods that run a closure of yours, such as ``Database/withTransaction(_:)``, throw `any Error`,
because they also pass on whatever your closure throws, as it was thrown. ``Entry/withHash(_:)`` throws exactly what its
closure throws. Code of yours that declares `throws(XitDBError)` makes such a call inside ``XitDBError/carrying(_:)``:
see "Your own types" below. Each case's own documentation says when it is thrown; this article says which of them to
expect where.

An error says three more things about itself.

Its ``XitDBError/code`` is its case without what the case carries, a ``XitDBError/Code``: a value to compare, to count by
and to keep, where the error itself cannot be a dictionary's key, since one case carries any error at all. The code's raw
value is the case's own name, the same for every error of the case, and it is what code logs, counts by, sends and pins.
It changes only if a case is renamed, which a release's notes would say. `XitDBError.Code(rawValue:)` is the way back from
a word, `nil` for a word that names no case, and `XitDBError.Code.allCases` is every code. A code names a case and is not a
number: the number a system gives a failure is what ``XitDBError/storageFailure(errno:)`` carries. Where the original has
an error of the same meaning under a name of its own, ``XitDBError/Code/originalName`` is that name. Here `files` are the
bytes of three files that are not databases:

```swift
var met: [XitDBError.Code: Int] = [:]
var log: [String] = []
for bytes in files {
    do {
        _ = try Database(opening: MemoryStorage(bytes: bytes))
    } catch {
        met[error.code, default: 0] += 1
        log.append("\(error.code.rawValue): \(error)")
    }
}
```

Its ``XitDBError/description`` is a line a person can read, which is what `print` and string interpolation give, as in the
log's lines above: lower case and no full stop, so that it reads on after your own words, as in
`"could not open the library: \(error)"`. The words may change in any version, so code never compares, parses or stores
them: that is the code's raw value's work. In a debugger, and from `String(reflecting:)`, an error is the code's raw value
with what the case carries, `storageFailure(errno: 28)`. A failed expectation of Swift Testing shows a value by its
description, so it shows an error by its line; a test target that would sooner see the case gives ``XitDBError`` a
conformance to Swift Testing's `CustomTestStringConvertible` whose `testDescription` is the error's `debugDescription`
(marked `@retroactive`, the type being another package's), as this package's own tests do.

What Foundation's `localizedDescription` says of an error is not its line unless the program says so: the library imports no
Foundation, so an ``XitDBError`` caught as `any Error` gives Foundation's stock sentence, "The operation couldn't be completed"
on Apple's platforms, with the type's name and a number. A program that depends on the package's `XitDBFoundation` product and
imports it gets the line, with the system's words for a storage failure's number after it; the conformance to `LocalizedError`
is there.

Its ``XitDBError/kind`` says whose it is, one ``XitDBError/Kind`` for each of the four headings below, for a program that
treats the errors of a kind alike. It is the code's ``XitDBError/Code/kind``. A case has one kind, by its commoner meaning;
where a case has a second meaning under another heading, the text below says so and the kind does not.

No bytes in a file can stop your program: damage that the code comes across is an error. That is not the same as noticing all
damage. Only the trailer that ends a commit is checksummed, and the data is not, so a changed byte in a value can read back as a
wrong value with no error at all.

### Your program

These mean the code asked for something it should not have, and their ``XitDBError/kind`` is
``XitDBError/Kind/program``. Most are worth fixing, not catching:
``XitDBError/unexpectedTag``, ``XitDBError/indexOutOfRange``, ``XitDBError/keyNotFound``, ``XitDBError/invalidHashSize``,
``XitDBError/noKeyHashing``, ``XitDBError/invalidUTF8``, ``XitDBError/expectedTxStart``,
``XitDBError/nestedTopLevelWrite``, ``XitDBError/cursorNotWritable``, ``XitDBError/staleCursor``,
``XitDBError/snapshotOverwritten``, ``XitDBError/subCollectionSnapshot``, ``XitDBError/byteWriterOpen``,
``XitDBError/structuralSlot``, ``XitDBError/poisonedTransaction``, ``XitDBError/streamTooLong``,
``XitDBError/unexpectedWriterPosition``, ``XitDBError/storageNotEmpty``, ``XitDBError/targetNotEmpty``,
``XitDBError/emptyLastMoment``, ``XitDBError/invalidRange``, ``XitDBError/invalidLength``,
``XitDBError/memoryMapNeedsLock`` and ``XitDBError/storageClosed``.

``XitDBError/invalidHashSize`` is the one error for a hash size, as it is in the original: a hasher or a stated size
that is not the file's when it is opened or recovered, a size no database can have, or a storage that holds an
unfinished creation of another size, when it is created; a hash of another length given to a map or set, or a shorter
one made by the hasher, once there is a map or set to look in; and a compaction target or a sync from 0 of another size.
Some come from the data rather than the code: ``XitDBError/unexpectedTag`` from a typed read of another kind than the
slot holds, ``XitDBError/invalidUTF8`` from bytes read as a `String` that are not UTF-8, and
``XitDBError/streamTooLong`` from a value longer than the limit it is read with. A program that reads what another wrote
catches those where it reads.

### The file

These mean the bytes are not what they should be, and their ``XitDBError/kind`` is ``XitDBError/Kind/file``. Catch them
where you open a file you did not write, or where a file might have been damaged: ``XitDBError/invalidDatabase``, ``XitDBError/untrustedRootHeader(lastVerified:)``, ``XitDBError/invalidVersion``,
``XitDBError/truncatedDatabase``, ``XitDBError/endOfStream``, ``XitDBError/invalidEnumTag``, ``XitDBError/invalidBTreeNode``,
``XitDBError/invalidBTreeNodeKind``, ``XitDBError/invalidCount``, ``XitDBError/keyOffsetExceeded`` and
``XitDBError/maxShiftExceeded``. The last seven, which a read of the data gives, are to be read as one thing: damage is reported
by whichever check comes across it first, so the case says where the damage was met and not what it is.

From such a read, ``XitDBError/unexpectedTag`` means the same, beside its meaning above; and ``XitDBError/endOfStream`` is
also a ``ByteSource`` of yours that ran out, or a whole buffer read from a `ByteReader` with fewer bytes left than it holds.

Four of them come also from what a read is held to (see <doc:DifferencesFromTheOriginal>): ``XitDBError/invalidCount``,
otherwise a write's error, from a size or a count the file has no room for; ``XitDBError/endOfStream`` from a read that would
take bytes from before where data starts, as well as beyond the end; and ``XitDBError/keyOffsetExceeded`` and
``XitDBError/invalidBTreeNode`` from a walk that enters more blocks or nodes than its collection can have.
``XitDBError/invalidBTreeNode`` is also a position that a copy the freeze hazard left does not have, though its size has it: no
byte of such a copy is damaged (see <doc:CloningFreezeAndStaleHandles>).

A file whose root header or last trailer is damaged does not open, even if the commits before it are intact. Opening names
the end of the last commit that verifies, and leaves the decision to recover to you, since recovering can lose a commit: see
<doc:Recovery>.

### The storage

``XitDBError/storageFailure(errno:)`` is the system's refusal, or the one the system would have made, with its error number: a
memory storage that has to grow asks the system for the memory first, and reports a refusal this way, with `ENOMEM`. The
commonest others are `ENOENT` for a missing file, `EWOULDBLOCK` for a lock that is held, `EACCES` for a file the process may not
open as asked, `ENOSPC` for a full disk, and `EINVAL` for a path with a NUL byte in it and, from `XitDBFoundation`, for a URL
that is no file's. ``XitDBError/maxSizeExceeded`` is a write that would pass a memory storage's limit, which is the machine's
physical memory where none was named, or what an array can hold if it has none. Their ``XitDBError/kind`` is
``XitDBError/Kind/storage``. A transaction that fails this way rolls back like any other. The exception is the second sync of a
commit, which comes after the root header has been rewritten. If that one fails, the call throws, and the commit stands, but it
may not survive a crash or a power loss.

### Your own types

``XitDBError/callerError(_:)``, whose ``XitDBError/kind`` is ``XitDBError/Kind/caller``, carries an error thrown by a
``ByteSink``, a ``ByteSource`` or an ``OffsetMap`` of yours, as it was thrown. Here is a sink whose connection drops, used
with `source`, a database with something in it:

```swift
struct ConnectionLost: Error {}
struct FailingSink: ByteSink {
    mutating func write(_ bytes: Span<UInt8>) throws { throw ConnectionLost() }
}

var sink = FailingSink()
var connectionLost = false
do {
    try source.readCommitted(from: 0, to: try source.committedSize, into: &sink)
} catch .callerError(let carried) where carried is ConnectionLost {
    connectionLost = true
}
```

An error from a closure is not carried by the call the closure is given to: it comes out of the call as itself, which is why
the four calls that take one throw `any Error`: ``Database/withTransaction(_:)``, the append of an ``ArrayList`` and of a
``LinkedArrayList`` that takes a body, and a cursor's `writeBytes`. A function that declares `throws(XitDBError)` cannot
make those calls bare, and the compiler says so at the call. It makes them inside ``XitDBError/carrying(_:)``, with no
error spelled on any closure. Here `database` has a hash map at its root:

```swift
struct Refused: Error {}

func record(_ visits: UInt64, in database: Database) throws(XitDBError) {
    try XitDBError.carrying {
        try database.withTransaction { root in
            guard visits > 0 else { throw Refused() }
            try HashMap(root).put(visits, forKey: "visits")
        }
    }
}

var refused = false
do {
    try record(0, in: database)
} catch .callerError(let carried) where carried is Refused {
    refused = true
}
```

Two ``XitDBError/callerError(_:)`` are equal when the errors they carry are of the same type and, where that type is
equatable, equal by its own `==`. A type that is not equatable is told from another type and not from itself: two errors
of it are equal whatever they hold. So a test that expects one carried error and not another of the same type makes the
type `Equatable`, or matches the case and looks at what it carries. Nothing is compared by what it prints.

Inside ``XitDBError/carrying(_:)`` an error of the library's comes out as itself, so a `catch` for
``XitDBError/keyNotFound`` matches as it did; anything else comes out as ``XitDBError/callerError(_:)``, with your error
inside it. That is the thing to get right: once it has left through ``XitDBError/carrying(_:)``, an error of your own is
no longer itself, and a `catch` for its type further out never matches. Carrying happens only there, where you wrote it;
the calls themselves carry nothing.

A ``StorableValue`` of your own throws an ``XitDBError``, as its two requirements declare.

### Cases you will not see

``XitDBError/writeNotAllowed``, ``XitDBError/pathPartMustBeAtEnd`` and ``XitDBError/notImplemented`` are raised only by the
package-level path API, and ``XitDBError/immutableBytes`` is a second check under two others, which refuse every public
route to it first. Their ``XitDBError/kind`` is ``XitDBError/Kind/program``, since a program is what would have asked.

The two others are ``XitDBError/staleCursor`` and ``XitDBError/byteWriterOpen``. A `switch` over ``XitDBError`` still has
to handle the four, so give it a `default` and keep it: new cases may be added in minor versions.

### What does stop the program

A few mistakes are preconditions, because they are bugs in the code and not conditions at run time, and no file can
cause them: a string literal of the wrong length as a ``FormatTag`` or a ``HashID`` (``FormatTag/init(string:)`` and
``HashID/init(string:)`` give `nil` for a string computed at run time), a range outside the buffer given to
``ReadableStorage/read(into:range:at:)``, and a hasher that appends more bytes than its ``KeyHashing/size``. An
in-memory database can still stop the process, or slow the machine, where the system grants memory it cannot back: a size
past the storage's limit is an error, and so is one the system itself refuses, and nothing more can be known from inside
a process. See ``MemoryStorage/maxSize``.

## See Also

- ``XitDBError``
- <doc:Transactions>
- <doc:Recovery>
- <doc:Storage>
- <doc:DifferencesFromTheOriginal>
