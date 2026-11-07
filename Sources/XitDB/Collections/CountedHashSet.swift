/// A counted hash set in a database: Zig's `CountedHashSet`.
///
/// A set holds keys, each under its hash. **The set hashes nothing itself.**
/// The caller hashes each key, with any function whose result has as many
/// bytes as the database's hash size, and gives the hash with the key. Two
/// keys with the same hash are the same key to the set.
///
/// A counted set keeps the number of its entries, which ``count()`` reads
/// without going through them. It costs eight bytes and one more write for
/// each entry added or removed.
///
/// A set is a view of a slot. Making one that can only read checks that
/// the slot holds a set of this kind, or nothing. Making one that can
/// write makes the slot a set if it holds nothing, and readies it for
/// this transaction's writes.
///
/// Writing needs a transaction: see ``Database/withTransaction(_:)``. A set at
/// the root of the database is the exception: there, every write is a
/// transaction of its own.
public struct CountedHashSet<Access: CursorAccess> {
    /// The cursor at the slot that holds the set.
    public let cursor: Cursor<Access>

    /// The slot that holds the set.
    ///
    /// - Throws: Only for a set at the root of the database, if the root
    ///   cannot be read.
    public func slot() throws(XitDBError) -> Slot {
        try cursor.slot()
    }

    /// The number of entries in the set.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   that has no count, or ``XitDBError/endOfStream`` if the count
    ///   cannot be read.
    public func count() throws(XitDBError) -> UInt64 {
        try cursor.count()
    }

    /// An iterator over the set's entries. Each cursor it gives is at an
    /// entry; ``Cursor/readKeyValuePair()`` reads the entry's key.
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

    /// A cursor at the key stored under a hash, or `nil` if the set has no
    /// entry for it or the entry's key was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot holds something other than a hash map or set, or an error
    ///   of the storage or of a damaged file.
    public func getCursor(_ hash: Span<UInt8>) throws(XitDBError) -> Cursor<ReadOnly>? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, KeyHash(hash))]
        return try cursor.readPath(path.span)
    }

    /// A cursor at the key stored under a hash, or `nil` if the set has no
    /// entry for it or the entry's key was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot holds something other than a hash map or set, or an error
    ///   of the storage or of a damaged file.
    public func getCursor(_ hash: [UInt8]) throws(XitDBError) -> Cursor<ReadOnly>? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, KeyHash(hash))]
        return try cursor.readPath(path.span)
    }

    /// The slot of the key stored under a hash, or `nil` if the set has no
    /// entry for it or the entry's key was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot holds something other than a hash map or set, or an error
    ///   of the storage or of a damaged file.
    public func getSlot(_ hash: Span<UInt8>) throws(XitDBError) -> Slot? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, KeyHash(hash))]
        return try cursor.readPathSlot(path.span)
    }

    /// The slot of the key stored under a hash, or `nil` if the set has no
    /// entry for it or the entry's key was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot holds something other than a hash map or set, or an error
    ///   of the storage or of a damaged file.
    public func getSlot(_ hash: [UInt8]) throws(XitDBError) -> Slot? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, KeyHash(hash))]
        return try cursor.readPathSlot(path.span)
    }

}

extension CountedHashSet where Access == ReadOnly {
    /// A view of the set at a cursor's slot, for reading.
    ///
    /// A slot that holds nothing is an empty set.
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

extension CountedHashSet where Access == ReadWrite {
    /// A view of the set at a cursor's slot, for reading and writing.
    ///
    /// A slot that holds nothing becomes an empty set. A set from an
    /// earlier transaction is readied for this one: its first block is
    /// copied, so that writing to it leaves earlier moments as they were.
    ///
    /// On the root cursor this is a transaction of its own, unless the root
    /// is such a set already, in which case nothing is written.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a counted hash set, ``XitDBError/expectedTxStart`` if no
    ///   transaction is in progress and `cursor` is not the root cursor, or
    ///   an error of the storage or of a damaged file.
    public init(_ cursor: Cursor<ReadWrite>) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.hashMapInit(counted: true, set: true)]
        self.cursor = try cursor.writePath(path.span)
    }

    /// A view of the same set that can only read.
    public func readOnly() -> CountedHashSet<ReadOnly> {
        CountedHashSet<ReadOnly>(unchecked: cursor.readOnly())
    }

    /// Adds a key to the set under its hash. If the set already has a key
    /// under that hash, nothing is changed.
    ///
    /// - Parameters:
    ///   - hash: The key's hash, as many bytes as the database's hash size.
    ///   - data: The key.
    /// - Throws: ``XitDBError/expectedTxStart`` if the set's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot no longer holds a hash map or set, or an error of the
    ///   storage or of a damaged file.
    public func put(_ hash: Span<UInt8>, _ data: WritableData) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.hashMapGet(.key, KeyHash(hash)), .ctx]
        _ = try cursor.writePath(
            path.span,
            typed: { (key: inout Cursor<ReadWrite>) throws(XitDBError) in
                try key.writeIfEmpty(data)
            })
    }

    /// Adds a key to the set under its hash. If the set already has a key
    /// under that hash, nothing is changed.
    ///
    /// - Parameters:
    ///   - hash: The key's hash, as many bytes as the database's hash size.
    ///   - data: The key.
    /// - Throws: ``XitDBError/expectedTxStart`` if the set's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot no longer holds a hash map or set, or an error of the
    ///   storage or of a damaged file.
    public func put(_ hash: [UInt8], _ data: WritableData) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.hashMapGet(.key, KeyHash(hash)), .ctx]
        _ = try cursor.writePath(
            path.span,
            typed: { (key: inout Cursor<ReadWrite>) throws(XitDBError) in
                try key.writeIfEmpty(data)
            })
    }

    /// A cursor at the key stored under a hash, for writing it. The set
    /// gets an entry for the hash if it has none.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/expectedTxStart`` if the set's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot no longer holds a hash map or set, or an error of the
    ///   storage or of a damaged file.
    public func putCursor(_ hash: Span<UInt8>) throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, KeyHash(hash))]
        return try cursor.writePath(path.span)
    }

    /// A cursor at the key stored under a hash, for writing it. The set
    /// gets an entry for the hash if it has none.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/expectedTxStart`` if the set's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot no longer holds a hash map or set, or an error of the
    ///   storage or of a damaged file.
    public func putCursor(_ hash: [UInt8]) throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, KeyHash(hash))]
        return try cursor.writePath(path.span)
    }

    /// Removes the entry stored under a hash.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Returns: Whether there was an entry to remove.
    /// - Throws: ``XitDBError/expectedTxStart`` if the set's cursor is not
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
    /// - Throws: ``XitDBError/expectedTxStart`` if the set's cursor is not
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

extension CountedHashSet {
    /// A view of the set at a cursor's slot, which the caller has made
    /// sure holds one.
    init(unchecked cursor: Cursor<Access>) {
        self.cursor = cursor
    }
}
