/// A storage that reads and writes a file through an in-memory buffer. This
/// is the storage to use for a database in a file.
///
/// Writes collect in the buffer and reach the file together, when the buffer
/// is flushed, instead of one system call at a time. A database flushes when
/// it commits. Bytes that were written and not flushed are lost if the
/// storage goes away, which is what should happen to a transaction that was
/// never committed.
///
/// The buffer is one window onto the file. It starts where the first write
/// lands and grows as writes continue from there. It is flushed and started
/// again when a write lands beyond its end or would grow it past
/// ``bufferLimit``. A write before the window goes straight to the file.
///
/// The storage opens its file itself and is the only thing that writes
/// through it: a file written by anything else while the window holds
/// bytes would lose them or keep stale ones.
public final class BufferedFileStorage: WritableStorage {
    private let file: FileStorage

    /// The window: bytes written and not yet flushed, which belong in the
    /// file from `memoryPosition` on.
    private(set) var memory = MemoryBuffer()

    /// Where in the file the window starts. It keeps its value while the
    /// window is empty, and can then be beyond the end of the file.
    private(set) var memoryPosition: UInt64 = 0

    /// The file's length, cached so that `length` need not ask the
    /// operating system each time. Another process may write to the file
    /// whenever this one is not, so it is only kept while this storage is
    /// writing, and it is dropped whenever the buffer is flushed.
    private(set) var fileLength: UInt64?

    /// The most bytes the buffer holds before it is flushed.
    public let bufferLimit: UInt64

    /// The buffer limit used when none is given: 2 MiB.
    public static let defaultBufferLimit: UInt64 = 2 * 1024 * 1024

    /// Puts a buffer in front of a file storage. Internal: the tests use it
    /// to put their own calls on the file; a client opens the file through
    /// ``init(path:access:durability:lock:bufferLimit:)``, so that nothing
    /// else can write through it.
    ///
    /// - Parameters:
    ///   - file: The storage to buffer. Nothing else may write through it
    ///     afterwards.
    ///   - bufferLimit: The most bytes to hold before flushing. A write
    ///     larger than this goes straight to the file.
    init(_ file: FileStorage, bufferLimit: UInt64 = BufferedFileStorage.defaultBufferLimit) {
        self.file = file
        self.bufferLimit = bufferLimit
    }

    /// Opens a file as a buffered storage.
    ///
    /// - Parameters:
    ///   - path: The path of the file.
    ///   - access: Whether to open the file for reading only, and whether to
    ///     create or empty it.
    ///   - durability: How far to go to put a commit on the disk.
    ///   - lock: An advisory lock to take on the file, or `nil` for none.
    ///   - bufferLimit: The most bytes to hold before flushing.
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the file cannot be
    ///   opened or the lock cannot be had at once.
    public convenience init(
        path: String,
        access: FileAccess,
        durability: Durability = .full,
        lock: FileLock? = nil,
        bufferLimit: UInt64 = BufferedFileStorage.defaultBufferLimit
    ) throws(XitDBError) {
        self.init(
            try FileStorage(path: path, access: access, durability: durability, lock: lock),
            bufferLimit: bufferLimit
        )
    }

    /// Reads the bytes that start at `offset` into a part of `buffer`, as
    /// many as fit there, taking them from the storage's own buffer where it
    /// holds them and from the file elsewhere.
    ///
    /// - Parameters:
    ///   - buffer: Where to put the bytes.
    ///   - range: The part of `buffer` to read into, which must lie within
    ///     it.
    ///   - offset: The position of the first byte to read.
    /// - Returns: The number of bytes read, which is less than `range.count`
    ///   only when the storage ends first.
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if reading the file
    ///   fails.
    public func read(
        into buffer: inout MutableSpan<UInt8>,
        range: Range<Int>,
        at offset: UInt64
    ) throws(XitDBError) -> Int {
        precondition(range.lowerBound >= 0 && range.upperBound <= buffer.count, "the range is out of bounds")
        var total = 0
        while total < range.count {
            let (position, overflow) = offset.addingReportingOverflow(UInt64(total))
            if overflow { break }
            let remaining = range.count - total
            let destination = range.lowerBound + total
            let windowEnd = memoryPosition + UInt64(memory.count)

            if position >= memoryPosition && position < windowEnd {
                // from the window
                let read = memory.read(
                    into: &buffer,
                    range: destination..<range.upperBound,
                    at: position - memoryPosition
                )
                // The window holds at least one byte at this position, so
                // this cannot be zero. Stopping is better than looping if it
                // ever is.
                if read == 0 { break }
                total += read
                continue
            }

            // from the file, stopping where the window starts
            let wanted =
                position < memoryPosition
                ? Int(min(UInt64(remaining), memoryPosition - position))
                : remaining
            let read = try file.read(into: &buffer, range: destination..<(destination + wanted), at: position)
            total += read
            if read == wanted { continue }

            // The file ended. If the window starts beyond the end of the file
            // and holds bytes, the storage goes on: the gap up to the window
            // will be zeros once the window is flushed, so it reads as zeros
            // now. Zig reports the end of the stream here.
            guard position < memoryPosition && memory.count > 0 else { break }
            for index in (destination + read)..<(destination + wanted) {
                buffer[index] = 0
            }
            total += wanted - read
        }
        return total
    }

