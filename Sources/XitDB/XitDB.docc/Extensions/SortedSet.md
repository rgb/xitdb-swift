# ``XitDB/SortedSet``

## Topics

### Making a set

- ``init(_:)-(Cursor<ReadOnly>)``
- ``init(_:)-(Cursor<CursorAccess>)``
- ``init(_:)-(Cursor<ReadWrite>)``
- ``cursor``
- ``slot``
- ``readOnly``

### Reading in order

See <doc:SortingAndPaginating>.

- ``count``
- ``contains(_:)-(Span<UInt8>)``
- ``contains(_:)-(Collection<UInt8>)``
- ``iterator()``
- ``iterator(fromIndex:)``
- ``iterator(fromKey:)-(Span<UInt8>)``
- ``iterator(fromKey:)-(Collection<UInt8>)``
- ``entry(at:)``
- ``rank(of:)-(Span<UInt8>)``
- ``rank(of:)-(Collection<UInt8>)``

### Writing

- ``insert(_:)-(Span<UInt8>)``
- ``insert(_:)-(Collection<UInt8>)``
- ``remove(forKey:)-(Span<UInt8>)``
- ``remove(forKey:)-(Collection<UInt8>)``
