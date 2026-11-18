/// Goes through the entries of a map or a set and gives each as an
/// ``Entry``: what a ``CollectionIterator`` gives as a cursor, with
/// ``Cursor/readEntry()`` done.
///
/// Call ``next()`` until it returns `nil`. The type is not a `Sequence` or
/// an `IteratorProtocol`, because reading the next entry can fail:
/// `while let entry = try entries.next()` is the shape. A loop may stop
/// where it likes; a walk to the end is also a collection's `forEachEntry(_:)`.
///
/// It goes through the collection as a ``CollectionIterator`` does: in the
/// order the collection keeps, as the collection was when the iterator was
/// made unless it is being changed in place in the same transaction, and it
/// is stale when the cursor it was made through is.
public struct EntryIterator {
    private var cursors: CollectionIterator

    init(_ cursors: CollectionIterator) {
        self.cursors = cursors
    }

    /// The next entry, or `nil` when there are no more.
    ///
    /// - Throws: What ``CollectionIterator/next()`` throws, and what
    ///   ``Cursor/readEntry()`` throws if what the collection gives is not
    ///   an entry, which only a damaged file causes in a map or a set.
    public mutating func next() throws(XitDBError) -> Entry? {
        guard let cursor = try cursors.next() else { return nil }
        return try cursor.readEntry()
    }
}

@available(*, unavailable, message: "an iterator stays with its database's thread or task; send a snapshot")
extension EntryIterator: Sendable {}

/// Goes through the elements of an array list or a linked array list and
/// gives each read as a type: what a ``CollectionIterator`` gives as a
/// cursor, with the typed read done.
///
/// Call ``next()`` until it returns `nil`. The type is not a `Sequence` or
/// an `IteratorProtocol`, because reading the next element can fail:
/// `while let age = try ages.next()` is the shape. A loop may stop where it
/// likes; a walk to the end is also a list's `forEachElement(as:_:)`.
///
/// It goes through the list as a ``CollectionIterator`` does: in order, as
/// the list was when the iterator was made unless it is being changed in
/// place in the same transaction, and it is stale when the cursor it was
/// made through is.
public struct ElementIterator<Value: StorableValue> {
    private var cursors: CollectionIterator

    init(_ cursors: CollectionIterator) {
        self.cursors = cursors
    }

    /// The next element, read as the iterator's type, or `nil` when there
    /// are no more.
    ///
    /// Every element has to be of the type, as ``Cursor/read(_:)`` reads
    /// it: one of another kind ends the walk with
    /// ``XitDBError/unexpectedTag``. An element appended and never written,
    /// a slot set to nothing, does so for a number, and reads as empty for
    /// a `String`, a `[UInt8]` or ``Bytes``: a list that holds several
    /// kinds is gone through by its cursors, with ``CollectionIterator``.
    ///
    /// - Throws: What ``CollectionIterator/next()`` throws, and what
    ///   reading the element as the type throws:
    ///   ``XitDBError/unexpectedTag`` if the element holds another kind
    ///   than the type is written as.
    public mutating func next() throws(XitDBError) -> Value? {
        guard let cursor = try cursors.next() else { return nil }
        return try Value(reading: cursor)
    }
}

@available(*, unavailable, message: "an iterator stays with its database's thread or task; send a snapshot")
extension ElementIterator: Sendable {}
