# ``XitDB/SortedSet``

## Topics

### Making a set

- ``init(_:)-(Cursor<ReadOnly>)``
- ``init(_:)-(Cursor<CursorAccess>)``
- ``init(_:)-(Cursor<ReadWrite>)``
- ``cursor``
- ``slot``
- ``readOnly``

### Reading by key

- ``contains(_:)-(Span<UInt8>)``
- ``contains(_:)-(KeyRepresentable)``

### Reading in order

See <doc:SortingAndPaginating>.

- ``count``
- ``isEmpty``
- ``iterator()``
- ``entries()``
- ``forEachEntry(_:)``
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
