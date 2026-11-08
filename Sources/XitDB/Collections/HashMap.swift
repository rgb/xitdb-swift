/// A hash map in a database.
///
/// A map holds values, each under the hash of its key. **The map hashes
/// nothing itself.** The caller hashes each key, with any function whose
/// result has as many bytes as the database's hash size, and gives the
/// hash. Two keys with the same hash are the same key to the map.
///
/// A hash cannot be turned back into its key. To be able to read the keys
/// of a map, for instance when iterating over it, store each key beside its
/// value with `putKey`.
///
/// A map is a view of a slot. Making one that can only read checks that
/// the slot holds a map of this kind, or nothing. Making one that can
/// write makes the slot a map if it holds nothing, and readies it for
/// this transaction's writes.
///
/// Writing needs a transaction: see ``Database/withTransaction(_:)``. A map at
/// the root of the database is the exception: there, every write is a
/// transaction of its own.
public struct HashMap<Access: CursorAccess> {
    /// The cursor at the slot that holds the map.
    public let cursor: Cursor<Access>

    /// The slot that holds the map.
    ///
    /// - Throws: Only for a map at the root of the database, if the root
    ///   cannot be read.
    public var slot: Slot {
        get throws(XitDBError) {
            try cursor.slot
        }
    }

    /// An iterator over the map's entries. Each cursor it gives is at an
    /// entry; ``Cursor/readEntry()`` reads the entry's key and value.
    ///
    /// The order is that of the hashes' last bits, which has nothing to do
    /// with the order of insertion.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something that
    ///   is not a collection, ``XitDBError/staleCursor`` if the map is not at
    ///   the root and its cursor is from a transaction that did not commit, or
    ///   an error of the storage or of a damaged file.
    public func iterator() throws(XitDBError) -> CollectionIterator {
        try cursor.iterator()
    }

