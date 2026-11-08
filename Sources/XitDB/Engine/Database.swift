/// A XitDB database: an immutable, append-only store of nested collections,
/// kept in one storage.
///
/// A database never changes bytes it has committed. A write copies what it
/// touches to the end of the storage and commits by appending a trailer that
/// names the new root and then rewriting the small root header at the start
/// to point at it. Everything committed before stays readable, which is what
/// makes every past state of a database available and copying one free.
///
/// Reading and writing start from ``rootCursor``.
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

    /// The number of the transaction in progress, or of the last one when
    /// none is: transactions are numbered from one as they start. A cursor
    /// records it when it is made, which is how a write through a cursor
    /// from an earlier transaction is told from one made in this one.
    private(set) var transactionNumber: UInt64 = 0

    /// How many times a transaction has frozen so far: ``freeze()`` and a
    /// concat, each once, counted across transactions. A cursor records it
    /// when it is made; a write through a cursor made before a freeze is
    /// refused, since what it would write in place may be shared since.
    private(set) var freezeNumber: UInt64 = 0

    /// The numbers of the transactions that did not commit, as ranges, so
    /// that a read through a cursor made in one of them can be refused: its
    /// bytes were truncated and the offsets reused. Consecutive numbers
    /// share a range, so this grows by one range per commit that a failure
    /// follows, far less than the file does.
    private var failedTransactions: [ClosedRange<UInt64>] = []

    /// How many writes the engine has issued to the storage, counted so
    /// that an operation can tell whether it wrote anything before it
    /// failed, which poisons the transaction. An init part writing its own
    /// slot back unchanged is not counted.
    private(set) var writesIssued: UInt64 = 0

    /// Whether the transaction in progress is poisoned: an operation in it
    /// failed after it had written to the storage. Every further write and
    /// the commit fail with ``XitDBError/poisonedTransaction``.
    private(set) var poisoned = false

    /// The source of the file ID of a new database and of every commit ID,
    /// shared with the target a compaction opens.
    let random: RandomSource

    /// Opens the database in a storage.
    ///
    /// - Parameters:
    ///   - storage: Where the database's bytes are. The database becomes
    ///     the only writer to it.
    ///   - hashSize: The size in bytes the database's hashes must have, or
    ///     `nil` to take whatever the database records. Give it when the
    ///     keys come from one algorithm, such as 20 for SHA-1, so that a
    ///     database hashed another way is refused at once.
    /// - Throws: ``XitDBError/invalidDatabase`` if the storage is empty or
    ///   does not hold a database, or the database's last commit does not
    ///   check out; ``XitDBError/invalidVersion`` if it was written in a
    ///   version of the format this implementation does not read;
    ///   ``XitDBError/invalidHashSize`` if `hashSize` was given and is not
    ///   the database's; ``XitDBError/truncatedDatabase`` if the storage is
    ///   shorter than the database says it is; ``XitDBError/endOfStream``
    ///   if it is too short to hold a header; and
    ///   ``XitDBError/storageFailure(errno:)`` if the storage fails.
    public convenience init(opening storage: any WritableStorage, hashSize: Int? = nil) throws(XitDBError) {
        try self.init(opening: storage, hashSize: hashSize, random: RandomSource(SystemRandomNumberGenerator()))
    }

    /// Creates a database in an empty storage.
    ///
    /// - Parameters:
    ///   - storage: Where the database's bytes go. It must be empty, and
    ///     the database becomes the only writer to it.
    ///   - hashSize: The size in bytes of every hash in the database, such
    ///     as 20 for SHA-1: from 1 to 65535.
    ///   - hashID: An identifier of the hash algorithm, recorded in the
    ///     header for whoever reads the file. XitDB never interprets it.
    ///   - fileID: The database's file ID. Left out, a random one is chosen,
    ///     which is what a database should normally have.
    /// - Throws: ``XitDBError/storageNotEmpty`` if the storage holds any
    ///   bytes; ``XitDBError/invalidHashSize`` if `hashSize` is 0 or more
    ///   than 65535; and ``XitDBError/storageFailure(errno:)`` if the
    ///   storage fails.
    public convenience init(
        creating storage: any WritableStorage,
        hashSize: Int,
        hashID: HashID? = nil,
        fileID: UInt64? = nil
    ) throws(XitDBError) {
        try self.init(
            creating: storage, hashSize: hashSize, hashID: hashID, fileID: fileID,
            random: RandomSource(SystemRandomNumberGenerator()))
    }

    /// Opens or creates a database, as Zig's `DB.init` does: a hash size on
    /// an empty storage creates. For the ported tests, which follow Zig's
    /// shape, and with a source of randomness of the caller's, so that a
    /// test can fix the file ID and the commit IDs and compare whole files.
    package convenience init(
        storage: any WritableStorage,
        hashSize: UInt16?,
        hashID: HashID? = nil,
        fileID: UInt64? = nil,
        random: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) throws(XitDBError) {
        try self.init(
            storage: storage, hashSize: hashSize, hashID: hashID, fileID: fileID, random: RandomSource(random))
    }

    /// Opens or creates a database, as above, drawing from a source another
    /// database draws from: what a compaction opens its target with.
    package convenience init(
        storage: any WritableStorage,
        hashSize: UInt16?,
        hashID: HashID? = nil,
        fileID: UInt64? = nil,
        random: RandomSource
    ) throws(XitDBError) {
        if try storage.length == 0 {
            guard let hashSize else { throw .invalidHashSize }
            try self.init(creating: storage, hashSize: Int(hashSize), hashID: hashID, fileID: fileID, random: random)
        } else {
            try self.init(opening: storage, hashSize: hashSize.map { Int($0) }, random: random)
        }
    }

    /// Opens a database with a given source of randomness for its commit
    /// IDs.
    package convenience init(opening storage: any WritableStorage, hashSize: Int?, random: any RandomNumberGenerator)
        throws(XitDBError)
    {
        try self.init(opening: storage, hashSize: hashSize, random: RandomSource(random))
    }

    /// Opens a database drawing its commit IDs from a source another
    /// database draws from.
    ///
    /// - Throws: What ``init(opening:hashSize:)`` throws.
    package init(opening storage: any WritableStorage, hashSize: Int?, random: RandomSource) throws(XitDBError) {
        var buffer = InlineArray<20, UInt8>(repeating: 0)
        var span = buffer.mutableSpan
        let read = try storage.read(into: &span, at: 0)
        if read == 0 { throw .invalidDatabase }
        let header = try DatabaseHeader(decoding: buffer.span.extracting(0..<read))
        if let hashSize, Int(header.hashSize) != hashSize { throw .invalidHashSize }

        self.storage = storage
        identity = DatabaseIdentity(header: header)
        self.reader = DatabaseReader(storage: storage, identity: identity)
        self.transactionStart = nil
        self.random = random
        _ = try reader.committedSize
    }

    /// Creates a database with a given source of randomness for its file ID
    /// and commit IDs.
    package convenience init(
        creating storage: any WritableStorage,
        hashSize: Int,
        hashID: HashID?,
        fileID: UInt64?,
        random: any RandomNumberGenerator
    ) throws(XitDBError) {
        try self.init(
            creating: storage, hashSize: hashSize, hashID: hashID, fileID: fileID, random: RandomSource(random))
    }

    /// Creates a database drawing its file ID, when none is given, and its
    /// commit IDs from a source another database draws from, in that
    /// order: the file ID is drawn here, before the first commit, whose ID
    /// is zero.
    ///
    /// - Throws: What ``init(creating:hashSize:hashID:fileID:)`` throws.
    package init(
        creating storage: any WritableStorage,
        hashSize: Int,
        hashID: HashID?,
        fileID: UInt64?,
        random: RandomSource
    ) throws(XitDBError) {
        guard try storage.length == 0 else { throw .storageNotEmpty }
        guard let hashSize = UInt16(exactly: hashSize), hashSize > 0 else { throw .invalidHashSize }
        let header = DatabaseHeader(
            fileID: fileID ?? random.next(),
            hashID: hashID ?? HashID(rawValue: 0),
            hashSize: hashSize
        )

        self.storage = storage
        identity = DatabaseIdentity(header: header)
        self.reader = DatabaseReader(storage: storage, identity: identity)
        self.transactionStart = nil
        self.random = random

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
    public var committedSize: UInt64 {
        get throws(XitDBError) {
            try reader.committedSize
        }
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
    /// The caller's part, as in Zig: finish any
    /// ``Cursor/writeBytes(formatTag:_:)`` before freezing, since a byte
    /// array grows only while it is the last thing written; and afterwards
    /// make writable collections again, and take nested write cursors
    /// again from the transaction's root cursor, before writing through
    /// them. A collection or cursor made before the freeze still points
    /// into data that is now frozen, and a write through it changes that
    /// data in place, as if nothing had been frozen: it is a collection's
    /// init that copies its header or first block into the transaction,
    /// and the path from the root that copies the blocks on the way.
    ///
    /// - Throws: ``XitDBError/expectedTxStart`` outside a transaction.
    public func freeze() throws(XitDBError) {
        guard transactionStart != nil else { throw .expectedTxStart }
        transactionStart = try storage.length
        noteFreeze()
    }

    // MARK: Transactions and the cursors made in them

    /// The transaction number a cursor made now records: the transaction in
    /// progress, or zero outside any.
    var cursorTransaction: UInt64 {
        transactionStart == nil ? 0 : transactionNumber
    }

    /// Counts a freeze of the transaction in progress: ``freeze()`` or a
    /// concat.
    func noteFreeze() {
        freezeNumber &+= 1
    }

    /// Starts the next transaction: numbers it and clears the poison.
    func beginTransaction() {
        transactionNumber &+= 1
        poisoned = false
    }

    /// Records that the transaction in progress did not commit.
    func recordFailedTransaction() {
        let number = transactionNumber
        if let last = failedTransactions.last, last.upperBound &+ 1 == number {
            failedTransactions[failedTransactions.count - 1] = last.lowerBound...number
        } else {
            failedTransactions.append(number...number)
        }
    }

    /// Whether the transaction with this number ended without committing.
    func transactionFailed(_ number: UInt64) -> Bool {
        var low = 0
        var high = failedTransactions.count
        while low < high {
            let middle = (low + high) / 2
            let range = failedTransactions[middle]
            if number < range.lowerBound {
                high = middle
            } else if number > range.upperBound {
                low = middle + 1
            } else {
                return true
            }
        }
        return false
    }

    /// Marks the transaction in progress as poisoned: an operation failed
    /// after writing.
    func poison() {
        if transactionStart != nil { poisoned = true }
    }

    /// Counts a write the engine issued to the storage.
    func noteWrite() {
        writesIssued &+= 1
    }

    /// Writes a slot back from an init part, which always writes its slot:
    /// one that is unchanged does not count as a write of the transaction's.
    func writeSlot(_ slot: Slot, at position: UInt64, unchangedFrom old: Slot) throws(XitDBError) {
        let bytes = InlineArray<9, UInt8> { (output: inout OutputSpan<UInt8>) in slot.encode(into: &output) }
        try storage.write(bytes.span, at: position)
        if slot != old { noteWrite() }
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
        noteWrite()

        // Rewriting the header is what completes the transaction. The data
        // must be on the disk first: otherwise a crash could leave a header
        // that points at data which never arrived.
        try storage.sync(.beforeRootHeader)

        let rootHeader = RootHeader(root: root, fileSize: try storage.length)
        let rootHeaderBytes = InlineArray<17, UInt8> { (output: inout OutputSpan<UInt8>) in
            rootHeader.encode(into: &output)
        }
        try storage.write(rootHeaderBytes.span, at: RootHeader.position)
        noteWrite()
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
        let committedSize = try reader.committedSize
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
        noteWrite()
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
        noteWrite()
    }

    func write(_ value: UInt64, at position: UInt64) throws(XitDBError) {
        let bytes = InlineArray<8, UInt8> { (output: inout OutputSpan<UInt8>) in
            output.appendBigEndian(value)
        }
        try storage.write(bytes.span, at: position)
        noteWrite()
    }

    func write(_ header: ArrayListHeader, at position: UInt64) throws(XitDBError) {
        let bytes = InlineArray<16, UInt8> { (output: inout OutputSpan<UInt8>) in
            header.encode(into: &output)
        }
        try storage.write(bytes.span, at: position)
        noteWrite()
    }

    /// Writes an index block of empty slots.
    func writeEmptyIndexBlock(at position: UInt64) throws(XitDBError) {
        let block = InlineArray<144, UInt8>(repeating: 0)
        try storage.write(block.span, at: position)
        noteWrite()
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
            noteWrite()
        } else {
            let record = hash.withBytes { (hashBytes: Span<UInt8>) in
                [UInt8](capacity: size) { (output: inout OutputSpan<UInt8>) in
                    pair.encodeHashed(hash: hashBytes, into: &output)
                }
            }
            try storage.write(record.span, at: position)
            noteWrite()
        }
    }
}

/// The source of a database's file ID and commit IDs, which the target of
/// a compaction shares with its source, as Zig's target is opened with the
/// source's `io`: the target draws its file ID, when none is given, and
/// then its commit IDs from the same generator, continuing where it is.
/// A box, so that a generator with state advances for both.
package final class RandomSource {
    private var generator: any RandomNumberGenerator

    /// A source over a generator of the caller's, or the system's.
    package init(_ generator: any RandomNumberGenerator) {
        self.generator = generator
    }

    /// The next value.
    package func next() -> UInt64 {
        generator.next()
    }
}
