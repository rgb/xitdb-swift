/// Whether a cursor can write. The two kinds are ``ReadOnly`` and
/// ``ReadWrite``.
public protocol CursorAccess {}

/// The access of a cursor that can only read.
public enum ReadOnly: CursorAccess {}

/// The access of a cursor that can read and write.
public enum ReadWrite: CursorAccess {}

/// A position in a database: one slot, and what it held when the cursor was
/// made.
///
/// A cursor is a value. Copying one gives two cursors that no longer affect
/// each other.
///
/// **A cursor holds a snapshot.** It remembers the slot as it was when the
/// cursor was made, or when something was last written through it. Reads go
/// by that snapshot, and do not notice if the slot has been written through
/// another cursor since. The exception is a cursor at the root of the
/// database, from ``Database/rootCursor``: every read through it looks up
/// the root of the last commit.
///
/// Writing is only possible inside a transaction. A write through a root
/// cursor is a transaction of its own; a write through any other cursor
/// fails with ``XitDBError/expectedTxStart`` unless a transaction is in
/// progress.
public struct Cursor<Access: CursorAccess> {
    /// The cursor's slot and its position. A position of `nil` means the
    /// slot cannot be written through this cursor.
    var slotPointer: SlotPointer

    /// The database the cursor reads from and writes to: where a helper
    /// given only a cursor reaches the root, or freezes.
    public let database: Database

    /// The freeze point: writes through this cursor copy any data written
    /// before this position, even data from the current transaction. Zero
    /// when there is none.
    var frozenAt: UInt64

    init(slotPointer: SlotPointer, database: Database, frozenAt: UInt64 = 0) {
        self.slotPointer = slotPointer
        self.database = database
        self.frozenAt = frozenAt
    }

    /// Whether this is a cursor at the root of the database.
    var isRoot: Bool {
        slotPointer.position == RootHeader.position
    }

    /// The slot this cursor reads from. A root cursor only has a snapshot of
    /// the root, which goes stale with the next transaction, so it reads the
    /// root again each time. Everything that reads the slot goes through
    /// this.
    func resolved() throws(XitDBError) -> SlotPointer {
        if isRoot {
            return try database.reader.resolvedRoot()
        }
        return slotPointer
    }

    // MARK: Paths

    /// Follows a path from this cursor without writing.
    ///
    /// - Returns: A cursor at the slot the path arrives at, or `nil` if
    ///   something on the way does not exist, an index names no element,
    ///   or that slot is empty.
    package func readPath(_ path: Span<PathPart>) throws(XitDBError) -> Cursor<ReadOnly>? {
        do throws(XitDBError) {
            let pointer = try database.reader.readSlotPointer(path, at: try resolved())
            return Cursor<ReadOnly>(slotPointer: pointer, database: database)
        } catch {
            guard error == .keyNotFound || error == .indexOutOfRange else { throw error }
            return nil
        }
    }

    /// Follows a path from this cursor without writing.
    package func readPath(_ path: [PathPart]) throws(XitDBError) -> Cursor<ReadOnly>? {
        try readPath(path.span)
    }

    /// Follows a path from this cursor without writing, and returns the slot
    /// it arrives at, or `nil` if there is none, an index names no element,
    /// or it is empty.
    package func readPathSlot(_ path: Span<PathPart>) throws(XitDBError) -> Slot? {
        do throws(XitDBError) {
            let pointer = try database.reader.readSlotPointer(path, at: try resolved())
            return pointer.slot.isEmpty ? nil : pointer.slot
        } catch {
            guard error == .keyNotFound || error == .indexOutOfRange else { throw error }
            return nil
        }
    }

    /// Follows a path from this cursor without writing, and returns the slot
    /// it arrives at.
    package func readPathSlot(_ path: [PathPart]) throws(XitDBError) -> Slot? {
        try readPathSlot(path.span)
    }

    // MARK: Reading

    /// The slot this cursor is at.
    ///
    /// - Throws: Only for a root cursor, if the root cannot be read.
    public var slot: Slot {
        get throws(XitDBError) {
            try resolved().slot
        }
    }

