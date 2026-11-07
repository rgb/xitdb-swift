/// A XitDB database: an immutable, append-only store of nested collections,
/// kept in one storage.
///
/// A database never changes bytes it has committed. A write copies what it
/// touches to the end of the storage and commits by appending a trailer that
/// names the new root and then rewriting the small root header at the start
/// to point at it. Everything committed before stays readable, which is what
/// makes every past state of a database available and copying one free.
///
/// Reading and writing start from ``rootCursor()``.
///
/// A database is not `Sendable`. It belongs to one thread or task at a time.
/// Only one database at a time may write to a storage; any number may read
/// from it, through storages of their own.
public final class Database {
    /// Where the database's bytes are kept.
    let storage: any WritableStorage

    /// The read side of the engine over this database's storage.
    let reader: DatabaseReader

    /// The header, in the box the reader shares. A class's stored `var` is
    /// read through a dynamic exclusivity check; the reader is used on every
    /// node read, so it is a `let`, and the one thing a replication from
    /// zero replaces, the header, lives here and is read once per use.
    private let identity: DatabaseIdentity

    /// The header at the start of the database: its file ID, hash size and
    /// hash ID, and the version of the file format. A replication from
    /// zero replaces it with the source's.
    public var header: DatabaseHeader { identity.header }

    /// Where the transaction in progress started, or `nil` between
    /// transactions.
    ///
    /// Everything at or after this position was written by the transaction
    /// and may be changed in place. Everything before it is committed and is
    /// copied before it is changed.
    var transactionStart: UInt64?

    /// The number of commits this object has made. A write looks at it
    /// before and after, to know whether it committed anything.
    private(set) var commitCount: UInt64 = 0

    /// The source of the file ID of a new database and of every commit ID.
    private var random: any RandomNumberGenerator

    /// Opens the database in a storage, or creates one if the storage is
    /// empty.
    ///
    /// - Parameters:
    ///   - storage: Where the database's bytes are kept. The database
    ///     becomes the only writer to it.
    ///   - hashSize: The size in bytes of every hash in the database, such
    ///     as 20 for SHA-1. It is required to create a database. To open
    ///     one it can be left out, in which case the size recorded in the
    ///     database is used.
    ///   - hashID: For a new database, an identifier of the hash algorithm
    ///     to record in its header. XitDB never interprets it.
    ///   - fileID: For a new database, its file ID. Left out, a random one
    ///     is chosen, which is what a database should normally have.
    /// - Throws: For an empty storage, ``XitDBError/invalidHashSize`` if no
    ///   hash size was given. For an existing database,
    ///   ``XitDBError/invalidDatabase`` if the storage does not hold a
    ///   database or its last commit does not check out,
    ///   ``XitDBError/invalidVersion`` if it was written in a version of the
    ///   format this implementation does not read,
    ///   ``XitDBError/invalidHashSize`` if `hashSize` was given and differs
    ///   from the database's, ``XitDBError/truncatedDatabase`` if the
    ///   storage is shorter than the database says it is, and
    ///   ``XitDBError/endOfStream`` if it is too short to hold a header.
    ///   Either way, ``XitDBError/storageFailure(errno:)`` if the storage
    ///   fails.
    public convenience init(
        storage: any WritableStorage,
        hashSize: UInt16? = nil,
        hashID: HashID? = nil,
        fileID: UInt64? = nil
    ) throws(XitDBError) {
        try self.init(
            storage: storage,
            hashSize: hashSize,
            hashID: hashID,
            fileID: fileID,
            random: SystemRandomNumberGenerator()
        )
    }

