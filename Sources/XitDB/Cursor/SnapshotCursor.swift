extension Snapshot {
    /// A read-only cursor at the snapshot's root, on a fresh
    /// ``SnapshotDatabase``.
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
    /// so for as long as the file holds that engine. The test is on what
    /// the slot points at, not on where the slot was read from: a slot
    /// pointing at or past the running transaction's start names the
    /// transaction's own work, which is in no commit yet, and is refused;
    /// one pointing below it names committed data, wherever the slot itself
    /// lies, since a slot copied into the transaction's blocks may point at
    /// committed data and a slot in committed bytes can point nowhere else;
    /// a slot that holds its value passes. Take the snapshot of the
    /// transaction's work after the commit.
    ///
    /// - Throws: ``XitDBError/staleCursor`` for a cursor from a transaction
    ///   that did not commit or at the work of the one under way, and what
    ///   ``Database/snapshot()`` throws for a cursor of a live engine.
    public init(_ cursor: Cursor<ReadOnly>) throws(XitDBError) {
        let engine = cursor.engine
        if engine.readsSnapshot, case .snapshot(let storage) = engine.storage {
            let root = try cursor.resolved().slot
            self.init(
                header: engine.header, committedSize: storage.committedSize, root: root,
                commitRoot: engine.reader.pinnedCommitRoot ?? root, storage: storage)
            return
        }
        try cursor.checkReadable()
        let whole = try engine.snapshot()
        // The root header is read once, in the snapshot: a root cursor's
        // slot is that commit's root, not a second read's.
        let root = cursor.isRoot ? whole.root : try cursor.resolved().slot
        // The transaction under way wrote everything at or past its start;
        // a slot pointing there names work no commit holds yet.
        if let start = engine.transactionStart, cursor.transaction == engine.transactionNumber,
            !root.holdsValue, root.value >= start
        {
            throw .staleCursor
        }
        self.init(
            header: whole.header, committedSize: whole.committedSize, root: root, commitRoot: whole.root,
            storage: whole.storage)
    }
}
