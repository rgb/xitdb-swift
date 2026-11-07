/// A list in a database that can be changed anywhere, not only at its end:
/// Zig's `LinkedArrayList`.
///
/// Elements are addressed by position, as in an ``ArrayList``, and can also
/// be inserted and removed at any position. Two lists are joined with
/// ``concat(_:)`` and a part of one kept with ``slice(offset:size:)``, each
/// in time that grows with the logarithm of the size, because the result
/// shares what it can with the lists it came from. A negative index counts
/// from the end: `-1` is the last element.
///
/// Underneath is a tree whose nodes hold up to sixteen elements or children
/// and whose branches count the elements beneath each child.
///
/// A list is a view of a slot. Making one that can only read checks that
/// the slot holds a linked array list, or nothing. Making one that can write
/// makes the slot a list if it holds nothing, and readies it for this
/// transaction's writes.
///
/// Writing needs a transaction: see ``Database/withTransaction(_:)``. A list at
/// the root of the database is the exception: there, every write is a
/// transaction of its own.
///
/// **A concat freezes the transaction.** The joined tree shares nodes with
/// both lists, so after a concat every write in the transaction copies what
/// was written before it, as after ``Database/freeze()``. Collections made
/// before the concat should be made again from their cursors afterwards.
public struct LinkedArrayList<Access: CursorAccess> {
    /// The cursor at the slot that holds the list.
    public let cursor: Cursor<Access>

    /// The slot that holds the list.
    ///
    /// - Throws: Only for a list at the root of the database, if the root
    ///   cannot be read.
    public func slot() throws(XitDBError) -> Slot {
        try cursor.slot()
    }

    /// The number of elements in the list.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   list, or ``XitDBError/endOfStream`` if the list's header cannot be
    ///   read.
    public func count() throws(XitDBError) -> UInt64 {
        try cursor.count()
    }

    /// An iterator over the list's elements, in order.
    ///
    /// An element that was appended and never written is given as a cursor
    /// at a slot set to nothing.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   that is not a collection, or an error of the storage or of a
    ///   damaged file.
    public func iterator() throws(XitDBError) -> CollectionIterator {
        try cursor.iterator()
    }

    /// An iterator over the list's elements from one of them on, in order.
    ///
    /// - Parameter index: The index of the first element to give. A negative
    ///   index counts from the end. An index that names no element gives an
    ///   iterator of nothing.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a list, or an error of the storage or of a damaged file.
    public func iteratorFrom(_ index: Int64) throws(XitDBError) -> CollectionIterator {
        try cursor.iterator(fromLinkedArrayListIndex: index)
    }

    /// A cursor at an element, or `nil` if there is no element at `index`
    /// or it was never written.
    ///
    /// - Parameter index: The element's index. A negative index counts from
    ///   the end.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a list, ``XitDBError/invalidBTreeNode`` if the list's
    ///   tree does not hold what its header says, or an error of the
    ///   storage or of a damaged file.
    public func getCursor(_ index: Int64) throws(XitDBError) -> Cursor<ReadOnly>? {
        let path: InlineArray<1, PathPart> = [.linkedArrayListGet(index)]
        return try cursor.readPath(path.span)
    }

    /// The slot of an element, or `nil` if there is no element at `index`
    /// or it was never written.
    ///
    /// - Parameter index: The element's index. A negative index counts from
    ///   the end.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a list, ``XitDBError/invalidBTreeNode`` if the list's
    ///   tree does not hold what its header says, or an error of the
    ///   storage or of a damaged file.
    public func getSlot(_ index: Int64) throws(XitDBError) -> Slot? {
        let path: InlineArray<1, PathPart> = [.linkedArrayListGet(index)]
        return try cursor.readPathSlot(path.span)
    }
}

extension LinkedArrayList where Access == ReadOnly {
    /// A view of the list at a cursor's slot, for reading.
    ///
    /// A slot that holds nothing is an empty list.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a linked array list.
    public init(_ cursor: Cursor<ReadOnly>) throws(XitDBError) {
        switch try cursor.resolved().slot.tag {
        case .none, .linkedArrayList:
            self.cursor = cursor
        default:
            throw .unexpectedTag
        }
    }
}