    /// A cursor at the value stored under a hash, or `nil` if the map has no
    /// entry for it or the entry's value was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, once the slot holds a map or set (a
    ///   slot that holds nothing checks no hash and has no entry for it, as in
    ///   the original), ``XitDBError/unexpectedTag`` if the slot holds
    ///   something other than a hash map or set, ``XitDBError/staleCursor`` if
    ///   the map is not at the root and its cursor is from a transaction that
    ///   did not commit, or an error of the storage or of a damaged file.
    public func cursor(forHash hash: Span<UInt8>) throws(XitDBError) -> Cursor<ReadOnly>? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.value, KeyHash(hash))]
        return try cursor.readPath(path.span)
    }

    /// A cursor at the value stored under a hash, or `nil` if the map has no
    /// entry for it or the entry's value was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size, in any sequence of bytes: an array, a CryptoKit digest, a slice,
    ///   `Data`, a string's `utf8`. Anything but an array is copied once; the
    ///   `Span` overload takes bytes already borrowed.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, once the slot holds a map or set (a
    ///   slot that holds nothing checks no hash and has no entry for it, as in
    ///   the original), ``XitDBError/unexpectedTag`` if the slot holds
    ///   something other than a hash map or set, ``XitDBError/staleCursor`` if
    ///   the map is not at the root and its cursor is from a transaction that
    ///   did not commit, or an error of the storage or of a damaged file.
    @inlinable
    public func cursor(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Cursor<ReadOnly>? {
        let bytes = Array(hash)
        return try cursor(forHash: bytes.span)
    }

    /// The slot of the value stored under a hash, or `nil` if the map has no
    /// entry for it or the entry's value was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, once the slot holds a map or set (a
    ///   slot that holds nothing checks no hash and has no entry for it, as in
    ///   the original), ``XitDBError/unexpectedTag`` if the slot holds
    ///   something other than a hash map or set, ``XitDBError/staleCursor`` if
    ///   the map is not at the root and its cursor is from a transaction that
    ///   did not commit, or an error of the storage or of a damaged file.
    public func slot(forHash hash: Span<UInt8>) throws(XitDBError) -> Slot? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.value, KeyHash(hash))]
        return try cursor.readPathSlot(path.span)
    }

    /// The slot of the value stored under a hash, or `nil` if the map has no
    /// entry for it or the entry's value was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size, in any sequence of bytes: an array, a CryptoKit digest, a slice,
    ///   `Data`, a string's `utf8`. Anything but an array is copied once; the
    ///   `Span` overload takes bytes already borrowed.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, once the slot holds a map or set (a
    ///   slot that holds nothing checks no hash and has no entry for it, as in
    ///   the original), ``XitDBError/unexpectedTag`` if the slot holds
    ///   something other than a hash map or set, ``XitDBError/staleCursor`` if
    ///   the map is not at the root and its cursor is from a transaction that
    ///   did not commit, or an error of the storage or of a damaged file.
    @inlinable
    public func slot(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Slot? {
        let bytes = Array(hash)
        return try slot(forHash: bytes.span)
    }

    /// A cursor at the key stored beside the value under a hash, or `nil`
    /// if the map has no entry for it or no key was stored with it.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, once the slot holds a map or set (a
    ///   slot that holds nothing checks no hash and has no entry for it, as in
    ///   the original), ``XitDBError/unexpectedTag`` if the slot holds
    ///   something other than a hash map or set, ``XitDBError/staleCursor`` if
    ///   the map is not at the root and its cursor is from a transaction that
    ///   did not commit, or an error of the storage or of a damaged file.
    public func keyCursor(forHash hash: Span<UInt8>) throws(XitDBError) -> Cursor<ReadOnly>? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, KeyHash(hash))]
        return try cursor.readPath(path.span)
    }

    /// A cursor at the key stored beside the value under a hash, or `nil`
    /// if the map has no entry for it or no key was stored with it.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size, in any sequence of bytes: an array, a CryptoKit digest, a slice,
    ///   `Data`, a string's `utf8`. Anything but an array is copied once; the
    ///   `Span` overload takes bytes already borrowed.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, once the slot holds a map or set (a
    ///   slot that holds nothing checks no hash and has no entry for it, as in
    ///   the original), ``XitDBError/unexpectedTag`` if the slot holds
    ///   something other than a hash map or set, ``XitDBError/staleCursor`` if
    ///   the map is not at the root and its cursor is from a transaction that
    ///   did not commit, or an error of the storage or of a damaged file.
    @inlinable
    public func keyCursor(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Cursor<ReadOnly>? {
        let bytes = Array(hash)
        return try keyCursor(forHash: bytes.span)
    }

    /// The slot of the key stored beside the value under a hash, or `nil`
    /// if the map has no entry for it or no key was stored with it.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, once the slot holds a map or set (a
    ///   slot that holds nothing checks no hash and has no entry for it, as in
    ///   the original), ``XitDBError/unexpectedTag`` if the slot holds
    ///   something other than a hash map or set, ``XitDBError/staleCursor`` if
    ///   the map is not at the root and its cursor is from a transaction that
    ///   did not commit, or an error of the storage or of a damaged file.
    public func keySlot(forHash hash: Span<UInt8>) throws(XitDBError) -> Slot? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, KeyHash(hash))]
        return try cursor.readPathSlot(path.span)
    }

    /// The slot of the key stored beside the value under a hash, or `nil`
    /// if the map has no entry for it or no key was stored with it.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size, in any sequence of bytes: an array, a CryptoKit digest, a slice,
    ///   `Data`, a string's `utf8`. Anything but an array is copied once; the
    ///   `Span` overload takes bytes already borrowed.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, once the slot holds a map or set (a
    ///   slot that holds nothing checks no hash and has no entry for it, as in
    ///   the original), ``XitDBError/unexpectedTag`` if the slot holds
    ///   something other than a hash map or set, ``XitDBError/staleCursor`` if
    ///   the map is not at the root and its cursor is from a transaction that
    ///   did not commit, or an error of the storage or of a damaged file.
    @inlinable
    public func keySlot(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Slot? {
        let bytes = Array(hash)
        return try keySlot(forHash: bytes.span)
    }

    /// The entry stored under a hash, as a cursor for its key and one for
    /// its value, or `nil` if the map has no entry for it.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, once the slot holds a map or set (a
    ///   slot that holds nothing checks no hash and has no entry for it, as in
    ///   the original), ``XitDBError/unexpectedTag`` if the slot holds
    ///   something other than a hash map or set, ``XitDBError/staleCursor`` if
    ///   the map is not at the root and its cursor is from a transaction that
    ///   did not commit, or an error of the storage or of a damaged file.
    public func entry(forHash hash: Span<UInt8>) throws(XitDBError) -> Entry? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.kvPair, KeyHash(hash))]
        return try cursor.readPath(path.span)?.readEntry()
    }

    /// The entry stored under a hash, as a cursor for its key and one for
    /// its value, or `nil` if the map has no entry for it.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size, in any sequence of bytes: an array, a CryptoKit digest, a slice,
    ///   `Data`, a string's `utf8`. Anything but an array is copied once; the
    ///   `Span` overload takes bytes already borrowed.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, once the slot holds a map or set (a
    ///   slot that holds nothing checks no hash and has no entry for it, as in
    ///   the original), ``XitDBError/unexpectedTag`` if the slot holds
    ///   something other than a hash map or set, ``XitDBError/staleCursor`` if
    ///   the map is not at the root and its cursor is from a transaction that
    ///   did not commit, or an error of the storage or of a damaged file.
    @inlinable
    public func entry(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Entry? {
        let bytes = Array(hash)
        return try entry(forHash: bytes.span)
    }

}

