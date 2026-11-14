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
- ``contains(_:)-(KeyRepresentable)``
- ``iterator()``
- ``iterator(fromIndex:)``
- ``iterator(fromKey:)-(Span<UInt8>)``
- ``iterator(fromKey:)-(KeyRepresentable)``
- ``entry(at:)``
- ``rank(of:)-(Span<UInt8>)``
- ``rank(of:)-(KeyRepresentable)``

### Writing

- ``insert(_:)-(Span<UInt8>)``
- ``insert(_:)-(KeyRepresentable)``
- ``remove(forKey:)-(Span<UInt8>)``
- ``remove(forKey:)-(KeyRepresentable)``
