# ``XitDB/CountedHashSet``

## Topics

### Making a set

- ``init(_:)-(Cursor<ReadOnly>)``
- ``init(_:)-(Cursor<CursorAccess>)``
- ``init(_:)-(Cursor<ReadWrite>)``
- ``cursor``
- ``slot``
- ``readOnly``

### Reading

- ``count``
- ``contains(hash:)-(Span<UInt8>)``
- ``contains(hash:)-(Sequence<UInt8>)``
- ``cursor(forHash:)-(Span<UInt8>)``
- ``cursor(forHash:)-(Sequence<UInt8>)``
- ``slot(forHash:)-(Span<UInt8>)``
- ``slot(forHash:)-(Sequence<UInt8>)``
- ``iterator()``

### Writing

- ``insert(_:forHash:)-(_,Span<UInt8>)``
- ``insert(_:forHash:)-(_,Sequence<UInt8>)``
- ``insertCursor(forHash:)-(Span<UInt8>)``
- ``insertCursor(forHash:)-(Sequence<UInt8>)``
- ``remove(forHash:)-(Span<UInt8>)``
- ``remove(forHash:)-(Sequence<UInt8>)``
