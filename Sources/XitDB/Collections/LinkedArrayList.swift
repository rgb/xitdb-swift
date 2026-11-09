/// A list in a database that can be changed anywhere, not only at its end.
///
/// Elements are addressed by position, as in an ``ArrayList``, and can also
/// be inserted and removed at any position. Two lists are joined with
/// ``append(contentsOf:)-(Slot)`` in time that grows with the logarithm of
/// the size, and a part of one kept with ``formSlice(offset:count:)`` at a
/// cost that grows little faster, because the result shares what it can
/// with the lists it came from. A negative index counts from the end: `-1`
/// is the last element.
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
/// **Appending another list freezes the transaction.** The joined tree shares
/// nodes with both lists, so after ``append(contentsOf:)-(Slot)`` every write
/// in the transaction copies what was written before it, as after
/// ``Database/freeze()``, with the same part for the caller: every collection
/// or cursor made before the call is stale, the list that made it included,
/// refused with ``XitDBError/staleCursor`` at its next write. The way on is a
/// new list from the transaction's cursor, the one
/// ``Database/withTransaction(_:)`` or a history append hands its body, through
/// which an init is allowed after a freeze. The article on cloning, freeze and
/// stale handles says why.
public struct LinkedArrayList<Access: CursorAccess> {
    /// The cursor the list is a view of.
    public let cursor: Cursor<Access>

    /// The slot that holds the list.
    ///
    /// - Throws: Only for a list at the root of the database, if the root
    ///   cannot be read.
    public var slot: Slot {
        get throws(XitDBError) {
            try cursor.slot
        }
    }

    /// The number of elements in the list.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   list, ``XitDBError/endOfStream`` if the list's header cannot be read,
    ///   or ``XitDBError/staleCursor`` if the list is not at the root and its
    ///   cursor is from a transaction that did not commit.
    public var count: UInt64 {
        get throws(XitDBError) {
            try cursor.count
        }
    }

    /// An iterator over the list's elements, in order.
    ///
    /// An element that was appended and never written is given as a cursor
    /// at a slot set to nothing.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something that
    ///   is not a collection, ``XitDBError/staleCursor`` if the list is not at
    ///   the root and its cursor is from a transaction that did not commit, or
    ///   an error of the storage or of a damaged file.
    public func iterator() throws(XitDBError) -> CollectionIterator {
        try cursor.iterator()
    }

    /// An iterator over the list's elements from one of them on, in order.
    ///
    /// - Parameter index: The index of the first element to give. A negative
    ///   index counts from the end: `-1` is the last element. An index that
    ///   names no element gives an iterator of nothing.
    /// - Throws: ``XitDBError/indexOutOfRange`` if `index` does not fit in an
    ///   `Int64`, ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a list, ``XitDBError/staleCursor`` if the list is not at
    ///   the root and its cursor is from a transaction that did not commit, or
    ///   an error of the storage or of a damaged file.
    public func iterator(fromIndex index: some BinaryInteger) throws(XitDBError) -> CollectionIterator {
        let index = try listIndex(index)
        return try cursor.iterator(fromLinkedArrayListIndex: index)
    }

    /// A cursor at an element, or `nil` if there is no element at `index`.
    /// An element that was never written is a slot set to nothing.
    ///
    /// - Parameter index: The element's index. A negative index counts from
    ///   the end: `-1` is the last element.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something other
    ///   than a list, ``XitDBError/invalidBTreeNode`` if the list's tree does
    ///   not hold what its header says, ``XitDBError/staleCursor`` if the list
    ///   is not at the root and its cursor is from a transaction that did not
    ///   commit, or an error of the storage or of a damaged file.
    public func cursor(at index: some BinaryInteger) throws(XitDBError) -> Cursor<ReadOnly>? {
        guard let index = Int64(exactly: index) else { return nil }
        let path: InlineArray<1, PathPart> = [.linkedArrayListGet(index)]
        return try cursor.readPath(path.span)
    }

