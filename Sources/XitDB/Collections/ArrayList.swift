/// A list in a database, indexed by position.
///
/// Elements are appended at the end, read and written by index, and cut off
/// from the end with ``truncate(to:)``. A negative index counts from the
/// end: `-1` is the last element.
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
///
/// **What the calls throw.** A call that reads throws
/// ``XitDBError/unexpectedTag`` if the slot holds something other than a list,
/// ``XitDBError/staleCursor`` if the list is not at the root and its cursor is
/// from a transaction that did not commit, or an error of the storage or of a
/// damaged file. A call that writes throws ``XitDBError/expectedTxStart`` if
/// the list's cursor is not the root cursor and no transaction is in progress,
/// ``XitDBError/nestedTopLevelWrite`` if it is the root cursor and one is,
/// ``XitDBError/staleCursor`` if it is from before the last freeze of this
/// transaction or from an earlier transaction,
/// ``XitDBError/poisonedTransaction`` if an earlier operation of the
/// transaction failed after writing, ``XitDBError/unexpectedTag`` if the slot
/// no longer holds a list, or an error of the storage or of a damaged file. A
/// call's own comment says what it throws beyond these.
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
    /// at a slot set to nothing. An element appended and never written
    /// before 0.3.0, or by the original before `89da8e7`, has an empty
    /// slot, and is passed over.
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
    ///   `Int64`, and what a read throws: see ``ArrayList``.
    public func iterator(fromIndex index: some BinaryInteger) throws(XitDBError) -> CollectionIterator {
        let index = try listIndex(index)
        return try cursor.iterator(fromArrayListIndex: index)
    }

    /// A cursor at an element, or `nil` if there is no element at `index`.
    ///
    /// An element that was appended and never written is a slot set to
    /// nothing, and has a cursor like any other. An element appended and
    /// never written before 0.3.0, or by the original before `89da8e7`,
    /// has an empty slot, and the result is `nil`.
    ///
    /// - Parameter index: The element's index. A negative index counts from
    ///   the end: `-1` is the last element.
    /// - Throws: What a read throws: see ``ArrayList``.
    public func cursor(at index: some BinaryInteger) throws(XitDBError) -> Cursor<ReadOnly>? {
        guard let index = Int64(exactly: index) else { return nil }
        let path: InlineArray<1, PathPart> = [.arrayListGet(index)]
        return try cursor.readPath(path.span)
    }

    /// The slot of an element, or `nil` if there is no element at `index`.
    ///
    /// An element that was appended and never written is a slot set to
    /// nothing. An element appended and never written before 0.3.0, or by
    /// the original before `89da8e7`, has an empty slot, and the result is
    /// `nil`.
    ///
    /// - Parameter index: The element's index. A negative index counts from
    ///   the end: `-1` is the last element.
    /// - Throws: What a read throws: see ``ArrayList``.
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
        try self.init(Cursor<ReadOnly>(viewing: cursor))
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
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something other
    ///   than an array list, ``XitDBError/expectedTxStart`` if no transaction
    ///   is in progress and `cursor` is not the root cursor,
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
    ///   `index`, and what a write throws: see ``ArrayList``.
    public func put(_ value: WritableData, at index: some BinaryInteger) throws(XitDBError) {
        let index = try listIndex(index)
        let path: InlineArray<2, PathPart> = [.arrayListGet(index), .write(value)]
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
    ///   `index`, and what a write throws: see ``ArrayList``.
    public func putCursor(at index: some BinaryInteger) throws(XitDBError) -> Cursor<ReadWrite> {
        let index = try listIndex(index)
        let path: InlineArray<1, PathPart> = [.arrayListGet(index)]
        return try cursor.writePath(path.span)
    }

    /// Appends an element.
    ///
    /// - Parameter value: The value.
    /// - Throws: ``XitDBError/invalidDatabase`` if the list is as long as a
    ///   list can be, and what a write throws: see ``ArrayList``.
    public func append(_ value: WritableData) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.arrayListAppend, .write(value)]
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
    /// - Throws: ``XitDBError/invalidDatabase`` if the list is as long as a
    ///   list can be, and what a write throws: see ``ArrayList``.
    public func appendCursor() throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.arrayListAppend]
        return try cursor.writePath(path.span)
    }

    /// Appends an element, writes it, runs `body` with a cursor at it, and
    /// gives what `body` returns.
    ///
    /// On a list at the root of the database this is how a transaction is run:
    /// `value` is usually the slot of the last element, so that the new element
    /// starts as a copy of the last moment, and `body` makes the changes. The
    /// transaction commits when `body` returns. If `body` throws, the error is
    /// rethrown; what was appended is discarded if this call started the
    /// transaction, as it does on the root. Inside a transaction the
    /// transaction is poisoned instead, since the element was appended before
    /// `body` ran: it can only roll back, as a ``LinkedArrayList``'s does. See
    /// the article on transactions.
    ///
    /// The result may be ignored: a transaction is often run for its writes
    /// alone, with a body whose one expression happens to have a value.
    ///
    /// The call throws `any Error`, since what `body` throws comes out as
    /// itself. Where the library's error is declared, with
    /// `throws(XitDBError)`, make the call inside
    /// ``XitDBError/carrying(_:)``.
    ///
    /// - Parameters:
    ///   - value: The value to write before `body` runs.
    ///   - body: Given a cursor at the new element.
    /// - Throws: What `body` throws, ``XitDBError/invalidDatabase`` if the list
    ///   is as long as a list can be, and what a write throws: see
    ///   ``ArrayList``.
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
    /// - Throws: ``XitDBError/indexOutOfRange`` if `count` is larger than the
    ///   list, and what a write throws: see ``ArrayList``.
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