    /// Opens or creates a database with a given source of randomness, so
    /// that tests can fix the file ID and the commit IDs and compare whole
    /// files.
    package init(
        storage: any WritableStorage,
        hashSize: UInt16?,
        hashID: HashID?,
        fileID: UInt64?,
        random: any RandomNumberGenerator
    ) throws(XitDBError) {
        var random = random
        let isNew = try storage.length == 0
        let header: DatabaseHeader
        if isNew {
            guard let hashSize else { throw .invalidHashSize }
            header = DatabaseHeader(
                fileID: fileID ?? random.next(),
                hashID: hashID ?? HashID(id: 0),
                hashSize: hashSize
            )
        } else {
            var buffer = InlineArray<20, UInt8>(repeating: 0)
            var span = buffer.mutableSpan
            let read = try storage.read(into: &span, at: 0)
            header = try DatabaseHeader(decoding: buffer.span.extracting(0..<read))
            if let hashSize, header.hashSize != hashSize { throw .invalidHashSize }
        }

        self.storage = storage
        identity = DatabaseIdentity(header: header)
        self.reader = DatabaseReader(storage: storage, identity: identity)
        self.transactionStart = nil
        self.random = random

        if isNew {
            let headerBytes = InlineArray<20, UInt8> { (output: inout OutputSpan<UInt8>) in
                header.encode(into: &output)
            }
            try storage.write(headerBytes.span, at: 0)
            // The root header, and a commit of an empty root, so that the
            // file ends with a trailer as it does after any transaction.
            let emptyRootHeader = InlineArray<17, UInt8>(repeating: 0)
            try storage.write(emptyRootHeader.span, at: RootHeader.position)
            // The first commit's ID is zero, so a new database's bytes
            // depend only on its header.
            try commitRoot(Slot(), commitID: 0)
            try storage.sync(.afterRootHeader)
        } else {
            _ = try reader.committedSize()
        }
    }

    /// The number of bytes that belong to committed transactions.
    ///
    /// Bytes beyond this, if the storage has any, are what an unfinished
    /// transaction left. They are discarded when the next one starts.
    ///
    /// - Throws: ``XitDBError/invalidDatabase``,
    ///   ``XitDBError/truncatedDatabase`` or
    ///   ``XitDBError/storageFailure(errno:)`` if the storage no longer
    ///   holds a database that checks out.
    public func committedSize() throws(XitDBError) -> UInt64 {
        try reader.committedSize()
    }

    /// Makes everything the transaction in progress has written so far
    /// immutable, as if it had been committed: later writes copy it instead
    /// of changing it in place.
    ///
    /// Within a transaction, data the transaction created is changed in
    /// place, because nothing committed can refer to it. That stops being
    /// safe once a slot has been copied to a second place: both places then
    /// name the same data, and a change through one shows through the
    /// other. Freezing after the copy makes them independent.
    ///
    /// - Throws: ``XitDBError/expectedTxStart`` outside a transaction.
    public func freeze() throws(XitDBError) {
        guard transactionStart != nil else { throw .expectedTxStart }
        transactionStart = try storage.length
    }

    // MARK: Commit and rollback

    /// The next value from the random source: a commit ID.
    func nextCommitID() -> UInt64 {
        random.next()
    }

    /// Completes a transaction by appending a trailer for `root` and
    /// rewriting the root header to point at it. The caller syncs afterwards
    /// to make the header itself durable.
    func commitRoot(_ root: Slot, commitID: UInt64) throws(XitDBError) {
        let trailerPosition = try storage.length
        let trailer = RootTrailer(fileID: header.fileID, position: trailerPosition, root: root, commitID: commitID)
        let trailerBytes = InlineArray<25, UInt8> { (output: inout OutputSpan<UInt8>) in
            trailer.encode(into: &output)
        }
        try storage.write(trailerBytes.span, at: trailerPosition)

        // Rewriting the header is what completes the transaction. The data
        // must be on the disk first: otherwise a crash could leave a header
        // that points at data which never arrived.
        try storage.sync(.beforeRootHeader)

        let rootHeader = RootHeader(root: root, fileSize: try storage.length)
        let rootHeaderBytes = InlineArray<17, UInt8> { (output: inout OutputSpan<UInt8>) in
            rootHeader.encode(into: &output)
        }
        try storage.write(rootHeaderBytes.span, at: RootHeader.position)
        commitCount &+= 1
    }