    /// Reads the slot's value as an unsigned 64-bit integer.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot does not hold one.
    public func readUInt64() throws(XitDBError) -> UInt64 {
        let slot = try resolved().slot
        if slot.tag != .uint { throw .unexpectedTag }
        return slot.value
    }

    /// Reads the slot's value as a signed 64-bit integer.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot does not hold one.
    public func readInt64() throws(XitDBError) -> Int64 {
        let slot = try resolved().slot
        if slot.tag != .int { throw .unexpectedTag }
        return Int64(bitPattern: slot.value)
    }

    /// Reads the slot's value as a 64-bit floating-point number.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot does not hold one.
    public func readDouble() throws(XitDBError) -> Double {
        let slot = try resolved().slot
        if slot.tag != .float { throw .unexpectedTag }
        return Double(bitPattern: slot.value)
    }

    /// Reads the slot's value as a byte array.
    ///
    /// An empty slot reads as no bytes.
    ///
    /// - Parameter maxCount: The most bytes to accept, or `nil` for no
    ///   limit.
    /// - Throws: ``XitDBError/streamTooLong`` if the value is larger than
    ///   `maxCount`, ``XitDBError/unexpectedTag`` if the slot does not hold
    ///   bytes, or ``XitDBError/endOfStream`` if the database ends before
    ///   the value does.
    public func readBytes(maxCount: Int? = nil) throws(XitDBError) -> [UInt8] {
        try readBytesWithFormatTag(maxCount: maxCount).value
    }

    /// Reads the slot's value as a byte array, with its format tag.
    ///
    /// An empty slot reads as no bytes and no tag.
    ///
    /// - Parameter maxCount: The most bytes to accept, or `nil` for no
    ///   limit.
    /// - Throws: ``XitDBError/streamTooLong`` if the value is larger than
    ///   `maxCount`, ``XitDBError/unexpectedTag`` if the slot does not hold
    ///   bytes, or ``XitDBError/endOfStream`` if the database ends before
    ///   the value does.
    public func readBytesWithFormatTag(maxCount: Int? = nil) throws(XitDBError) -> Bytes {
        try database.reader.bytesObject(try resolved().slot, maxSize: maxCount)
    }

    /// Reads the slot's value as a byte array into a buffer, without
    /// allocating.
    ///
    /// An empty slot reads as no bytes.
    ///
    /// - Parameter buffer: Where to put the bytes. They are written from its
    ///   start, and the rest of it is left as it was.
    /// - Returns: The number of bytes read.
    /// - Throws: ``XitDBError/streamTooLong`` if the value does not fit in
    ///   `buffer`, ``XitDBError/unexpectedTag`` if the slot does not hold
    ///   bytes, or ``XitDBError/endOfStream`` if the database ends before
    ///   the value does.
    public func readBytes(into buffer: inout MutableSpan<UInt8>) throws(XitDBError) -> Int {
        try readBytesWithFormatTag(into: &buffer).count
    }

    /// Reads the slot's value as a byte array into a buffer, with its format
    /// tag, without allocating.
    ///
    /// An empty slot reads as no bytes and no tag.
    ///
    /// - Parameter buffer: Where to put the bytes. They are written from its
    ///   start, and the rest of it is left as it was.
    /// - Returns: The number of bytes read, and the value's format tag if it
    ///   has one.
    /// - Throws: ``XitDBError/streamTooLong`` if the value does not fit in
    ///   `buffer`, ``XitDBError/unexpectedTag`` if the slot does not hold
    ///   bytes, or ``XitDBError/endOfStream`` if the database ends before
    ///   the value does.
    public func readBytesWithFormatTag(
        into buffer: inout MutableSpan<UInt8>
    ) throws(XitDBError) -> (count: Int, formatTag: FormatTag?) {
        try database.reader.bytesObject(try resolved().slot, into: &buffer)
    }