    /// The slot of an element, or `nil` if there is no element at `index`.
    /// An element that was never written is a slot set to nothing.
    ///
    /// - Parameter index: The element's index. A negative index counts from
    ///   the end: `-1` is the last element.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something other
    ///   than a list, ``XitDBError/invalidBTreeNode`` if the list's tree does
    ///   not hold what its header says, ``XitDBError/staleCursor`` if the list
    ///   is not at the root and its cursor is from a transaction that did not
    ///   commit, or an error of the storage or of a damaged file.
    public func slot(at index: some BinaryInteger) throws(XitDBError) -> Slot? {
        guard let index = Int64(exactly: index) else { return nil }
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

    /// A view of the list at a cursor's slot, for reading, from a cursor of
    /// either access: one that can write is read through as its
    /// ``Cursor/readOnly``, so that a reader need not take it first.
    ///
    /// A slot that holds nothing is an empty list.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a linked array list.
    public init(_ cursor: Cursor<some CursorAccess>) throws(XitDBError) {
        try self.init(Cursor<ReadOnly>(viewing: cursor))
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
    /// A linked array list has no sibling kind: a slot that holds an
    /// ``ArrayList`` is refused, and the tag of a slot is never rewritten.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something other
    ///   than a linked array list, ``XitDBError/expectedTxStart`` if no
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
    ///   - value: The value.
    ///   - index: The element's index. A negative index counts from the end:
    ///     `-1` is the last element.
    /// - Throws: ``XitDBError/indexOutOfRange`` if there is no element at
    ///   `index`, ``XitDBError/expectedTxStart`` if the list's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/unexpectedTag`` if the
    ///   slot no longer holds a list, ``XitDBError/invalidBTreeNode`` if the
    ///   list's tree does not hold what its header says, or an error of the
    ///   storage or of a damaged file.
    public func put(_ value: WritableData, at index: some BinaryInteger) throws(XitDBError) {
        let index = try listIndex(index)
        let path: InlineArray<2, PathPart> = [.linkedArrayListGet(index), .write(value)]
        _ = try cursor.writePath(path.span)
    }

    /// A cursor at an element, for writing it or for making a collection
    /// there.
    ///
    /// Use it in a transaction. On a list at the root the call is a
    /// transaction of its own, committed by the time it returns, so the
    /// element is as it was and a write through the cursor throws
    /// ``XitDBError/expectedTxStart``.
    ///
    /// - Parameter index: The element's index. A negative index counts from
    ///   the end: `-1` is the last element.
    /// - Throws: ``XitDBError/indexOutOfRange`` if there is no element at
    ///   `index`, ``XitDBError/expectedTxStart`` if the list's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/unexpectedTag`` if the
    ///   slot no longer holds a list, ``XitDBError/invalidBTreeNode`` if the
    ///   list's tree does not hold what its header says, or an error of the
    ///   storage or of a damaged file.
    public func putCursor(at index: some BinaryInteger) throws(XitDBError) -> Cursor<ReadWrite> {
        let index = try listIndex(index)
        let path: InlineArray<1, PathPart> = [.linkedArrayListGet(index)]
        return try cursor.writePath(path.span)
    }

    /// Appends an element.
    ///
    /// - Parameter value: The value.
    /// - Throws: ``XitDBError/expectedTxStart`` if the list's cursor is not the
    ///   root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/unexpectedTag`` if the
    ///   slot no longer holds a list, ``XitDBError/invalidBTreeNode`` if the
    ///   list's tree does not hold what its header says, or an error of the
    ///   storage or of a damaged file.
    public func append(_ value: WritableData) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.linkedArrayListAppend, .write(value)]
        _ = try cursor.writePath(path.span)
    }

