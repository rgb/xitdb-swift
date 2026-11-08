# ``XitDB/HashSet``

## Topics

### Making a set

- ``init(_:)-(Cursor<ReadOnly>)``
- ``init(_:)-(Cursor<CursorAccess>)``
- ``init(_:)-(Cursor<ReadWrite>)``
- ``cursor``
- ``slot``
- ``readOnly``

### Reading

- ``contains(hash:)-(Span<UInt8>)``
- ``contains(hash:)-(Collection<UInt8>)``
- ``cursor(forHash:)-(Span<UInt8>)``
- ``cursor(forHash:)-(Collection<UInt8>)``
- ``slot(forHash:)-(Span<UInt8>)``
- ``slot(forHash:)-(Collection<UInt8>)``
- ``iterator()``

### Writing

- ``insert(_:forHash:)-(_,Span<UInt8>)``
- ``insert(_:forHash:)-(_,Collection<UInt8>)``
- ``insertCursor(forHash:)-(Span<UInt8>)``
- ``insertCursor(forHash:)-(Collection<UInt8>)``
- ``remove(forHash:)-(Span<UInt8>)``
- ``remove(forHash:)-(Collection<UInt8>)``
