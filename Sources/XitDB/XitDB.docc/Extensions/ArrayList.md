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
- ``isEmpty``
- ``value(at:as:)``
- ``cursor(at:)``
- ``slot(at:)``
- ``iterator()``
- ``elements(as:)``
- ``forEachElement(_:)``
- ``forEachElement(as:_:)``
- ``iterator(fromIndex:)``

### Writing

- ``append(_:)-(StorableValue)``
- ``append(_:)-(WritableData)``
- ``append(_:_:)``
- ``appendCursor()``
- ``put(_:at:)-(StorableValue,_)``
- ``put(_:at:)-(WritableData,_)``
- ``putCursor(at:)``
- ``truncate(to:)``