    /// Reads the entry of a map or set that this cursor is at: its key, its
    /// value and its hash.
    ///
    /// The cursor should be at an entry: one obtained by asking a map for an
    /// entry, or by iterating over a map or set. Any slot that holds bytes
    /// is read as a key on its own, which is what a sorted set's entry is,
    /// so on a cursor at a byte value this succeeds, as Zig's does: the
    /// key cursor is at the bytes, the value is empty and the hash is
    /// zeros. Nothing tells such a value from a set's key.
    ///
    /// The entry is read-only whatever this cursor is: an entry's key is
    /// what the collection is ordered or indexed by, and is changed only
    /// through the collection.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds anything
    ///   else: a number, a collection, or nothing.
    public func readEntry() throws(XitDBError) -> Entry {
        let entry = try resolved().slot
        let found = try database.reader.keyValuePair(entry)
        let hashSize = database.header.hashSize
        return Entry(
            key: Cursor<ReadOnly>(
                slotPointer: SlotPointer(
                    position: KeyValuePair.keyPosition(of: entry, hashSize: hashSize),
                    slot: found.pair.keySlot
                ),
                database: database,
                frozenAt: frozenAt
            ),
            value: Cursor<ReadOnly>(
                slotPointer: SlotPointer(
                    position: KeyValuePair.valuePosition(of: entry, hashSize: hashSize),
                    slot: found.pair.valueSlot
                ),
                database: database,
                frozenAt: frozenAt
            ),
            keyHash: found.hash
        )
    }

    /// The number of elements in the collection the slot holds, or of bytes
    /// in its byte array. An empty slot counts zero.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   that has no count: a number, or a hash map or set that does not
    ///   keep one.
    public var count: UInt64 {
        get throws(XitDBError) {
            try database.reader.count(try resolved().slot)
        }
    }
}

/// One entry of a map or set: its key and its value, each as a read-only
/// cursor, and the hash it is stored under.
///
/// Everything that gives an entry gives a read-only one: a key is changed
/// only through its collection, which keeps the collection's order and
/// index right.
public struct Entry {
    /// A cursor at the entry's key.
    public let key: Cursor<ReadOnly>

    /// A cursor at the entry's value. In a set it is empty.
    public let value: Cursor<ReadOnly>

    /// The hash the entry is stored under, kept in the pair itself so that
    /// reading a pair allocates nothing.
    package var keyHash: KeyHash

    /// The hash the entry is stored under, in the order its bytes are
    /// stored. All zeros for an entry of a sorted map or set, which has no
    /// hash.
    ///
    /// This makes an array each time it is read. To look at the hash without
    /// one, use ``withHash(_:)``.
    public var hash: [UInt8] {
        keyHash.bytes
    }

    /// Calls `body` with the hash the entry is stored under, without
    /// copying it.
    ///
    /// - Parameter body: Given the hash's bytes, in the order they are
    ///   stored. The span must not be kept after `body` returns.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    public func withHash<Result, Failure: Error>(
        _ body: (Span<UInt8>) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try keyHash.withBytes(body)
    }
}

extension Cursor where Access == ReadWrite {
    /// A cursor at the same slot that can only read.
    public var readOnly: Cursor<ReadOnly> {
        Cursor<ReadOnly>(slotPointer: slotPointer, database: database)
    }

    // MARK: Paths

    /// Follows a path from this cursor, writing as its parts say.
    ///
    /// On a root cursor this is a transaction: it commits when the path has
    /// finished, and everything it wrote is discarded if an error leaves
    /// it before the commit. An error from the storage's sync after the
    /// commit is thrown too, but the commit stands, as in Zig.
    ///
    /// The cursor itself is not changed. The result is a new cursor at the
    /// slot the path arrived at.
    package func writePath(_ path: Span<PathPart>) throws(XitDBError) -> Cursor<ReadWrite> {
        try writePath(
            path,
            lift: { $0 },
            callback: { (_: inout Cursor<ReadWrite>) throws(XitDBError) in
                // The path has a `ctx` part and nothing to run for it.
                throw .notImplemented
            }
        )
    }

