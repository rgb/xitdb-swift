/// A map from byte strings to values in a database, kept in key order:
/// Zig's `SortedMap`.
///
/// Keys are bytes, compared as unsigned bytes from the first; a key that is
/// a prefix of another comes before it. The map gives its entries in that
/// order, from the start, from a key or from a position, and the position
/// of any key, whether or not it is there: what a secondary index needs to
/// sort and paginate.
///
/// Underneath is a tree whose leaves hold up to sixteen entries in key
/// order and whose branches carry a separator key and a count for each
/// child. A key of up to eight bytes without a zero byte is stored in its
/// entry's slot; a longer one is a byte record of its own.
///
/// A map is a view of a slot. Making one that can only read checks that
/// the slot holds a sorted map or set, or nothing. Making one that can
/// write makes the slot a sorted map if it holds nothing, and readies it
/// for this transaction's writes. A map and a set are one kind to the
/// tree: a view of the other kind reads the same entries, and writing
/// through it makes the slot its own kind.
///
/// Writing needs a transaction: see ``Database/withTransaction(_:)``. A map at
/// the root of the database is the exception: there, every write is a
/// transaction of its own.
public struct SortedMap<Access: CursorAccess> {
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
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   sorted map or set, or ``XitDBError/endOfStream`` if the header
    ///   cannot be read.
    public func count() throws(XitDBError) -> UInt64 {
        try cursor.count()
    }

    /// An iterator over the map's entries in key order. Each cursor it
    /// gives is at an entry; ``Cursor/readEntry()`` reads the
    /// entry's key and value.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   that is not a collection, or an error of the storage or of a
    ///   damaged file.
    public func iterator() throws(XitDBError) -> CollectionIterator {
        try cursor.iterator()
    }

    /// An iterator over the map's entries in key order, from one of them
    /// on.
    ///
    /// - Parameter index: The position of the first entry to give. A
    ///   negative index counts from the end. An index that names no entry
    ///   gives an iterator of nothing.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a sorted map or set, ``XitDBError/invalidBTreeNode`` if
    ///   the tree does not hold what its header or its branches say, or an
    ///   error of the storage or of a damaged file.
    public func iteratorFromIndex(_ index: Int64) throws(XitDBError) -> CollectionIterator {
        try cursor.iterator(fromSortedMapIndex: index)
    }

    /// An iterator over the map's entries in key order, from the first
    /// key that is not below `key` on, which need not be there. A key
    /// beyond every entry gives an iterator of nothing.
    ///
    /// - Parameter key: The key's bytes.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a sorted map or set, ``XitDBError/invalidBTreeNode`` if
    ///   the tree does not hold what its header or its branches say, or an
    ///   error of the storage or of a damaged file.
    public func iteratorFrom(_ key: Span<UInt8>) throws(XitDBError) -> CollectionIterator {
        try cursor.iterator(fromSortedMapKey: SortedKey(key))
    }

    /// An iterator over the map's entries in key order, from the first
    /// key that is not below `key` on, which need not be there. A key
    /// beyond every entry gives an iterator of nothing.
    ///
    /// - Parameter key: The key's bytes.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a sorted map or set, ``XitDBError/invalidBTreeNode`` if
    ///   the tree does not hold what its header or its branches say, or an
    ///   error of the storage or of a damaged file.
    public func iteratorFrom(_ key: [UInt8]) throws(XitDBError) -> CollectionIterator {
        try cursor.iterator(fromSortedMapKey: SortedKey(key))
    }

    /// The number of keys in the map that are below `key`, which need
    /// not be there: the position it has, or would have.
    ///
    /// - Parameter key: The key's bytes.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a sorted map or set, ``XitDBError/invalidBTreeNode`` if
    ///   the tree does not hold what its header or its branches say, or an
    ///   error of the storage or of a damaged file.
    public func rank(_ key: Span<UInt8>) throws(XitDBError) -> UInt64 {
        let slot = try cursor.resolved().slot
        if slot.tag == .none { return 0 }
        let header = try cursor.database.reader.sortedMapHeader(slot)
        let sortedKey = SortedKey(key)
        return try sortedKey.withBytes { (bytes: Span<UInt8>) throws(XitDBError) in
            try cursor.database.reader.sortedRank(rootPtr: header.rootPtr, key: bytes)
        }
    }

    /// The number of keys in the map that are below `key`, which need
    /// not be there: the position it has, or would have.
    ///
    /// - Parameter key: The key's bytes.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a sorted map or set, ``XitDBError/invalidBTreeNode`` if
    ///   the tree does not hold what its header or its branches say, or an
    ///   error of the storage or of a damaged file.
    public func rank(_ key: [UInt8]) throws(XitDBError) -> UInt64 {
        let slot = try cursor.resolved().slot
        if slot.tag == .none { return 0 }
        let header = try cursor.database.reader.sortedMapHeader(slot)
        let sortedKey = SortedKey(key)
        return try sortedKey.withBytes { (bytes: Span<UInt8>) throws(XitDBError) in
            try cursor.database.reader.sortedRank(rootPtr: header.rootPtr, key: bytes)
        }
    }

