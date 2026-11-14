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
- ``cursor(forKey:)-(KeyRepresentable)``
- ``slot(forKey:)-(Span<UInt8>)``
- ``slot(forKey:)-(KeyRepresentable)``
- ``entry(forKey:)-(Span<UInt8>)``
- ``entry(forKey:)-(KeyRepresentable)``

### Reading in order

See <doc:SortingAndPaginating>.

- ``count``
- ``iterator()``
- ``iterator(fromIndex:)``
- ``iterator(fromKey:)-(Span<UInt8>)``
- ``iterator(fromKey:)-(KeyRepresentable)``
- ``entry(at:)``
- ``rank(of:)-(Span<UInt8>)``
- ``rank(of:)-(KeyRepresentable)``

### Writing

- ``put(_:forKey:)-(_,Span<UInt8>)``
- ``put(_:forKey:)-(WritableData,KeyRepresentable)``
- ``putCursor(forKey:)-(Span<UInt8>)``
- ``putCursor(forKey:)-(KeyRepresentable)``
- ``remove(forKey:)-(Span<UInt8>)``
- ``remove(forKey:)-(KeyRepresentable)``
