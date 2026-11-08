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
    /// right for a cursor at committed data, made outside a transaction or
    /// in one, since that data is in the commit the snapshot pins and stays
    /// so for as long as the file holds that database. A cursor at data the
    /// transaction under way wrote is refused, since that data is in no
    /// commit yet; take the snapshot after the commit.
    ///
    /// - Throws: ``XitDBError/staleCursor`` for a cursor from a transaction
    ///   that did not commit or at data of the one under way, and what
    ///   ``Database/snapshot()`` throws for a cursor of a live database.
    public init(_ cursor: Cursor<ReadOnly>) throws(XitDBError) {
        let database = cursor.database
        if database.readsSnapshot, case .snapshot(let storage) = database.storage {
            let root = try cursor.resolved().slot
            self.init(
                header: database.header, committedSize: storage.committedSize, root: root,
                commitRoot: database.reader.pinnedCommitRoot ?? root, storage: storage)
            return
        }
        try cursor.checkReadable()
        // A slot the transaction under way wrote lies at or past its start;
        // one in committed bytes, read during the transaction or not, is in
        // the commit the snapshot pins.
        if let start = database.transactionStart, cursor.transaction == database.transactionNumber,
            let position = cursor.slotPointer.position, position >= start
        {
            throw .staleCursor
        }
        let whole = try database.snapshot()
        // The root header is read once, in the snapshot: a root cursor's
        // slot is that commit's root, not a second read's.
        let root = cursor.isRoot ? whole.root : try cursor.resolved().slot
        self.init(
            header: whole.header, committedSize: whole.committedSize, root: root, commitRoot: whole.root,
            storage: whole.storage)
    }
}
