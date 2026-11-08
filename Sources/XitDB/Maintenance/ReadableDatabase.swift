// The reading side of a database, shared by the live `Database` and a
// `SnapshotDatabase` (decision D26). It lives in this layer because it names
// the replication's `ReplicaState` and the compaction's `OffsetMap`, which
// are this layer's; the extension that types a read-only cursor's database
// with it is here for the same reason.

/// What a live ``Database`` and a ``SnapshotDatabase`` share: the root
/// cursor, the header and committed size, taking a snapshot, the reading
/// side of replication, and compaction into a target.
///
/// Code that only reads a database takes `some ReadableDatabase` and works
/// on either. The access of the root cursor is the type's own: a live
/// database's is read-write, a snapshot database's read-only, so a holder
/// who knows it has a reader can write `any ReadableDatabase<ReadOnly>` and
/// call ``rootCursor`` on it; on the plain `any ReadableDatabase`, which is
/// what a read-only cursor's `database` is, the root is reached
/// through ``snapshot()``.
///
/// Every member is as it is on ``Database``; nothing here writes.
public protocol ReadableDatabase<RootAccess>: AnyObject {
    /// The access of the root cursor: ``ReadWrite`` for a live database,
    /// ``ReadOnly`` for a snapshot's.
    associatedtype RootAccess: CursorAccess

    /// A cursor at the root, which every read starts from. On a live
    /// database it reads the last commit at the time of the read; on a
    /// snapshot's it reads the snapshot's commit.
    var rootCursor: Cursor<RootAccess> { get }

    /// The header at the start of the database: its file ID, hash size
    /// and hash ID.
    var header: DatabaseHeader { get }

    /// The number of bytes that belong to committed transactions.
    ///
    /// - Throws: What reading the root header throws on a live database;
    ///   a snapshot's never throws.
    var committedSize: UInt64 { get throws(XitDBError) }

    /// A snapshot of the last commit; of the one pinned, on a snapshot's
    /// database.
    ///
    /// - Throws: What ``Database/snapshot()`` throws; a snapshot's database
    ///   never throws.
    func snapshot() throws(XitDBError) -> Snapshot

    /// The database's ``ReplicaState``: its committed size and the checksum
    /// of the trailer that ends it.
    ///
    /// - Throws: What ``committedSize`` throws.
    var replicaState: ReplicaState { get throws(XitDBError) }

    /// Where a replica in `state` has to be synced from: the committed
    /// size it has if its trailer matches this database's, zero otherwise.
    ///
    /// - Throws: What ``Database/replicationStart(for:)`` throws.
    func replicationStart(for state: ReplicaState) throws(XitDBError) -> UInt64

    /// The committed bytes from `start` up to `end`, written to `sink`.
    ///
    /// - Throws: What ``Database/readCommitted(from:to:into:)-(_,_,Sink)``
    ///   throws.
    func readCommitted<Sink: ByteSink>(from start: UInt64, to end: UInt64, into sink: inout Sink)
        throws(XitDBError)

    /// The committed bytes from `start` up to `end`, appended to `bytes`.
    ///
    /// - Throws: What ``Database/readCommitted(from:to:into:)-(_,_,[UInt8])``
    ///   throws.
    func readCommitted(from start: UInt64, to end: UInt64, into bytes: inout [UInt8]) throws(XitDBError)

    /// The committed bytes from `start` up to `end`, in memory.
    ///
    /// - Throws: What ``Database/readCommitted(from:to:)`` throws.
    func readCommitted(from start: UInt64, to end: UInt64) throws(XitDBError) -> [UInt8]

    /// Compacts this database into `target`, a database whose root is
    /// empty.
    ///
    /// - Throws: What ``Database/compact(into:offsetMap:)`` throws.
    func compact<Map: OffsetMap>(into target: Database, offsetMap: inout Map) throws(XitDBError)

    /// Compacts this database into a new one in `storage`, and returns it.
    ///
    /// - Throws: What ``Database/compact(into:hashID:fileID:offsetMap:)``
    ///   throws.
    func compact<Map: OffsetMap>(
        into storage: any WritableStorage, hashID: HashID?, fileID: UInt64?, offsetMap: inout Map
    ) throws(XitDBError) -> Database
}

extension Database: ReadableDatabase {}

extension Cursor where Access == ReadOnly {
    /// The database the cursor reads from: the live ``Database`` for a
    /// cursor of one, the ``SnapshotDatabase`` for a cursor read from a
    /// snapshot. A read-only cursor may come from either, so this is the
    /// protocol's existential; a holder who needs the live type casts.
    ///
    /// The root is reached through `database.snapshot().rootCursor`, the
    /// root of a commit pinned at that moment: the one a reader wants, since
    /// a live database's root moves with every commit, and a snapshot's
    /// gives the same commit the cursor reads.
    public var database: any ReadableDatabase {
        if engine.readsSnapshot {
            return (engine.readingOwner as? SnapshotDatabase) ?? SnapshotDatabase(engine: engine)
        }
        return engine
    }
}
