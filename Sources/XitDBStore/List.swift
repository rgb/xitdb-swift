// The lists over a handle: the array list and the linked array list.

public import XitDB

/// An array list at a handle, with elements of type `V`.
///
/// Reading a list that does not exist yet finds nothing and a count of
/// zero; the first write makes it. Indices count from the end when
/// negative.
public struct List<V: StorableValue> {
    /// The handle the list stands on.
    public let handle: Handle

    func reading() throws(XitDBError) -> ArrayList<ReadOnly>? {
        guard let cursor = try handle.read() else { return nil }
        return try ArrayList<ReadOnly>(cursor)
    }

    func writing() throws(XitDBError) -> ArrayList<ReadWrite> {
        try ArrayList<ReadWrite>(try handle.write())
    }

    /// How many elements the list has.
    public var count: Int {
        get throws(XitDBError) {
            Int(try reading()?.count ?? 0)
        }
    }

    /// The element at an index, negative from the end, or nil past either
    /// end.
    public subscript(index: Int) -> V? {
        get throws(XitDBError) {
            guard let cursor = try reading()?.cursor(at: index) else { return nil }
            return try V(reading: cursor)
        }
    }

    /// Adds an element at the end, making the list first if the place is
    /// empty.
    public func append(_ value: V) throws(XitDBError) {
        var cursor = try writing().appendCursor()
        try value.write(to: &cursor)
    }

    /// Replaces the element at an index, negative from the end.
    ///
    /// - Throws: `XitDBError.indexOutOfRange` past either end.
    public func put(_ value: V, at index: Int) throws(XitDBError) {
        var cursor = try writing().putCursor(at: index)
        try value.write(to: &cursor)
    }

    /// Adds an empty element at the end and gives its handle, for a
    /// collection nested in the list: `rows.append().list(String.self)`.
    @discardableResult
    public func append() throws(XitDBError) -> Handle {
        try handle.appendElement()
    }

    /// Drops the elements from `count` on.
    public func truncate(to count: Int) throws(XitDBError) {
        try writing().truncate(to: UInt64(max(count, 0)))
    }

    /// The handle one level down, for a nested collection at an index.
    public subscript(handleAt index: Int) -> Handle {
        handle[index: index]
    }

    /// The elements in order.
    public func elements() throws(XitDBError) -> ValueIterator<V> {
        ValueIterator(try reading()?.iterator()) { (element) throws(XitDBError) in try V(reading: element) }
    }
}

/// A linked array list at a handle: a list that inserts and removes in the
/// middle, and joins and slices by sharing.
///
/// What ``List`` says holds here too. A join or a slice freezes the
/// transaction, which the handle hides: nothing is held, so nothing goes
/// stale.
public struct LinkedList<V: StorableValue> {
    /// The handle the list stands on.
    public let handle: Handle

    func reading() throws(XitDBError) -> LinkedArrayList<ReadOnly>? {
        guard let cursor = try handle.read() else { return nil }
        return try LinkedArrayList<ReadOnly>(cursor)
    }

    func writing() throws(XitDBError) -> LinkedArrayList<ReadWrite> {
        try LinkedArrayList<ReadWrite>(try handle.write())
    }

    /// How many elements the list has.
    public var count: Int {
        get throws(XitDBError) {
            Int(try reading()?.count ?? 0)
        }
    }

    /// The element at an index, negative from the end, or nil past either
    /// end.
    public subscript(index: Int) -> V? {
        get throws(XitDBError) {
            guard let cursor = try reading()?.cursor(at: index) else { return nil }
            return try V(reading: cursor)
        }
    }

    /// Adds an element at the end, making the list first if the place is
    /// empty.
    public func append(_ value: V) throws(XitDBError) {
        var cursor = try writing().appendCursor()
        try value.write(to: &cursor)
    }

    /// Replaces the element at an index, negative from the end.
    public func put(_ value: V, at index: Int) throws(XitDBError) {
        var cursor = try writing().putCursor(at: index)
        try value.write(to: &cursor)
    }

    /// Adds an empty element at the end and gives its handle, for a
    /// collection nested in the list.
    @discardableResult
    public func append() throws(XitDBError) -> Handle {
        _ = try writing().appendCursor()
        return handle[index: try count - 1]
    }

    /// Inserts an element before the one at an index, negative from the
    /// end; to add at the end, append.
    public func insert(_ value: V, at index: Int) throws(XitDBError) {
        var cursor = try writing().insertCursor(at: index)
        try value.write(to: &cursor)
    }

    /// Removes the element at an index, negative from the end.
    public func remove(at index: Int) throws(XitDBError) {
        try writing().remove(at: index)
    }

    /// Appends every element of another linked list, sharing them.
    ///
    /// - Throws: `XitDBError.unexpectedTag` if the other handle's
    ///   place holds no linked list.
    public func join(_ other: LinkedList<V>) throws(XitDBError) {
        guard let otherCursor = try other.handle.read() else { return }
        try writing().append(contentsOf: try LinkedArrayList<ReadOnly>(otherCursor))
    }

    /// Keeps `count` elements from `offset` on, in place.
    public func slice(offset: Int, count: Int) throws(XitDBError) {
        try writing().formSlice(offset: UInt64(max(offset, 0)), count: UInt64(max(count, 0)))
    }

    /// The handle one level down, for a nested collection at an index.
    public subscript(handleAt index: Int) -> Handle {
        handle[index: index]
    }

    /// The elements in order.
    public func elements() throws(XitDBError) -> ValueIterator<V> {
        ValueIterator(try reading()?.iterator()) { (element) throws(XitDBError) in try V(reading: element) }
    }
}
