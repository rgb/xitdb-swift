# ``XitDB/Cursor``

## Topics

### The slot

- ``slot``
- ``count``
- ``database``

### Reading numbers

- ``readUInt64()``
- ``readInt64()``
- ``readDouble()``

### Reading bytes

See <doc:LargeByteArrays> for reading a part at a time.

- ``readBytes(maxCount:)``
- ``readBytes(into:)``
- ``readBytesWithFormatTag(maxCount:)``
- ``readBytesWithFormatTag(into:)``
- ``reader()``

### Reading collections

- ``iterator()``
- ``readEntry()``

### Writing

Only on a cursor of ``ReadWrite`` access, and only in a transaction. See <doc:CloningFreezeAndStaleHandles> for how the
two freezes differ.

- ``write(_:)``
- ``writeIfEmpty(_:)``
- ``writeBytes(formatTag:_:)``
- ``freeze()``
- ``readOnly``
