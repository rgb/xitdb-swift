/// A set of byte strings in a database, kept in order.
///
/// Keys are bytes, compared as unsigned bytes from the first; a key that is
/// a prefix of another comes before it. Each key is stored once. The set
/// gives its keys in that order, from the start, from a key or from a
/// position, and the position of any key, whether or not it is there.
///
/// Underneath is a tree whose leaves hold up to sixteen entries in key
/// order and whose branches carry a separator key and a count for each
/// child. A key of up to eight bytes without a zero byte is stored in its
/// entry's slot; a longer one is a byte record of its own.
///
/// A set is a view of a slot. Making one that can only read checks that
/// the slot holds a sorted map or set, or nothing. Making one that can
/// write makes the slot a sorted set if it holds nothing, and readies it
/// for this transaction's writes. A map and a set are one kind to the
/// tree: a view of the other kind reads the same entries, and writing
/// through it makes the slot its own kind.
///
/// Writing needs a transaction: see ``Database/withTransaction(_:)``. A set at
/// the root of the database is the exception: there, every write is a
/// transaction of its own.
public struct SortedSet<Access: CursorAccess> {
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

    /// The number of entries in the set.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   sorted map or set, ``XitDBError/endOfStream`` if the header cannot be
    ///   read, or ``XitDBError/staleCursor`` if the set is not at the root and
    ///   its cursor is from a transaction that did not commit.
    public var count: UInt64 {
        get throws(XitDBError) {
            try cursor.count
        }
    }

    /// An iterator over the set's entries in key order. Each cursor it
    /// gives is at an entry; ``Cursor/readEntry()`` reads the
    /// entry's key.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something that
    ///   is not a collection, ``XitDBError/staleCursor`` if the set is not at
    ///   the root and its cursor is from a transaction that did not commit, or
    ///   an error of the storage or of a damaged file.
    public func iterator() throws(XitDBError) -> CollectionIterator {
        try cursor.iterator()
    }

    /// An iterator over the set's entries in key order, from one of them
    /// on.
    ///
    /// - Parameter index: The position of the first entry to give. A
    ///   negative index counts from the end: `-1` is the last entry. An
    ///   index that names no entry gives an iterator of nothing.
    /// - Throws: ``XitDBError/indexOutOfRange`` if `index` does not fit in an
    ///   `Int64`, ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a sorted map or set, ``XitDBError/invalidBTreeNode`` if the
    ///   tree does not hold what its header or its branches say,
    ///   ``XitDBError/staleCursor`` if the set is not at the root and its
    ///   cursor is from a transaction that did not commit, or an error of the
    ///   storage or of a damaged file.
    public func iterator(fromIndex index: some BinaryInteger) throws(XitDBError) -> CollectionIterator {
        let index = try listIndex(index)
        return try cursor.iterator(fromSortedMapIndex: index)
    }

    /// An iterator over the set's entries in key order, from the first
    /// key that is not below `key` on, which need not be there. A key
    /// beyond every entry gives an iterator of nothing.
    ///
    /// - Parameter key: The key's bytes.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something other
    ///   than a sorted map or set, ``XitDBError/invalidBTreeNode`` if the tree
    ///   does not hold what its header or its branches say,
    ///   ``XitDBError/staleCursor`` if the set is not at the root and its
    ///   cursor is from a transaction that did not commit, or an error of the
    ///   storage or of a damaged file.
    public func iterator(fromKey key: Span<UInt8>) throws(XitDBError) -> CollectionIterator {
        try cursor.iterator(fromSortedMapKey: SortedKey(key))
    }

    /// An iterator over the set's entries in key order, from the first
    /// key that is not below `key` on, which need not be there. A key
    /// beyond every entry gives an iterator of nothing.
    ///
    /// - Parameter key: The key's bytes, in any sequence of bytes: an array, a
    ///   slice, `Data`, a string's `utf8`. Anything but an array is copied
    ///   once; the `Span` overload takes bytes already borrowed.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something other
    ///   than a sorted map or set, ``XitDBError/invalidBTreeNode`` if the tree
    ///   does not hold what its header or its branches say,
    ///   ``XitDBError/staleCursor`` if the set is not at the root and its
    ///   cursor is from a transaction that did not commit, or an error of the
    ///   storage or of a damaged file.
    @inlinable
    public func iterator(fromKey key: some Sequence<UInt8>) throws(XitDBError) -> CollectionIterator {
        let bytes = Array(key)
        return try iterator(fromKey: bytes.span)
    }

