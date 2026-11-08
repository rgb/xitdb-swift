/// A growable run of bytes with the read, write and truncate rules of a
/// storage. It is the state of a ``MemoryStorage`` and the window of a
/// ``BufferedFileStorage``, as Zig's `CoreMemory` is for its two.
struct MemoryBuffer {
    private(set) var bytes: [UInt8]

    /// The most bytes the buffer may grow to, or `nil` for no limit.
    let maxSize: UInt64?

    init(bytes: [UInt8] = [], maxSize: UInt64? = nil) {
        self.bytes = bytes
        self.maxSize = maxSize
    }

    var count: Int {
        bytes.count
    }

    /// Reads the bytes that start at `offset` into `buffer[range]`, as many
    /// as fit, and returns how many that was. Nothing is read at or beyond
    /// the end.
    func read(into buffer: inout MutableSpan<UInt8>, range: Range<Int>, at offset: UInt64) -> Int {
        guard offset < UInt64(bytes.count) else { return 0 }
        let start = Int(offset)
        let count = min(range.count, bytes.count - start)
        buffer.copyBytes(from: bytes.span, at: start, count: count, to: range.lowerBound)
        return count
    }

    /// Calls `body` with the buffer's bytes.
    func withBytes<Failure: Error>(_ body: (Span<UInt8>) throws(Failure) -> Void) throws(Failure) {
        try body(bytes.span)
    }

    /// Writes `source` at `offset`, growing the buffer if needed and filling
    /// any gap before the write with zeros. Writing nothing does nothing.
    ///
    /// - Throws: `maxSizeExceeded` if the write would grow the buffer beyond
    ///   `maxSize`, or beyond what an array can hold. Nothing is changed
    ///   then.
    mutating func write(_ source: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        guard source.count > 0 else { return }
        let oldCount = bytes.count
        let (end, overflow) = offset.addingReportingOverflow(UInt64(source.count))
        // An end that cannot be an array index cannot be allocated either.
        guard !overflow, let endIndex = Int(exactly: end) else { throw .maxSizeExceeded }
        if endIndex > oldCount {
            if let maxSize, end > maxSize { throw .maxSizeExceeded }
            // A write that makes the array grow leaves room for more: the
            // double the array would take for a small write, and half as
            // much again for a large one, such as a replica's full sync,
            // which would otherwise fit exactly and make the next write
            // copy everything.
            if endIndex > bytes.capacity {
                bytes.reserveCapacity(max(endIndex + endIndex / 2, bytes.capacity * 2))
            }
            if offset == UInt64(oldCount) {
                // The write starts at the end, as nearly every write of a
                // transaction does: append the bytes themselves.
                bytes.append(bytesOf: source)
                return
            }
            // Grows the buffer with zeros, which also fills the gap when the
            // write starts beyond the old end.
            bytes.append(contentsOf: repeatElement(0, count: endIndex - oldCount))
        }
        var target = bytes.mutableSpan
        target.copyBytes(from: source, count: source.count, to: Int(offset))
    }

    /// Cuts the buffer down to `length` bytes, keeping its capacity.
    ///
    /// - Throws: `invalidLength` if `length` is larger than the current
    ///   length. Nothing is changed then.
    mutating func truncate(to length: UInt64) throws(XitDBError) {
        guard length <= UInt64(bytes.count) else { throw .invalidLength }
        bytes.removeLast(bytes.count - Int(length))
    }

    /// Empties the buffer, keeping its capacity.
    mutating func removeAll() {
        bytes.removeAll(keepingCapacity: true)
    }
}

/// A storage that keeps a database's bytes in memory.
///
/// The bytes of an in-memory database are a complete database file. A
/// storage can be started from bytes that came from elsewhere, and its
/// ``bytes`` can be sent elsewhere and opened there, which makes an in-memory
/// database usable as a serialization format.
///
/// A ``Snapshot`` of a database in this storage shares the array: taking
/// one is free, and the first write after it copies the array once, as the
/// first write after ``bytes`` does. A writer that keeps a snapshot alive
/// across every commit therefore copies the whole database at each one.
///
/// Flushing and syncing do nothing.
public final class MemoryStorage: WritableStorage {
    // The engine calls a storage several times for every slot it follows,
    // and the run-time exclusivity check on this property cost more than the
    // copy it guarded: 11% of a hash map insert. The check is off for this
    // one property, which makes every use of it `unsafe` to the compiler.
    //
    // Safe: what the check catches is an access to `buffer` that begins
    // while another one, a modification, is still going on. Every access is
    // in a method below, and lasts only while that method runs `MemoryBuffer`
    // code, which takes no closure and calls nothing of the caller's. So no
    // access can begin on a thread while another is in progress there. (The
    // check says nothing about two threads; the class is not `Sendable`.)
    // The spans a caller passes in cannot overlap the buffer's memory either:
    // the buffer hands out no span, and the array that `bytes` returns is
    // copied by the first write that follows it.
    @exclusivity(unchecked) private var buffer: MemoryBuffer

