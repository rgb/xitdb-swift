/// A list in a database, indexed by position.
///
/// Elements are appended at the end, read and written by index, and cut off
/// from the end with ``truncate(to:)``; it is Zig's `ArrayList`. A negative
/// index counts from the end: `-1` is the last element.
///
/// A list is a view of a slot. Making one that can only read checks that
/// the slot holds a list, or nothing. Making one that can write makes the
/// slot a list if it holds nothing, and readies it for this transaction's
/// writes.
///
/// Writing needs a transaction: see ``Database/withTransaction(_:)``. A list at
/// the root of the database is the exception: there, every write is a
/// transaction of its own. That is how a database's history is kept: a
/// list at the root, with one element per transaction, each appended with
/// ``append(_:_:)``.
public struct ArrayList<Access: CursorAccess> {
    /// The cursor at the slot that holds the list.
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
    ///   list, or ``XitDBError/endOfStream`` if the list's header cannot be
    ///   read.
    public var count: UInt64 {
        get throws(XitDBError) {
            try cursor.count
        }
    }

    /// An iterator over the list's elements, in order.
    ///
    /// An element that was appended and never written is passed over.
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
    ///   index counts from the end: `-1` is the last element. An index that
    ///   names no element gives an iterator of nothing.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a list, or an error of the storage or of a damaged file.
    public func iterator(fromIndex index: some BinaryInteger) throws(XitDBError) -> CollectionIterator {
        let index = try listIndex(index)
        return try cursor.iterator(fromArrayListIndex: index)
    }

    /// A cursor at an element, or `nil` if there is no element at `index`
    /// or it was never written.
    ///
    /// - Parameter index: The element's index. A negative index counts from
    ///   the end: `-1` is the last element.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a list, or an error of the storage or of a damaged
    ///   file.
    public func cursor(at index: some BinaryInteger) throws(XitDBError) -> Cursor<ReadOnly>? {
        guard let index = Int64(exactly: index) else { return nil }
        let path: InlineArray<1, PathPart> = [.arrayListGet(index)]
        return try cursor.readPath(path.span)
    }

    /// The slot of an element, or `nil` if there is no element at `index`
    /// or it was never written.
    ///
    /// - Parameter index: The element's index. A negative index counts from
    ///   the end: `-1` is the last element.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a list, or an error of the storage or of a damaged
    ///   file.
    public func slot(at index: some BinaryInteger) throws(XitDBError) -> Slot? {
        guard let index = Int64(exactly: index) else { return nil }
        let path: InlineArray<1, PathPart> = [.arrayListGet(index)]
        return try cursor.readPathSlot(path.span)
    }
}

extension ArrayList where Access == ReadOnly {
    /// A view of the list at a cursor's slot, for reading.
    ///
    /// A slot that holds nothing is an empty list.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a list.
    public init(_ cursor: Cursor<ReadOnly>) throws(XitDBError) {
        switch try cursor.resolved().slot.tag {
        case .none, .arrayList:
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
    ///   other than a list.
    public init(_ cursor: Cursor<some CursorAccess>) throws(XitDBError) {
        try self.init(Cursor<ReadOnly>(slotPointer: cursor.slotPointer, database: cursor.database))
    }
}

extension ArrayList where Access == ReadWrite {
    /// A view of the list at a cursor's slot, for reading and writing.
    ///
    /// A slot that holds nothing becomes an empty list. A list from an
    /// earlier transaction is readied for this one: its header and first
    /// block are copied, so that writing to it leaves earlier moments as
    /// they were.
    ///
    /// On the root cursor this is a transaction of its own, unless the root
    /// is a list already, in which case nothing is written.
    ///
    /// A list has no sibling kind: a slot that holds a ``LinkedArrayList``
    /// is refused, and the tag of a slot is never rewritten.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than an array list, ``XitDBError/expectedTxStart`` if no
    ///   transaction is in progress and `cursor` is not the root cursor,
    ///   ``XitDBError/nestedTopLevelWrite`` if `cursor` is the root cursor
    ///   and one is, or an error of the storage or of a damaged file.
    public init(_ cursor: Cursor<ReadWrite>) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.arrayListInit]
        self.cursor = try cursor.writePath(path.span)
    }

