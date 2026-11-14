# ``XitDB/ArrayList``

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

### Writing

- ``append(_:)-(WritableData)``
- ``append(_:_:)``
- ``appendCursor()``
- ``put(_:at:)-(WritableData,_)``
- ``putCursor(at:)``
- ``truncate(to:)``
