// A moment: one entry of the history, the hash map everything hangs from.

public import XitDB

/// One moment of a database's history: a hash map at the root, read-only
/// unless it is the one a ``Store/transaction(_:)`` is writing.
///
/// A moment made by ``Store/latest`` or ``Store/moment(at:)`` reads a
/// commit; one made by ``init(reading:hashing:)`` reads the latest commit of
/// any reading database, a `SnapshotDatabase` on another thread
/// included, and keeps that database alive for as long as it lives. A
/// read-only moment reads committed bytes, which nothing moves, so its
/// handles keep what they resolve for good. Handles descend from ``root``
/// or through the subscript.
public struct Moment {
    let base: Root
    /// The database the moment reads, kept so that a snapshot's database
    /// outlives the moment's handles.
    let database: any ReadableDatabase
    let hasher: KeyHasher
    let shared: Handle.SharedCache?

    /// The moment's place in the history.
    public let index: Int

    init(base: Root, database: any ReadableDatabase, hasher: KeyHasher, index: Int) {
        self.base = base
        self.database = database
        self.hasher = hasher
        self.index = index
        if case .writing = base {
            shared = Handle.SharedCache()
        } else {
            shared = nil
        }
    }

    /// The latest committed moment of a reading database, with the hash its
    /// keys are hashed by: a snapshot's database on another thread, or a
    /// live database for its last commit.
    ///
    /// - Throws: `XitDBError.hashSizeMismatch` if the database's
    ///   header records a hash size other than the hash's,
    ///   `XitDBError.indexOutOfRange` if nothing has been committed.
    public init(reading database: some ReadableDatabase, hashing: (some KeyHashing).Type) throws(XitDBError) {
        let hasher = KeyHasher(hashing)
        guard Int(database.header.hashSize) == hasher.size else { throw .hashSizeMismatch }
        let history = try ArrayList<ReadOnly>(database.rootCursor)
        let count = try exactInt(try history.count)
        guard count > 0, let cursor = try history.cursor(at: count - 1) else { throw .indexOutOfRange }
        self.init(base: .reading(cursor), database: database, hasher: hasher, index: count - 1)
    }

    /// Whether this is the moment a transaction is writing.
    public var isWritable: Bool {
        if case .writing = base { return true }
        return false
    }

    /// The handle of the moment's map itself.
    public var root: Handle {
        Handle(base: base, hasher: hasher, steps: [], shared: shared)
    }

    /// The handle one level down, through the root map, for a key.
    public subscript(key: some KeyRepresentable) -> Handle {
        root[key]
    }
}