    /// The entry at a position, as a cursor for its key and one for its
    /// value, or `nil` if there is no entry at `index`.
    ///
    /// - Parameter index: The entry's position in key order. A negative
    ///   index counts from the end.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a sorted map or set, ``XitDBError/invalidBTreeNode`` if
    ///   the tree does not hold what its header or its branches say, or an
    ///   error of the storage or of a damaged file.
    public func getIndexKeyValuePair(_ index: Int64) throws(XitDBError) -> Entry? {
        let path: InlineArray<1, PathPart> = [.sortedMapGetIndex(index)]
        return try cursor.readPath(path.span)?.readEntry()
    }

    /// A cursor at the value stored under a key, or `nil` if the map has no
    /// entry for it or the entry's value was never written.
    ///
    /// - Parameter key: The key's bytes.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a sorted map or set, ``XitDBError/invalidBTreeNode`` if
    ///   the tree does not hold what its header or its branches say, or an
    ///   error of the storage or of a damaged file.
    public func getCursor(_ key: Span<UInt8>) throws(XitDBError) -> Cursor<ReadOnly>? {
        let path: InlineArray<1, PathPart> = [.sortedMapGet(.value, SortedKey(key))]
        return try cursor.readPath(path.span)
    }

    /// A cursor at the value stored under a key, or `nil` if the map has no
    /// entry for it or the entry's value was never written.
    ///
    /// - Parameter key: The key's bytes.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a sorted map or set, ``XitDBError/invalidBTreeNode`` if
    ///   the tree does not hold what its header or its branches say, or an
    ///   error of the storage or of a damaged file.
    public func getCursor(_ key: [UInt8]) throws(XitDBError) -> Cursor<ReadOnly>? {
        let path: InlineArray<1, PathPart> = [.sortedMapGet(.value, SortedKey(key))]
        return try cursor.readPath(path.span)
    }

    /// The slot of the value stored under a key, or `nil` if the map has no
    /// entry for it or the entry's value was never written.
    ///
    /// - Parameter key: The key's bytes.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a sorted map or set, ``XitDBError/invalidBTreeNode`` if
    ///   the tree does not hold what its header or its branches say, or an
    ///   error of the storage or of a damaged file.
    public func getSlot(_ key: Span<UInt8>) throws(XitDBError) -> Slot? {
        let path: InlineArray<1, PathPart> = [.sortedMapGet(.value, SortedKey(key))]
        return try cursor.readPathSlot(path.span)
    }

    /// The slot of the value stored under a key, or `nil` if the map has no
    /// entry for it or the entry's value was never written.
    ///
    /// - Parameter key: The key's bytes.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a sorted map or set, ``XitDBError/invalidBTreeNode`` if
    ///   the tree does not hold what its header or its branches say, or an
    ///   error of the storage or of a damaged file.
    public func getSlot(_ key: [UInt8]) throws(XitDBError) -> Slot? {
        let path: InlineArray<1, PathPart> = [.sortedMapGet(.value, SortedKey(key))]
        return try cursor.readPathSlot(path.span)
    }

    /// The entry stored under a key, as a cursor for its key and one for
    /// its value, or `nil` if the map has no entry for it.
    ///
    /// - Parameter key: The key's bytes.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a sorted map or set, ``XitDBError/invalidBTreeNode`` if
    ///   the tree does not hold what its header or its branches say, or an
    ///   error of the storage or of a damaged file.
    public func getKeyValuePair(_ key: Span<UInt8>) throws(XitDBError) -> Entry? {
        let path: InlineArray<1, PathPart> = [.sortedMapGet(.kvPair, SortedKey(key))]
        return try cursor.readPath(path.span)?.readEntry()
    }

    /// The entry stored under a key, as a cursor for its key and one for
    /// its value, or `nil` if the map has no entry for it.
    ///
    /// - Parameter key: The key's bytes.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a sorted map or set, ``XitDBError/invalidBTreeNode`` if
    ///   the tree does not hold what its header or its branches say, or an
    ///   error of the storage or of a damaged file.
    public func getKeyValuePair(_ key: [UInt8]) throws(XitDBError) -> Entry? {
        let path: InlineArray<1, PathPart> = [.sortedMapGet(.kvPair, SortedKey(key))]
        return try cursor.readPath(path.span)?.readEntry()
    }

}

extension SortedMap where Access == ReadOnly {
    /// A view of the map at a cursor's slot, for reading.
    ///
    /// A slot that holds nothing is an empty map.
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

