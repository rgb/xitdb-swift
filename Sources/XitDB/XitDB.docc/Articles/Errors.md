# Errors

What can go wrong, grouped by whose it is.

## Overview

The package throws one type, ``XitDBError``. Methods that run no closure of yours declare it, as `throws(XitDBError)`, so
their errors arrive typed. Methods that run a closure of yours, such as ``Database/withTransaction(_:)``, throw `any Error`,
because they also pass on whatever your closure throws, as it was thrown. ``Entry/withHash(_:)`` throws exactly what its closure
throws.

No bytes in a file can stop your program: damage that the code comes across is an error. That is not the same as noticing all
damage. Only the trailer that ends a commit is checksummed, and the data is not, so a changed byte in a value can read back as a
wrong value with no error at all.

### Your program

These mean the code asked for something it should not have. Most are worth fixing, not catching.

- ``XitDBError/unexpectedTag``: A slot holds another kind of value than the operation works with: reading a number as bytes, or making a ``HashMap`` of a list.
- ``XitDBError/indexOutOfRange``: A write to an index that names no element, an insert at the end, or a cut past the end. A lookup gives `nil` instead. An iterator throws it only for an index that does not fit
  in an `Int64`.
- ``XitDBError/keyNotFound``: Reads and removes turn this into `nil` and `false`. It gets out only from a write through a collection whose slot was cleared after the collection was made.
- ``XitDBError/invalidHashSize``: A hash without the database's number of bytes, once there is a map to look in, opening with a stated size that is not the file's, creating with a size of 0 or over 65535, or a compaction target or replica of another size.
- ``XitDBError/expectedTxStart``: A write below the root, or a freeze, with no transaction running.
- ``XitDBError/nestedTopLevelWrite``: A write through the root, or a new transaction, while one is running.
- ``XitDBError/cursorNotWritable``: ``Cursor/writeBytes(formatTag:_:)`` on the ``Database/rootCursor``.
- ``XitDBError/streamTooLong``: A value larger than the limit or the buffer it was read with.
- ``XitDBError/unexpectedWriterPosition``: A byte array being written grew, or took a format tag, after something else was
  written behind it; or a seek went beyond any position a storage can have.
- ``XitDBError/storageNotEmpty``: Creating a database in a storage that has bytes.
- ``XitDBError/targetNotEmpty``: Compacting into a database whose root holds something.
- ``XitDBError/invalidRange``: A range of committed bytes that makes no sense: past the committed size, starting inside the root header, or a replica's start that is neither 0 nor its size.
- ``XitDBError/invalidLength``: Cutting a storage to more than its length.

### The file

These mean the bytes are not what they should be. Catch them where you open a file you did not write, or where a file might have
been damaged.

- ``XitDBError/invalidDatabase``: It is not a database, it is empty, or its root header does not lead to a trailer whose checksum
  matches.
- ``XitDBError/invalidVersion``: It was written with a format version this package does not read.
- ``XitDBError/truncatedDatabase``: It is shorter than the committed size it records.
- ``XitDBError/endOfStream``: It ended before a value did, or is too short to hold its headers, which is 37 bytes. Also a
  ``ByteSource`` that runs out, and ``ByteReader/readAll(into:)`` with fewer bytes left than the buffer holds.
- ``XitDBError/invalidEnumTag``: A slot's tag is not a known one.
- ``XitDBError/invalidBTreeNode``: A tree node, or a tree's header, does not hold what it should.
- ``XitDBError/invalidBTreeNodeKind``: A tree node is neither a leaf nor a branch.
- ``XitDBError/invalidCount``: A counted map or set records a count that disagrees with its tree.
- ``XitDBError/keyOffsetExceeded``: A hash map goes deeper than its hashes allow.
- ``XitDBError/maxShiftExceeded``: A list goes deeper than the format allows.

A file whose root header or last trailer is damaged does not open at the moment, even though the commits before it are intact. In
the next version, opening it fails with an error that names the last position that verifies, and a separate call truncates the file
to it: see <doc:DifferencesFromTheOriginal>.

```swift
// A program handles the few it expects, and lets the rest go up.
func open(_ storage: any WritableStorage) throws -> Database? {
    do {
        return try Database(opening: storage)
    } catch XitDBError.invalidDatabase, XitDBError.truncatedDatabase, XitDBError.endOfStream {
        return nil
    }
}
```

### The storage

- ``XitDBError/storageFailure(errno:)``: The system refused, or would have: `ENOENT` for a missing file, `EWOULDBLOCK` for a lock that is held, `EBADF` for a write to a read-only file, `ENOSPC` for a full disk, `EINVAL` for a path with a NUL byte in it. The number is the system's for that error.
- ``XitDBError/maxSizeExceeded``: A write would pass a memory storage's limit, or what an array can hold if it has none.

A transaction that fails this way rolls back like any other. The exception is the second sync of a commit, which comes after the
root header has been rewritten. If that one fails, the call throws, and the commit stands, but it may not survive a crash or a power
loss.

### Your own types

``XitDBError/callerError(_:)`` carries an error thrown by a ``ByteSink``, a ``ByteSource`` or an ``OffsetMap`` of yours, as it was
thrown. Here is a sink whose connection drops, used with `source`, a database with something in it:

```swift
struct ConnectionLost: Error {}
struct FailingSink: ByteSink {
    mutating func write(_ bytes: Span<UInt8>) throws { throw ConnectionLost() }
}
```

```swift
var sink = FailingSink()
var connectionLost = false
do {
    try source.readCommitted(from: 0, to: try source.committedSize, into: &sink)
} catch .callerError(let carried) where carried is ConnectionLost {
    connectionLost = true
}
```

An error from a closure is not carried. It comes out of the call as itself. Two ``XitDBError/callerError(_:)`` values compare as equal
if the errors they carry have the same description.

### Cases you will not see

Nothing public raises these, so you can leave them out of your handling. They are there because the enum is shared with the
package-level path API:

- ``XitDBError/writeNotAllowed``, ``XitDBError/pathPartMustBeAtEnd`` and ``XitDBError/notImplemented``, which only that API raises.
- ``XitDBError/expectedSlotPosition``, which nothing raises at all. The original's byte reader needed it, and this one does not.

A `switch` over ``XitDBError`` still has to handle them, so give it a `default`. More cases will arrive before the first release.

### What does stop the program

A few mistakes are preconditions, because they are bugs in the code and not conditions at run time, and no file can cause them:

- A string literal of the wrong length as a ``FormatTag`` or a ``HashID``. For a string computed at run time, ``FormatTag/init(string:)``
  and ``HashID/init(string:)`` give `nil`.
- A range outside the buffer given to ``ReadableStorage/read(into:range:at:)``.

And an in-memory database without a limit stops the process if it asks for more memory than can be had, as any array would. Give it a
limit if what it is told to hold is not under your control: see ``MemoryStorage/maxSize``.

## See Also

- ``XitDBError``
- <doc:Transactions>
- <doc:Storage>
- <doc:DifferencesFromTheOriginal>
