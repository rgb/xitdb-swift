/// A counted hash map in a database: Zig's `CountedHashMap`.
///
/// A map holds values, each under the hash of its key. **The map hashes
/// nothing itself.** The caller hashes each key, with any function whose
/// result has as many bytes as the database's hash size, and gives the hash.
/// Two keys with the same hash are the same key to the map.
///
/// A hash cannot be turned back into its key. To be able to read the keys
/// of a map, for instance when iterating over it, store each key beside its
/// value with `putKey`.
///
/// A counted map keeps the number of its entries, which ``count()`` reads
/// without going through them. It costs eight bytes and one more write for
/// each entry added or removed.
///
/// A map is a view of a slot. Making one that can only read checks that
/// the slot holds a map of this kind, or nothing. Making one that can
/// write makes the slot a map if it holds nothing, and readies it for
/// this transaction's writes.
///
/// Writing needs a transaction: see ``Database/withTransaction(_:)``. A map at
/// the root of the database is the exception: there, every write is a
/// transaction of its own.
public struct CountedHashMap<Access: CursorAccess> {
    /// The cursor at the slot that holds the map.
    public let cursor: Cursor<Access>

    /// The slot that holds the map.
    ///
    /// - Throws: Only for a map at the root of the database, if the root
    ///   cannot be read.
    public func slot() throws(XitDBError) -> Slot {
        try cursor.slot()
    }

    /// The number of entries in the map.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   that has no count, or ``XitDBError/endOfStream`` if the count
    ///   cannot be read.
    public func count() throws(XitDBError) -> UInt64 {
        try cursor.count()
    }

    /// An iterator over the map's entries. Each cursor it gives is at an
    /// entry; ``Cursor/readKeyValuePair()`` reads the entry's key and value.
    ///
    /// The order is that of the hashes' last bits, which has nothing to do
    /// with the order of insertion.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   that is not a collection, or an error of the storage or of a
    ///   damaged file.
    public func iterator() throws(XitDBError) -> Cursor<Access>.Iter {
        try cursor.iterator()
    }

    /// A cursor at the value stored under a hash, or `nil` if the map has no
    /// entry for it or the entry's value was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot holds something other than a hash map or set, or an error
    ///   of the storage or of a damaged file.
    public func getCursor(_ hash: Span<UInt8>) throws(XitDBError) -> Cursor<ReadOnly>? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.value, KeyHash(hash))]
        return try cursor.readPath(path.span)
    }

    /// A cursor at the value stored under a hash, or `nil` if the map has no
    /// entry for it or the entry's value was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot holds something other than a hash map or set, or an error
    ///   of the storage or of a damaged file.
    public func getCursor(_ hash: [UInt8]) throws(XitDBError) -> Cursor<ReadOnly>? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.value, KeyHash(hash))]
        return try cursor.readPath(path.span)
    }

    /// The slot of the value stored under a hash, or `nil` if the map has no
    /// entry for it or the entry's value was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot holds something other than a hash map or set, or an error
    ///   of the storage or of a damaged file.
    public func getSlot(_ hash: Span<UInt8>) throws(XitDBError) -> Slot? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.value, KeyHash(hash))]
        return try cursor.readPathSlot(path.span)
    }

    /// The slot of the value stored under a hash, or `nil` if the map has no
    /// entry for it or the entry's value was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot holds something other than a hash map or set, or an error
    ///   of the storage or of a damaged file.
    public func getSlot(_ hash: [UInt8]) throws(XitDBError) -> Slot? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.value, KeyHash(hash))]
        return try cursor.readPathSlot(path.span)
    }

    /// A cursor at the key stored beside the value under a hash, or `nil`
    /// if the map has no entry for it or no key was stored with it.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot holds something other than a hash map or set, or an error
    ///   of the storage or of a damaged file.
    public func getKeyCursor(_ hash: Span<UInt8>) throws(XitDBError) -> Cursor<ReadOnly>? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, KeyHash(hash))]
        return try cursor.readPath(path.span)
    }

    /// A cursor at the key stored beside the value under a hash, or `nil`
    /// if the map has no entry for it or no key was stored with it.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot holds something other than a hash map or set, or an error
    ///   of the storage or of a damaged file.
    public func getKeyCursor(_ hash: [UInt8]) throws(XitDBError) -> Cursor<ReadOnly>? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, KeyHash(hash))]
        return try cursor.readPath(path.span)
    }

    /// The slot of the key stored beside the value under a hash, or `nil`
    /// if the map has no entry for it or no key was stored with it.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot holds something other than a hash map or set, or an error
    ///   of the storage or of a damaged file.
    public func getKeySlot(_ hash: Span<UInt8>) throws(XitDBError) -> Slot? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, KeyHash(hash))]
        return try cursor.readPathSlot(path.span)
    }

    /// The slot of the key stored beside the value under a hash, or `nil`
    /// if the map has no entry for it or no key was stored with it.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot holds something other than a hash map or set, or an error
    ///   of the storage or of a damaged file.
    public func getKeySlot(_ hash: [UInt8]) throws(XitDBError) -> Slot? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, KeyHash(hash))]
        return try cursor.readPathSlot(path.span)
    }

    /// The entry stored under a hash, as a cursor for its key and one for
    /// its value, or `nil` if the map has no entry for it.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot holds something other than a hash map or set, or an error
    ///   of the storage or of a damaged file.
    public func getKeyValuePair(_ hash: Span<UInt8>) throws(XitDBError) -> KeyValuePairCursor<ReadOnly>? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.kvPair, KeyHash(hash))]
        return try cursor.readPath(path.span)?.readKeyValuePair()
    }

    /// The entry stored under a hash, as a cursor for its key and one for
    /// its value, or `nil` if the map has no entry for it.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot holds something other than a hash map or set, or an error
    ///   of the storage or of a damaged file.
    public func getKeyValuePair(_ hash: [UInt8]) throws(XitDBError) -> KeyValuePairCursor<ReadOnly>? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.kvPair, KeyHash(hash))]
        return try cursor.readPath(path.span)?.readKeyValuePair()
    }

}

