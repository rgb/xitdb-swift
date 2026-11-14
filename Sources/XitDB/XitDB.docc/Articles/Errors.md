# Errors

What can go wrong, grouped by whose it is.

## Overview

The package throws one type, ``XitDBError``. Methods that run no closure of yours declare it, as `throws(XitDBError)`, so
their errors arrive typed. Methods that run a closure of yours, such as ``Database/withTransaction(_:)``, throw `any Error`,
because they also pass on whatever your closure throws, as it was thrown. ``Entry/withHash(_:)`` throws exactly what its
closure throws. Each case's own documentation says when it is thrown; this article says which of them to expect where.

No bytes in a file can stop your program: damage that the code comes across is an error. That is not the same as noticing all
damage. Only the trailer that ends a commit is checksummed, and the data is not, so a changed byte in a value can read back as a
wrong value with no error at all.

### Your program

These mean the code asked for something it should not have. Most are worth fixing, not catching:
``XitDBError/unexpectedTag``, ``XitDBError/indexOutOfRange``, ``XitDBError/keyNotFound``, ``XitDBError/invalidHashSize``,
``XitDBError/noKeyHashing``, ``XitDBError/invalidUTF8``, ``XitDBError/expectedTxStart``,
``XitDBError/nestedTopLevelWrite``, ``XitDBError/cursorNotWritable``, ``XitDBError/staleCursor``,
``XitDBError/snapshotOverwritten``, ``XitDBError/subCollectionSnapshot``, ``XitDBError/byteWriterOpen``,
``XitDBError/structuralSlot``, ``XitDBError/poisonedTransaction``, ``XitDBError/streamTooLong``,
``XitDBError/unexpectedWriterPosition``, ``XitDBError/storageNotEmpty``, ``XitDBError/targetNotEmpty``,
``XitDBError/emptyLastMoment``, ``XitDBError/invalidRange`` and ``XitDBError/invalidLength``.

``XitDBError/invalidHashSize`` is the one error for a hash size, as it is in the original: a hasher or a stated size
that is not the file's when it is opened or recovered, a size no database can have when it is created, a hash of another
length given to a map or set, and a compaction target or a sync from 0 of another size. Two come from the data rather
than the code: ``XitDBError/unexpectedTag`` from a typed read of another kind than the slot holds, and
``XitDBError/invalidUTF8`` from bytes read as a `String` that are not UTF-8. A program that reads what another wrote
catches those where it reads.

### The file

These mean the bytes are not what they should be. Catch them where you open a file you did not write, or where a file might
have been damaged: ``XitDBError/invalidDatabase``, ``XitDBError/untrustedRootHeader(lastVerified:)``,
``XitDBError/invalidVersion``, ``XitDBError/truncatedDatabase``, ``XitDBError/endOfStream``, ``XitDBError/invalidEnumTag``,
``XitDBError/invalidBTreeNode``, ``XitDBError/invalidBTreeNodeKind``, ``XitDBError/invalidCount``,
``XitDBError/keyOffsetExceeded`` and ``XitDBError/maxShiftExceeded``.

A file whose root header or last trailer is damaged does not open, even if the commits before it are intact. Opening names
the end of the last commit that verifies, and leaves the decision to recover to you, since recovering can lose a commit: see
<doc:Recovery>.

### The storage

``XitDBError/storageFailure(errno:)`` is the system's refusal, with its error number, and ``XitDBError/maxSizeExceeded`` a
write that would pass a memory storage's limit. A transaction that fails this way rolls back like any other. The exception is
the second sync of a commit, which comes after the root header has been rewritten. If that one fails, the call throws, and
the commit stands, but it may not survive a crash or a power loss.

### Your own types

``XitDBError/callerError(_:)`` carries an error thrown by a ``ByteSink``, a ``ByteSource`` or an ``OffsetMap`` of yours, as it
was thrown. Here is a sink whose connection drops, used with `source`, a database with something in it:

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

An error from a closure is not carried: it comes out of the call as itself. A ``StorableValue`` of your own throws an
``XitDBError``, as its two requirements declare.

### Cases you will not see

``XitDBError/writeNotAllowed``, ``XitDBError/pathPartMustBeAtEnd`` and ``XitDBError/notImplemented`` are raised only by the
package-level path API, and ``XitDBError/immutableBytes`` is a second check under ``XitDBError/staleCursor`` and
``XitDBError/byteWriterOpen``, which refuse every public route to it first. A `switch` over ``XitDBError`` still has to handle
them, so give it a `default` and keep it: new cases may be added in minor versions.

### What does stop the program

A few mistakes are preconditions, because they are bugs in the code and not conditions at run time, and no file can cause
them: a string literal of the wrong length as a ``FormatTag`` or a ``HashID`` (``FormatTag/init(string:)`` and
``HashID/init(string:)`` give `nil` for a string computed at run time), and a range outside the buffer given to
``ReadableStorage/read(into:range:at:)``. An in-memory database without a limit stops the process if it asks for more memory
than can be had, as any array would: see ``MemoryStorage/maxSize``.

## See Also

- ``XitDBError``
- <doc:Transactions>
- <doc:Recovery>
- <doc:Storage>
- <doc:DifferencesFromTheOriginal>
