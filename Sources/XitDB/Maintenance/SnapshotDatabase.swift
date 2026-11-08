/// A database that reads one commit, from a ``Snapshot``, and has no
/// writing members.
///
/// Where a snapshot is used, a snapshot database is made over it at no I/O
/// cost; it belongs to the thread or task that made it, as every database
/// does, and every cursor, collection, iterator and byte reader made from
/// its ``rootCursor`` works as on a live database, reading the snapshot's
/// commit whatever the writer has done since. There is no transaction, no
/// freeze and no replication onto it, so nothing it gives out is ever stale
/// in the sense of ``XitDBError/staleCursor``.
///
/// It serves replication as the file is the unit: ``replicaState`` and the
/// `readCommitted` members give the whole commit's bytes, for a snapshot of
/// a sub-collection too. Compaction from it writes the commit into a target
/// that is a live ``Database``; from a sub-collection snapshot it is refused
/// with ``XitDBError/subCollectionSnapshot``.
///
/// Like ``Database``, it is not `Sendable`: the snapshot is, and each task
/// makes its own database over it.
public final class SnapshotDatabase: ReadableDatabase {
    /// The engine under this database: a `Database` over the snapshot's
    /// read half with the root pinned.
    let engine: Database

    private let pinned: Snapshot

    /// Opens a database over `snapshot`, reading nothing.
    ///
    /// - Parameter snapshot: The commit to read.
    public init(_ snapshot: Snapshot) {
        pinned = snapshot
        engine = Database(reading: snapshot)
        engine.readingOwner = self
    }

    /// A database over the engine a read-only cursor holds, when the one it
    /// was made with has gone.
    init(engine: Database) {
        self.engine = engine
        pinned = engine.snapshotOfEngine()
        engine.readingOwner = self
    }

    /// A read-only cursor at the snapshot's root. Each access gives a new
    /// cursor and reads nothing.
    public var rootCursor: Cursor<ReadOnly> {
        Cursor(viewing: engine.rootCursor)
    }

    /// The header of the database the commit belongs to.
    public var header: DatabaseHeader {
        pinned.header
    }

    /// The size of the database at the commit. This never throws.
    public var committedSize: UInt64 {
        pinned.committedSize
    }

    /// The snapshot this database reads. This never throws and reads
    /// nothing.
    public func snapshot() -> Snapshot {
        pinned
    }

    /// The commit's ``ReplicaState``, as the live database's was at it.
    ///
    /// - Throws: ``XitDBError/invalidDatabase`` if the trailer at the
    ///   committed size does not verify, which a snapshot's never fails.
    public var replicaState: ReplicaState {
        get throws(XitDBError) {
            try engine.replicaState
        }
    }

    /// Where a replica in `state` has to be synced from, against this
    /// commit.
    ///
    /// - Throws: What ``Database/replicationStart(for:)`` throws.
    public func replicationStart(for state: ReplicaState) throws(XitDBError) -> UInt64 {
        try engine.replicationStart(for: state)
    }

    /// The commit's bytes from `start` up to `end`, written to `sink`.
    ///
    /// - Throws: What ``Database/readCommitted(from:to:into:)-(_,_,Sink)``
    ///   throws; `end` past the committed size is ``XitDBError/invalidRange``.
    public func readCommitted<Sink: ByteSink>(from start: UInt64, to end: UInt64, into sink: inout Sink)
        throws(XitDBError)
    {
        try engine.readCommitted(from: start, to: end, into: &sink)
    }

    /// The commit's bytes from `start` up to `end`, appended to `bytes`.
    ///
    /// - Throws: What ``Database/readCommitted(from:to:into:)-(_,_,[UInt8])``
    ///   throws.
    public func readCommitted(from start: UInt64, to end: UInt64, into bytes: inout [UInt8]) throws(XitDBError) {
        try engine.readCommitted(from: start, to: end, into: &bytes)
    }

    /// The commit's bytes from `start` up to `end`, in memory.
    ///
    /// - Throws: What ``Database/readCommitted(from:to:)`` throws.
    public func readCommitted(from start: UInt64, to end: UInt64) throws(XitDBError) -> [UInt8] {
        try engine.readCommitted(from: start, to: end)
    }

    /// Compacts the commit into `target`, a live database whose root is
    /// empty, while the live database the snapshot came from may go on
    /// committing.
    ///
    /// - Throws: ``XitDBError/subCollectionSnapshot`` for a snapshot of a
    ///   sub-collection, before anything is written, and what
    ///   ``Database/compact(into:offsetMap:)`` throws.
    public func compact<Map: OffsetMap>(into target: Database, offsetMap: inout Map) throws(XitDBError) {
        try engine.compact(into: target, offsetMap: &offsetMap)
    }

    /// Compacts the commit into a new database in `storage`, and returns
    /// it.
    ///
    /// - Throws: ``XitDBError/subCollectionSnapshot`` for a snapshot of a
    ///   sub-collection, before anything is written, and what
    ///   ``Database/compact(into:hashID:fileID:offsetMap:)`` throws.
    public func compact<Map: OffsetMap>(
        into storage: any WritableStorage,
        hashID: HashID? = nil,
        fileID: UInt64? = nil,
        offsetMap: inout Map
    ) throws(XitDBError) -> Database {
        try engine.compact(into: storage, hashID: hashID, fileID: fileID, offsetMap: &offsetMap)
    }
}

@available(*, unavailable, message: "a snapshot database is used from one thread at a time; the snapshot is Sendable")
extension SnapshotDatabase: Sendable {}
