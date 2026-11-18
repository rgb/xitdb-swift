/// A database opened to be read, which has no writing members: what a
/// reader of a file that another database writes opens.
///
/// It reads as a live ``Database`` does. Every read through ``rootCursor``
/// looks at the storage again, so it sees the commits a writer has made
/// since, in this process or another, and everything reached from one root
/// comes from one commit. What it does not have is a way to write. Its
/// root cursor is a ``Cursor`` of ``ReadOnly`` access, so the collections
/// made from it are the read-only ones, and there is no transaction, no
/// freeze, no replication onto it and no recovery: a write that the
/// original refuses on a read-only file when the program runs does not
/// compile here.
///
/// ```swift
/// let storage = try ReadOnlyFileStorage(path: "main.db")
/// let database = try ReadOnlyDatabase(opening: storage, hashing: SHA256.self)
/// let list = try ArrayList(database.rootCursor)
/// ```
///
/// It is opened over any ``ReadableStorage``, so a storage of your own that
/// can only read is enough, and it never writes to the storage it is given,
/// whatever that storage could do. A reader of a file opens a
/// ``ReadOnlyFileStorage`` all the same: that is how a storage reads beside
/// a writer, with no lock, through a memory map included.
///
/// It serves what a ``Database`` serves to a reader, as
/// ``ReadableDatabase`` lists it: a ``Snapshot`` for other threads and
/// tasks, the reading side of replication, and compaction into a target.
/// Nothing it gives out is ever stale in the sense of
/// ``XitDBError/staleCursor``, since nothing runs a transaction on it.
///
/// Like ``Database``, it is not `Sendable`: it belongs to one thread or
/// task at a time, with every cursor, collection and iterator made from
/// it. Another task opens a storage and a database of its own, or reads a
/// snapshot.
public final class ReadOnlyDatabase: ReadableDatabase {
    /// The engine under this database: a `Database` over the storage, which
    /// nothing public writes through, since this type has no writing
    /// members and gives out read-only cursors alone.
    let engine: Database

    /// Opens the database in a storage, to be read.
    ///
    /// This opens what ``Database/init(opening:hashSize:)`` opens and
    /// refuses what that refuses, with the same errors: it reads and checks
    /// the header and then the root header, and writes nothing.
    ///
    /// - Parameters:
    ///   - storage: Where the database's bytes are. It is read and never
    ///     written. A storage that is no ``WritableStorage`` is read
    ///     through the protocol, and a ``snapshot()`` of a database in it
    ///     is a copy of the committed bytes, as it is for any storage of
    ///     the caller's own.
    ///   - hashSize: The size in bytes the database's hashes must have, or
    ///     `nil` to take whatever the database records.
    /// - Throws: What ``Database/init(opening:hashSize:)`` throws.
    public init(opening storage: any ReadableStorage, hashSize: Int? = nil) throws(XitDBError) {
        engine = try Database(
            opening: ReadOnlyDatabase.asTheEngineHoldsIt(storage), hashSize: hashSize,
            random: RandomSource(SystemRandomNumberGenerator()))
        engine.servesAReadOnlyDatabase = true
        engine.readingOwner = self
    }

    /// Opens the database in a storage, to be read, with the hasher of its
    /// keys.
    ///
    /// This is ``init(opening:hashSize:)`` with the hash size the hasher's,
    /// as ``Database/init(opening:hashing:)`` is of its own: the database
    /// holds the hasher from then on, as do its snapshots and the target
    /// ``compact(into:hashID:fileID:offsetMap:)`` makes.
    ///
    /// - Parameters:
    ///   - storage: Where the database's bytes are. It is read and never
    ///     written.
    ///   - hashing: The hash function of the database's keys. Its
    ///     ``KeyHashing/size`` must be the database's hash size.
    /// - Throws: What ``Database/init(opening:hashing:)`` throws.
    public init(opening storage: any ReadableStorage, hashing: (some KeyHashing).Type) throws(XitDBError) {
        engine = try Database(
            opening: ReadOnlyDatabase.asTheEngineHoldsIt(storage), hashSize: nil,
            random: RandomSource(SystemRandomNumberGenerator()), hasher: KeyHasher(hashing))
        engine.servesAReadOnlyDatabase = true
        engine.readingOwner = self
    }

    /// A database over the engine a read-only cursor holds, when the one it
    /// was made with has gone.
    init(engine: Database) {
        self.engine = engine
        engine.readingOwner = self
    }

    /// The storage as the engine holds one: the file storage a
    /// ``ReadOnlyFileStorage`` is the face of, which is in its reading
    /// mode; the storage itself where it is a ``WritableStorage``, as the
    /// package's writing storages are; and otherwise behind a class whose
    /// writes refuse. So each of the package's storages reaches the engine
    /// by its class.
    private static func asTheEngineHoldsIt(_ storage: any ReadableStorage) -> any WritableStorage {
        if let reading = storage as? ReadOnlyFileStorage { return reading.file }
        return (storage as? any WritableStorage) ?? ReadingStorage(storage)
    }