    /// The length of the storage: the file's length, or the end of the
    /// buffered bytes if that is further.
    ///
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the file's length
    ///   cannot be read.
    public var length: UInt64 {
        get throws(XitDBError) {
            // `??` would lose the typed error.
            let fileLength: UInt64
            if let known = self.fileLength {
                fileLength = known
            } else {
                fileLength = try file.length
            }
            // A failed write or a rollback can leave an empty window positioned
            // beyond the end of the file.
            if memory.count == 0 { return fileLength }
            return max(memoryPosition + UInt64(memory.count), fileLength)
        }
    }

    /// Writes `bytes` at `offset`, into the buffer if they continue or fall
    /// inside it and to the file otherwise.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to write.
    ///   - offset: The position of the first byte written.
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the buffer had to
    ///   be flushed or the bytes written to the file, and that failed. Also,
    ///   at once and without buffering anything, for a storage opened with
    ///   ``FileAccess/readOnly`` and for bytes that would lie beyond the
    ///   largest offset a file can have: the same errors, at the same
    ///   moment, as ``FileStorage`` gives.
    public func write(_ bytes: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        guard bytes.count > 0 else { return }
        // Zig accepts these writes into the buffer and fails when it flushes.
        try file.checkWritable(bytes, at: offset)
        let count = UInt64(bytes.count)
        let end = offset + count

        // The buffer is one contiguous window of the file that starts at
        // `memoryPosition`. Start a new window at this write if the buffer
        // is empty, the write is beyond the end of the window, or the write
        // would grow the window beyond the limit.
        let bufferSize = UInt64(memory.count)
        if bufferSize == 0
            || offset > memoryPosition + bufferSize
            || (offset >= memoryPosition && offset - memoryPosition + count > bufferLimit)
        {
            try flush()
            memoryPosition = offset
        }

        if fileLength == nil {
            fileLength = try file.length
        }

        if offset >= memoryPosition && offset - memoryPosition + count <= bufferLimit {
            // into the buffer
            try memory.write(bytes, at: offset - memoryPosition)
        } else {
            // to the file. A direct write that overlaps the buffered bytes
            // would be overwritten by a later flush of what the buffer holds
            // for the same place, so flush first.
            if offset < memoryPosition + UInt64(memory.count) && end > memoryPosition {
                try flush()
            }
            try writeToFile(bytes, at: offset)
        }
    }

    /// Cuts the storage down to `length` bytes.
    ///
    /// Buffered bytes beyond the new end are discarded, not flushed. A
    /// rollback must not depend on writing the data it is throwing away,
    /// because that write may be the one that failed, on a full disk for
    /// example.
    ///
    /// On a storage opened with ``FileAccess/readOnly`` a length within the
    /// storage leaves the file as it is; a larger one is still
    /// ``XitDBError/invalidLength``.
    ///
    /// - Parameter length: The new length in bytes.
    /// - Throws: ``XitDBError/invalidLength`` if `length` is larger than the
    ///   storage's length, or ``XitDBError/storageFailure(errno:)`` if the
    ///   file cannot be shortened.
    public func truncate(to length: UInt64) throws(XitDBError) {
        guard length <= (try self.length) else { throw .invalidLength }
        let bufferSize = UInt64(memory.count)
        if length <= memoryPosition {
            memory.removeAll()
        } else if length < memoryPosition + bufferSize {
            try memory.truncate(to: length - memoryPosition)
        }
        fileLength = nil
        // This can lengthen the file: when the window started beyond the end
        // of the file, the gap before it becomes part of the file here.
        try file.resize(to: length)
    }

    /// Writes the buffered bytes to the file and empties the buffer.
    ///
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if writing fails. The
    ///   bytes stay in the buffer, and a later flush tries again.
    public func flush() throws(XitDBError) {
        fileLength = nil
        if memory.count > 0 {
            let position = memoryPosition
            try memory.withBytes { (bytes: Span<UInt8>) throws(XitDBError) in
                try writeToFile(bytes, at: position)
            }
            memory.removeAll()
        }
    }

    /// Flushes, then asks the operating system to put the file's data on the
    /// disk, as far as the file storage's durability level calls for.
    ///
    /// - Parameter point: Which of a commit's two syncs this is.
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if flushing or syncing
    ///   fails.
    public func sync(_ point: SyncPoint) throws(XitDBError) {
        try flush()
        try file.sync(point)
    }

    private func writeToFile(_ bytes: Span<UInt8>, at position: UInt64) throws(XitDBError) {
        // If the write fails partway, the file's length is unknown.
        let known = fileLength
        fileLength = nil
        try file.write(bytes, at: position)
        if let known {
            fileLength = max(known, position + UInt64(bytes.count))
        }
    }
}

@available(*, unavailable, message: "a buffered file storage is used from one thread at a time")
extension BufferedFileStorage: Sendable {}