    /// A view of the map at a cursor's slot, for reading, from a cursor of
    /// either access: one that can write is read through as its
    /// ``Cursor/readOnly``, so that a reader need not take it first.
    ///
    /// A slot that holds nothing is an empty map.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a sorted map or set.
    public init(_ cursor: Cursor<some CursorAccess>) throws(XitDBError) {
        try self.init(Cursor<ReadOnly>(slotPointer: cursor.slotPointer, database: cursor.database))
    }
}

extension SortedMap where Access == ReadWrite {
    /// A view of the map at a cursor's slot, for reading and writing.
    ///
    /// A slot that holds nothing becomes an empty sorted map. One from an
    /// earlier transaction is readied for this one: its header is copied,
    /// so that writing to it leaves earlier moments as they were; its nodes
    /// are copied as they are written to. A sorted set becomes a
    /// sorted map.
    ///
    /// On the root cursor this is a transaction of its own, unless the root
    /// is a sorted map already, in which case nothing is written.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a sorted map or set, ``XitDBError/expectedTxStart`` if
    ///   no transaction is in progress and `cursor` is not the root cursor,
    ///   or an error of the storage or of a damaged file.
    public init(_ cursor: Cursor<ReadWrite>) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.sortedMapInit(set: false)]
        self.cursor = try cursor.writePath(path.span)
    }

    /// A view of the same map that can only read.
    public var readOnly: SortedMap<ReadOnly> {
        SortedMap<ReadOnly>(unchecked: cursor.readOnly)
    }

    /// Stores a value under a key, in place of any value that was there.
    ///
    /// - Parameters:
    ///   - key: The key's bytes.
    ///   - data: The value.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   sorted map or set, ``XitDBError/invalidBTreeNode`` if the tree does
    ///   not hold what its header or its branches say, or an error of the
    ///   storage or of a damaged file.
    public func put(_ key: Span<UInt8>, _ data: WritableData) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.sortedMapGet(.value, SortedKey(key)), .write(data)]
        _ = try cursor.writePath(path.span)
    }

    /// Stores a value under a key, in place of any value that was there.
    ///
    /// - Parameters:
    ///   - key: The key's bytes.
    ///   - data: The value.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   sorted map or set, ``XitDBError/invalidBTreeNode`` if the tree does
    ///   not hold what its header or its branches say, or an error of the
    ///   storage or of a damaged file.
    public func put(_ key: [UInt8], _ data: WritableData) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.sortedMapGet(.value, SortedKey(key)), .write(data)]
        _ = try cursor.writePath(path.span)
    }

    /// A cursor at the value stored under a key, for writing it or for
    /// making a collection there. The map gets an entry for the key if it
    /// has none.
    ///
    /// - Parameter key: The key's bytes.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   sorted map or set, ``XitDBError/invalidBTreeNode`` if the tree does
    ///   not hold what its header or its branches say, or an error of the
    ///   storage or of a damaged file.
    public func putCursor(_ key: Span<UInt8>) throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.sortedMapGet(.value, SortedKey(key))]
        return try cursor.writePath(path.span)
    }

    /// A cursor at the value stored under a key, for writing it or for
    /// making a collection there. The map gets an entry for the key if it
    /// has none.
    ///
    /// - Parameter key: The key's bytes.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   sorted map or set, ``XitDBError/invalidBTreeNode`` if the tree does
    ///   not hold what its header or its branches say, or an error of the
    ///   storage or of a damaged file.
    public func putCursor(_ key: [UInt8]) throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.sortedMapGet(.value, SortedKey(key))]
        return try cursor.writePath(path.span)
    }

    /// Removes the entry for a key. The place it had in its leaf stays
    /// empty; the tree is not rebalanced.
    ///
    /// - Parameter key: The key's bytes.
    /// - Returns: Whether there was an entry to remove.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   sorted map or set, ``XitDBError/invalidBTreeNode`` if the tree does
    ///   not hold what its header or its branches say, or an error of the
    ///   storage or of a damaged file.
    @discardableResult
    public func remove(_ key: Span<UInt8>) throws(XitDBError) -> Bool {
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
    /// - Parameter key: The key's bytes.
    /// - Returns: Whether there was an entry to remove.
    /// - Throws: ``XitDBError/expectedTxStart`` if the map's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   sorted map or set, ``XitDBError/invalidBTreeNode`` if the tree does
    ///   not hold what its header or its branches say, or an error of the
    ///   storage or of a damaged file.
    @discardableResult
    public func remove(_ key: [UInt8]) throws(XitDBError) -> Bool {
        let path: InlineArray<1, PathPart> = [.sortedMapRemove(SortedKey(key))]
        do throws(XitDBError) {
            _ = try cursor.writePath(path.span)
        } catch {
            guard error == .keyNotFound else { throw error }
            return false
        }
        return true
    }

}

extension SortedMap {
    /// A view of the map at a cursor's slot, which the caller has made
    /// sure holds one.
    init(unchecked cursor: Cursor<Access>) {
        self.cursor = cursor
    }
}
