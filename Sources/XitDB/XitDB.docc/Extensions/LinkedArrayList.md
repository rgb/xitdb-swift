# ``XitDB/LinkedArrayList``

## Topics

### Making a list

- ``init(_:)-(Cursor<ReadOnly>)``
- ``init(_:)-(Cursor<CursorAccess>)``
- ``init(_:)-(Cursor<ReadWrite>)``
- ``cursor``
- ``slot``
- ``readOnly``

### Reading

- ``count``
- ``cursor(at:)``
- ``slot(at:)``
- ``iterator()``
- ``iterator(fromIndex:)``

### Adding and changing elements

- ``append(_:)``
- ``append(_:_:)``
- ``appendCursor()``
- ``insert(_:at:)``
- ``insertCursor(at:)``
- ``put(_:at:)``
- ``putCursor(at:)``
- ``remove(at:)``

### Joining and cutting

A join freezes the transaction. See <doc:CloningFreezeAndStaleHandles> for what that does to the handles you hold.

- ``append(contentsOf:)-(LinkedArrayList<CursorAccess>)``
- ``append(contentsOf:)-(Slot)``
- ``formSlice(offset:count:)``
