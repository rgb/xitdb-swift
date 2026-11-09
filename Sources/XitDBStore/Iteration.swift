// Going through a collection's elements: a throwing iterator, since reading
// the next element can fail.

public import XitDB

/// Goes through the elements of a collection, in the order the collection
/// keeps them.
///
/// `while let element = try iterator.next()` is the shape: the type is not
/// a `Sequence`, because reading the next element can fail. An iterator
/// made in a writable moment can give a mix of old and new elements if the
/// collection is changed while it runs, as the faithful one can. After an
/// error the iterator is done: `next()` gives nil from then on.
public struct ValueIterator<Element> {
    var base: CollectionIterator?
    let read: (Cursor<ReadOnly>) throws(XitDBError) -> Element

    init(_ base: CollectionIterator?, read: @escaping (Cursor<ReadOnly>) throws(XitDBError) -> Element) {
        self.base = base
        self.read = read
    }

    /// The next element, or nil after the last.
    public mutating func next() throws(XitDBError) -> Element? {
        guard let cursor = try base?.next() else { return nil }
        return try read(cursor)
    }
}

/// A key and its value, as a sorted map or a key set gives them.
public struct Entry<Key, Value> {
    /// The key.
    public let key: Key

    /// The value.
    public let value: Value
}