extension CountedHashMap where Access == ReadOnly {
    /// A view of the map at a cursor's slot, for reading.
    ///
    /// A slot that holds nothing is an empty map.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a counted hash map or set.
    public init(_ cursor: Cursor<ReadOnly>) throws(XitDBError) {
        switch try cursor.resolved().slot.tag {
        case .none, .countedHashMap, .countedHashSet:
            self.cursor = cursor
        default:
            throw .unexpectedTag
        }
    }
}

extension CountedHashMap where Access == ReadWrite {
    /// A view of the map at a cursor's slot, for reading and writing.
    ///
    /// A slot that holds nothing becomes an empty map. A map from an
    /// earlier transaction is readied for this one: its first block is
    /// copied, so that writing to it leaves earlier moments as they were.
    ///
    /// On the root cursor this is a transaction of its own, unless the root
    /// is such a map already, in which case nothing is written.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a counted hash map, ``XitDBError/expectedTxStart`` if no
    ///   transaction is in progress and `cursor` is not the root cursor, or
    ///   an error of the storage or of a damaged file.
    public init(_ cursor: Cursor<ReadWrite>) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.hashMapInit(counted: true, set: false)]
        self.cursor = try cursor.writePath(path.span)
    }

    /// A view of the same map that can only read.
    public func readOnly() -> CountedHashMap<ReadOnly> {
        CountedHashMap<ReadOnly>(unchecked: cursor.readOnly())
    }

    /// Stores a value under a hash, in place of any value that was there.
    ///
    /// - Parameters:
    ///   - hash: The key's hash, as many bytes as the database's hash size.
    ///   - data: The value.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot no longer holds a hash map or set, or an error of the
    ///   storage or of a damaged file.
    public func put(_ hash: Span<UInt8>, _ data: WritableData) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.hashMapGet(.value, KeyHash(hash)), .write(data)]
        _ = try cursor.writePath(path.span)
    }

    /// Stores a value under a hash, in place of any value that was there.
    ///
    /// - Parameters:
    ///   - hash: The key's hash, as many bytes as the database's hash size.
    ///   - data: The value.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot no longer holds a hash map or set, or an error of the
    ///   storage or of a damaged file.
    public func put(_ hash: [UInt8], _ data: WritableData) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.hashMapGet(.value, KeyHash(hash)), .write(data)]
        _ = try cursor.writePath(path.span)
    }

    /// A cursor at the value stored under a hash, for writing it or for
    /// making a collection there. The map gets an entry for the hash if it
    /// has none.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot no longer holds a hash map or set, or an error of the
    ///   storage or of a damaged file.
    public func putCursor(_ hash: Span<UInt8>) throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.value, KeyHash(hash))]
        return try cursor.writePath(path.span)
    }

    /// A cursor at the value stored under a hash, for writing it or for
    /// making a collection there. The map gets an entry for the hash if it
    /// has none.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot no longer holds a hash map or set, or an error of the
    ///   storage or of a damaged file.
    public func putCursor(_ hash: [UInt8]) throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.value, KeyHash(hash))]
        return try cursor.writePath(path.span)
    }

    /// Stores a key beside the value under its hash, unless a key is there
    /// already. The map gets an entry for the hash if it has none.
    ///
    /// A key is only written once, because the key under one hash should
    /// always be the same.
    ///
    /// - Parameters:
    ///   - hash: The key's hash, as many bytes as the database's hash size.
    ///   - data: The key.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot no longer holds a hash map or set, or an error of the
    ///   storage or of a damaged file.
    public func putKey(_ hash: Span<UInt8>, _ data: WritableData) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.hashMapGet(.key, KeyHash(hash)), .ctx]
        _ = try cursor.writePath(
            path.span,
            typed: { (key: inout Cursor<ReadWrite>) throws(XitDBError) in
                try key.writeIfEmpty(data)
            })
    }

    /// Stores a key beside the value under its hash, unless a key is there
    /// already. The map gets an entry for the hash if it has none.
    ///
    /// A key is only written once, because the key under one hash should
    /// always be the same.
    ///
    /// - Parameters:
    ///   - hash: The key's hash, as many bytes as the database's hash size.
    ///   - data: The key.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot no longer holds a hash map or set, or an error of the
    ///   storage or of a damaged file.
    public func putKey(_ hash: [UInt8], _ data: WritableData) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.hashMapGet(.key, KeyHash(hash)), .ctx]
        _ = try cursor.writePath(
            path.span,
            typed: { (key: inout Cursor<ReadWrite>) throws(XitDBError) in
                try key.writeIfEmpty(data)
            })
    }

    /// A cursor at the key stored beside the value under a hash, for
    /// writing it. The map gets an entry for the hash if it has none.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot no longer holds a hash map or set, or an error of the
    ///   storage or of a damaged file.
    public func putKeyCursor(_ hash: Span<UInt8>) throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, KeyHash(hash))]
        return try cursor.writePath(path.span)
    }

    /// A cursor at the key stored beside the value under a hash, for
    /// writing it. The map gets an entry for the hash if it has none.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot no longer holds a hash map or set, or an error of the
    ///   storage or of a damaged file.
    public func putKeyCursor(_ hash: [UInt8]) throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, KeyHash(hash))]
        return try cursor.writePath(path.span)
    }

    /// Removes the entry stored under a hash.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Returns: Whether there was an entry to remove.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot no longer holds a hash map or set, or an error of the
    ///   storage or of a damaged file.
    @discardableResult
    public func remove(_ hash: Span<UInt8>) throws(XitDBError) -> Bool {
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
    ///   size.
    /// - Returns: Whether there was an entry to remove.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot no longer holds a hash map or set, or an error of the
    ///   storage or of a damaged file.
    @discardableResult
    public func remove(_ hash: [UInt8]) throws(XitDBError) -> Bool {
        let path: InlineArray<1, PathPart> = [.hashMapRemove(KeyHash(hash))]
        do throws(XitDBError) {
            _ = try cursor.writePath(path.span)
        } catch {
            guard error == .keyNotFound else { throw error }
            return false
        }
        return true
    }

}

extension CountedHashMap {
    /// A view of the map at a cursor's slot, which the caller has made
    /// sure holds one.
    init(unchecked cursor: Cursor<Access>) {
        self.cursor = cursor
    }
}