    /// Appends an element and gives a cursor at it, for writing it or for
    /// making a collection there. An element that is never written stays
    /// in the list as a slot set to nothing.
    ///
    /// Use it in a transaction. On a list at the root the call is a
    /// transaction of its own, committed by the time it returns, so the new
    /// element holds nothing and a write through the cursor throws
    /// ``XitDBError/expectedTxStart``.
    ///
    /// - Throws: ``XitDBError/expectedTxStart`` if the list's cursor is not the
    ///   root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/unexpectedTag`` if the
    ///   slot no longer holds a list, ``XitDBError/invalidBTreeNode`` if the
    ///   list's tree does not hold what its header says, or an error of the
    ///   storage or of a damaged file.
    public func appendCursor() throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.linkedArrayListAppend]
        return try cursor.writePath(path.span)
    }

    /// Appends an element, writes it, runs `body` with a cursor at it, and
    /// gives what `body` returns.
    ///
    /// If `body` throws, the error is rethrown; what was appended is discarded
    /// if this call started the transaction. Inside a transaction the
    /// transaction is poisoned instead, since the element was appended before
    /// `body` ran: it can only roll back. See the article on transactions.
    ///
    /// The result may be ignored: the call is often made for its writes
    /// alone, with a body whose one expression happens to have a value.
    ///
    /// - Parameters:
    ///   - value: The value to write before `body` runs.
    ///   - body: Given a cursor at the new element.
    /// - Throws: What `body` throws, or ``XitDBError/expectedTxStart`` if the
    ///   list's cursor is not the root cursor and no transaction is in
    ///   progress, ``XitDBError/nestedTopLevelWrite`` if it is the root cursor
    ///   and one is, ``XitDBError/staleCursor`` if it is from before the last
    ///   freeze of this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/unexpectedTag`` if the
    ///   slot no longer holds a list, ``XitDBError/invalidBTreeNode`` if the
    ///   list's tree does not hold what its header says, or an error of the
    ///   storage or of a damaged file.
    @discardableResult
    public func append<Result>(_ value: WritableData, _ body: (inout Cursor<ReadWrite>) throws -> Result) throws
        -> Result
    {
        let path: InlineArray<3, PathPart> = [.linkedArrayListAppend, .write(value), .ctx]
        var result: Result?
        _ = try cursor.writePath(path.span) { cursor in result = try body(&cursor) }
        // A write path that ends in `.ctx` runs the body or throws.
        guard let result else { preconditionFailure("the body was not run") }
        return result
    }

    /// Keeps `count` elements of the list from `offset` on, and drops the
    /// rest. The elements kept share their nodes with the list as it was.
    ///
    /// - Parameters:
    ///   - offset: The index of the first element to keep, at most the
    ///     number of elements the list has.
    ///   - count: The number of elements to keep.
    /// - Throws: ``XitDBError/indexOutOfRange`` if the offset is beyond the
    ///   list or fewer than `count` elements follow it,
    ///   ``XitDBError/expectedTxStart`` if the list's cursor is not the root
    ///   cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/unexpectedTag`` if the
    ///   slot no longer holds a list, ``XitDBError/invalidBTreeNode`` if the
    ///   list's tree does not hold what its header says, or an error of the
    ///   storage or of a damaged file.
    public func formSlice(offset: UInt64, count: UInt64) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.linkedArrayListSlice(offset: offset, size: count)]
        _ = try cursor.writePath(path.span)
    }

    /// Appends every element of another linked array list to this one. The
    /// other list is unchanged, and the result shares nodes with both.
    ///
    /// This freezes the transaction: every write after it copies what was
    /// written before it, as after ``Database/freeze()``, and every collection
    /// or cursor made before the call is stale, this list included, refused
    /// with ``XitDBError/staleCursor`` at its next write. The way on is a new
    /// list from the transaction's cursor, the one
    /// ``Database/withTransaction(_:)`` or a history append hands its body;
    /// the article on cloning, freeze and stale handles says why.
    ///
    /// - Parameter list: The other list, which may be one that can only
    ///   read.
    /// - Throws: ``XitDBError/unexpectedTag`` if `list` is not at the slot of a
    ///   linked array list or this slot no longer holds one,
    ///   ``XitDBError/expectedTxStart`` if the list's cursor is not the root
    ///   cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/invalidBTreeNode`` if
    ///   either tree does not hold what its header says, or an error of the
    ///   storage or of a damaged file.
    public func append(contentsOf list: LinkedArrayList<some CursorAccess>) throws(XitDBError) {
        try append(contentsOf: try list.slot)
    }

    /// Appends every element of another linked array list to this one. The
    /// other list is unchanged, and the result shares nodes with both.
    ///
    /// This freezes the transaction: every write after it copies what was
    /// written before it, as after ``Database/freeze()``, and every collection
    /// or cursor made before the call is stale, this list included, refused
    /// with ``XitDBError/staleCursor`` at its next write. The way on is a new
    /// list from the transaction's cursor, the one
    /// ``Database/withTransaction(_:)`` or a history append hands its body;
    /// the article on cloning, freeze and stale handles says why.
    ///
    /// - Parameter list: The slot of the other list, from its ``slot``,
    ///   in this database.
    /// - Throws: ``XitDBError/unexpectedTag`` if `list` is not the slot of a
    ///   linked array list or this slot no longer holds one,
    ///   ``XitDBError/expectedTxStart`` if the list's cursor is not the root
    ///   cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/invalidBTreeNode`` if
    ///   either tree does not hold what its header says, or an error of the
    ///   storage or of a damaged file.
    public func append(contentsOf list: Slot) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.linkedArrayListConcat(list)]
        // The join freezes the transaction, which makes this list's own
        // cursor stale with every other (D24): the caller goes on from the
        // transaction's cursor, not from this list.
        _ = try cursor.writePath(path.span)
    }

    /// Inserts an element before the one at `index`.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - index: The index of the element to insert before, which must
    ///     name an element: to add at the end, use ``append(_:)``. A
    ///     negative index counts from the end: `-1` is the last element.
    /// - Throws: ``XitDBError/indexOutOfRange`` if there is no element at
    ///   `index`, ``XitDBError/expectedTxStart`` if the list's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/unexpectedTag`` if the
    ///   slot no longer holds a list, ``XitDBError/invalidBTreeNode`` if the
    ///   list's tree does not hold what its header says, or an error of the
    ///   storage or of a damaged file.
    public func insert(_ value: WritableData, at index: some BinaryInteger) throws(XitDBError) {
        let index = try listIndex(index)
        let path: InlineArray<2, PathPart> = [.linkedArrayListInsert(index), .write(value)]
        _ = try cursor.writePath(path.span)
    }

    /// Inserts an element before the one at `index` and gives a cursor at
    /// it, for writing it or for making a collection there. An element
    /// that is never written stays in the list as a slot set to nothing.
    ///
    /// Use it in a transaction. On a list at the root the call is a
    /// transaction of its own, committed by the time it returns, so the new
    /// element holds nothing and a write through the cursor throws
    /// ``XitDBError/expectedTxStart``.
    ///
    /// - Parameter index: The index of the element to insert before, which
    ///   must name an element. A negative index counts from the end: `-1`
    ///   is the last element.
    /// - Throws: ``XitDBError/indexOutOfRange`` if there is no element at
    ///   `index`, ``XitDBError/expectedTxStart`` if the list's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/unexpectedTag`` if the
    ///   slot no longer holds a list, ``XitDBError/invalidBTreeNode`` if the
    ///   list's tree does not hold what its header says, or an error of the
    ///   storage or of a damaged file.
    public func insertCursor(at index: some BinaryInteger) throws(XitDBError) -> Cursor<ReadWrite> {
        let index = try listIndex(index)
        let path: InlineArray<1, PathPart> = [.linkedArrayListInsert(index)]
        return try cursor.writePath(path.span)
    }

    /// Removes the element at `index`.
    ///
    /// - Parameter index: The element's index. A negative index counts from
    ///   the end: `-1` is the last element.
    /// - Throws: ``XitDBError/indexOutOfRange`` if there is no element at
    ///   `index`, ``XitDBError/expectedTxStart`` if the list's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/staleCursor`` if it is from before the last freeze of
    ///   this transaction or from an earlier transaction,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, ``XitDBError/unexpectedTag`` if the
    ///   slot no longer holds a list, ``XitDBError/invalidBTreeNode`` if the
    ///   list's tree does not hold what its header says, or an error of the
    ///   storage or of a damaged file.
    public func remove(at index: some BinaryInteger) throws(XitDBError) {
        let index = try listIndex(index)
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
