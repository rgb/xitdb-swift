/// A hash set in a database.
///
/// A set holds keys, each under its hash. **The set hashes nothing
/// itself.** The caller hashes each key, with any function whose result
/// has as many bytes as the database's hash size, and gives the hash with
/// the key. Two keys with the same hash are the same key to the set.
///
/// A set is a view of a slot. Making one that can only read checks that
/// the slot holds a set of this kind, or nothing. Making one that can
/// write makes the slot a set if it holds nothing, and readies it for
/// this transaction's writes.
///
/// Writing needs a transaction: see ``Database/withTransaction(_:)``. A set at
/// the root of the database is the exception: there, every write is a
/// transaction of its own.
public struct HashSet<Access: CursorAccess> {
    /// The cursor at the slot that holds the set.
    public let cursor: Cursor<Access>

    /// The slot that holds the set.
    ///
    /// - Throws: Only for a set at the root of the database, if the root
    ///   cannot be read.
    public var slot: Slot {
        get throws(XitDBError) {
            try cursor.slot
        }
    }

    /// An iterator over the set's entries. Each cursor it gives is at an
    /// entry; ``Cursor/readEntry()`` reads the entry's key.
    ///
    /// The order is that of the hashes' last bits, which has nothing to do
    /// with the order of insertion.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   that is not a collection, or an error of the storage or of a
    ///   damaged file.
    public func iterator() throws(XitDBError) -> CollectionIterator {
        try cursor.iterator()
    }

    /// A cursor at the key stored under a hash, or `nil` if the set has no
    /// entry for it or the entry's key was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, once the slot holds a map or
    ///   set (a slot that holds nothing checks no hash and has no entry for
    ///   it, as in Zig), ``XitDBError/unexpectedTag`` if the slot holds
    ///   something other than a hash map or set, or an error of the storage
    ///   or of a damaged file.
    public func cursor(forHash hash: Span<UInt8>) throws(XitDBError) -> Cursor<ReadOnly>? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, KeyHash(hash))]
        return try cursor.readPath(path.span)
    }

    /// A cursor at the key stored under a hash, or `nil` if the set has no
    /// entry for it or the entry's key was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size, in any sequence of bytes: an array, a CryptoKit digest, a
    ///   slice, `Data`, a string's `utf8`. The `Span` overload takes bytes
    ///   already borrowed.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, once the slot holds a map or
    ///   set (a slot that holds nothing checks no hash and has no entry for
    ///   it, as in Zig), ``XitDBError/unexpectedTag`` if the slot holds
    ///   something other than a hash map or set, or an error of the storage
    ///   or of a damaged file.
    @inlinable
    public func cursor(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Cursor<ReadOnly>? {
        let bytes = Array(hash)
        return try cursor(forHash: bytes.span)
    }

    /// The slot of the key stored under a hash, or `nil` if the set has no
    /// entry for it or the entry's key was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, once the slot holds a map or
    ///   set (a slot that holds nothing checks no hash and has no entry for
    ///   it, as in Zig), ``XitDBError/unexpectedTag`` if the slot holds
    ///   something other than a hash map or set, or an error of the storage
    ///   or of a damaged file.
    public func slot(forHash hash: Span<UInt8>) throws(XitDBError) -> Slot? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, KeyHash(hash))]
        return try cursor.readPathSlot(path.span)
    }

    /// The slot of the key stored under a hash, or `nil` if the set has no
    /// entry for it or the entry's key was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size, in any sequence of bytes: an array, a CryptoKit digest, a
    ///   slice, `Data`, a string's `utf8`. The `Span` overload takes bytes
    ///   already borrowed.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, once the slot holds a map or
    ///   set (a slot that holds nothing checks no hash and has no entry for
    ///   it, as in Zig), ``XitDBError/unexpectedTag`` if the slot holds
    ///   something other than a hash map or set, or an error of the storage
    ///   or of a damaged file.
    @inlinable
    public func slot(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Slot? {
        let bytes = Array(hash)
        return try slot(forHash: bytes.span)
    }

    /// Whether a key is stored under a hash.
    ///
    /// An entry whose key was never written, from
    /// ``insertCursor(forHash:)-(Sequence<UInt8>)`` with nothing written through
    /// the cursor, does not count.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, once the slot holds a map or
    ///   set (a slot that holds nothing checks no hash and has no entry for
    ///   it, as in Zig), ``XitDBError/unexpectedTag`` if the slot holds
    ///   something other than a hash map or set, or an error of the storage
    ///   or of a damaged file.
    public func contains(hash: Span<UInt8>) throws(XitDBError) -> Bool {
        try slot(forHash: hash) != nil
    }

    /// Whether a key is stored under a hash.
    ///
    /// An entry whose key was never written, from
    /// ``insertCursor(forHash:)-(Sequence<UInt8>)`` with nothing written through
    /// the cursor, does not count.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size, in any sequence of bytes: an array, a CryptoKit digest, a
    ///   slice, `Data`, a string's `utf8`. The `Span` overload takes bytes
    ///   already borrowed.
    /// - Throws: ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, once the slot holds a map or
    ///   set (a slot that holds nothing checks no hash and has no entry for
    ///   it, as in Zig), ``XitDBError/unexpectedTag`` if the slot holds
    ///   something other than a hash map or set, or an error of the storage
    ///   or of a damaged file.
    @inlinable
    public func contains(hash: some Sequence<UInt8>) throws(XitDBError) -> Bool {
        let bytes = Array(hash)
        return try contains(hash: bytes.span)
    }

}

extension HashSet where Access == ReadOnly {
    /// A view of the set at a cursor's slot, for reading.
    ///
    /// A slot that holds nothing is an empty set.
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

