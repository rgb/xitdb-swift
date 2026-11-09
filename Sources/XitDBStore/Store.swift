// The store: one per database, the hash its keys are hashed by, and the
// moments of the database's history as the layer sees them.

public import XitDB

/// The Swift layer's view of a database: keys as values, values as types,
/// and handles that name a place in a moment.
///
/// A store is made over a `Database` with the hash its keys are
/// hashed by, `SHA256.self` from `XitDBHashing` for most; the database's
/// header records the hash size, and a store whose hash has another size is
/// refused with `XitDBError.hashSizeMismatch` before anything is
/// read or written. The header's hash ID is not checked: it is a label the
/// creator of a database chooses, which the format does not interpret. The
/// database's root is the history, an array list of moments, each a hash
/// map; ``transaction(_:)`` appends a moment cloned from the latest and
/// lets the body write it, ``latest`` and ``moment(at:)`` read committed
/// ones. A store is not `Sendable`, as the database is not: other threads
/// read a snapshot through ``Moment/init(reading:hashing:)``.
public final class Store {
    /// The database underneath, for the faithful calls.
    public let database: Database

    /// The type of the hash the keys are hashed by.
    public let hashing: any KeyHashing.Type

    let hasher: KeyHasher

    /// Over a live database, with the hash its keys are hashed by.
    ///
    /// - Throws: `XitDBError.hashSizeMismatch` if the database's
    ///   header records a hash size other than the hash's.
    public init(_ database: Database, hashing: (some KeyHashing).Type) throws(XitDBError) {
        let hasher = KeyHasher(hashing)
        guard Int(database.header.hashSize) == hasher.size else { throw .hashSizeMismatch }
        self.database = database
        self.hashing = hashing
        self.hasher = hasher
    }

    /// Runs `body` with a new moment, cloned from the latest, and commits it
    /// when the body returns.
    ///
    /// The moment is writable for the body's duration and for nothing
    /// after it: a handle kept past the body refuses writes as a faithful
    /// cursor would, with `XitDBError.expectedTxStart` outside any
    /// transaction and `XitDBError.staleCursor` inside a later one, and reads
    /// through it read the moment as it was committed. The moment's map is
    /// made by its first write: a body that writes nothing commits a plain
    /// clone of the latest moment, or for the first moment an empty place,
    /// which reads as an empty map. An error thrown by the body rolls the
    /// moment back, and nothing of it remains. A transaction while another
    /// is in progress is refused with `XitDBError.nestedTopLevelWrite`. The
    /// result may be ignored: a transaction is often run for its writes
    /// alone, with a body whose one expression happens to have a value.
    @discardableResult
    public func transaction<Result>(_ body: (Moment) throws -> Result) throws -> Result {
        let hasher = hasher
        let database = database
        let history = try ArrayList<ReadOnly>(database.rootCursor)
        let count = try exactInt(try history.count)
        let previous = count > 0 ? try history.slot(at: -1) : nil
        // The faithful idiom, one path from the root: append a moment, clone
        // the latest into it and run the body with the cursor at it. That
        // cursor is the transaction's own, the one the engine lets go on
        // after a freeze, and every handle resolves from it.
        let path: InlineArray<4, PathPart> = [.arrayListInit, .arrayListAppend, .write(.slot(previous)), .ctx]
        var result: Result?
        _ = try database.rootCursor.writePath(path.span) { cursor in
            result = try body(Moment(base: .writing(cursor), database: database, hasher: hasher, index: count))
        }
        guard let result else { preconditionFailure("the body was not run") }
        return result
    }

    /// The last committed moment, read-only.
    ///
    /// - Throws: `XitDBError.indexOutOfRange` if nothing has been
    ///   committed yet.
    public var latest: Moment {
        get throws(XitDBError) {
            try moment(at: -1)
        }
    }

    /// A committed moment by its place in the history, counted from the
    /// end when negative, read-only. Inside a transaction the root reads
    /// the last commit, so the moment being written does not count and `-1`
    /// is the commit before it. A moment taken inside a transaction that
    /// then fails reads `XitDBError.staleCursor`, though its bytes are
    /// committed: the engine holds every cursor read during a failed
    /// transaction to be stale. Take it again.
    ///
    /// - Throws: `XitDBError.indexOutOfRange` if the history has no
    ///   such moment.
    public func moment(at index: Int) throws(XitDBError) -> Moment {
        let history = try ArrayList<ReadOnly>(database.rootCursor)
        let count = try exactInt(try history.count)
        let place = index < 0 ? count + index : index
        guard place >= 0, place < count, let cursor = try history.cursor(at: place) else { throw .indexOutOfRange }
        return Moment(base: .reading(cursor), database: database, hasher: hasher, index: place)
    }

    /// How many moments the history holds, the one a transaction is
    /// writing not counted.
    public var momentCount: Int {
        get throws(XitDBError) {
            try exactInt(try ArrayList<ReadOnly>(database.rootCursor).count)
        }
    }

    /// A snapshot of the latest commit, for reading on another thread
    /// through ``Moment/init(reading:hashing:)`` over a
    /// `SnapshotDatabase`.
    public func snapshot() throws(XitDBError) -> Snapshot {
        try database.snapshot()
    }
}

/// The store's hash as a value: its size and the hash of a key's bytes,
/// the hashing captured from the type while it was known.
struct KeyHasher: Sendable {
    let type: any KeyHashing.Type
    let size: Int
    private let digest: @Sendable ([UInt8]) -> [UInt8]

    init<Hash: KeyHashing>(_ type: Hash.Type) {
        self.type = type
        size = Hash.size
        digest = { Array(Hash.hash($0)) }
    }

    /// The hash of a key's bytes, as the database's hash size bytes.
    func hash(_ key: some KeyRepresentable) -> [UInt8] {
        digest(key.keyBytes)
    }
}

/// Where a moment's handles start from: a committed moment's element, read
/// only, or the element of the moment a transaction is writing, which is the
/// transaction's own cursor.
enum Root {
    case reading(Cursor<ReadOnly>)
    case writing(Cursor<ReadWrite>)
}

/// A count read from a file as an `Int`.
///
/// - Throws: `XitDBError.invalidCount` for a count the machine's `Int`
///   cannot hold, which no well-formed file has.
func exactInt(_ count: UInt64) throws(XitDBError) -> Int {
    guard let value = Int(exactly: count) else { throw .invalidCount }
    return value
}
