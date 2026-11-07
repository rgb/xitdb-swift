extension Cursor {
    /// Goes through the elements of an array list or a linked array list,
    /// or the entries of a hash map or set, in the order they are stored:
    /// Zig's `Cursor.Iter`.
    ///
    /// Call ``next()`` until it returns `nil`. The type is not a `Sequence`,
    /// because reading the next element can fail.
    ///
    /// An array list gives its elements in order. A hash map or set gives
    /// its entries in the order of their hashes' last bits, which looks
    /// random; each cursor is at an entry, to be read with
    /// ``Cursor/readKeyValuePair()``.
    ///
    /// The iterator goes through the collection as it was when the iterator
    /// was made, unless the collection is being changed in place in the same
    /// transaction, in which case what it gives is not defined.
    public struct Iter {
        private var slots: SlotIterator
        private let database: Database
        private let frozenAt: UInt64

        init(slots: SlotIterator, database: Database, frozenAt: UInt64) {
            self.slots = slots
            self.database = database
            self.frozenAt = frozenAt
        }

        /// The next element or entry, or `nil` when there are no more.
        ///
        /// The cursors are read-only whatever the collection's cursor was:
        /// an iterator does not copy what it goes through, so writing
        /// through them would change other moments of the database.
        ///
        /// An element of an array list that was appended and never written
        /// is passed over. One that was set to nothing is given, and so is
        /// an element of a linked array list that was never written, as a
        /// cursor at a slot set to nothing.
        ///
        /// - Throws: ``XitDBError/keyOffsetExceeded``,
        ///   ``XitDBError/maxShiftExceeded`` or ``XitDBError/invalidBTreeNode``
        ///   if the collection is deeper than a hash map, an array list of
        ///   its size or a linked array list can be, and
        ///   ``XitDBError/invalidEnumTag`` or ``XitDBError/endOfStream`` if
        ///   part of it cannot be read. Only a damaged file causes these.
        public mutating func next() throws(XitDBError) -> Cursor<ReadOnly>? {
            guard let pointer = try slots.next() else { return nil }
            return Cursor<ReadOnly>(slotPointer: pointer, database: database, frozenAt: frozenAt)
        }
    }

    /// An iterator over the collection the slot holds. An empty slot gives
    /// an iterator of nothing.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   that is not a collection.
    public func iterator() throws(XitDBError) -> Iter {
        let slot = try resolved().slot
        return Iter(
            slots: try SlotIterator(reader: database.reader, collection: slot),
            database: database,
            frozenAt: frozenAt
        )
    }

    /// An iterator over the array list the slot holds, starting at one of
    /// its elements.
    func iterator(fromArrayListIndex index: Int64) throws(XitDBError) -> Iter {
        let slot = try resolved().slot
        return Iter(
            slots: try SlotIterator(reader: database.reader, arrayList: slot, from: index),
            database: database,
            frozenAt: frozenAt
        )
    }

    /// An iterator over the linked array list the slot holds, starting at
    /// one of its elements.
    func iterator(fromLinkedArrayListIndex index: Int64) throws(XitDBError) -> Iter {
        let slot = try resolved().slot
        return Iter(
            slots: try SlotIterator(reader: database.reader, linkedArrayList: slot, from: index),
            database: database,
            frozenAt: frozenAt
        )
    }
}