    /// The number of keys in the set that are below `key`, which need
    /// not be there: the position it has, or would have.
    ///
    /// - Parameter key: The key's bytes.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something other
    ///   than a sorted map or set, ``XitDBError/invalidBTreeNode`` if the tree
    ///   does not hold what its header or its branches say,
    ///   ``XitDBError/staleCursor`` if the set is not at the root and its
    ///   cursor is from a transaction that did not commit, or an error of the
    ///   storage or of a damaged file.
    public func rank(of key: Span<UInt8>) throws(XitDBError) -> UInt64 {
        try cursor.checkReadable()
        let slot = try cursor.resolved().slot
        if slot.tag == .none { return 0 }
        let header = try cursor.engine.reader.sortedMapHeader(slot)
        let sortedKey = SortedKey(key)
        return try sortedKey.withBytes { (bytes: Span<UInt8>) throws(XitDBError) in
            try cursor.engine.reader.sortedRank(rootPtr: header.rootPtr, key: bytes)
        }
    }

    /// The number of keys in the set that are below `key`, which need
    /// not be there: the position it has, or would have.
    ///
    /// - Parameter key: The key's bytes, in any sequence of bytes: an array, a
    ///   slice, `Data`, a string's `utf8`. Anything but an array is copied
    ///   once; the `Span` overload takes bytes already borrowed.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something other
    ///   than a sorted map or set, ``XitDBError/invalidBTreeNode`` if the tree
    ///   does not hold what its header or its branches say,
    ///   ``XitDBError/staleCursor`` if the set is not at the root and its
    ///   cursor is from a transaction that did not commit, or an error of the
    ///   storage or of a damaged file.
    @inlinable
    public func rank(of key: some Sequence<UInt8>) throws(XitDBError) -> UInt64 {
        let bytes = Array(key)
        return try rank(of: bytes.span)
    }

    /// The entry at a position, as a cursor for its key and one for its
    /// value, or `nil` if there is no entry at `index`.
    ///
    /// - Parameter index: The entry's position in key order. A negative
    ///   index counts from the end: `-1` is the last entry.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something other
    ///   than a sorted map or set, ``XitDBError/invalidBTreeNode`` if the tree
    ///   does not hold what its header or its branches say,
    ///   ``XitDBError/staleCursor`` if the set is not at the root and its
    ///   cursor is from a transaction that did not commit, or an error of the
    ///   storage or of a damaged file.
    public func entry(at index: some BinaryInteger) throws(XitDBError) -> Entry? {
        guard let index = Int64(exactly: index) else { return nil }
        let path: InlineArray<1, PathPart> = [.sortedMapGetIndex(index)]
        return try cursor.readPath(path.span)?.readEntry()
    }

    /// Whether `key` is in the set.
    ///
    /// - Parameter key: The key's bytes.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something other
    ///   than a sorted map or set, ``XitDBError/invalidBTreeNode`` if the tree
    ///   does not hold what its header or its branches say,
    ///   ``XitDBError/staleCursor`` if the set is not at the root and its
    ///   cursor is from a transaction that did not commit, or an error of the
    ///   storage or of a damaged file.
    public func contains(_ key: Span<UInt8>) throws(XitDBError) -> Bool {
        let path: InlineArray<1, PathPart> = [.sortedMapGet(.key, SortedKey(key))]
        return try cursor.readPath(path.span) != nil
    }

    /// Whether `key` is in the set.
    ///
    /// - Parameter key: The key's bytes, in any sequence of bytes: an array, a
    ///   slice, `Data`, a string's `utf8`. Anything but an array is copied
    ///   once; the `Span` overload takes bytes already borrowed.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something other
    ///   than a sorted map or set, ``XitDBError/invalidBTreeNode`` if the tree
    ///   does not hold what its header or its branches say,
    ///   ``XitDBError/staleCursor`` if the set is not at the root and its
    ///   cursor is from a transaction that did not commit, or an error of the
    ///   storage or of a damaged file.
    @inlinable
    public func contains(_ key: some Sequence<UInt8>) throws(XitDBError) -> Bool {
        let bytes = Array(key)
        return try contains(bytes.span)
    }

}

extension SortedSet where Access == ReadOnly {
    /// A view of the set at a cursor's slot, for reading.
    ///
    /// A slot that holds nothing is an empty set.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a sorted map or set.
    public init(_ cursor: Cursor<ReadOnly>) throws(XitDBError) {
        switch try cursor.resolved().slot.tag {
        case .none, .sortedMap, .sortedSet:
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
    ///   other than a sorted map or set.
    public init(_ cursor: Cursor<some CursorAccess>) throws(XitDBError) {
        try self.init(Cursor<ReadOnly>(viewing: cursor))
    }
}

extension SortedSet where Access == ReadWrite {
    /// A view of the set at a cursor's slot, for reading and writing.
    ///
    /// A slot that holds nothing becomes an empty sorted set. One from an
    /// earlier transaction is readied for this one: its header is copied,
    /// so that writing to it leaves earlier moments as they were; its nodes
    /// are copied as they are written to.
    ///
    /// **A sorted map becomes a sorted set.** A sorted map and a sorted
    /// set are one kind to the slot, as in the original: the slot's tag is
    /// written as a set and the entries stay, values included, though a set
    /// reads only their keys. On the root, where this is a transaction of
    /// its own, a map is a set from then on; a map is opened with
    /// `SortedMap`.
    ///
    /// On the root cursor this is a transaction of its own, unless the root
    /// is a sorted set already, in which case nothing is written.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something other
    ///   than a sorted map or set, ``XitDBError/expectedTxStart`` if no
    ///   transaction is in progress and `cursor` is not the root cursor,
    ///   ``XitDBError/nestedTopLevelWrite`` if `cursor` is the root cursor and
    ///   one is, ``XitDBError/cursorNotWritable`` if `cursor` has no position,
    ///   as the key cursor of a sorted map's entry has not,
    ///   ``XitDBError/staleCursor`` if `cursor` is from an earlier transaction,
    ///   or from before the last freeze or join of this one unless it is at
    ///   the slot of the transaction's cursor,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, or an error of the storage or of a
    ///   damaged file.
    public init(_ cursor: Cursor<ReadWrite>) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.sortedMapInit(set: true)]
        self.cursor = try cursor.writePath(path.span)
    }