    /// Follows a path from this cursor, writing as its parts say.
    package func writePath(_ path: [PathPart]) throws(XitDBError) -> Cursor<ReadWrite> {
        try writePath(path.span)
    }

    /// Follows a path that ends in a `ctx` part, and runs `callback` with a
    /// cursor at the slot the path arrives there with.
    ///
    /// What the callback leaves in its cursor is the path's result. An error
    /// it throws leaves this call unchanged, and discards the transaction if
    /// this is the call that started it.
    package func writePath(
        _ path: Span<PathPart>,
        _ callback: (inout Cursor<ReadWrite>) throws -> Void
    ) throws -> Cursor<ReadWrite> {
        try writePath(path, lift: { $0 }, callback: callback)
    }

    /// Follows a path that ends in a `ctx` part, and runs `callback` there.
    package func writePath(
        _ path: [PathPart],
        _ callback: (inout Cursor<ReadWrite>) throws -> Void
    ) throws -> Cursor<ReadWrite> {
        try writePath(path.span, callback)
    }

    /// Follows a path that ends in a `ctx` part, and runs there a callback
    /// that can only fail with an error of the database, so that the call
    /// keeps its typed error.
    package func writePath(
        _ path: Span<PathPart>,
        typed callback: (inout Cursor<ReadWrite>) throws(XitDBError) -> Void
    ) throws(XitDBError) -> Cursor<ReadWrite> {
        try writePath(path, lift: { $0 }, callback: callback)
    }

    /// Zig's `Cursor.writePath`: the checks, the fresh look at the starting
    /// slot, the rollback when an error leaves the outermost write, and the
    /// sync that makes a commit durable.
    private func writePath<Failure: Error>(
        _ path: Span<PathPart>,
        lift: (XitDBError) -> Failure,
        callback: (inout Cursor<ReadWrite>) throws(Failure) -> Void
    ) throws(Failure) -> Cursor<ReadWrite> {
        // Writes below the root must run inside a transaction.
        if database.transactionStart == nil && !isRoot && path.count > 0 {
            throw lift(.expectedTxStart)
        }
        // A write from the root inside a transaction could commit before
        // the outer transaction ends.
        if database.transactionStart != nil && isRoot && path.count > 0 {
            throw lift(.nestedTopLevelWrite)
        }

        // An earlier write through this cursor may have moved what its slot
        // points at, so start from what the slot holds now.
        var start = slotPointer
        if !isRoot, let position = start.position {
            do throws(XitDBError) {
                start.slot = try database.reader.slot(at: position)
            } catch {
                throw lift(error)
            }
        }

        let database = self.database
        let frozenAt = self.frozenAt
        let commitsBefore = database.commitCount
        let result: SlotPointer
        do throws(Failure) {
            result = try database.writeSlotPointer(path, at: start, frozenAt: frozenAt, lift: lift) {
                (pointer: inout SlotPointer) throws(Failure) in
                var cursor = Cursor<ReadWrite>(slotPointer: pointer, database: database, frozenAt: frozenAt)
                try callback(&cursor)
                // Only the slot comes back out. A freeze made on the
                // callback's cursor ends with the callback.
                pointer = cursor.slotPointer
            }
        } catch {
            // Only discard when the error leaves the outermost write. The
            // caller of a nested one may still commit its work.
            if database.transactionStart == nil {
                try? database.truncate()
            }
            throw error
        }

        // The second sync of a commit, which makes the root header durable.
        // Zig syncs here after every write that is not inside a transaction,
        // including the ones that commit nothing: an empty path, and
        // initialising a root that is already initialised. With full
        // durability that would be a drive flush each time a collection is
        // wrapped around a root cursor, for no bytes written. So this syncs
        // only after a commit, which only the outermost write makes, as it
        // ends: there is no transaction left by then.
        if database.commitCount != commitsBefore {
            do throws(XitDBError) {
                try database.storage.sync(.afterRootHeader)
            } catch {
                throw lift(error)
            }
        }
        return Cursor<ReadWrite>(slotPointer: result, database: database, frozenAt: frozenAt)
    }

