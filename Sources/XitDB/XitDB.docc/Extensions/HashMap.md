# ``XitDB/HashMap``

## Topics

### Making a map

- ``init(_:)-(Cursor<ReadOnly>)``
- ``init(_:)-(Cursor<CursorAccess>)``
- ``init(_:)-(Cursor<ReadWrite>)``
- ``cursor``
- ``slot``
- ``readOnly``

### Reading values

- ``value(forKey:as:)``
- ``cursor(forKey:)``
- ``slot(forKey:)``
- ``entry(forKey:)``
- ``cursor(forHash:)-(Span<UInt8>)``
- ``cursor(forHash:)-(Sequence<UInt8>)``
- ``slot(forHash:)-(Span<UInt8>)``
- ``slot(forHash:)-(Sequence<UInt8>)``
- ``entry(forHash:)-(Span<UInt8>)``
- ``entry(forHash:)-(Sequence<UInt8>)``
- ``iterator()``

### Reading keys

A map has a key to give only where one was stored, as a put given `storingKey: true` and ``putKey(_:)`` store it. See
<doc:CursorsAndValues>.

- ``keyCursor(forKey:)``
- ``keySlot(forKey:)``
- ``keyCursor(forHash:)-(Span<UInt8>)``
- ``keyCursor(forHash:)-(Sequence<UInt8>)``
- ``keySlot(forHash:)-(Span<UInt8>)``
- ``keySlot(forHash:)-(Sequence<UInt8>)``

### Writing

A put stores the value under the key's hash, and the key only when given `storingKey: true`. See <doc:TheCollections>.

- ``put(_:forKey:storingKey:)-(StorableValue,_,_)``
- ``put(_:forKey:storingKey:)-(WritableData,_,_)``
- ``putCursor(forKey:)``
- ``putKey(_:)``
- ``putKeyCursor(forKey:)``
- ``remove(forKey:)``
- ``put(_:forHash:)-(_,Span<UInt8>)``
- ``put(_:forHash:)-(_,Sequence<UInt8>)``
- ``putCursor(forHash:)-(Span<UInt8>)``
- ``putCursor(forHash:)-(Sequence<UInt8>)``
- ``putKey(_:forHash:)-(_,Span<UInt8>)``
- ``putKey(_:forHash:)-(_,Sequence<UInt8>)``
- ``putKeyCursor(forHash:)-(Span<UInt8>)``
- ``putKeyCursor(forHash:)-(Sequence<UInt8>)``
- ``remove(forHash:)-(Span<UInt8>)``
- ``remove(forHash:)-(Sequence<UInt8>)``
