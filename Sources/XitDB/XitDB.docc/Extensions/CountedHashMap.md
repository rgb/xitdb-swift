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
- ``cursor(forHash:)-(Collection<UInt8>)``
- ``slot(forHash:)-(Span<UInt8>)``
- ``slot(forHash:)-(Collection<UInt8>)``
- ``entry(forHash:)-(Span<UInt8>)``
- ``entry(forHash:)-(Collection<UInt8>)``
- ``iterator()``

### Reading keys

- ``keyCursor(forHash:)-(Span<UInt8>)``
- ``keyCursor(forHash:)-(Collection<UInt8>)``
- ``keySlot(forHash:)-(Span<UInt8>)``
- ``keySlot(forHash:)-(Collection<UInt8>)``

### Writing

- ``put(_:forHash:)-(_,Span<UInt8>)``
- ``put(_:forHash:)-(_,Collection<UInt8>)``
- ``putCursor(forHash:)-(Span<UInt8>)``
- ``putCursor(forHash:)-(Collection<UInt8>)``
- ``putKey(_:forHash:)-(_,Span<UInt8>)``
- ``putKey(_:forHash:)-(_,Collection<UInt8>)``
- ``putKeyCursor(forHash:)-(Span<UInt8>)``
- ``putKeyCursor(forHash:)-(Collection<UInt8>)``
- ``remove(forHash:)-(Span<UInt8>)``
- ``remove(forHash:)-(Collection<UInt8>)``
