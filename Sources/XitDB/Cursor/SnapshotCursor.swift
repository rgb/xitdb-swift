extension Snapshot {
    /// A read-only cursor at the snapshot's root, on a fresh database made
    /// with ``Database/init(reading:)``.
    ///
    /// Each access makes a new database and costs no read. The cursor, and
    /// every collection, iterator and byte reader made from it, belongs to
    /// the task that reads it; another task takes its own from the same
    /// snapshot. The collections' read-only initialisers take it as they
    /// take any cursor.
    public var rootCursor: Cursor<ReadOnly> {
        Cursor(viewing: Database(reading: self).rootCursor)
    }

    /// A snapshot of what `cursor` points at, so that one task can find a
    /// collection inside a snapshot and hand it to many: the result's
    /// ``rootCursor`` is at that collection, and reads the same commit.
    ///
    /// For a cursor read from a snapshot this reads nothing and cannot
    /// fail. For a cursor of a live database it takes ``Database/snapshot()``
    /// of that database first and pins the cursor's slot under it, which is
    /// right for a cursor made outside a transaction, since what it points
    /// at is committed and never changes; a cursor made inside a transaction
    /// that has not committed points above the commit, and reads through the
    /// result report ``XitDBError/endOfStream``.
    ///
    /// - Throws: ``XitDBError/staleCursor`` for a cursor from a transaction
    ///   that did not commit, and what ``Database/snapshot()`` throws for a
    ///   cursor of a live database.
    public init(_ cursor: Cursor<ReadOnly>) throws(XitDBError) {
        let database = cursor.database
        if database.readsSnapshot, case .snapshot(let storage) = database.storage {
            self.init(
                header: database.header, committedSize: storage.committedSize, root: try cursor.resolved().slot,
                storage: storage)
            return
        }
        try cursor.checkReadable()
        let whole = try database.snapshot()
        self.init(
            header: whole.header, committedSize: whole.committedSize, root: try cursor.resolved().slot,
            storage: whole.storage)
    }
}
