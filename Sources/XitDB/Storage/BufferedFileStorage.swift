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
public final class BufferedFileStorage: WritableStorage {
    private let file: FileStorage

    /// The window: bytes written and not yet flushed, which belong in the
    /// file from `memoryPosition` on.
    private(set) var memory = MemoryBuffer()

    /// Where in the file the window starts. It keeps its value while the
    /// window is empty, and can then be beyond the end of the file.
    private(set) var memoryPosition: UInt64 = 0

    /// The file's length, cached so that `length()` need not ask the
    /// operating system each time. Another process may write to the file
    /// whenever this one is not, so it is only kept while this storage is
    /// writing, and it is dropped whenever the buffer is flushed.
    private(set) var fileLength: UInt64?

    /// The most bytes the buffer holds before it is flushed.
    public let bufferLimit: UInt64

    /// The buffer limit used when none is given: 2 MiB.
    public static let defaultBufferLimit: UInt64 = 2 * 1024 * 1024

    /// Puts a buffer in front of a file storage.
    ///
    /// - Parameters:
    ///   - file: The storage to buffer. Nothing else should write through it
    ///     afterwards.
    ///   - bufferLimit: The most bytes to hold before flushing. A write
    ///     larger than this goes straight to the file.
    public init(_ file: FileStorage, bufferLimit: UInt64 = BufferedFileStorage.defaultBufferLimit) {
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
        access: FileAccess = .create,
        durability: Durability = .full,
        lock: FileLock? = nil,
        bufferLimit: UInt64 = BufferedFileStorage.defaultBufferLimit
    ) throws(XitDBError) {
        self.init(
            try FileStorage(path: path, access: access, durability: durability, lock: lock),
            bufferLimit: bufferLimit
        )
    }

    /// Reads the bytes that start at `offset` into `buffer`, as many as fit,
    /// taking them from the buffer where it holds them and from the file
    /// elsewhere.
    ///
    /// - Parameters:
    ///   - buffer: Where to put the bytes.
    ///   - offset: The position of the first byte to read.
    /// - Returns: The number of bytes read, which is less than `buffer.count`
    ///   only when the storage ends first.
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if reading the file
    ///   fails.
    public func read(into buffer: inout MutableSpan<UInt8>, at offset: UInt64) throws(XitDBError) -> Int {
        var total = 0
        while total < buffer.count {
            let (position, overflow) = offset.addingReportingOverflow(UInt64(total))
            if overflow { break }
            let remaining = buffer.count - total
            let windowEnd = memoryPosition + UInt64(memory.count)

            if position >= memoryPosition && position < windowEnd {
                // from the window
                total += memory.read(
                    into: &buffer,
                    range: total..<buffer.count,
                    at: position - memoryPosition
                )
                continue
            }

            // from the file, stopping where the window starts
            let wanted =
                position < memoryPosition
                ? Int(min(UInt64(remaining), memoryPosition - position))
                : remaining
            let read = try file.read(into: &buffer, range: total..<(total + wanted), at: position)
            total += read
            if read == wanted { continue }

            // The file ended. If the window starts beyond the end of the file
            // and holds bytes, the storage goes on: the gap up to the window
            // will be zeros once the window is flushed, so it reads as zeros
            // now. Zig reports the end of the stream here.
            guard position < memoryPosition && memory.count > 0 else { break }
            for index in total..<(total + wanted - read) {
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
    public func length() throws(XitDBError) -> UInt64 {
        // `??` would lose the typed error.
        let fileLength: UInt64
        if let known = self.fileLength {
            fileLength = known
        } else {
            fileLength = try file.length()
        }
        // A failed write or a rollback can leave an empty window positioned
        // beyond the end of the file.
        if memory.count == 0 { return fileLength }
        return max(memoryPosition + UInt64(memory.count), fileLength)
    }

    /// Writes `bytes` at `offset`, into the buffer if they continue or fall
    /// inside it and to the file otherwise.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to write.
    ///   - offset: The position of the first byte written.
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the buffer had to
    ///   be flushed or the bytes written to the file, and that failed.
    public func write(_ bytes: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        guard bytes.count > 0 else { return }
        let count = UInt64(bytes.count)
        let (end, overflow) = offset.addingReportingOverflow(count)
        if overflow { throw .storageFailure(errno: Platform.fileTooLarge) }

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
            fileLength = try file.length()
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
    /// On a storage opened with ``FileAccess/readOnly`` the file is left as
    /// it is.
    ///
    /// - Parameter length: The new length in bytes.
    /// - Throws: ``XitDBError/invalidLength`` if `length` is larger than the
    ///   storage's length, or ``XitDBError/storageFailure(errno:)`` if the
    ///   file cannot be shortened.
    public func setLength(_ length: UInt64) throws(XitDBError) {
        guard length <= (try self.length()) else { throw .invalidLength }
        let bufferSize = UInt64(memory.count)
        if length <= memoryPosition {
            memory.removeAll()
        } else if length < memoryPosition + bufferSize {
            try memory.setLength(length - memoryPosition)
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