    /// Makes this object the database its storage now holds, after a
    /// replication from zero replaced the bytes: the header and the reader
    /// take the new file ID.
    func become(_ newHeader: DatabaseHeader) {
        identity.header = newHeader
    }

    /// Discards whatever lies beyond the committed size: what a transaction
    /// that failed, or a process that died, left behind.
    func truncate() throws(XitDBError) {
        let committedSize = try reader.committedSize()
        if try storage.length > committedSize {
            try storage.truncate(to: committedSize)
        }
    }

    // MARK: Copy-on-write

    /// Whether the data at `position` must be copied before it is changed:
    /// it was written before this transaction, or before the writing
    /// cursor's freeze point.
    ///
    /// - Throws: `expectedTxStart` outside a transaction.
    func isOld(_ position: UInt64, frozenAt: UInt64) throws(XitDBError) -> Bool {
        guard let transactionStart else { throw .expectedTxStart }
        return position < max(transactionStart, frozenAt)
    }

    /// Copies an index block to the end of the storage, unless this
    /// transaction made it, and returns where the block now is.
    func copyIndexBlockIfOld(_ position: UInt64, frozenAt: UInt64) throws(XitDBError) -> UInt64 {
        if !(try isOld(position, frozenAt: frozenAt)) { return position }
        let block = try reader.indexBlockBytes(at: position)
        let copyPosition = try storage.length
        try storage.write(block.span, at: copyPosition)
        return copyPosition
    }

    // MARK: Writing records

    // The engine writes only inside the storage or at its end. Every
    // position it writes at is either the storage's current length or a
    // position at which it has just read the record it is about to replace,
    // so no content of a file can send a write somewhere else. (The one
    // exception is the byte writer's seek, which is the caller's own
    // request.) This matters because a memory storage without a size limit
    // has to allocate all the way to wherever it is asked to write.

    func write(_ slot: Slot, at position: UInt64) throws(XitDBError) {
        let bytes = InlineArray<9, UInt8> { (output: inout OutputSpan<UInt8>) in
            slot.encode(into: &output)
        }
        try storage.write(bytes.span, at: position)
    }

    func write(_ value: UInt64, at position: UInt64) throws(XitDBError) {
        let bytes = InlineArray<8, UInt8> { (output: inout OutputSpan<UInt8>) in
            output.appendBigEndian(value)
        }
        try storage.write(bytes.span, at: position)
    }

    func write(_ header: ArrayListHeader, at position: UInt64) throws(XitDBError) {
        let bytes = InlineArray<16, UInt8> { (output: inout OutputSpan<UInt8>) in
            header.encode(into: &output)
        }
        try storage.write(bytes.span, at: position)
    }

    /// Writes an index block of empty slots.
    func writeEmptyIndexBlock(at position: UInt64) throws(XitDBError) {
        let block = InlineArray<144, UInt8>(repeating: 0)
        try storage.write(block.span, at: position)
    }

    /// Writes a hashed key-value pair record: the hash, the key slot, the
    /// value slot.
    func write(_ pair: KeyValuePair, hash: KeyHash, at position: UInt64) throws(XitDBError) {
        let size = hash.count + 18
        if size <= 82 {
            // The record is built in the buffer it is written from, with a
            // copy for the hash and one store for each slot's value. Filled
            // a byte at a time and then moved, it was the slowest line of an
            // insert.
            var record = InlineArray<82, UInt8>(repeating: 0)
            var bytes = record.mutableSpan
            hash.copyBytes(into: &bytes)
            pair.keySlot.encode(into: &bytes, at: hash.count)
            pair.valueSlot.encode(into: &bytes, at: hash.count + 9)
            try storage.write(record.span.extracting(0..<size), at: position)
        } else {
            let record = hash.withBytes { (hashBytes: Span<UInt8>) in
                [UInt8](capacity: size) { (output: inout OutputSpan<UInt8>) in
                    pair.encodeHashed(hash: hashBytes, into: &output)
                }
            }
            try storage.write(record.span, at: position)
        }
    }
}