    /// Creates a storage.
    ///
    /// - Parameters:
    ///   - bytes: The storage's initial contents: the bytes of an existing
    ///     database, or nothing for a new one.
    ///   - maxSize: The most bytes the storage may grow to, or `nil` for no
    ///     limit. Initial contents are not checked against it.
    public init(bytes: [UInt8] = [], maxSize: UInt64? = nil) {
        unsafe self.buffer = MemoryBuffer(bytes: bytes, maxSize: maxSize)
    }

    /// The most bytes the storage may grow to, or `nil` for no limit.
    ///
    /// A write that would grow the storage beyond the limit throws
    /// ``XitDBError/maxSizeExceeded`` and changes nothing.
    ///
    /// Without a limit, a write far beyond the end makes the storage as large
    /// as it takes to reach it, and the process ends if that much memory
    /// cannot be had. Set a limit for a storage whose writes are not under
    /// the caller's control. Only a write whose bytes would end beyond what
    /// an array can hold, past `Int.max`, is refused without a limit, with
    /// the same ``XitDBError/maxSizeExceeded``.
    public var maxSize: UInt64? {
        unsafe buffer.maxSize
    }

    /// The storage's current contents.
    ///
    /// This is a copy as far as the caller is concerned: later writes to the
    /// storage do not change an array obtained here.
    public var bytes: [UInt8] {
        unsafe buffer.bytes
    }

    /// Reads the bytes that start at `offset` into a part of `buffer`, as
    /// many as fit there.
    ///
    /// This never throws.
    ///
    /// - Parameters:
    ///   - buffer: Where to put the bytes.
    ///   - range: The part of `buffer` to read into, which must lie within
    ///     it.
    ///   - offset: The position of the first byte to read.
    /// - Returns: The number of bytes read, which is less than `range.count`
    ///   only when the storage ends first.
    /// - Precondition: `range` lies within `buffer`, as the file storages
    ///   require too; a range that does not is a programming error, whatever
    ///   the offset.
    public func read(
        into buffer: inout MutableSpan<UInt8>,
        range: Range<Int>,
        at offset: UInt64
    ) throws(XitDBError) -> Int {
        precondition(range.lowerBound >= 0 && range.upperBound <= buffer.count, "the range is out of bounds")
        return unsafe self.buffer.read(into: &buffer, range: range, at: offset)
    }

    /// The number of bytes in the storage. This never throws.
    public var length: UInt64 {
        get throws(XitDBError) {
            UInt64(unsafe buffer.count)
        }
    }

    /// Writes `bytes` at `offset`, growing the storage if they reach beyond
    /// its end and filling any gap before them with zeros.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to write.
    ///   - offset: The position of the first byte written.
    /// - Throws: ``XitDBError/maxSizeExceeded`` if the write would grow the
    ///   storage beyond ``maxSize``, or, with or without a limit, if the
    ///   bytes would end beyond what an array can hold, past `Int.max`.
    ///   Nothing is changed then.
    public func write(_ bytes: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        try unsafe buffer.write(bytes, at: offset)
    }

    /// Cuts the storage down to `length` bytes.
    ///
    /// - Parameter length: The new length in bytes.
    /// - Throws: ``XitDBError/invalidLength`` if `length` is larger than the
    ///   current length. A memory storage does not grow this way, and nothing
    ///   is changed.
    public func truncate(to length: UInt64) throws(XitDBError) {
        try unsafe buffer.truncate(to: length)
    }

    /// Does nothing: there is nothing underneath a memory storage to flush
    /// to.
    public func flush() throws(XitDBError) {}

    /// Does nothing: a memory storage is not durable.
    ///
    /// - Parameter point: Which of a commit's two syncs this is.
    public func sync(_ point: SyncPoint) throws(XitDBError) {}
}

@available(*, unavailable, message: "a memory storage is used from one thread at a time")
extension MemoryStorage: Sendable {}
