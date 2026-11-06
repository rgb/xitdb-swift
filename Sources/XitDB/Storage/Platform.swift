// The one file that imports the platform C library. Everything the storage
// layer needs from the operating system goes through `Platform`.

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Android)
    import Android
#endif

/// A way of asking the operating system to put a file's data on the disk,
/// from strongest to weakest.
enum SyncCall: Sendable, Equatable {
    /// The data reaches the disk and the drive flushes its cache. On Apple
    /// platforms, `fcntl` with `F_FULLFSYNC`.
    case full

    /// The data reaches the drive before anything written later, without
    /// waiting for the drive to flush. On Apple platforms, `fcntl` with
    /// `F_BARRIERFSYNC`.
    case barrier

    /// `fsync`.
    case plain

    /// The call to fall back to when a volume does not support this one.
    var nextWeaker: SyncCall? {
        switch self {
        case .full: .barrier
        case .barrier: .plain
        case .plain: nil
        }
    }
}

enum Platform {
    /// The error for an offset that the operating system cannot express.
    static let fileTooLarge: Int32 = EFBIG

    /// Whether an error from a sync call means that the volume does not
    /// offer that kind of sync, as opposed to the sync having failed.
    static func isUnsupported(_ error: Int32) -> Bool {
        error == ENOTSUP || error == EOPNOTSUPP || error == ENOTTY || error == EINVAL
    }

    /// Opens a file and returns its descriptor.
    ///
    /// A file opened with `truncate` is not emptied here. The caller empties
    /// it once it holds whatever lock it was asked to take, so that a file
    /// locked by someone else is not destroyed by an opener that then fails.
    ///
    /// - Throws: `storageFailure` with the error `open` reported.
    static func openFile(_ path: String, access: FileAccess) throws(XitDBError) -> Int32 {
        let flags: Int32 =
            switch access {
            case .readOnly: O_RDONLY
            case .readWrite: O_RDWR
            case .create, .truncate: O_RDWR | O_CREAT
            }
        while true {
            // Safe: the path is passed as a C string that `open` only reads,
            // and only during the call.
            let descriptor = unsafe open(path, flags | O_CLOEXEC, 0o644)
            if descriptor >= 0 { return descriptor }
            let error = errno
            if error != EINTR { throw .storageFailure(errno: error) }
        }
    }

    /// Closes a descriptor. A failure is ignored: there is nothing to be
    /// done about it, and the descriptor is gone either way.
    static func closeFile(_ descriptor: Int32) {
        _ = close(descriptor)
    }

    /// Reads into `buffer[range]` the bytes of the file that start at
    /// `offset`, until the range is full or the file ends.
    ///
    /// - Returns: The number of bytes read.
    /// - Throws: `storageFailure` with the error `pread` reported.
    static func readFile(
        _ descriptor: Int32,
        into buffer: inout MutableSpan<UInt8>,
        range: Range<Int>,
        at offset: UInt64
    ) throws(XitDBError) -> Int {
        precondition(range.lowerBound >= 0 && range.upperBound <= buffer.count, "the range is out of bounds")
        var total = 0
        while total < range.count {
            let (position, overflow) = offset.addingReportingOverflow(UInt64(total))
            // Nothing can be stored beyond the largest offset the system has.
            guard !overflow, let fileOffset = off_t(exactly: position) else { break }
            let start = range.lowerBound + total
            let wanted = range.count - total
            // Safe: `start` and `wanted` stay within the span, which was
            // checked above, and `pread` writes at most `wanted` bytes.
            let result = buffer.withUnsafeMutableBytes { bytes in
                unsafe pread(descriptor, bytes.baseAddress.unsafelyUnwrapped + start, wanted, fileOffset)
            }
            if result > 0 {
                total += result
            } else if result == 0 {
                break
            } else {
                let error = errno
                if error != EINTR { throw .storageFailure(errno: error) }
            }
        }
        return total
    }

    /// Writes all of `bytes` to the file at `offset`.
    ///
    /// - Throws: `storageFailure` with the error `pwrite` reported. Some of
    ///   the bytes may have been written.
    static func writeFile(_ descriptor: Int32, _ bytes: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        var total = 0
        while total < bytes.count {
            let (position, overflow) = offset.addingReportingOverflow(UInt64(total))
            guard !overflow, let fileOffset = off_t(exactly: position) else {
                throw .storageFailure(errno: fileTooLarge)
            }
            let start = total
            let wanted = bytes.count - total
            // Safe: `start` and `wanted` stay within the span, and `pwrite`
            // reads at most `wanted` bytes.
            let result = bytes.withUnsafeBytes { source in
                unsafe pwrite(descriptor, source.baseAddress.unsafelyUnwrapped + start, wanted, fileOffset)
            }
            if result > 0 {
                total += result
            } else if result == 0 {
                // A write that makes no progress would loop forever.
                throw .storageFailure(errno: EIO)
            } else {
                let error = errno
                if error != EINTR { throw .storageFailure(errno: error) }
            }
        }
    }

    /// The length of the file.
    ///
    /// - Throws: `storageFailure` with the error `fstat` reported.
    static func fileLength(_ descriptor: Int32) throws(XitDBError) -> UInt64 {
        var status = stat()
        while true {
            // Safe: `fstat` writes one `stat` structure through the pointer.
            if unsafe fstat(descriptor, &status) == 0 { return UInt64(status.st_size) }
            let error = errno
            if error != EINTR { throw .storageFailure(errno: error) }
        }
    }

    /// Sets the length of the file.
    ///
    /// - Throws: `storageFailure` with the error `ftruncate` reported.
    static func setFileLength(_ descriptor: Int32, _ length: UInt64) throws(XitDBError) {
        guard let fileLength = off_t(exactly: length) else { throw .storageFailure(errno: fileTooLarge) }
        while true {
            if ftruncate(descriptor, fileLength) == 0 { return }
            let error = errno
            if error != EINTR { throw .storageFailure(errno: error) }
        }
    }

    /// Makes one sync call.
    ///
    /// On platforms without the stronger calls, every kind is `fsync`.
    ///
    /// - Returns: Zero, or the error the call reported.
    static func syncFile(_ descriptor: Int32, _ call: SyncCall) -> Int32 {
        while true {
            let result: Int32
            #if canImport(Darwin)
                switch call {
                case .full: result = fcntl(descriptor, F_FULLFSYNC)
                case .barrier: result = fcntl(descriptor, F_BARRIERFSYNC)
                case .plain: result = fsync(descriptor)
                }
            #else
                result = fsync(descriptor)
            #endif
            if result != -1 { return 0 }
            let error = errno
            if error != EINTR { return error }
        }
    }

    /// Takes an advisory lock on the whole file without waiting for it.
    ///
    /// - Throws: `storageFailure` with the error `flock` reported, which is
    ///   `EWOULDBLOCK` when the lock is held elsewhere.
    static func lockFile(_ descriptor: Int32, _ lock: FileLock) throws(XitDBError) {
        let operation: Int32 =
            switch lock {
            case .shared: LOCK_SH
            case .exclusive: LOCK_EX
            }
        while true {
            if flock(descriptor, operation | LOCK_NB) == 0 { return }
            let error = errno
            if error != EINTR { throw .storageFailure(errno: error) }
        }
    }
}
