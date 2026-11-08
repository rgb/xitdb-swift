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
- ``contains(_:)-(Sequence<UInt8>)``
- ``iterator()``
- ``iterator(fromIndex:)``
- ``iterator(fromKey:)-(Span<UInt8>)``
- ``iterator(fromKey:)-(Sequence<UInt8>)``
- ``entry(at:)``
- ``rank(of:)-(Span<UInt8>)``
- ``rank(of:)-(Sequence<UInt8>)``

### Writing

- ``insert(_:)-(Span<UInt8>)``
- ``insert(_:)-(Sequence<UInt8>)``
- ``remove(forKey:)-(Span<UInt8>)``
- ``remove(forKey:)-(Sequence<UInt8>)``
