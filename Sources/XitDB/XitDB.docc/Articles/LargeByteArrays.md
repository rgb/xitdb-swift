# Large byte arrays

Writing and reading a value too large to hold in memory, a part at a time.

## Overview

A byte array is a value like any other. ``WritableData/bytes(_:formatTag:)`` writes one whole, and
``Cursor/readBytes(maxCount:)`` reads one whole. For a value you would rather not have in memory, a cursor can also
write and read it in parts.

The examples use `sha256(_:)`, a helper that hashes a string: see <doc:BringYourOwnHashes>. They force-unwrap a lookup
where the value was just written; real code handles the `nil` that means it is not there. Where they use `moment`, it is a
``HashMap`` that is one moment of a history, as in <doc:MomentsAndHistory>: a read-only one to read through, and to write
through a read-write one in a transaction's body.

### Writing a part at a time

``Cursor/writeBytes(formatTag:_:)`` runs a body with a ``ByteWriter``. What the body writes goes straight to the end of
the storage, and when the body returns the array is finished and the slot is pointed at it. There is nothing to
remember to call at the end.

```swift
var cursor = try moment.putCursor(forHash: sha256("long-text"))
try cursor.writeBytes { writer in
    for _ in 0..<50 {
        try writer.write(Array("hello, world!\n".utf8))
    }
}
```

This happens inside a transaction, like any write below the root. On the ``Database/rootCursor`` itself it throws
``XitDBError/cursorNotWritable``; the cursor in a transaction's body can write a byte array at the root.

Three things to know:

- **Write nothing else meanwhile.** The array can only grow while it is the last thing in the storage, so after a write to
  anything else in the body, more bytes for the array, or a format tag, throw ``XitDBError/unexpectedWriterPosition``. A
  ``Database/freeze()``, or a join with ``LinkedArrayList/append(contentsOf:)-(LinkedArrayList<CursorAccess>)``, in the
  body is refused with ``XitDBError/byteWriterOpen``, since it would freeze the array before it is finished.
- **A failure poisons the transaction.** The array is begun in the storage before the body runs, so when the body throws, even
  before it has written a byte, or a write of the array fails, bytes are left behind that only a rollback removes. The slot is
  left as it was, nothing more can be written in the transaction, and it rolls back when its body returns: see
  <doc:Transactions>.
- **A value written this way always has a record of its own**, however short it is: eight bytes of length, the bytes, and
  two more for a format tag if it has one. The same bytes written with ``WritableData/bytes(_:formatTag:)`` go in the slot if they are short enough:
  see <doc:CursorsAndValues>.

### Reading a part at a time

``Cursor/reader()`` gives a ``ByteReader``. ``ByteReader/read(into:)`` fills as much of a buffer as it can, and gives back
how many bytes that was, which is zero at the end. Here it counts the lines of the text above, a kilobyte at a time:

```swift
var reader = try moment.cursor(forHash: sha256("long-text"))!.reader()
var buffer = [UInt8](repeating: 0, count: 1024)
var span = buffer.mutableSpan

var lines = 0
var count = try reader.read(into: &span)
while count > 0 {
    for index in 0..<count where span[index] == UInt8(ascii: "\n") {
        lines += 1
    }
    count = try reader.read(into: &span)
}
```

A reader buffers nothing, and each read of a long value is one read of the storage, so read in parts of a useful size and
not a byte at a time. A value short enough to be in its slot is read from there, and costs no read of the storage.

A reader reads the value its cursor held when the reader was made. If the slot is written afterwards, the reader goes on
reading the old value, which is still there:

```swift
let map = try HashMap<ReadWrite>(database.rootCursor)
try map.put(.bytes(Array("the first value".utf8)), forHash: sha256("value"))

var reader = try map.cursor(forHash: sha256("value"))!.reader()
try map.put(.bytes(Array("the second value".utf8)), forHash: sha256("value"))
```

The exception is a reader made in a transaction that failed, whose bytes are gone: as through a cursor from that
transaction, a read through it throws ``XitDBError/staleCursor``. A slot set to nothing reads as no bytes, and a slot
holding anything else than bytes throws ``XitDBError/unexpectedTag``.

A ``ByteWriter`` can also take its format tag once the bytes decide it, and seek to fill in what it did not know when it
started. A ``ByteReader`` can seek, to read one part of a value.

## See Also

- <doc:CursorsAndValues>
- <doc:Compaction>
- ``ByteWriter``
- ``ByteReader``
- ``Bytes``
- ``FormatTag``