    /// A view of the same set that can only read.
    public var readOnly: SortedSet<ReadOnly> {
        SortedSet<ReadOnly>(unchecked: cursor.readOnly)
    }

    /// Adds `key` to the set. A key that is there already is left as it
    /// is.
    ///
    /// - Parameter key: The key's bytes.
    /// - Throws: ``XitDBError/expectedTxStart`` if the set's cursor is not the
    ///   root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/unexpectedTag`` if the
    ///   slot no longer holds a sorted map or set,
    ///   ``XitDBError/invalidBTreeNode`` if the tree does not hold what its
    ///   header or its branches say, or an error of the storage or of a damaged
    ///   file.
    public func insert(_ key: Span<UInt8>) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.sortedMapGet(.key, SortedKey(key))]
        _ = try cursor.writePath(path.span)
    }

    /// Adds `key` to the set. A key that is there already is left as it
    /// is.
    ///
    /// - Parameter key: The key's bytes, in any sequence of bytes: an array, a
    ///   slice, `Data`, a string's `utf8`. Anything but an array is copied
    ///   once; the `Span` overload takes bytes already borrowed.
    /// - Throws: ``XitDBError/expectedTxStart`` if the set's cursor is not the
    ///   root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/unexpectedTag`` if the
    ///   slot no longer holds a sorted map or set,
    ///   ``XitDBError/invalidBTreeNode`` if the tree does not hold what its
    ///   header or its branches say, or an error of the storage or of a damaged
    ///   file.
    @inlinable
    public func insert(_ key: some Sequence<UInt8>) throws(XitDBError) {
        let bytes = Array(key)
        try insert(bytes.span)
    }

    /// Removes the entry for a key. The place it had in its leaf stays
    /// empty; the tree is not rebalanced.
    ///
    /// - Parameter key: The key's bytes.
    /// - Returns: Whether there was an entry to remove.
    /// - Throws: ``XitDBError/expectedTxStart`` if the set's cursor is not the
    ///   root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/unexpectedTag`` if the
    ///   slot no longer holds a sorted map or set,
    ///   ``XitDBError/invalidBTreeNode`` if the tree does not hold what its
    ///   header or its branches say, or an error of the storage or of a damaged
    ///   file.
    @discardableResult
    public func remove(forKey key: Span<UInt8>) throws(XitDBError) -> Bool {
        let path: InlineArray<1, PathPart> = [.sortedMapRemove(SortedKey(key))]
        do throws(XitDBError) {
            _ = try cursor.writePath(path.span)
        } catch {
            guard error == .keyNotFound else { throw error }
            return false
        }
        return true
    }

    /// Removes the entry for a key. The place it had in its leaf stays
    /// empty; the tree is not rebalanced.
    ///
    /// - Parameter key: The key's bytes, in any sequence of bytes: an array, a
    ///   slice, `Data`, a string's `utf8`. Anything but an array is copied
    ///   once; the `Span` overload takes bytes already borrowed.
    /// - Returns: Whether there was an entry to remove.
    /// - Throws: ``XitDBError/expectedTxStart`` if the set's cursor is not the
    ///   root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/unexpectedTag`` if the
    ///   slot no longer holds a sorted map or set,
    ///   ``XitDBError/invalidBTreeNode`` if the tree does not hold what its
    ///   header or its branches say, or an error of the storage or of a damaged
    ///   file.
    @discardableResult
    @inlinable
    public func remove(forKey key: some Sequence<UInt8>) throws(XitDBError) -> Bool {
        let bytes = Array(key)
        return try remove(forKey: bytes.span)
    }

}

extension SortedSet {
    /// A view of the set at a cursor's slot, which the caller has made
    /// sure holds one.
    init(unchecked cursor: Cursor<Access>) {
        self.cursor = cursor
    }
}
