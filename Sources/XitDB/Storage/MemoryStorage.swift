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

    /// Reads the bytes that start at `offset` into `buffer`, as many as fit,
    /// and returns how many that was. Nothing is read at or beyond the end.
    func read(into buffer: inout MutableSpan<UInt8>, at offset: UInt64) -> Int {
        guard offset < UInt64(bytes.count) else { return 0 }
        let start = Int(offset)
        let count = min(buffer.count, bytes.count - start)
        buffer.copyBytes(from: bytes.span, at: start, count: count)
        return count
    }

    /// Writes `source` at `offset`, growing the buffer if needed and filling
    /// any gap before the write with zeros. Writing nothing does nothing.
    ///
    /// - Throws: `maxSizeExceeded` if the write would grow the buffer beyond
    ///   `maxSize`. Nothing is changed then.
    mutating func write(_ source: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        guard source.count > 0 else { return }
        let oldCount = bytes.count
        let (end, overflow) = offset.addingReportingOverflow(UInt64(source.count))
        // An end that cannot be an array index cannot be allocated either.
        guard !overflow, let endIndex = Int(exactly: end) else { throw .maxSizeExceeded }
        if endIndex > oldCount {
            if let maxSize, end > maxSize { throw .maxSizeExceeded }
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
    mutating func setLength(_ length: UInt64) throws(XitDBError) {
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
/// Flushing and syncing do nothing.
public final class MemoryStorage: WritableStorage {
    private var buffer: MemoryBuffer

    /// Creates a storage.
    ///
    /// - Parameters:
    ///   - bytes: The storage's initial contents: the bytes of an existing
    ///     database, or nothing for a new one.
    ///   - maxSize: The most bytes the storage may grow to, or `nil` for no
    ///     limit. Initial contents are not checked against it.
    public init(bytes: [UInt8] = [], maxSize: UInt64? = nil) {
        self.buffer = MemoryBuffer(bytes: bytes, maxSize: maxSize)
    }

    /// The most bytes the storage may grow to, or `nil` for no limit.
    ///
    /// A write that would grow the storage beyond the limit throws
    /// ``XitDBError/maxSizeExceeded`` and changes nothing.
    public var maxSize: UInt64? {
        buffer.maxSize
    }

    /// The storage's current contents.
    ///
    /// This is a copy as far as the caller is concerned: later writes to the
    /// storage do not change an array obtained here.
    public var bytes: [UInt8] {
        buffer.bytes
    }

    /// Reads the bytes that start at `offset` into `buffer`, as many as fit.
    ///
    /// This never throws.
    ///
    /// - Parameters:
    ///   - buffer: Where to put the bytes.
    ///   - offset: The position of the first byte to read.
    /// - Returns: The number of bytes read, which is less than `buffer.count`
    ///   only when the storage ends first.
    public func read(into buffer: inout MutableSpan<UInt8>, at offset: UInt64) throws(XitDBError) -> Int {
        self.buffer.read(into: &buffer, at: offset)
    }

    /// The number of bytes in the storage. This never throws.
    public func length() throws(XitDBError) -> UInt64 {
        UInt64(buffer.count)
    }

    /// Writes `bytes` at `offset`, growing the storage if they reach beyond
    /// its end and filling any gap before them with zeros.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to write.
    ///   - offset: The position of the first byte written.
    /// - Throws: ``XitDBError/maxSizeExceeded`` if the write would grow the
    ///   storage beyond ``maxSize``. Nothing is changed then.
    public func write(_ bytes: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        try buffer.write(bytes, at: offset)
    }

    /// Cuts the storage down to `length` bytes.
    ///
    /// - Parameter length: The new length in bytes.
    /// - Throws: ``XitDBError/invalidLength`` if `length` is larger than the
    ///   current length. A memory storage does not grow this way, and nothing
    ///   is changed.
    public func setLength(_ length: UInt64) throws(XitDBError) {
        try buffer.setLength(length)
    }

    /// Does nothing: there is nothing underneath a memory storage to flush
    /// to.
    public func flush() throws(XitDBError) {}

    /// Does nothing: a memory storage is not durable.
    ///
    /// - Parameter point: Which of a commit's two syncs this is.
    public func sync(_ point: SyncPoint) throws(XitDBError) {}
}
