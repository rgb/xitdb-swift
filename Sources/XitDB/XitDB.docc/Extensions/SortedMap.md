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
- ``cursor(forKey:)-(Sequence<UInt8>)``
- ``slot(forKey:)-(Span<UInt8>)``
- ``slot(forKey:)-(Sequence<UInt8>)``
- ``entry(forKey:)-(Span<UInt8>)``
- ``entry(forKey:)-(Sequence<UInt8>)``

### Reading in order

See <doc:SortingAndPaginating>.

- ``count``
- ``iterator()``
- ``iterator(fromIndex:)``
- ``iterator(fromKey:)-(Span<UInt8>)``
- ``iterator(fromKey:)-(Sequence<UInt8>)``
- ``entry(at:)``
- ``rank(of:)-(Span<UInt8>)``
- ``rank(of:)-(Sequence<UInt8>)``

### Writing

- ``put(_:forKey:)-(_,Span<UInt8>)``
- ``put(_:forKey:)-(_,Sequence<UInt8>)``
- ``putCursor(forKey:)-(Span<UInt8>)``
- ``putCursor(forKey:)-(Sequence<UInt8>)``
- ``remove(forKey:)-(Span<UInt8>)``
- ``remove(forKey:)-(Sequence<UInt8>)``