    /// A view of the same list that can only read.
    public var readOnly: ArrayList<ReadOnly> {
        ArrayList<ReadOnly>(unchecked: cursor.readOnly)
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
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   list, or an error of the storage or of a damaged file.
    public func put(_ value: WritableData, at index: some BinaryInteger) throws(XitDBError) {
        let index = try listIndex(index)
        let path: InlineArray<2, PathPart> = [.arrayListGet(index), .write(value)]
        _ = try cursor.writePath(path.span)
    }

    /// A cursor at an element, for writing it or for making a collection
    /// there.
    ///
    /// - Parameter index: The element's index. A negative index counts from
    ///   the end: `-1` is the last element.
    /// - Throws: ``XitDBError/indexOutOfRange`` if there is no element at
    ///   `index`, ``XitDBError/expectedTxStart`` if the list's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   list, or an error of the storage or of a damaged file.
    public func putCursor(at index: some BinaryInteger) throws(XitDBError) -> Cursor<ReadWrite> {
        let index = try listIndex(index)
        let path: InlineArray<1, PathPart> = [.arrayListGet(index)]
        return try cursor.writePath(path.span)
    }

    /// Appends an element.
    ///
    /// - Parameter value: The value.
    /// - Throws: ``XitDBError/expectedTxStart`` if the list's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   list, ``XitDBError/invalidDatabase`` if the list is as long as a
    ///   list can be, or an error of the storage or of a damaged file.
    public func append(_ value: WritableData) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.arrayListAppend, .write(value)]
        _ = try cursor.writePath(path.span)
    }

    /// Appends an element and gives a cursor at it, for writing it or for
    /// making a collection there.
    ///
    /// - Throws: ``XitDBError/expectedTxStart`` if the list's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   list, ``XitDBError/invalidDatabase`` if the list is as long as a
    ///   list can be, or an error of the storage or of a damaged file.
    public func appendCursor() throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.arrayListAppend]
        return try cursor.writePath(path.span)
    }

    /// Appends an element, writes it, runs `body` with a cursor at it, and
    /// gives what `body` returns.
    ///
    /// On a list at the root of the database this is how a transaction is
    /// run: `value` is usually the slot of the last element, so that the new
    /// element starts as a copy of the last moment, and `body` makes the
    /// changes. The transaction commits when `body` returns. If `body`
    /// throws, the error is rethrown; what was appended is discarded only
    /// if this call started the transaction, as it does on the root. Inside
    /// a transaction the element stays, with what `body` wrote before it
    /// threw, as a ``LinkedArrayList``'s does.
    ///
    /// The result may be ignored: a transaction is often run for its writes
    /// alone, with a body whose one expression happens to have a value.
    ///
    /// - Parameters:
    ///   - value: The value to write before `body` runs.
    ///   - body: Given a cursor at the new element.
    /// - Throws: What `body` throws, or ``XitDBError/expectedTxStart`` if
    ///   the list's cursor is not the root cursor and no transaction is in
    ///   progress, ``XitDBError/nestedTopLevelWrite`` if it is the root
    ///   cursor and one is, ``XitDBError/unexpectedTag`` if the slot no
    ///   longer holds a list, ``XitDBError/invalidDatabase`` if the list is
    ///   as long as a list can be, or an error of the storage or of a
    ///   damaged file.
    @discardableResult
    public func append<Result>(_ value: WritableData, _ body: (inout Cursor<ReadWrite>) throws -> Result) throws
        -> Result
    {
        let path: InlineArray<3, PathPart> = [.arrayListAppend, .write(value), .ctx]
        var result: Result?
        _ = try cursor.writePath(path.span) { cursor in result = try body(&cursor) }
        // A write path that ends in `.ctx` runs the body or throws.
        guard let result else { preconditionFailure("the body was not run") }
        return result
    }

    /// Cuts the list down to its first `count` elements.
    ///
    /// - Parameter count: The number of elements to keep, at most the number
    ///   the list has.
    /// - Throws: ``XitDBError/indexOutOfRange`` if `count` is larger than
    ///   the list, ``XitDBError/expectedTxStart`` if the list's cursor is not
    ///   the root cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one
    ///   is, ``XitDBError/unexpectedTag`` if the slot no longer holds a
    ///   list, or an error of the storage or of a damaged file.
    public func truncate(to count: UInt64) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.arrayListSlice(size: count)]
        _ = try cursor.writePath(path.span)
    }
}

extension ArrayList {
    /// A view of the list at a cursor's slot, which the caller has made sure
    /// holds one.
    init(unchecked cursor: Cursor<Access>) {
        self.cursor = cursor
    }
}

/// An index of any integer type as the format's 64-bit signed index.
///
/// - Throws: ``XitDBError/indexOutOfRange`` if the index does not fit, since
///   no list has an element there.
func listIndex(_ index: some BinaryInteger) throws(XitDBError) -> Int64 {
    guard let index = Int64(exactly: index) else { throw .indexOutOfRange }
    return index
}