    /// A read-only cursor at the root, which every read starts from.
    ///
    /// Everything read through it comes from the last commit, whichever
    /// that is at the time of the read. Each access gives a new cursor,
    /// which costs one read of the root header.
    public var rootCursor: Cursor<ReadOnly> {
        Cursor(viewing: engine.rootCursor)
    }

    /// The header at the start of the database: its file ID, hash size and
    /// hash ID, and the version of the file format, as they were read when
    /// the database was opened.
    public var header: DatabaseHeader {
        engine.header
    }

    /// The number of bytes that belong to committed transactions, at the
    /// time of the call.
    ///
    /// - Throws: What ``Database/committedSize`` throws.
    public var committedSize: UInt64 {
        get throws(XitDBError) {
            try engine.committedSize
        }
    }

    /// Takes a snapshot of the last commit, as ``Database/snapshot()``
    /// does, with what it costs on each kind of storage.
    ///
    /// - Throws: What ``Database/snapshot()`` throws.
    public func snapshot() throws(XitDBError) -> Snapshot {
        try engine.snapshot()
    }

    /// The database's ``ReplicaState`` at the time of the call: its
    /// committed size and the checksum of the trailer that ends it.
    ///
    /// - Throws: What ``Database/replicaState`` throws.
    public var replicaState: ReplicaState {
        get throws(XitDBError) {
            try engine.replicaState
        }
    }

    /// Where a replica in `state` has to be synced from.
    ///
    /// - Throws: What ``Database/replicationStart(for:)`` throws.
    public func replicationStart(for state: ReplicaState) throws(XitDBError) -> UInt64 {
        try engine.replicationStart(for: state)
    }

    /// The committed bytes from `start` up to `end`, written to `sink`.
    ///
    /// - Throws: What ``Database/readCommitted(from:to:into:)-(_,_,Sink)``
    ///   throws.
    public func readCommitted<Sink: ByteSink>(from start: UInt64, to end: UInt64, into sink: inout Sink)
        throws(XitDBError)
    {
        try engine.readCommitted(from: start, to: end, into: &sink)
    }

    /// The committed bytes from `start` up to `end`, appended to `bytes`.
    ///
    /// - Throws: What ``Database/readCommitted(from:to:into:)-(_,_,[UInt8])``
    ///   throws.
    public func readCommitted(from start: UInt64, to end: UInt64, into bytes: inout [UInt8]) throws(XitDBError) {
        try engine.readCommitted(from: start, to: end, into: &bytes)
    }

    /// The committed bytes from `start` up to `end`, in memory.
    ///
    /// - Throws: What ``Database/readCommitted(from:to:)`` throws.
    public func readCommitted(from start: UInt64, to end: UInt64) throws(XitDBError) -> [UInt8] {
        try engine.readCommitted(from: start, to: end)
    }

    /// Compacts the database into `target`, a live database whose root is
    /// empty. This database's storage is read and not written.
    ///
    /// - Throws: What ``Database/compact(into:offsetMap:)`` throws.
    public func compact<Map: OffsetMap>(into target: Database, offsetMap: inout Map) throws(XitDBError) {
        try engine.compact(into: target, offsetMap: &offsetMap)
    }

    /// Compacts the database into a new one in `storage`, and returns it.
    /// This database's storage is read and not written; the one returned
    /// is a ``Database``, open for reading and writing.
    ///
    /// - Throws: What ``Database/compact(into:hashID:fileID:offsetMap:)``
    ///   throws.
    public func compact<Map: OffsetMap>(
        into storage: any WritableStorage,
        hashID: HashID? = nil,
        fileID: UInt64? = nil,
        offsetMap: inout Map
    ) throws(XitDBError) -> Database {
        try engine.compact(into: storage, hashID: hashID, fileID: fileID, offsetMap: &offsetMap)
    }
}

@available(*, unavailable, message: "a database is used from one thread or task at a time; send a snapshot of it")
extension ReadOnlyDatabase: Sendable {}

/// A storage that can only be read, as the engine holds a storage: its
/// reads are the storage's, and its writes refuse, as a backstop that
/// nothing public reaches, since the one type that makes it has no writing
/// members.
private final class ReadingStorage: WritableStorage {
    private let storage: any ReadableStorage

    init(_ storage: any ReadableStorage) {
        self.storage = storage
    }

    func read(into buffer: inout MutableSpan<UInt8>, range: Range<Int>, at offset: UInt64) throws(XitDBError) -> Int {
        try storage.read(into: &buffer, range: range, at: offset)
    }

    var length: UInt64 {
        get throws(XitDBError) {
            try storage.length
        }
    }

    func write(_ bytes: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        throw .cursorNotWritable
    }

    func truncate(to length: UInt64) throws(XitDBError) {
        throw .cursorNotWritable
    }

    func flush() throws(XitDBError) {
        throw .cursorNotWritable
    }

    func sync(_ point: SyncPoint) throws(XitDBError) {
        throw .cursorNotWritable
    }
}