    // MARK: Writing

    /// Writes a value to the slot.
    ///
    /// On a root cursor this is a transaction of its own. Afterwards the
    /// cursor holds the slot as written.
    ///
    /// - Throws: ``XitDBError/expectedTxStart`` if the cursor is not a root
    ///   cursor and no transaction is in progress,
    ///   ``XitDBError/nestedTopLevelWrite`` if it is a root cursor and one
    ///   is, ``XitDBError/cursorNotWritable`` if the slot has no position
    ///   to write to, or ``XitDBError/storageFailure(errno:)`` if the
    ///   storage fails.
    public mutating func write(_ data: WritableData) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.write(data)]
        self = try writePath(path.span)
    }

    /// Writes a value to the slot if the cursor's snapshot of it is empty,
    /// and does nothing otherwise.
    ///
    /// This goes by the snapshot. If the slot has been written through
    /// another cursor since this one was made, the value there is
    /// overwritten.
    ///
    /// - Throws: As ``write(_:)``.
    public mutating func writeIfEmpty(_ data: WritableData) throws(XitDBError) {
        if try resolved().slot.isEmpty {
            try write(data)
        }
    }

    /// Writes a byte array to the slot piece by piece, without having it in
    /// memory as a whole.
    ///
    /// The bytes that `body` writes are appended to the database as they
    /// come. When `body` returns, the array is completed and the slot is
    /// pointed at it. If `body` throws, the slot is left as it was, and the
    /// bytes already written stay behind unused.
    ///
    /// A value written this way always gets a record of its own, however
    /// short it is.
    ///
    /// Nothing else may be written to the database while `body` runs, since
    /// the array can only grow while it is the last thing in it.
    ///
    /// - Parameters:
    ///   - formatTag: A format tag to store with the bytes, or `nil` for
    ///     none. `body` can also set it, through the writer.
    ///   - body: Writes the bytes.
    /// - Throws: ``XitDBError/cursorNotWritable`` on a root cursor, to
    ///   which bytes are written with ``write(_:)``, or if the slot has no
    ///   position; ``XitDBError/expectedTxStart`` outside a transaction;
    ///   ``XitDBError/unexpectedWriterPosition`` if something else was
    ///   written while `body` ran; and whatever `body` throws.
    public mutating func writeBytes(
        formatTag: FormatTag? = nil,
        _ body: (inout ByteWriter) throws -> Void
    ) throws {
        var writer = ByteWriter(record: try ByteRecordWriter(database: database, at: slotPointer))
        writer.formatTag = formatTag
        try body(&writer)
        slotPointer.slot = try writer.record.finish(slotPosition: slotPointer.position)
    }

    /// Makes writes through this cursor, and through cursors made from it
    /// afterwards, copy what the transaction has written so far instead of
    /// changing it in place.
    ///
    /// Call it after pointing this slot at data that something else still
    /// refers to, and before wrapping the cursor in a collection: a
    /// collection keeps its own copy of the cursor, freeze point included,
    /// so freezing the cursor after wrapping it changes nothing the
    /// collection does. Other cursors keep writing in place;
    /// ``Database/freeze()`` does the same for all of them.
    ///
    /// - Throws: ``XitDBError/expectedTxStart`` outside a transaction.
    public mutating func freeze() throws(XitDBError) {
        guard database.transactionStart != nil else { throw .expectedTxStart }
        frozenAt = try database.storage.length
    }
}

/// Writes the bytes of a byte array, for ``Cursor/writeBytes(formatTag:_:)``.
public struct ByteWriter: ~Copyable {
    var record: ByteRecordWriter

    /// A format tag to store with the bytes, or `nil` for none.
    public var formatTag: FormatTag? {
        get { record.formatTag }
        set { record.formatTag = newValue }
    }