    /// A view of the set at a cursor's slot, for reading, from a cursor of
    /// either access: one that can write is read through as its
    /// ``Cursor/readOnly``, so that a reader need not take it first.
    ///
    /// A slot that holds nothing is an empty set.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a hash map or set that keeps no count.
    public init(_ cursor: Cursor<some CursorAccess>) throws(XitDBError) {
        try self.init(Cursor<ReadOnly>(viewing: cursor))
    }
}

extension HashSet where Access == ReadWrite {
    /// A view of the set at a cursor's slot, for reading and writing.
    ///
    /// A slot that holds nothing becomes an empty set. A set from an
    /// earlier transaction is readied for this one: its first block is
    /// copied, so that writing to it leaves earlier moments as they were.
    ///
    /// **A hash map becomes a hash set.** A map and a set that keep no
    /// count are one kind to the slot, as in Zig: the slot's tag is written
    /// as a set and the entries stay, values included, though a set reads
    /// only their keys. On the root, where this is a transaction of its
    /// own, a map is a set from then on; a map is opened with ``HashMap``.
    ///
    /// On the root cursor this is a transaction of its own, unless the root
    /// is such a set already, in which case nothing is written.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a hash map or set that keeps no count,
    ///   ``XitDBError/expectedTxStart`` if no transaction is in progress
    ///   and `cursor` is not the root cursor,
    ///   ``XitDBError/nestedTopLevelWrite`` if `cursor` is the root cursor
    ///   and one is, or an error of the storage or of a damaged file.
    public init(_ cursor: Cursor<ReadWrite>) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.hashMapInit(counted: false, set: true)]
        self.cursor = try cursor.writePath(path.span)
    }

    /// A view of the same set that can only read.
    public var readOnly: HashSet<ReadOnly> {
        HashSet<ReadOnly>(unchecked: cursor.readOnly)
    }

    /// Adds a key to the set under its hash. If the set already has a key
    /// under that hash, nothing is changed.
    ///
    /// - Parameters:
    ///   - key: The key.
    ///   - hash: The key's hash, as many bytes as the database's hash size.
    /// - Throws: ``XitDBError/expectedTxStart`` if the set's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot no longer holds a hash map or set, or an error of the
    ///   storage or of a damaged file.
    public func insert(_ key: WritableData, forHash hash: Span<UInt8>) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.hashMapGet(.key, KeyHash(hash)), .ctx]
        _ = try cursor.writePath(
            path.span,
            typed: { (keyCursor: inout Cursor<ReadWrite>) throws(XitDBError) in
                try keyCursor.writeIfEmpty(key)
            })
    }

    /// Adds a key to the set under its hash. If the set already has a key
    /// under that hash, nothing is changed.
    ///
    /// - Parameters:
    ///   - key: The key.
    ///   - hash: The key's hash, as many bytes as the database's hash size,
    ///     in any sequence of bytes: an array, a CryptoKit digest, a slice,
    ///     `Data`, a string's `utf8`. The `Span` overload takes bytes already
    ///     borrowed.
    /// - Throws: ``XitDBError/expectedTxStart`` if the set's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot no longer holds a hash map or set, or an error of the
    ///   storage or of a damaged file.
    @inlinable
    public func insert(_ key: WritableData, forHash hash: some Sequence<UInt8>) throws(XitDBError) {
        let bytes = Array(hash)
        try insert(key, forHash: bytes.span)
    }

    /// A cursor at the key stored under a hash, for writing it. The set
    /// gets an entry for the hash if it has none.
    ///
    /// Use it in a transaction. On a collection at the root the call is a
    /// transaction of its own, committed by the time it returns, so a new
    /// entry holds nothing and a write through the cursor throws
    /// ``XitDBError/expectedTxStart``.
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
    public func insertCursor(forHash hash: Span<UInt8>) throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, KeyHash(hash))]
        return try cursor.writePath(path.span)
    }

    /// A cursor at the key stored under a hash, for writing it. The set
    /// gets an entry for the hash if it has none.
    ///
    /// Use it in a transaction. On a collection at the root the call is a
    /// transaction of its own, committed by the time it returns, so a new
    /// entry holds nothing and a write through the cursor throws
    /// ``XitDBError/expectedTxStart``.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size, in any sequence of bytes: an array, a CryptoKit digest, a
    ///   slice, `Data`, a string's `utf8`. The `Span` overload takes bytes
    ///   already borrowed.
    /// - Throws: ``XitDBError/expectedTxStart`` if the set's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot no longer holds a hash map or set, or an error of the
    ///   storage or of a damaged file.
    @inlinable
    public func insertCursor(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Cursor<ReadWrite> {
        let bytes = Array(hash)
        return try insertCursor(forHash: bytes.span)
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
    ///   size, in any sequence of bytes: an array, a CryptoKit digest, a
    ///   slice, `Data`, a string's `utf8`. The `Span` overload takes bytes
    ///   already borrowed.
    /// - Returns: Whether there was an entry to remove.
    /// - Throws: ``XitDBError/expectedTxStart`` if the set's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidHashSize`` if `hash` does not have as many
    ///   bytes as the database's hash size, ``XitDBError/unexpectedTag`` if
    ///   the slot no longer holds a hash map or set, or an error of the
    ///   storage or of a damaged file.
    @discardableResult
    @inlinable
    public func remove(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Bool {
        let bytes = Array(hash)
        return try remove(forHash: bytes.span)
    }

}

extension HashSet {
    /// A view of the set at a cursor's slot, which the caller has made
    /// sure holds one.
    init(unchecked cursor: Cursor<Access>) {
        self.cursor = cursor
    }
}
