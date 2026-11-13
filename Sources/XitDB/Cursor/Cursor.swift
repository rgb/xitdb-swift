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

    /// The engine the cursor reads from and writes through: the live
    /// database, or the one under a ``SnapshotDatabase``. The public view
    /// is the cursor's `database`, typed by its access.
    let engine: Database

    /// The freeze point: writes through this cursor copy any data written
    /// before this position, even data from the current transaction. Zero
    /// when there is none.
    var frozenAt: UInt64

    /// The transaction the cursor was made in, by number, or zero outside
    /// any. A write through the cursor during another transaction is
    /// refused (finding 1), and so is a read if that transaction did not
    /// commit (its bytes are gone).
    var transaction: UInt64

    /// How many times the database had frozen when the cursor was made. A
    /// write through the cursor after a later freeze is refused (D18),
    /// unless its path begins with an init part.
    var freezeCount: UInt64

    /// A cursor made now: it records the transaction in progress and the
    /// database's freezes so far.
    init(slotPointer: SlotPointer, database: Database, frozenAt: UInt64 = 0) {
        self.slotPointer = slotPointer
        self.engine = database
        self.frozenAt = frozenAt
        self.transaction = database.cursorTransaction
        self.freezeCount = database.freezeNumber
    }

    /// A view of another cursor: the same slot, snapshot, freeze point and
    /// numbers, so that a view of a cursor from a transaction that did not
    /// commit is refused as the cursor is.
    init(viewing other: Cursor<some CursorAccess>) {
        self.slotPointer = other.slotPointer
        self.engine = other.engine
        self.frozenAt = other.frozenAt
        self.transaction = other.transaction
        self.freezeCount = other.freezeCount
    }

    /// Whether the cursor is from a transaction that did not commit: its
    /// bytes were truncated and the offsets reused, so nothing may be read
    /// from the file through it. The ``slot`` snapshot touches no bytes and
    /// stays readable.
    ///
    /// - Throws: ``XitDBError/staleCursor`` if it is.
    func checkReadable() throws(XitDBError) {
        if transaction != 0 && !isRoot && engine.transactionFailed(transaction) { throw .staleCursor }
    }

    /// The checks before a write through this cursor, in the order the
    /// port fixes: no transaction, a nested one, a poisoned one, a cursor
    /// that cannot write (one with no position, for any path but one that
    /// begins with a get, and for the empty path of a byte writer), a
    /// cursor from an earlier transaction, a cursor from before the last
    /// freeze (unless it is the transaction's own cursor and `path` begins
    /// with an init part or a write, the ways to go on after a freeze).
    ///
    /// A root cursor is never stale: it resolves itself through the root
    /// header. Outside a transaction nothing is stale either: a write is
    /// ``XitDBError/expectedTxStart`` as it always was, and an empty path
    /// works.
    func checkWritable(_ path: Span<PathPart>) throws(XitDBError) {
        if engine.transactionStart == nil {
            if !isRoot && path.count > 0 { throw .expectedTxStart }
            return
        }
        if isRoot {
            if path.count > 0 { throw .nestedTopLevelWrite }
            return
        }
        if engine.poisoned { throw .poisonedTransaction }
        if slotPointer.position == nil, path.count == 0 || !path[0].isGet { throw .cursorNotWritable }
        if transaction != engine.transactionNumber { throw .staleCursor }
        if freezeCount < engine.freezeNumber {
            // After a freeze the one way on through a cursor from before it
            // is the transaction's own cursor, with a path that begins with
            // an init part or a write (D24, item 3 as refined): its slot is
            // the engine's own record, which nothing inside the transaction
            // can copy. The init copies the collection's header into the
            // transaction and gives a fresh cursor; the write rewrites that
            // slot in place, as the original does; the parts after either
            // go on from there. Every other write through a cursor from
            // before the freeze is stale, inits through other cursors
            // included.
            guard let body = engine.bodyPosition, slotPointer.position == body, path.count > 0,
                path[0].isInit || path[0].isWrite
            else { throw .staleCursor }
        }
    }

    /// Refuses a path that would write a slot with one of the trees' own
    /// tags, before any part of it runs, so that nothing is written and
    /// nothing poisoned (finding 3). It comes after ``checkWritable(_:)``,
    /// so that a write with no transaction open is `expectedTxStart` first.
    func checkData(_ path: Span<PathPart>) throws(XitDBError) {
        for index in 0..<path.count where path[index].writesStructuralSlot {
            throw .structuralSlot
        }
    }

    /// Whether this is a cursor at the root of the engine.
    var isRoot: Bool {
        slotPointer.position == RootHeader.position
    }

    /// The slot this cursor reads from. A root cursor only has a snapshot of
    /// the root, which goes stale with the next transaction, so it reads the
    /// root again each time. Everything that reads the slot goes through
    /// this.
    func resolved() throws(XitDBError) -> SlotPointer {
        if isRoot {
            return try engine.reader.resolvedRoot()
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
        try checkReadable()
        do throws(XitDBError) {
            let pointer = try engine.reader.readSlotPointer(path, at: try resolved())
            return Cursor<ReadOnly>(slotPointer: pointer, database: engine)
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
        try checkReadable()
        do throws(XitDBError) {
            let pointer = try engine.reader.readSlotPointer(path, at: try resolved())
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
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot does not hold one,
    ///   or ``XitDBError/staleCursor`` if the cursor is not a root cursor and
    ///   is from a transaction that did not commit.
    public func readUInt64() throws(XitDBError) -> UInt64 {
        try checkReadable()
        let slot = try resolved().slot
        if slot.tag != .uint { throw .unexpectedTag }
        return slot.value
    }

    /// Reads the slot's value as a signed 64-bit integer.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot does not hold one,
    ///   or ``XitDBError/staleCursor`` if the cursor is not a root cursor and
    ///   is from a transaction that did not commit.
    public func readInt64() throws(XitDBError) -> Int64 {
        try checkReadable()
        let slot = try resolved().slot
        if slot.tag != .int { throw .unexpectedTag }
        return Int64(bitPattern: slot.value)
    }

    /// Reads the slot's value as a 64-bit floating-point number.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot does not hold one,
    ///   or ``XitDBError/staleCursor`` if the cursor is not a root cursor and
    ///   is from a transaction that did not commit.
    public func readDouble() throws(XitDBError) -> Double {
        try checkReadable()
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
    ///   bytes, ``XitDBError/endOfStream`` if the database ends before the
    ///   value does, or ``XitDBError/staleCursor`` if the cursor is not a
    ///   root cursor and is from a transaction that did not commit.
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
    ///   bytes, ``XitDBError/endOfStream`` if the database ends before the
    ///   value does, or ``XitDBError/staleCursor`` if the cursor is not a
    ///   root cursor and is from a transaction that did not commit.
    public func readBytesWithFormatTag(maxCount: Int? = nil) throws(XitDBError) -> Bytes {
        try checkReadable()
        return try engine.reader.bytesObject(try resolved().slot, maxSize: maxCount)
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
    ///   bytes, ``XitDBError/endOfStream`` if the database ends before the
    ///   value does, or ``XitDBError/staleCursor`` if the cursor is not a
    ///   root cursor and is from a transaction that did not commit.
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
    ///   bytes, ``XitDBError/endOfStream`` if the database ends before the
    ///   value does, or ``XitDBError/staleCursor`` if the cursor is not a
    ///   root cursor and is from a transaction that did not commit.
    public func readBytesWithFormatTag(
        into buffer: inout MutableSpan<UInt8>
    ) throws(XitDBError) -> (count: Int, formatTag: FormatTag?) {
        try checkReadable()
        return try engine.reader.bytesObject(try resolved().slot, into: &buffer)
    }

    /// Reads the entry of a map or set that this cursor is at: its key, its
    /// value and its hash.
    ///
    /// The cursor should be at an entry: one obtained by asking a map for an
    /// entry, or by iterating over a map or set. Any slot that holds bytes
    /// is read as a key on its own, which is what a sorted set's entry is,
    /// so on a cursor at a byte value this succeeds, as the original's
    /// does: the key cursor is at the bytes, the value is empty and the
    /// hash is zeros. Nothing tells such a value from a set's key.
    ///
    /// The entry is read-only whatever this cursor is: an entry's key is
    /// what the collection is ordered or indexed by, and is changed only
    /// through the collection.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds anything
    ///   else: a number, a collection, or nothing; ``XitDBError/staleCursor``
    ///   if the cursor is not a root cursor and is from a transaction that
    ///   did not commit.
    public func readEntry() throws(XitDBError) -> Entry {
        try checkReadable()
        let entry = try resolved().slot
        let found = try engine.reader.keyValuePair(entry)
        let hashSize = engine.header.hashSize
        // A sorted map's key is never writable, since the map is ordered by
        // it (finding 2): its cursor has no position, as in the original's
        // fix branch, so the package-level path API cannot write it either.
        let keyPosition = entry.tag == .sortedKvPair ? nil : KeyValuePair.keyPosition(of: entry, hashSize: hashSize)
        return Entry(
            key: Cursor<ReadOnly>(
                slotPointer: SlotPointer(
                    position: keyPosition,
                    slot: found.pair.keySlot
                ),
                database: engine,
                frozenAt: frozenAt
            ),
            value: Cursor<ReadOnly>(
                slotPointer: SlotPointer(
                    position: KeyValuePair.valuePosition(of: entry, hashSize: hashSize),
                    slot: found.pair.valueSlot
                ),
                database: engine,
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
    ///   keep one; ``XitDBError/staleCursor`` if the cursor is not a root
    ///   cursor and is from a transaction that did not commit.
    public var count: UInt64 {
        get throws(XitDBError) {
            try checkReadable()
            return try engine.reader.count(try resolved().slot)
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

extension Cursor {
    /// A read-only view of this cursor at the slot as the storage holds it
    /// now.
    ///
    /// A cursor keeps the slot it was made with; a write through another
    /// cursor at the same position moves what the slot points at, and a
    /// write path reads the slot again before it starts, but a read does
    /// not. A holder that reads through a copy kept across writes, as the
    /// store layer's handles do at a moment's root, reads through this
    /// instead. The root reads itself again on every use already.
    package func refreshed() throws(XitDBError) -> Cursor<ReadOnly> {
        try checkReadable()
        var view = Cursor<ReadOnly>(viewing: self)
        if !isRoot, let position = slotPointer.position {
            view.slotPointer.slot = try engine.reader.slot(at: position)
        }
        return view
    }

    /// A cursor at the same slot that can only read; a read-only cursor is
    /// its own. It is as stale as this one: a view of a cursor from a
    /// transaction that did not commit is refused the same way. A helper
    /// given a cursor of any access reaches its database through it, as
    /// `database` has the type the access decides.
    public var readOnly: Cursor<ReadOnly> {
        Cursor<ReadOnly>(viewing: self)
    }
}

extension Cursor where Access == ReadWrite {
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
        // The checks before anything is written, in the port's fixed order,
        // then the data every write part carries.
        do throws(XitDBError) {
            try checkWritable(path)
            try checkData(path)
        } catch {
            throw lift(error)
        }

        // An earlier write through this cursor may have moved what its slot
        // points at, so start from what the slot holds now.
        var start = slotPointer
        if !isRoot, let position = start.position {
            do throws(XitDBError) {
                start.slot = try engine.reader.slot(at: position)
            } catch {
                throw lift(error)
            }
        }

        let engine = self.engine
        let frozenAt = self.frozenAt
        let commitsBefore = engine.commitCount
        let writesBefore = engine.writesIssued
        // A cursor this operation gives back, the callback's or the result,
        // is stamped with the freezes as they were when the operation began
        // (D24 item 6): a freeze the operation itself makes, a concat's or
        // a callback's, must not make its result look fresh.
        let freezesBefore = engine.freezeNumber
        let result: SlotPointer
        do throws(Failure) {
            result = try engine.writeSlotPointer(path, at: start, frozenAt: frozenAt, lift: lift) {
                (pointer: inout SlotPointer) throws(Failure) in
                // The first callback of a transaction is the transaction's
                // own: its cursor is the one that goes on after a freeze.
                engine.noteBody(pointer.position)
                var cursor = Cursor<ReadWrite>(slotPointer: pointer, database: engine, frozenAt: frozenAt)
                cursor.freezeCount = freezesBefore
                try callback(&cursor)
                // Only the slot comes back out. A freeze made on the
                // callback's cursor ends with the callback.
                pointer = cursor.slotPointer
            }
        } catch {
            // Only discard when the error leaves the outermost write. The
            // caller of a nested one may still commit its work, unless this
            // write had already written something: what it left cannot be
            // undone short of the whole transaction, which is poisoned
            // (finding 16).
            if engine.transactionStart == nil {
                try? engine.truncate()
            } else if engine.writesIssued != writesBefore {
                engine.poison()
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
        if engine.commitCount != commitsBefore {
            do throws(XitDBError) {
                try engine.storage.sync(.afterRootHeader)
            } catch {
                throw lift(error)
            }
        }
        var written = Cursor<ReadWrite>(slotPointer: result, database: engine, frozenAt: frozenAt)
        written.freezeCount = freezesBefore
        return written
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
    ///   to write to, ``XitDBError/staleCursor`` if the cursor is from
    ///   before the last freeze of this transaction or from an earlier
    ///   transaction, ``XitDBError/poisonedTransaction`` if an earlier
    ///   operation of the transaction failed after writing, or
    ///   ``XitDBError/storageFailure(errno:)`` if the storage fails.
    public mutating func write(_ data: WritableData) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.write(data)]
        update(to: try writePath(path.span))
    }

    /// Takes the slot a write through this cursor arrived at, keeping when
    /// the cursor was made: a write does not make a cursor fresh.
    private mutating func update(to written: Cursor<ReadWrite>) {
        slotPointer = written.slotPointer
    }

    /// Writes a value to the slot if nothing has been written there, and
    /// does nothing otherwise.
    ///
    /// What decides is the slot as it is in the database now, not the copy
    /// of it this cursor took when it was made: another cursor may have
    /// written a value there since, and that value is kept. The original
    /// decides by the cursor's copy, and overwrites such a value.
    ///
    /// The value is written when the slot is empty, which means never
    /// written. It is also written when this cursor was made on an empty
    /// slot and the slot is set to nothing now. That is how the database
    /// keeps an element which ``ArrayList/appendCursor()``,
    /// ``LinkedArrayList/appendCursor()`` or
    /// ``LinkedArrayList/insertCursor(at:)`` has just made and handed this
    /// cursor to, so that the element counts before anything is written to
    /// it. A slot that another cursor has set to nothing in the meantime
    /// looks the same, and is written over as well.
    ///
    /// In every other case nothing is written: when the slot holds a value
    /// now, and when this cursor was made on a slot that had been set to
    /// nothing, which is not empty.
    ///
    /// - Throws: As ``write(_:)``, and ``XitDBError/invalidEnumTag`` or
    ///   ``XitDBError/endOfStream`` if the slot cannot be read.
    public mutating func writeIfEmpty(_ data: WritableData) throws(XitDBError) {
        // Inside a transaction the checks of a write come first, stale
        // cursors included; outside one, a slot that is not empty is left
        // alone without an error, as it always was, and an empty one gets
        // the write's expectedTxStart.
        let path: InlineArray<1, PathPart> = [.write(data)]
        if engine.transactionStart != nil {
            try checkWritable(path.span)
        } else {
            try checkReadable()
        }
        // The data is checked before the slot is looked at, so that a
        // structural slot is refused whatever the slot holds.
        try checkData(path.span)
        // The cursor's own copy of the slot, and the slot as it is now. An
        // append or an insert hands back a cursor whose copy is empty while
        // the slot in the storage is set to nothing, so that the element
        // counts: that slot is still to be written.
        let own = try resolved()
        var now = own.slot
        if !isRoot, let position = own.position {
            now = try engine.reader.slot(at: position)
        }
        if now.isEmpty || (own.slot.isEmpty && now.tag == .none) {
            try write(data)
        }
    }

    /// Writes a byte array to the slot piece by piece, without having it in
    /// memory as a whole.
    ///
    /// The bytes that `body` writes are appended to the database as they
    /// come. When `body` returns, the array is completed and the slot is
    /// pointed at it. If `body` throws, the slot is left as it was, the
    /// bytes already written stay behind unused, and the transaction is
    /// poisoned, even when `body` wrote nothing: the record's length was
    /// appended before `body` ran, and a write issued is what poisons.
    ///
    /// A value written this way always gets a record of its own, however
    /// short it is.
    ///
    /// Nothing else may be written to the database while `body` runs, since the
    /// array can only grow while it is the last thing in it, and nothing may be
    /// frozen: ``Database/freeze()`` and a join are refused inside `body` with
    /// ``XitDBError/byteWriterOpen``, since the record being filled would fall
    /// below the freeze.
    ///
    /// - Parameters:
    ///   - formatTag: A format tag to store with the bytes, or `nil` for
    ///     none. `body` can also set it, through the writer.
    ///   - body: Writes the bytes.
    /// - Throws: ``XitDBError/cursorNotWritable`` on a root cursor, to
    ///   which bytes are written with ``write(_:)``, or if the slot has no
    ///   position; ``XitDBError/expectedTxStart`` outside a transaction;
    ///   ``XitDBError/staleCursor`` if the cursor is from before the last
    ///   freeze of this transaction or from an earlier transaction;
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing;
    ///   ``XitDBError/unexpectedWriterPosition`` if something else was
    ///   written while `body` ran; ``XitDBError/byteWriterOpen`` from a
    ///   freeze or a join inside `body`, which `body` passes on, so that
    ///   the transaction is poisoned; and whatever else `body` throws.
    public mutating func writeBytes(
        formatTag: FormatTag? = nil,
        _ body: (inout ByteWriter) throws -> Void
    ) throws {
        // A byte writer is a write with no path: the same checks first.
        try checkWritable(Span())
        let writesBefore = engine.writesIssued
        do {
            var writer = ByteWriter(record: try ByteRecordWriter(database: engine, at: slotPointer))
            writer.formatTag = formatTag
            // A freeze while the body runs would leave the record below the
            // frozen point: Database.freeze() and a concat refuse while one
            // is open.
            engine.openByteWriters += 1
            defer { engine.openByteWriters -= 1 }
            try body(&writer)
            slotPointer.slot = try writer.record.finish(slotPosition: slotPointer.position)
        } catch {
            // A writer that failed after appending bytes has left them
            // behind, which poisons the transaction (finding 16).
            if engine.transactionStart != nil && engine.writesIssued != writesBefore {
                engine.poison()
            }
            throw error
        }
    }

    /// Makes writes through this cursor, and through cursors made from it
    /// afterwards, copy what the transaction has written so far instead of
    /// changing it in place.
    ///
    /// Call it after pointing this slot at data that something else still
    /// refers to, and before wrapping the cursor in a collection: a
    /// collection keeps its own copy of the cursor, freeze point included,
    /// so freezing the cursor after wrapping it changes nothing the
    /// collection does.
    ///
    /// No other handle is affected. Cursors and collections made earlier
    /// keep writing in place, none of them becomes stale, and the guard
    /// that refuses writes through a cursor from before a freeze does not
    /// count this one. So it protects the data from writes through this
    /// cursor only: a write through a handle that pointed at the data
    /// first still changes it, and the change shows through this cursor.
    /// When both sides are written in the same transaction, use
    /// ``Database/freeze()``, which holds for every handle.
    ///
    /// - Throws: ``XitDBError/expectedTxStart`` outside a transaction.
    public mutating func freeze() throws(XitDBError) {
        guard engine.transactionStart != nil else { throw .expectedTxStart }
        frozenAt = try engine.storage.length
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
    /// A cursor at the root of the engine.
    ///
    /// Everything read through it comes from the last commit, whichever
    /// that is at the time of the read. Every write through it is a
    /// transaction. Each access gives a new cursor, which costs one read of
    /// the root header.
    ///
    /// The cursor is read-write on every storage, as in the original. A reader
    /// opens its storage with ``FileAccess/readOnly`` and wraps
    /// ``Cursor/readOnly`` in the read-only collections, or gives the cursor to
    /// their read-only inits; a write through the root cursor on a read-only
    /// storage fails with the storage's write error and truncates nothing. Two
    /// processes on one file use the file's lock: a reader that opened
    /// read-write is a second writer, and starting a write-mode collection on
    /// its root cursor discards whatever the other process's transaction has
    /// written so far. The article on concurrency and snapshots says which
    /// types cross threads and how readers share a file with a writer.
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
    /// commit, the error is thrown, but the commit stands, as in the
    /// original.
    ///
    /// An operation in `body` that fails after it has written to the storage
    /// poisons the transaction: every further write and the commit are refused
    /// with ``XitDBError/poisonedTransaction``, and the transaction rolls back
    /// when `body` returns. An operation that fails before writing anything, a
    /// refused guard included, leaves the transaction as it was. The cursor
    /// `body` is given is the transaction's cursor: after a freeze,
    /// ``Database/freeze()`` or a join, it is the one place from before the
    /// freeze that a write may go through, making a collection or writing a
    /// value with ``Cursor/write(_:)`` or ``Cursor/writeIfEmpty(_:)``, a byte
    /// writer excepted, it or any cursor at the same slot, such as the cursor of a
    /// collection made from it, so a collection made again from either is
    /// fresh. It and every cursor and
    /// collection made from it belong to this transaction: a write through one
    /// of them after `body` returns is refused with ``XitDBError/staleCursor``.
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
    ///   already in progress, ``XitDBError/poisonedTransaction`` in place of
    ///   the commit if an operation in `body` poisoned it,
    ///   ``XitDBError/storageFailure(errno:)`` if the storage fails, and
    ///   whatever `body` throws.
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

extension Cursor where Access == ReadWrite {
    /// The database the cursor writes to: where a helper given only a
    /// cursor reaches the root, or freezes. A read-write cursor only ever
    /// comes from a live database's transaction, so this is that database.
    public var database: Database {
        engine
    }
}
