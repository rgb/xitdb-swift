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
///
/// The three kinds exist on Apple platforms. On Linux every kind is `fsync`,
/// which there waits for the drive to flush as well, so it is the full sync,
/// and no barrier call exists.
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

    /// The error number for a name that leads to no file.
    static let noSuchFile: Int32 = ENOENT

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
    static func openFile(_ path: String, _ opening: FileOpening) throws(XitDBError) -> Int32 {
        guard !path.utf8.contains(0) else { throw .storageFailure(errno: EINVAL) }
        let flags: Int32 =
            switch opening {
            case .toRead: O_RDONLY
            case .toWrite(.readWrite): O_RDWR
            case .toWrite(.create), .toWrite(.truncate): O_RDWR | O_CREAT
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
    /// nothing can be stored there. Nor is a read asked to reach past the
    /// largest offset: Apple platforms answer such a call with nothing,
    /// Linux refuses it with `EINVAL`, so the call is cut to end at that
    /// offset and the read stops when nothing is left before it.
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
            let room = direction == .read ? Int(clamping: off_t.max - fileOffset) : Int.max
            let wanted = min(count - total, callLimit, room)
            if wanted == 0 { break }
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

    // MARK: The memory map

    /// The size of a page of memory. A mapping starts at a multiple of it
    /// in its file.
    static var pageSize: Int {
        Int(getpagesize())
    }

    /// Maps `length` bytes of an open file, from `offset`, into memory for
    /// reading only, shared with the file: what a file call writes there
    /// afterwards is what the memory holds.
    ///
    /// The range may reach beyond the end of the file. Reading a page of it
    /// that lies wholly beyond the end, at the time of the read, is not an
    /// error the process can catch: it is a signal that ends it. Whoever
    /// holds the mapping reads only bytes known to be in the file.
    ///
    /// - Parameters:
    ///   - offset: Where in the file the mapping starts, a multiple of
    ///     ``pageSize``.
    ///   - length: The number of bytes to map, more than zero.
    /// - Returns: The mapping's address and zero, or the error the system
    ///   refused it with.
    static func mapFile(_ descriptor: Int32, offset: UInt64, length: Int) -> (address: UInt, error: Int32) {
        guard length > 0, let fileOffset = off_t(exactly: offset) else { return (0, EINVAL) }
        // Safe: the system chooses the address and nothing is passed in by
        // pointer. The address leaves here as an integer, and only
        // `MappedSegment` makes a pointer of it again. A refusal is the
        // pointer with every bit set, `MAP_FAILED`.
        let address = unsafe UInt(bitPattern: mmap(nil, length, PROT_READ, MAP_SHARED, descriptor, fileOffset))
        if address == UInt.max { return (0, errno) }
        return (address, 0)
    }

    /// Asks the system whether it would give the process `bytes` of memory
    /// right now, by mapping that much memory that belongs to no file and
    /// unmapping it at once. None of it is touched, and nothing is written
    /// anywhere, where a `malloc` the system refuses writes a message to the
    /// process's standard error on macOS.
    ///
    /// A yes is not a promise that the memory can be used: a system may
    /// grant address space it cannot back, and end the process when the
    /// bytes are written. A no is what an allocation of that size would
    /// have met, which for a Swift array ends the process.
    ///
    /// - Returns: Zero if the system gave the memory, or the error it
    ///   refused with, `ENOMEM` as a rule.
    static func askForMemory(_ bytes: Int) -> Int32 {
        guard bytes > 0 else { return 0 }
        #if canImport(Darwin)
            let anonymous = MAP_PRIVATE | MAP_ANON
        #else
            let anonymous = MAP_PRIVATE | MAP_ANONYMOUS
        #endif
        // Safe: the system chooses the address, nothing is passed in by
        // pointer, and nothing is read or written through the mapping, which
        // is unmapped before the function returns. A refusal is the pointer
        // with every bit set, `MAP_FAILED`.
        let address = unsafe UInt(bitPattern: mmap(nil, bytes, PROT_READ | PROT_WRITE, anonymous, -1, 0))
        if address == UInt.max { return errno }
        _ = unsafe munmap(UnsafeMutableRawPointer(bitPattern: address), bytes)
        return 0
    }

    /// The error of a system that has no memory to give, `ENOMEM`.
    static let noMemory: Int32 = ENOMEM

    /// The machine's physical memory in bytes, asked of the system once:
    /// its count of pages of physical memory times the size of one. `nil`
    /// where the system does not say.
    ///
    /// It is the machine's figure, or the virtual machine's, and not a
    /// limit the process itself may be under, such as a container's.
    static let physicalMemory: UInt64? = memory(
        pages: sysconf(Int32(_SC_PHYS_PAGES)), pageSize: sysconf(Int32(_SC_PAGESIZE)))

    /// The bytes in `pages` pages of `pageSize` bytes, or `nil` where
    /// either is not a number of something, as the system's answer of -1
    /// for what it cannot say is not, or where no integer holds the
    /// product.
    static func memory(pages: Int, pageSize: Int) -> UInt64? {
        guard pages > 0, pageSize > 0 else { return nil }
        let bytes = UInt64(pages).multipliedReportingOverflow(by: UInt64(pageSize))
        return bytes.overflow ? nil : bytes.partialValue
    }

    /// Tells the system that a mapped range is read in no order, as a
    /// database is that is read by following pointers: a read of a page
    /// that is not in memory then brings that page, and not its neighbours
    /// with it. Left to itself the system brings neighbours, on Linux a
    /// fixed stretch of some megabytes around the page, which a process
    /// short of memory pays for with the pages it needs next.
    ///
    /// It is advice: a refusal changes nothing and is not reported.
    static func adviseRandom(address: UInt, length: Int) {
        // Safe: the range is one that `mapFile` returned, and the call
        // reads and writes nothing through the pointer.
        _ = unsafe madvise(UnsafeMutableRawPointer(bitPattern: address), length, MADV_RANDOM)
    }

    /// Unmaps what ``mapFile(_:offset:length:)`` mapped.
    static func unmapFile(address: UInt, length: Int) {
        // Safe: the range is one that `mapFile` returned, unmapped once, by
        // the one owner of the mapping when it goes.
        _ = unsafe munmap(UnsafeMutableRawPointer(bitPattern: address), length)
    }

    /// Whether an open file is on a volume of this machine, as far as the
    /// system says: the mount's local flag on Apple platforms, and on Linux
    /// a kind of file system that is not one of the network and
    /// passed-through ones (``FileSystemKind/isRemote``). A file whose
    /// volume cannot be asked is not local.
    ///
    /// A file that is not local is not read through a memory map: what the
    /// other side of such a mount does to the file is not ours to know.
    ///
    /// Linux gives a file system's kind through `statfs`, which Swift is
    /// not shown there. So the kind is taken from the system's own list of
    /// mounts, `/proc/self/mountinfo`: of the mount that has the device
    /// number the open file reports, or, where none has it, as on a btrfs
    /// subvolume, of the longest mount point that leads to the file's path.
    static func volumeIsLocal(_ descriptor: Int32) -> Bool {
        #if canImport(Darwin)
            var status = statfs()
            while true {
                // Safe: `fstatfs` writes one `statfs` structure through the
                // pointer.
                if unsafe fstatfs(descriptor, &status) == 0 { break }
                if errno != EINTR { return false }
            }
            return status.f_flags & UInt32(MNT_LOCAL) != 0
        #else
            var status = stat()
            while true {
                // Safe: `fstat` writes one `stat` structure through the
                // pointer.
                if unsafe fstat(descriptor, &status) == 0 { break }
                if errno != EINTR { return false }
            }
            guard let mounts = wholeFile("/proc/self/mountinfo") else { return false }
            let kind = fileSystemKind(
                device: UInt64(status.st_dev), path: pathOfOpenFile(descriptor), mounts: mounts)
            guard let kind else { return false }
            return !kind.isRemote
        #endif
    }

    /// The kind of file system a file is on, from the text of Linux's list
    /// of mounts: the kind of the mount whose device number is `device`,
    /// as `fstat` gives it, or, where no mount has that number, of the
    /// longest mount point that leads to `path`; `nil` where neither is
    /// found. A later mount is taken before an earlier one that it covers.
    /// A path the system gives with ` (deleted)` after it is the path of a
    /// file that has no name any more, and leads nowhere.
    ///
    /// A line of the list reads `36 35 98:0 / /mnt rw,noatime shared:1 -
    /// ext4 /dev/root rw`: the third field is the device, the fifth the
    /// mount point, with a space, a tab, a newline and a backslash written
    /// as a backslash and three octal digits, and the kind follows the
    /// lone hyphen. That word is made a ``FileSystemKind`` here, and is
    /// not compared as a word anywhere.
    static func fileSystemKind(device: UInt64, path: String?, mounts: String) -> FileSystemKind? {
        // the numbers as glibc packs them into a device number
        let major = ((device >> 32) & 0xFFFF_F000) | ((device >> 8) & 0xFFF)
        let minor = ((device >> 12) & 0xFFFF_FF00) | (device & 0xFF)
        let wanted = "\(major):\(minor)"
        let path = path.flatMap { $0.hasSuffix(" (deleted)") ? nil : $0 }
        var byDevice: FileSystemKind?
        var byPath: (length: Int, kind: FileSystemKind)?
        for line in mounts.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count >= 7, let hyphen = fields.dropFirst(6).firstIndex(of: "-"), hyphen + 1 < fields.count
            else { continue }
            let kind = FileSystemKind(linuxName: String(fields[hyphen + 1]))
            if fields[2] == wanted { byDevice = kind }
            if let path {
                let mountPoint = unescapedMountPoint(fields[4])
                let leads = mountPoint == "/" || path == mountPoint || path.hasPrefix(mountPoint + "/")
                if leads, mountPoint.utf8.count >= byPath?.length ?? 0 {
                    byPath = (mountPoint.utf8.count, kind)
                }
            }
        }
        return byDevice ?? byPath?.kind
    }

    /// A mount point as the list of mounts writes it, with its escapes of a
    /// backslash and three octal digits put back into the bytes they stand
    /// for.
    private static func unescapedMountPoint(_ field: Substring) -> String {
        let bytes = Array(field.utf8)
        var plain: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let isOctal = { (byte: UInt8) in byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "7") }
            if bytes[index] == UInt8(ascii: "\\"), index + 3 < bytes.count, isOctal(bytes[index + 1]),
                isOctal(bytes[index + 2]), isOctal(bytes[index + 3])
            {
                let value =
                    Int(bytes[index + 1] - 48) * 64 + Int(bytes[index + 2] - 48) * 8 + Int(bytes[index + 3] - 48)
                plain.append(UInt8(truncatingIfNeeded: value))
                index += 4
            } else {
                plain.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: plain, as: UTF8.self)
    }

    #if !canImport(Darwin)
        /// The text of a file that the system makes up as it is read, which
        /// has no length to ask for: read to its end, or `nil` if it cannot
        /// be opened or read, or is longer than any list of mounts.
        private static func wholeFile(_ path: String) -> String? {
            // Safe: the path is passed as a C string that `open` only reads,
            // and only during the call.
            let descriptor = unsafe open(path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            defer { _ = close(descriptor) }
            var bytes: [UInt8] = []
            let size = 16 * 1024
            var buffer = [UInt8](repeating: 0, count: size)
            while bytes.count < 16 * 1024 * 1024 {
                // Safe: `read` writes at most `size` bytes into the buffer,
                // which holds that many and outlives the call.
                let count = unsafe read(descriptor, &buffer, size)
                if count == 0 { return String(decoding: bytes, as: UTF8.self) }
                if count < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                bytes.append(contentsOf: buffer[0..<count])
            }
            return nil
        }

        /// The path the system has for an open file, or `nil` if it gives
        /// none.
        private static func pathOfOpenFile(_ descriptor: Int32) -> String? {
            let size = 4096
            var buffer = [CChar](repeating: 0, count: size)
            // Safe: `readlink` writes at most `size` bytes into the buffer,
            // which holds that many and outlives the call, and the link's
            // path is a C string it only reads.
            let count = unsafe readlink("/proc/self/fd/\(descriptor)", &buffer, size)
            guard count > 0, count < size else { return nil }
            return String(decoding: buffer[0..<count].map { UInt8(truncatingIfNeeded: $0) }, as: UTF8.self)
        }
    #endif

    // MARK: Replacing a file by another

    /// The directory a path's last component lies in: what comes before
    /// its last slash, `/` for a path directly under the root, and `.` for
    /// a path with no slash in it.
    static func directory(of path: String) -> String {
        let bytes = Array(path.utf8)
        guard let slash = bytes.lastIndex(of: UInt8(ascii: "/")) else { return "." }
        if slash == 0 { return "/" }
        return String(decoding: bytes[..<slash], as: UTF8.self)
    }

    /// Gives the file at `source` the name `destination`, in place of any
    /// file that has it: one step, after which the name is the new file's
    /// and before which it is the old one's. Whoever has the old file open
    /// keeps it, with no name.
    ///
    /// The step is not on the disk until the directory is synced
    /// (``syncDirectory(of:_:)``).
    ///
    /// - Throws: `storageFailure` with the error `rename` reported, or with
    ///   `EINVAL` for a path that contains a NUL byte.
    static func renameFile(_ source: String, to destination: String) throws(XitDBError) {
        guard !source.utf8.contains(0), !destination.utf8.contains(0) else { throw .storageFailure(errno: EINVAL) }
        while true {
            // Safe: both paths are passed as C strings that `rename` only
            // reads, and only during the call.
            if unsafe rename(source, destination) == 0 { return }
            let error = errno
            if error != EINTR { throw .storageFailure(errno: error) }
        }
    }

    /// Syncs the directory that `path`'s last component lies in, which is
    /// what puts a file's new name, or its removal, on the disk.
    ///
    /// - Returns: Zero, or the error the directory's opening or its sync
    ///   reported, `EINVAL` for a path that contains a NUL byte.
    static func syncDirectory(of path: String, _ call: SyncCall) -> Int32 {
        guard !path.utf8.contains(0) else { return EINVAL }
        let directory = directory(of: path)
        var descriptor: Int32 = -1
        while descriptor < 0 {
            // Safe: the path is passed as a C string that `open` only reads,
            // and only during the call.
            descriptor = unsafe open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if descriptor < 0 {
                let error = errno
                if error != EINTR { return error }
            }
        }
        defer { _ = close(descriptor) }
        return syncFile(descriptor, call)
    }

    /// Removes the name `path` from its directory.
    ///
    /// - Returns: Whether there was a file of that name.
    /// - Throws: `storageFailure` with the error `unlink` reported, other
    ///   than there being no such file, or with `EINVAL` for a path that
    ///   contains a NUL byte.
    static func removeFile(_ path: String) throws(XitDBError) -> Bool {
        guard !path.utf8.contains(0) else { throw .storageFailure(errno: EINVAL) }
        while true {
            // Safe: the path is passed as a C string that `unlink` only
            // reads, and only during the call.
            if unsafe unlink(path) == 0 { return true }
            let error = errno
            if error == ENOENT { return false }
            if error != EINTR { throw .storageFailure(errno: error) }
        }
    }

    /// Gives the open file `new` what the open file `old` has beyond its
    /// bytes, as far as the system lets a process carry it: what a new file
    /// that takes an old one's place must have before a byte is written to
    /// it, so that it is never less protected than the old one.
    ///
    /// On every system the permission bits, first. On Apple platforms then
    /// the access control list, the file's flags, its owner and group
    /// where the process may set them, and its extended attributes, the
    /// mark that keeps a file out of backups among them, by the system's
    /// own call for a file's metadata; and the data protection class,
    /// which that call does not carry, where the old file has one. On
    /// Linux the owner and the group: a process that is neither the
    /// superuser nor the owner may not give a file to another owner, and
    /// then the group alone is asked for; where that is refused too the
    /// new file stays the process's own, which is no error.
    ///
    /// Not carried, on any system: the file's times and its other names.
    /// On Linux, also not: the extended attributes and the access control
    /// list, which is one of them there (Swift is not shown the calls),
    /// the security labels and the file's flags.
    ///
    /// - Parameter setOwner: Sets the owner and the group of an open file
    ///   and returns zero or the error; `uid_t.max` for the owner leaves
    ///   the owner as it is. Used on Linux only; a test puts a refusing
    ///   one in its place.
    /// - Throws: `storageFailure` with the error of the first step that
    ///   failed, other than a refusal of the owner or the group on Linux.
    static func carryAttributes(
        from old: Int32, to new: Int32, setOwner: (Int32, uid_t, gid_t) -> Int32 = Platform.setOwner
    ) throws(XitDBError) {
        var status = stat()
        while true {
            // Safe: `fstat` writes one `stat` structure through the
            // pointer.
            if unsafe fstat(old, &status) == 0 { break }
            let error = errno
            if error != EINTR { throw .storageFailure(errno: error) }
        }
        while fchmod(new, status.st_mode & 0o7777) != 0 {
            let error = errno
            if error != EINTR { throw .storageFailure(errno: error) }
        }
        #if canImport(Darwin)
            // No state is passed: the call reads the one open file's
            // metadata and sets the other's.
            if fcopyfile(old, new, nil, copyfile_flags_t(COPYFILE_METADATA)) != 0 {
                throw .storageFailure(errno: errno)
            }
            // The class a file's bytes are encrypted under. A file that has
            // none, or a system that has no classes, answers with an error
            // here, and there is nothing to carry.
            let protection = fcntl(old, F_GETPROTECTIONCLASS)
            if protection >= 0, fcntl(new, F_SETPROTECTIONCLASS, protection) != 0 {
                throw .storageFailure(errno: errno)
            }
        #else
            var error = setOwner(new, status.st_uid, status.st_gid)
            if error == EPERM {
                error = setOwner(new, uid_t.max, status.st_gid)
                if error == EPERM { error = 0 }
            }
            if error != 0 { throw .storageFailure(errno: error) }
        #endif
    }

    /// Sets the owner and the group of an open file; `uid_t.max` for the
    /// owner, or `gid_t.max` for the group, leaves that one as it is.
    ///
    /// - Returns: Zero, or the error `fchown` reported.
    static func setOwner(_ descriptor: Int32, _ owner: uid_t, _ group: gid_t) -> Int32 {
        while true {
            if fchown(descriptor, owner, group) == 0 { return 0 }
            let error = errno
            if error != EINTR { return error }
        }
    }

    /// The path of the file itself that `path` leads to, every symbolic
    /// link in it followed.
    ///
    /// - Throws: `storageFailure` with the error `realpath` reported, as
    ///   for a path that leads nowhere, or with `EINVAL` for a path that
    ///   contains a NUL byte.
    static func realPath(_ path: String) throws(XitDBError) -> String {
        guard !path.utf8.contains(0) else { throw .storageFailure(errno: EINVAL) }
        // Safe: the path is passed as a C string that `realpath` only
        // reads; with no buffer given it returns one of its own, which is
        // read as a C string and freed here.
        guard let resolved = unsafe realpath(path, nil) else { throw .storageFailure(errno: errno) }
        defer { unsafe free(resolved) }
        return unsafe String(cString: resolved)
    }

    /// Whether the name `path`, its symbolic links followed now, leads to
    /// the file that `descriptor` has open: the same file on the same
    /// volume. A path that leads to no file leads to another one.
    ///
    /// - Throws: `storageFailure` with the error the system reported for
    ///   the open file or for the path, other than there being no file at
    ///   the path, or with `EINVAL` for a path that contains a NUL byte.
    static func leads(_ path: String, to descriptor: Int32) throws(XitDBError) -> Bool {
        guard !path.utf8.contains(0) else { throw .storageFailure(errno: EINVAL) }
        var open = stat()
        while true {
            // Safe: `fstat` writes one `stat` structure through the
            // pointer.
            if unsafe fstat(descriptor, &open) == 0 { break }
            let error = errno
            if error != EINTR { throw .storageFailure(errno: error) }
        }
        var named = stat()
        while true {
            // Safe: the path is passed as a C string that `stat` only
            // reads, and it writes one `stat` structure through the
            // pointer.
            if unsafe stat(path, &named) == 0 { break }
            let error = errno
            if error == ENOENT || error == ENOTDIR { return false }
            if error != EINTR { throw .storageFailure(errno: error) }
        }
        return open.st_dev == named.st_dev && open.st_ino == named.st_ino
    }

    /// Lets go of an advisory lock on an open file. A failure is ignored:
    /// the lock goes with the last descriptor on the open file at the
    /// latest.
    static func unlockFile(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
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