extension LinkedArrayList where Access == ReadWrite {
    /// A view of the list at a cursor's slot, for reading and writing.
    ///
    /// A slot that holds nothing becomes an empty list. A list from an
    /// earlier transaction is readied for this one: its header is copied,
    /// so that writing to it leaves earlier moments as they were. Its nodes
    /// are copied as they are written to.
    ///
    /// On the root cursor this is a transaction of its own, unless the root
    /// is a linked array list already, in which case nothing is written.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a linked array list, ``XitDBError/expectedTxStart`` if
    ///   no transaction is in progress and `cursor` is not the root cursor,
    ///   or an error of the storage or of a damaged file.
    public init(_ cursor: Cursor<ReadWrite>) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.linkedArrayListInit]
        self.cursor = try cursor.writePath(path.span)
    }

    /// A view of the same list that can only read.
    public var readOnly: LinkedArrayList<ReadOnly> {
        LinkedArrayList<ReadOnly>(unchecked: cursor.readOnly)
    }

    /// Writes an element.
    ///
    /// - Parameters:
    ///   - index: The element's index. A negative index counts from the end.
    ///   - data: The value.
    /// - Throws: ``XitDBError/keyNotFound`` if there is no element at
    ///   `index`, ``XitDBError/expectedTxStart`` if the list's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   list, ``XitDBError/invalidBTreeNode`` if the list's tree does not
    ///   hold what its header says, or an error of the storage or of a
    ///   damaged file.
    public func put(_ index: Int64, _ data: WritableData) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.linkedArrayListGet(index), .write(data)]
        _ = try cursor.writePath(path.span)
    }

    /// A cursor at an element, for writing it or for making a collection
    /// there.
    ///
    /// - Parameter index: The element's index. A negative index counts from
    ///   the end.
    /// - Throws: ``XitDBError/keyNotFound`` if there is no element at
    ///   `index`, ``XitDBError/expectedTxStart`` if the list's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   list, ``XitDBError/invalidBTreeNode`` if the list's tree does not
    ///   hold what its header says, or an error of the storage or of a
    ///   damaged file.
    public func putCursor(_ index: Int64) throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.linkedArrayListGet(index)]
        return try cursor.writePath(path.span)
    }

    /// Appends an element.
    ///
    /// - Parameter data: The value.
    /// - Throws: ``XitDBError/expectedTxStart`` if the list's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   list, ``XitDBError/invalidBTreeNode`` if the list's tree does not
    ///   hold what its header says, or an error of the storage or of a
    ///   damaged file.
    public func append(_ data: WritableData) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.linkedArrayListAppend, .write(data)]
        _ = try cursor.writePath(path.span)
    }

    /// Appends an element and gives a cursor at it, for writing it or for
    /// making a collection there. An element that is never written stays
    /// in the list as a slot set to nothing.
    ///
    /// - Throws: ``XitDBError/expectedTxStart`` if the list's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   list, ``XitDBError/invalidBTreeNode`` if the list's tree does not
    ///   hold what its header says, or an error of the storage or of a
    ///   damaged file.
    public func appendCursor() throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.linkedArrayListAppend]
        return try cursor.writePath(path.span)
    }

    /// Appends an element, writes it, and runs `body` with a cursor at it.
    ///
    /// If `body` throws, the error is rethrown; what was appended is
    /// discarded only if this call started the transaction.
    ///
    /// - Parameters:
    ///   - data: The value to write before `body` runs.
    ///   - body: Given a cursor at the new element.
    /// - Throws: What `body` throws, or ``XitDBError/expectedTxStart`` if
    ///   the list's cursor is not the root cursor and no transaction is in
    ///   progress, ``XitDBError/nestedTopLevelWrite`` if it is the root
    ///   cursor and one is, ``XitDBError/unexpectedTag`` if the slot no
    ///   longer holds a list, ``XitDBError/invalidBTreeNode`` if the list's
    ///   tree does not hold what its header says, or an error of the
    ///   storage or of a damaged file.
    public func appendContext(_ data: WritableData, _ body: (inout Cursor<ReadWrite>) throws -> Void) throws {
        let path: InlineArray<3, PathPart> = [.linkedArrayListAppend, .write(data), .ctx]
        _ = try cursor.writePath(path.span, body)
    }

    /// Keeps `size` elements of the list from `offset` on, and drops the
    /// rest. The elements kept share their nodes with the list as it was.
    ///
    /// - Parameters:
    ///   - offset: The index of the first element to keep.
    ///   - size: The number of elements to keep.
    /// - Throws: ``XitDBError/keyNotFound`` if the offset is beyond the
    ///   list or fewer than `size` elements follow it,
    ///   ``XitDBError/expectedTxStart`` if the list's cursor is not the root
    ///   cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   list, ``XitDBError/invalidBTreeNode`` if the list's tree does not
    ///   hold what its header says, or an error of the storage or of a
    ///   damaged file.
    public func slice(offset: UInt64, size: UInt64) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.linkedArrayListSlice(offset: offset, size: size)]
        _ = try cursor.writePath(path.span)
    }

    /// Appends every element of another linked array list to this one. The
    /// other list is unchanged, and the result shares nodes with both.
    ///
    /// This freezes the transaction: every write after it copies what was
    /// written before it, as after ``Database/freeze()``. Collections made
    /// before the concat, this one included, should be made again from
    /// their cursors.
    ///
    /// - Parameter list: The slot of the other list, from its ``slot()``.
    /// - Throws: ``XitDBError/unexpectedTag`` if `list` is not the slot of
    ///   a linked array list or this slot no longer holds one,
    ///   ``XitDBError/expectedTxStart`` if the list's cursor is not the root
    ///   cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/invalidBTreeNode`` if either tree does not hold
    ///   what its header says, or an error of the storage or of a damaged
    ///   file.
    public func concat(_ list: Slot) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.linkedArrayListConcat(list)]
        _ = try cursor.writePath(path.span)
    }

    /// Inserts an element before the one at `index`.
    ///
    /// - Parameters:
    ///   - index: The index of the element to insert before, which must
    ///     name an element: to add at the end, use ``append(_:)``. A
    ///     negative index counts from the end.
    ///   - data: The value.
    /// - Throws: ``XitDBError/keyNotFound`` if there is no element at
    ///   `index`, ``XitDBError/expectedTxStart`` if the list's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   list, ``XitDBError/invalidBTreeNode`` if the list's tree does not
    ///   hold what its header says, or an error of the storage or of a
    ///   damaged file.
    public func insert(_ index: Int64, _ data: WritableData) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.linkedArrayListInsert(index), .write(data)]
        _ = try cursor.writePath(path.span)
    }

    /// Inserts an element before the one at `index` and gives a cursor at
    /// it, for writing it or for making a collection there. An element
    /// that is never written stays in the list as a slot set to nothing.
    ///
    /// - Parameter index: The index of the element to insert before, which
    ///   must name an element. A negative index counts from the end.
    /// - Throws: ``XitDBError/keyNotFound`` if there is no element at
    ///   `index`, ``XitDBError/expectedTxStart`` if the list's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   list, ``XitDBError/invalidBTreeNode`` if the list's tree does not
    ///   hold what its header says, or an error of the storage or of a
    ///   damaged file.
    public func insertCursor(_ index: Int64) throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.linkedArrayListInsert(index)]
        return try cursor.writePath(path.span)
    }

    /// Removes the element at `index`.
    ///
    /// - Parameter index: The element's index. A negative index counts from
    ///   the end.
    /// - Throws: ``XitDBError/keyNotFound`` if there is no element at
    ///   `index`, ``XitDBError/expectedTxStart`` if the list's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   list, ``XitDBError/invalidBTreeNode`` if the list's tree does not
    ///   hold what its header says, or an error of the storage or of a
    ///   damaged file.
    public func remove(_ index: Int64) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.linkedArrayListRemove(index)]
        _ = try cursor.writePath(path.span)
    }
}

extension LinkedArrayList {
    /// A view of the list at a cursor's slot, which the caller has made sure
    /// holds one.
    init(unchecked cursor: Cursor<Access>) {
        self.cursor = cursor
    }
}