// MARK: Typed values

extension ArrayList {
    /// The element at an index, read as a type, or `nil` if the index
    /// names no element.
    ///
    /// The type can be given or left to what the result is assigned to:
    /// `try list.value(at: 0, as: String.self)`, or `let first: String? =
    /// try list.value(at: 0)`.
    ///
    /// `nil` means the index names no element, or one whose slot is empty:
    /// an element appended and never written before 0.3.0, or by the
    /// original before `89da8e7`, as ``cursor(at:)`` says. An element that
    /// is there is read strictly, as ``StorableValue`` says: one of another
    /// kind than the type is written as is an error and not `nil`. An
    /// element that was set to nothing, or appended and never written since
    /// 0.3.0, is there: read as a number it is that error, and read as a
    /// `String`, a `[UInt8]` or ``Bytes`` it is empty.
    ///
    /// - Parameters:
    ///   - index: The element's index. A negative index counts from the
    ///     end: -1 is the last element.
    ///   - type: The type to read.
    /// - Throws: What ``cursor(at:)`` throws, and what ``Cursor/read(_:)``
    ///   throws, ``XitDBError/unexpectedTag`` for an element of another
    ///   kind among them.
    public func value<Value: StorableValue>(at index: some BinaryInteger, as type: Value.Type = Value.self)
        throws(XitDBError) -> Value?
    {
        guard let cursor = try cursor(at: index) else { return nil }
        return try Value(reading: cursor)
    }
}

extension ArrayList where Access == ReadWrite {
    /// Appends a value to the list.
    ///
    /// The value writes itself into the new element, in the same
    /// transaction: a value of one of the library's types leaves the file
    /// the append of ``WritableData`` leaves, and a type of your own
    /// writes what it says, a collection included.
    ///
    /// - Parameter value: The value.
    /// - Throws: What the append of ``WritableData`` throws, and what the
    ///   value's own writing throws. A value that fails once the list has
    ///   grown poisons the transaction, as any write that fails after it
    ///   has written does.
    @inlinable
    public func append(_ value: some StorableValue) throws(XitDBError) {
        // One of the library's own values is its data, and its typed write
        // is the write of that data. Where the caller's code knows the
        // value's type, the compiler settles which it is, and for the
        // library's six this call is that write and nothing else.
        if let data = WritableData(ownValue: value) {
            try append(data)
            return
        }
        try appendWritingItself(value)
    }

    /// The append of a value of the caller's own, which writes itself in
    /// the element the list makes for it.
    @usableFromInline
    func appendWritingItself(_ value: some StorableValue) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.arrayListAppend, .ctx]
        _ = try cursor.writePath(
            path.span,
            typed: { (element: inout Cursor<ReadWrite>) throws(XitDBError) in
                try value.write(to: &element)
            })
    }

    /// Stores a value at an index, in place of the element that was there.
    ///
    /// The value writes itself into the element, in the same transaction,
    /// as ``append(_:)-(StorableValue)`` says.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - index: The element's index. A negative index counts from the
    ///     end.
    /// - Throws: What the put of ``WritableData`` throws,
    ///   ``XitDBError/indexOutOfRange`` for an index that names no element
    ///   among them, and what the value's own writing throws.
    @inlinable
    public func put(_ value: some StorableValue, at index: some BinaryInteger) throws(XitDBError) {
        if let data = WritableData(ownValue: value) {
            try put(data, at: index)
            return
        }
        try putWritingItself(value, at: index)
    }

    /// The put of a value of the caller's own, which writes itself in the
    /// element.
    @usableFromInline
    func putWritingItself(_ value: some StorableValue, at index: some BinaryInteger) throws(XitDBError) {
        let index = try listIndex(index)
        let path: InlineArray<2, PathPart> = [.arrayListGet(index), .ctx]
        _ = try cursor.writePath(
            path.span,
            typed: { (element: inout Cursor<ReadWrite>) throws(XitDBError) in
                try value.write(to: &element)
            })
    }
}

@available(*, unavailable, message: "an array list stays with its database's thread or task; send a snapshot")
extension ArrayList: Sendable {}
