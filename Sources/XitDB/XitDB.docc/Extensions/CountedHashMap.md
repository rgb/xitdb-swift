# ``XitDB/CountedHashMap``

## Topics

### Making a map

- ``init(_:)-(Cursor<ReadOnly>)``
- ``init(_:)-(Cursor<CursorAccess>)``
- ``init(_:)-(Cursor<ReadWrite>)``
- ``cursor``
- ``slot``
- ``readOnly``

### Reading values

- ``count``
- ``cursor(forHash:)-(Span<UInt8>)``
- ``cursor(forHash:)-(Sequence<UInt8>)``
- ``slot(forHash:)-(Span<UInt8>)``
- ``slot(forHash:)-(Sequence<UInt8>)``
- ``entry(forHash:)-(Span<UInt8>)``
- ``entry(forHash:)-(Sequence<UInt8>)``
- ``iterator()``

### Reading keys

- ``keyCursor(forHash:)-(Span<UInt8>)``
- ``keyCursor(forHash:)-(Sequence<UInt8>)``
- ``keySlot(forHash:)-(Span<UInt8>)``
- ``keySlot(forHash:)-(Sequence<UInt8>)``

### Writing

- ``put(_:forHash:)-(_,Span<UInt8>)``
- ``put(_:forHash:)-(_,Sequence<UInt8>)``
- ``putCursor(forHash:)-(Span<UInt8>)``
- ``putCursor(forHash:)-(Sequence<UInt8>)``
- ``putKey(_:forHash:)-(_,Span<UInt8>)``
- ``putKey(_:forHash:)-(_,Sequence<UInt8>)``
- ``putKeyCursor(forHash:)-(Span<UInt8>)``
- ``putKeyCursor(forHash:)-(Sequence<UInt8>)``
- ``remove(forHash:)-(Span<UInt8>)``
- ``remove(forHash:)-(Sequence<UInt8>)``
