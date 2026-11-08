# ``XitDB/SortedMap``

## Topics

### Making a map

- ``init(_:)-(Cursor<ReadOnly>)``
- ``init(_:)-(Cursor<CursorAccess>)``
- ``init(_:)-(Cursor<ReadWrite>)``
- ``cursor``
- ``slot``
- ``readOnly``

### Reading by key

- ``cursor(forKey:)-(Span<UInt8>)``
- ``cursor(forKey:)-(Collection<UInt8>)``
- ``slot(forKey:)-(Span<UInt8>)``
- ``slot(forKey:)-(Collection<UInt8>)``
- ``entry(forKey:)-(Span<UInt8>)``
- ``entry(forKey:)-(Collection<UInt8>)``

### Reading in order

See <doc:SortingAndPaginating>.

- ``count``
- ``iterator()``
- ``iterator(fromIndex:)``
- ``iterator(fromKey:)-(Span<UInt8>)``
- ``iterator(fromKey:)-(Collection<UInt8>)``
- ``entry(at:)``
- ``rank(of:)-(Span<UInt8>)``
- ``rank(of:)-(Collection<UInt8>)``

### Writing

- ``put(_:forKey:)-(_,Span<UInt8>)``
- ``put(_:forKey:)-(_,Collection<UInt8>)``
- ``putCursor(forKey:)-(Span<UInt8>)``
- ``putCursor(forKey:)-(Collection<UInt8>)``
- ``remove(forKey:)-(Span<UInt8>)``
- ``remove(forKey:)-(Collection<UInt8>)``
