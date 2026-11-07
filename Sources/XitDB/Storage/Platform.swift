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

/// A way of asking the operating system to put a file's data on the disk.
package enum SyncCall: Sendable, Equatable {
    /// The data reaches the disk and the drive flushes its cache. On Apple
    /// platforms, `fcntl` with `F_FULLFSYNC`.
    case full

    /// The data reaches the drive before anything written later, without
    /// waiting for the drive to flush. On Apple platforms, `fcntl` with
    /// `F_BARRIERFSYNC`.
    case barrier

    /// `fsync`, which on Apple platforms promises neither that writes reach
    /// the disk in order nor that the drive flushes them.
    case plain
}

enum Platform {
    /// The error for an offset that the operating system cannot express.
    static let fileTooLarge: Int32 = EFBIG

    /// The error the operating system gives for a write to a file that was
    /// opened for reading only.
    static let notOpenForWriting: Int32 = EBADF

    /// The largest offset a byte of a file can end at.
    static let maximumFileOffset = UInt64(off_t.max)

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
    /// - Throws: `storageFailure` with the error `open` reported, or with
    ///   `EINVAL` for a path that contains a NUL byte: a C string ends at
    ///   the first NUL, so `open` would be given the part before it and
    ///   open some other file.
    static func openFile(_ path: String, access: FileAccess) throws(XitDBError) -> Int32 {
        guard !path.utf8.contains(0) else { throw .storageFailure(errno: EINVAL) }
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

    /// The most bytes one `pread` or `pwrite` is asked for: 1 GiB.
    ///
    /// A single call for more than `INT_MAX` bytes fails with `EINVAL` on
    /// Apple platforms, and a value of a few gigabytes written through a
    /// cursor is one write of the storage. Zig's standard library caps its
    /// calls the same way; the loop in ``transfer(_:count:at:callLimit:_:)``
    /// makes as many calls as it takes.
    static let maximumCallSize = 1 << 30

    /// Which way ``transfer(_:count:at:callLimit:_:)`` moves bytes, which
    /// decides what a call that moves nothing, or fewer bytes than it was
    /// asked for, means.
    enum TransferDirection {
        case read
        case write
    }

    /// The loop that `readFile` and `writeFile` share: moves `count` bytes
    /// from `offset` on, in calls of at most `callLimit` bytes each.
    ///
    /// `call` makes one system call for the bytes from `done` on, `wanted`
    /// of them at most, at `fileOffset`, and returns what the system
    /// returned: the bytes moved, zero at the end of the file, or -1 with
    /// `errno` set. A call interrupted by a signal is made again.
    ///
    /// A read stops at the end of the file, which is a call that moves
    /// nothing or fewer bytes than it was asked for: a regular file gives
    /// fewer only at its end, and asking again would cost a call that
    /// returns nothing. A read that reaches the end is common: the trailer
    /// that ends the file, a leaf asked for with a branch's worth. A call
    /// that moves exactly what it was asked for is not short, the cap
    /// included, so a read of more than the cap goes on to the next call.
    /// A read at an offset the system cannot express stops as well:
    /// nothing can be stored there.
    ///
    /// A write stops only when every byte is written. A call that writes
    /// nothing would loop forever and is reported as `EIO`; an offset the
    /// system cannot express is `EFBIG`.
    ///
    /// - Returns: The number of bytes moved.
    /// - Throws: `storageFailure` with the error the call reported, or with
    ///   `EIO` or `EFBIG` as above.
    static func transfer(
        _ direction: TransferDirection,
        count: Int,
        at offset: UInt64,
        callLimit: Int,
        _ call: (_ done: Int, _ wanted: Int, _ fileOffset: off_t) -> Int
    ) throws(XitDBError) -> Int {
        precondition(callLimit > 0, "a call must be allowed at least one byte")
        var total = 0
        while total < count {
            let (position, overflow) = offset.addingReportingOverflow(UInt64(total))
            guard !overflow, let fileOffset = off_t(exactly: position) else {
                if direction == .write { throw .storageFailure(errno: fileTooLarge) }
                break
            }
            let wanted = min(count - total, callLimit)
            let result = call(total, wanted, fileOffset)
            if result > 0 {
                total += result
                if direction == .read && result < wanted { break }
            } else if result == 0 {
                if direction == .write { throw .storageFailure(errno: EIO) }
                break
            } else {
                let error = errno
                if error != EINTR { throw .storageFailure(errno: error) }
            }
        }
        return total
    }

    /// Reads into `buffer[range]` the bytes of the file that start at
    /// `offset`, until the range is full or the file ends, in calls of at
    /// most ``maximumCallSize`` bytes.
    ///
    /// - Returns: The number of bytes read.
    /// - Throws: `storageFailure` with the error `pread` reported.
    static func readFile(
        _ descriptor: Int32,
        into buffer: inout MutableSpan<UInt8>,
        range: Range<Int>,
        at offset: UInt64
    ) throws(XitDBError) -> Int {
        try readFile(descriptor, into: &buffer, range: range, at: offset, callLimit: maximumCallSize)
    }

    /// ``readFile(_:into:range:at:)`` with the cap on each call given, so
    /// that a test can see the loop go on past a call for the whole cap
    /// without a file of gigabytes.
    static func readFile(
        _ descriptor: Int32,
        into buffer: inout MutableSpan<UInt8>,
        range: Range<Int>,
        at offset: UInt64,
        callLimit: Int
    ) throws(XitDBError) -> Int {
        precondition(range.lowerBound >= 0 && range.upperBound <= buffer.count, "the range is out of bounds")
        return try transfer(.read, count: range.count, at: offset, callLimit: callLimit) { done, wanted, fileOffset in
            let start = range.lowerBound + done
            // Safe: `start` and `wanted` stay within the range, which was
            // checked against the span above, and `pread` writes at most
            // `wanted` bytes.
            return buffer.withUnsafeMutableBytes { bytes in
                unsafe pread(descriptor, bytes.baseAddress.unsafelyUnwrapped + start, wanted, fileOffset)
            }
        }
    }

    /// Writes all of `bytes` to the file at `offset`, in calls of at most
    /// ``maximumCallSize`` bytes.
    ///
    /// - Throws: `storageFailure` with the error `pwrite` reported. Some of
    ///   the bytes may have been written.
    static func writeFile(_ descriptor: Int32, _ bytes: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        try writeFile(descriptor, bytes, at: offset, callLimit: maximumCallSize)
    }

    /// ``writeFile(_:_:at:)`` with the cap on each call given, for the same
    /// test as ``readFile(_:into:range:at:callLimit:)``.
    static func writeFile(
        _ descriptor: Int32,
        _ bytes: Span<UInt8>,
        at offset: UInt64,
        callLimit: Int
    ) throws(XitDBError) {
        _ = try transfer(.write, count: bytes.count, at: offset, callLimit: callLimit) { done, wanted, fileOffset in
            // Safe: `done` and `wanted` stay within the span, and `pwrite`
            // reads at most `wanted` bytes.
            bytes.withUnsafeBytes { source in
                unsafe pwrite(descriptor, source.baseAddress.unsafelyUnwrapped + done, wanted, fileOffset)
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
            if unsafe fstat(descriptor, &status) == 0 { return UInt64(clamping: status.st_size) }
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