extension HashMap where Access == ReadOnly {
    /// A view of the map at a cursor's slot, for reading.
    ///
    /// A slot that holds nothing is an empty map.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a hash map or set that keeps no count.
    public init(_ cursor: Cursor<ReadOnly>) throws(XitDBError) {
        switch try cursor.resolved().slot.tag {
        case .none, .hashMap, .hashSet:
            self.cursor = cursor
        default:
            throw .unexpectedTag
        }
    }

    /// A view of the map at a cursor's slot, for reading, from a cursor of
    /// either access: one that can write is read through as its
    /// ``Cursor/readOnly``, so that a reader need not take it first.
    ///
    /// A slot that holds nothing is an empty map.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a hash map or set that keeps no count.
    public init(_ cursor: Cursor<some CursorAccess>) throws(XitDBError) {
        try self.init(Cursor<ReadOnly>(viewing: cursor))
    }
}

extension HashMap where Access == ReadWrite {
    /// A view of the map at a cursor's slot, for reading and writing.
    ///
    /// A slot that holds nothing becomes an empty map. A map from an
    /// earlier transaction is readied for this one: its first block is
    /// copied, so that writing to it leaves earlier moments as they were.
    ///
    /// **A hash set becomes a hash map.** A map and a set that keep no
    /// count are one kind to the slot, as in the original: the slot's tag
    /// is written as a map and the entries stay. On the root, where this is
    /// a transaction of its own, a set is a map from then on; a set is
    /// opened with ``HashSet``.
    ///
    /// On the root cursor this is a transaction of its own, unless the root
    /// is such a map already, in which case nothing is written.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something other
    ///   than a hash map or set that keeps no count,
    ///   ``XitDBError/expectedTxStart`` if no transaction is in progress and
    ///   `cursor` is not the root cursor, ``XitDBError/nestedTopLevelWrite`` if
    ///   `cursor` is the root cursor and one is,
    ///   ``XitDBError/cursorNotWritable`` if `cursor` has no position, as the
    ///   key cursor of a sorted map's entry has not, ``XitDBError/staleCursor``
    ///   if `cursor` is from an earlier transaction (one from before a freeze
    ///   of this transaction is allowed here),
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, or an error of the storage or of a
    ///   damaged file.
    public init(_ cursor: Cursor<ReadWrite>) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.hashMapInit(counted: false, set: false)]
        self.cursor = try cursor.writePath(path.span)
    }

    /// A view of the same map that can only read.
    public var readOnly: HashMap<ReadOnly> {
        HashMap<ReadOnly>(unchecked: cursor.readOnly)
    }

    /// Stores a value under a hash, in place of any value that was there.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - hash: The key's hash, as many bytes as the database's hash size.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not the
    ///   root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/invalidHashSize`` if
    ///   `hash` does not have as many bytes as the database's hash size,
    ///   ``XitDBError/unexpectedTag`` if the slot no longer holds a hash map or
    ///   set, or an error of the storage or of a damaged file.
    public func put(_ value: WritableData, forHash hash: Span<UInt8>) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.hashMapGet(.value, KeyHash(hash)), .write(value)]
        _ = try cursor.writePath(path.span)
    }

    /// Stores a value under a hash, in place of any value that was there.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - hash: The key's hash, as many bytes as the database's hash size, in
    ///     any sequence of bytes: an array, a CryptoKit digest, a slice,
    ///     `Data`, a string's `utf8`. Anything but an array is copied once; the
    ///     `Span` overload takes bytes already borrowed.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not the
    ///   root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/invalidHashSize`` if
    ///   `hash` does not have as many bytes as the database's hash size,
    ///   ``XitDBError/unexpectedTag`` if the slot no longer holds a hash map or
    ///   set, or an error of the storage or of a damaged file.
    @inlinable
    public func put(_ value: WritableData, forHash hash: some Sequence<UInt8>) throws(XitDBError) {
        let bytes = Array(hash)
        try put(value, forHash: bytes.span)
    }

    /// A cursor at the value stored under a hash, for writing it or for
    /// making a collection there. The map gets an entry for the hash if it
    /// has none.
    ///
    /// Use it in a transaction. On a collection at the root the call is a
    /// transaction of its own, committed by the time it returns, so a new
    /// entry holds nothing and a write through the cursor throws
    /// ``XitDBError/expectedTxStart``.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not the
    ///   root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/invalidHashSize`` if
    ///   `hash` does not have as many bytes as the database's hash size,
    ///   ``XitDBError/unexpectedTag`` if the slot no longer holds a hash map or
    ///   set, or an error of the storage or of a damaged file.
    public func putCursor(forHash hash: Span<UInt8>) throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.value, KeyHash(hash))]
        return try cursor.writePath(path.span)
    }

    /// A cursor at the value stored under a hash, for writing it or for
    /// making a collection there. The map gets an entry for the hash if it
    /// has none.
    ///
    /// Use it in a transaction. On a collection at the root the call is a
    /// transaction of its own, committed by the time it returns, so a new
    /// entry holds nothing and a write through the cursor throws
    /// ``XitDBError/expectedTxStart``.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size, in any sequence of bytes: an array, a CryptoKit digest, a slice,
    ///   `Data`, a string's `utf8`. Anything but an array is copied once; the
    ///   `Span` overload takes bytes already borrowed.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not the
    ///   root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/invalidHashSize`` if
    ///   `hash` does not have as many bytes as the database's hash size,
    ///   ``XitDBError/unexpectedTag`` if the slot no longer holds a hash map or
    ///   set, or an error of the storage or of a damaged file.
    @inlinable
    public func putCursor(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Cursor<ReadWrite> {
        let bytes = Array(hash)
        return try putCursor(forHash: bytes.span)
    }

    /// Stores a key beside the value under its hash, unless a key is there
    /// already. The map gets an entry for the hash if it has none.
    ///
    /// A key is only written once, because the key under one hash should
    /// always be the same.
    ///
    /// - Parameters:
    ///   - key: The key.
    ///   - hash: The key's hash, as many bytes as the database's hash size.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not the
    ///   root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/invalidHashSize`` if
    ///   `hash` does not have as many bytes as the database's hash size,
    ///   ``XitDBError/unexpectedTag`` if the slot no longer holds a hash map or
    ///   set, or an error of the storage or of a damaged file.
    public func putKey(_ key: WritableData, forHash hash: Span<UInt8>) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.hashMapGet(.key, KeyHash(hash)), .ctx]
        // The key is written inside the callback, so it is not a part of
        // the path: check it here, after the cursor's checks and before the
        // entry is made, as a write part would be checked.
        try cursor.checkWritable(path.span)
        try key.checkIsValue()
        _ = try cursor.writePath(
            path.span,
            typed: { (keyCursor: inout Cursor<ReadWrite>) throws(XitDBError) in
                try keyCursor.writeIfEmpty(key)
            })
    }

    /// Stores a key beside the value under its hash, unless a key is there
    /// already. The map gets an entry for the hash if it has none.
    ///
    /// A key is only written once, because the key under one hash should
    /// always be the same.
    ///
    /// - Parameters:
    ///   - key: The key.
    ///   - hash: The key's hash, as many bytes as the database's hash size, in
    ///     any sequence of bytes: an array, a CryptoKit digest, a slice,
    ///     `Data`, a string's `utf8`. Anything but an array is copied once; the
    ///     `Span` overload takes bytes already borrowed.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not the
    ///   root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/invalidHashSize`` if
    ///   `hash` does not have as many bytes as the database's hash size,
    ///   ``XitDBError/unexpectedTag`` if the slot no longer holds a hash map or
    ///   set, or an error of the storage or of a damaged file.
    @inlinable
    public func putKey(_ key: WritableData, forHash hash: some Sequence<UInt8>) throws(XitDBError) {
        let bytes = Array(hash)
        try putKey(key, forHash: bytes.span)
    }

    /// A cursor at the key stored beside the value under a hash, for
    /// writing it. The map gets an entry for the hash if it has none.
    ///
    /// Use it in a transaction. On a collection at the root the call is a
    /// transaction of its own, committed by the time it returns, so a new
    /// entry holds nothing and a write through the cursor throws
    /// ``XitDBError/expectedTxStart``.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not the
    ///   root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/invalidHashSize`` if
    ///   `hash` does not have as many bytes as the database's hash size,
    ///   ``XitDBError/unexpectedTag`` if the slot no longer holds a hash map or
    ///   set, or an error of the storage or of a damaged file.
    public func putKeyCursor(forHash hash: Span<UInt8>) throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, KeyHash(hash))]
        return try cursor.writePath(path.span)
    }

    /// A cursor at the key stored beside the value under a hash, for
    /// writing it. The map gets an entry for the hash if it has none.
    ///
    /// Use it in a transaction. On a collection at the root the call is a
    /// transaction of its own, committed by the time it returns, so a new
    /// entry holds nothing and a write through the cursor throws
    /// ``XitDBError/expectedTxStart``.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size, in any sequence of bytes: an array, a CryptoKit digest, a slice,
    ///   `Data`, a string's `utf8`. Anything but an array is copied once; the
    ///   `Span` overload takes bytes already borrowed.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not the
    ///   root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/invalidHashSize`` if
    ///   `hash` does not have as many bytes as the database's hash size,
    ///   ``XitDBError/unexpectedTag`` if the slot no longer holds a hash map or
    ///   set, or an error of the storage or of a damaged file.
    @inlinable
    public func putKeyCursor(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Cursor<ReadWrite> {
        let bytes = Array(hash)
        return try putKeyCursor(forHash: bytes.span)
    }

    /// Removes the entry stored under a hash.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Returns: Whether there was an entry to remove.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not the
    ///   root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/invalidHashSize`` if
    ///   `hash` does not have as many bytes as the database's hash size,
    ///   ``XitDBError/unexpectedTag`` if the slot no longer holds a hash map or
    ///   set, or an error of the storage or of a damaged file.
    @discardableResult
    public func remove(forHash hash: Span<UInt8>) throws(XitDBError) -> Bool {
        let path: InlineArray<1, PathPart> = [.hashMapRemove(KeyHash(hash))]
        do throws(XitDBError) {
            _ = try cursor.writePath(path.span)
        } catch {
            guard error == .keyNotFound else { throw error }
            return false
        }
        return true
    }

    /// Removes the entry stored under a hash.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size, in any sequence of bytes: an array, a CryptoKit digest, a slice,
    ///   `Data`, a string's `utf8`. Anything but an array is copied once; the
    ///   `Span` overload takes bytes already borrowed.
    /// - Returns: Whether there was an entry to remove.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not the
    ///   root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/invalidHashSize`` if
    ///   `hash` does not have as many bytes as the database's hash size,
    ///   ``XitDBError/unexpectedTag`` if the slot no longer holds a hash map or
    ///   set, or an error of the storage or of a damaged file.
    @discardableResult
    @inlinable
    public func remove(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Bool {
        let bytes = Array(hash)
        return try remove(forHash: bytes.span)
    }

}

extension HashMap {
    /// A view of the map at a cursor's slot, which the caller has made
    /// sure holds one.
    init(unchecked cursor: Cursor<Access>) {
        self.cursor = cursor
    }
}
