/// Somewhere a database's bytes can be read from.
///
/// A storage is a flat run of bytes addressed by offset, like a file. Reads
/// are positional: every call names the offset it reads at, and no call
/// depends on one made before it. The parts of XitDB that only read depend on
/// this protocol alone.
///
/// A conforming type is not required to be safe to use from several threads
/// at once.
public protocol ReadableStorage {
    /// Reads the bytes that start at `offset` into a part of `buffer`, as
    /// many as fit there.
    ///
    /// The bytes are written from the start of `range`. Fewer bytes than
    /// `range` holds are read only when the storage ends first, so a result
    /// smaller than `range.count` means the end of the storage was reached.
    /// Reading at or beyond the end reads nothing and is not an error.
    /// Everything in `buffer` that was not read into is left as it was.
    ///
    /// The range lets a caller fill part of a buffer in one call, for
    /// example when the value it is reading is smaller than the buffer it
    /// has.
    ///
    /// - Parameters:
    ///   - buffer: Where to put the bytes.
    ///   - range: The part of `buffer` to read into. Its size is the most
    ///     that will be read. It must lie within `buffer`.
    ///   - offset: The position in the storage of the first byte to read.
    /// - Returns: The number of bytes read, from zero to `range.count`.
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the storage
    ///   underneath fails.
    func read(
        into buffer: inout MutableSpan<UInt8>,
        range: Range<Int>,
        at offset: UInt64
    ) throws(XitDBError) -> Int

    /// The number of bytes in the storage, including any that were written
    /// and not yet flushed.
    ///
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the storage
    ///   underneath fails.
    var length: UInt64 { get throws(XitDBError) }
}

extension ReadableStorage {
    /// Reads the bytes that start at `offset` into `buffer`, as many as fit.
    ///
    /// The bytes are written from the start of `buffer`. Fewer bytes than
    /// `buffer` holds are read only when the storage ends first. The part of
    /// `buffer` that was not read into is left as it was.
    ///
    /// - Parameters:
    ///   - buffer: Where to put the bytes. Its size is the most that will be
    ///     read.
    ///   - offset: The position in the storage of the first byte to read.
    /// - Returns: The number of bytes read, from zero to `buffer.count`.
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the storage
    ///   underneath fails.
    public func read(into buffer: inout MutableSpan<UInt8>, at offset: UInt64) throws(XitDBError) -> Int {
        try read(into: &buffer, range: 0..<buffer.count, at: offset)
    }
}

/// Somewhere a database's bytes can be read from and written to.
///
/// A database owns its storage and is the only thing that writes to it. A
/// conforming type is a class: the methods are not `mutating`, and a database
/// and its cursors share the one instance.
///
/// XitDB provides three: ``MemoryStorage``, ``FileStorage`` and
/// ``BufferedFileStorage``.
public protocol WritableStorage: AnyObject, ReadableStorage {
    /// Writes `bytes` at `offset`, replacing what is there and growing the
    /// storage if the bytes reach beyond its end.
    ///
    /// When `offset` is beyond the end, the gap between the old end and
    /// `offset` is filled with zeros. Writing no bytes does nothing, whatever
    /// the offset.
    ///
    /// Either all of the bytes are written or an error is thrown. After an
    /// error, some of them may have been written.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to write.
    ///   - offset: The position in the storage of the first byte written.
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the storage
    ///   underneath fails, or ``XitDBError/maxSizeExceeded`` if the write
    ///   would grow the storage beyond a size limit it has, or beyond what
    ///   it can hold at all, as a memory storage cannot hold more than an
    ///   array.
    func write(_ bytes: Span<UInt8>, at offset: UInt64) throws(XitDBError)

    /// Cuts the storage down to `length` bytes, discarding everything after.
    ///
    /// A database uses this to drop what a failed transaction wrote. Bytes
    /// past the new length that were written and not yet flushed are
    /// discarded without being written first, so that dropping them cannot
    /// fail the way writing them did; bytes before it stay as they are.
    ///
    /// A storage cannot be made longer this way; only writing does that.
    ///
    /// - Parameter length: The new length in bytes, at most the current
    ///   length.
    /// - Throws: ``XitDBError/invalidLength`` if `length` is larger than the
    ///   current length, in which case nothing is changed, or
    ///   ``XitDBError/storageFailure(errno:)`` if the storage underneath
    ///   fails.
    func truncate(to length: UInt64) throws(XitDBError)

    /// Hands every byte the storage is still holding in memory to whatever is
    /// underneath it.
    ///
    /// This does not ask for the bytes to reach the disk; ``sync(_:)`` does.
    ///
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the storage
    ///   underneath fails. The bytes are then still held, and a later call
    ///   tries again.
    func flush() throws(XitDBError)

    /// Flushes, then asks for what has been written to reach the disk, as far
    /// as the storage's durability setting calls for.
    ///
    /// A database calls this twice for every commit, and says which of the
    /// two it is, because they need different things. See ``SyncPoint``.
    ///
    /// - Parameter point: Which of a commit's two syncs this is.
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the storage
    ///   underneath fails. The commit must then be treated as not made.
    func sync(_ point: SyncPoint) throws(XitDBError)
}

/// The two moments in a commit at which a database syncs its storage.
///
/// A transaction appends its data and then rewrites the root header at the
/// start of the file to point at it. Rewriting the header is what completes
/// the transaction.
public enum SyncPoint: Sendable {
    /// The transaction's data is written, and the root header is about to be
    /// rewritten to point at it.
    ///
    /// The data must reach the disk before the header does. Otherwise a crash
    /// could leave a header that points at data which never arrived.
    case beforeRootHeader

    /// The root header has been rewritten.
    ///
    /// For the commit to survive a power loss, the header must now reach the
    /// disk too.
    case afterRootHeader
}