    /// Writes bytes at the writer's position and moves the position past
    /// them.
    ///
    /// - Parameter bytes: The bytes to write.
    /// - Throws: ``XitDBError/unexpectedWriterPosition`` if the write would
    ///   make the array longer and something else has been written to the
    ///   database since the writer was made, or if the position, after a
    ///   far ``seek(to:)``, lies beyond any position a storage has;
    ///   ``XitDBError/expectedTxStart`` if the transaction has ended; or
    ///   ``XitDBError/storageFailure(errno:)`` if the storage fails.
    public mutating func write(_ bytes: Span<UInt8>) throws(XitDBError) {
        try record.write(bytes)
    }

    /// Writes bytes at the writer's position and moves the position past
    /// them.
    ///
    /// - Parameter bytes: The bytes to write.
    /// - Throws: As ``write(_:)-(Span<UInt8>)``.
    public mutating func write(_ bytes: [UInt8]) throws(XitDBError) {
        try record.write(bytes.span)
    }

    /// Moves the position at which the next bytes are written, counted from
    /// the start of the array.
    ///
    /// Writing beyond the end of what has been written leaves zeros in
    /// between: a seek far past the end makes the next write grow the
    /// array, and the storage with it, to where the position reaches, and
    /// the array stays that long. A position beyond any a storage has is
    /// reported by that write.
    ///
    /// - Parameter offset: The new position.
    public mutating func seek(to offset: UInt64) {
        record.seek(to: offset)
    }
}

extension Database {
    /// A cursor at the root of the database.
    ///
    /// Everything read through it comes from the last commit, whichever
    /// that is at the time of the read. Every write through it is a
    /// transaction. Each access gives a new cursor, which costs one read of
    /// the root header.
    ///
    /// The cursor is read-write on every storage, as in Zig. A reader opens
    /// its storage with ``FileAccess/readOnly`` and wraps ``Cursor/readOnly``
    /// in the read-only collections, or gives the cursor to their read-only
    /// inits; a write through the root cursor on a read-only storage fails
    /// with the storage's write error and truncates nothing. Two processes
    /// on one file use the file's lock: a reader that opened read-write is a
    /// second writer, and starting a write-mode collection on its root cursor
    /// discards whatever the other process's transaction has written so far.
    public var rootCursor: Cursor<ReadWrite> {
        // The cursor only holds a snapshot of the root slot, and everything
        // that starts at it reads the root again. If this read fails, the
        // cursor looks empty and the next operation reports the error.
        let root = (try? reader.rootSlot()) ?? Slot()
        return Cursor(slotPointer: SlotPointer(position: RootHeader.position, slot: root), database: self)
    }

    /// Runs `body` as one transaction, with a cursor at the root to write
    /// through, and gives what it returns.
    ///
    /// The transaction commits when `body` returns. If `body` throws,
    /// everything it wrote is discarded and the database is as it was. One
    /// error is not a rollback: if the storage fails in the sync after the
    /// commit, the error is thrown, but the commit stands, as in Zig.
    ///
    /// Use this to group writes to a root that is not an array list, such as
    /// a hash map: without it, each write through a root cursor is a
    /// transaction of its own.
    ///
    /// The result may be ignored: a transaction is often run for its writes
    /// alone, with a body whose one expression happens to have a value.
    ///
    /// - Parameter body: Does the writing, through the cursor it is given.
    /// - Throws: ``XitDBError/nestedTopLevelWrite`` if a transaction is
    ///   already in progress, ``XitDBError/storageFailure(errno:)`` if the
    ///   storage fails, and whatever `body` throws.
    @discardableResult
    public func withTransaction<Result>(_ body: (inout Cursor<ReadWrite>) throws -> Result) throws -> Result {
        let path: InlineArray<1, PathPart> = [.ctx]
        var result: Result?
        _ = try rootCursor.writePath(path.span) { cursor in result = try body(&cursor) }
        // A write path that ends in `.ctx` runs the body or throws.
        guard let result else { preconditionFailure("the transaction's body was not run") }
        return result
    }
}
