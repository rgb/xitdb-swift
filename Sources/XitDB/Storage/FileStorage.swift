/// How a file storage opens its file.
public enum FileAccess: Sendable {
    /// Open an existing file for reading only.
    ///
    /// Writing to the storage fails. A request to shorten it is ignored; a
    /// length larger than the file's is still ``XitDBError/invalidLength``,
    /// as on every storage.
    case readOnly

    /// Open an existing file for reading and writing.
    case readWrite

    /// Open a file for reading and writing, creating it if it does not
    /// exist.
    case create

    /// Open a file for reading and writing, creating it if it does not exist
    /// and emptying it if it does.
    ///
    /// When a lock is asked for as well, the file is emptied only once the
    /// lock is held.
    case truncate
}

/// How far a file storage goes to put a commit on the disk.
///
/// A database syncs twice for every commit: once when the transaction's data
/// is written, before the root header is changed to point at it, and once
/// after. The level decides what each of those does.
///
/// On Apple platforms the levels use `F_BARRIERFSYNC` and `F_FULLFSYNC`:
/// ``ordered`` makes a barrier sync at both points, and ``full`` a barrier
/// sync before the root header and a full sync after it. Plain `fsync` is
/// not a level there, because it promises neither that writes reach the
/// disk in order nor that the drive flushes them.
///
/// Not every volume supports every call. Where one is not supported, the
/// storage tries the next best, which can keep less than the level
/// promises, and plain `fsync` only when nothing better is left. In
/// particular the sync before
/// the root header, which is what keeps a file openable after a power loss,
/// falls back from a barrier to a full sync before it settles for less.
///
/// Off Apple platforms there are no such calls, and every call the storage
/// makes is plain `fsync`, so ``ordered`` and ``full`` are the same there:
/// one `fsync` at each of the two points, promising what `fsync` promises
/// on that system. ``none`` makes no call anywhere.
public enum Durability: Sendable {
    /// Never sync.
    ///
    /// After a power loss or a system crash the file may hold anything,
    /// including a database that cannot be opened. A crash of the process
    /// alone loses nothing that was committed.
    case none

    /// Keep writes in order, without waiting for the drive to flush.
    ///
    /// After a power loss the file opens, but the latest commits may be
    /// missing.
    case ordered

    /// Keep writes in order, and have the drive flush before a commit
    /// returns.
    ///
    /// A commit that has returned is on stable storage. This is the slowest
    /// level and the default.
    case full
}

/// An advisory lock that a file storage takes on its file when it opens it
/// and holds until it goes away.
///
/// Locks are advisory: they keep out only other openers that ask for a lock
/// too. The lock is never waited for. If it cannot be had at once, opening
/// the storage fails with ``XitDBError/storageFailure(errno:)`` carrying
/// `EWOULDBLOCK`.
public enum FileLock: Sendable {
    /// Any number of openers may hold a shared lock at once, as long as none
    /// holds an exclusive one. For readers.
    case shared

    /// Only one opener may hold an exclusive lock, and no shared lock may be
    /// held with it. For the writer.
    case exclusive
}

/// The system calls a file storage makes, which tests replace to watch
/// them or to make them fail, and the benchmark replaces to count them.
package struct FileCalls {
    /// Makes one sync call and returns zero or the error it reported.
    package var sync: (Int32, SyncCall) -> Int32 = Platform.syncFile

    /// Writes all of the bytes to the file at an offset.
    package var write: (Int32, Span<UInt8>, UInt64) throws(XitDBError) -> Void = Platform.writeFile

    /// Reads into a part of a buffer from an offset, as many bytes as fit
    /// there or are left.
    package var read: (Int32, inout MutableSpan<UInt8>, Range<Int>, UInt64) throws(XitDBError) -> Int =
        Platform.readFile

    /// The file's length.
    package var length: (Int32) throws(XitDBError) -> UInt64 = Platform.fileLength

    /// Sets the file's length.
    package var setLength: (Int32, UInt64) throws(XitDBError) -> Void = Platform.setFileLength
}

/// Owns an open file descriptor and closes it when the last reference goes.
///
/// The descriptor never changes and positional reads on it are safe from any
/// thread, so this owner can be shared.
final class FileDescriptor: Sendable {
    let rawValue: Int32

    init(opening path: String, access: FileAccess) throws(XitDBError) {
        self.rawValue = try Platform.openFile(path, access: access)
    }

    deinit {
        Platform.closeFile(rawValue)
    }
}

/// A storage that reads and writes a file directly, with no buffering.
///
/// Every read and write is a system call, which makes this the slowest
/// storage for a database that is written to. ``BufferedFileStorage`` is the
/// one to use for that. A file storage suits a database that is only read.
///
/// The storage owns its file descriptor and closes it when the storage goes
/// away, which also releases its lock.
public final class FileStorage: WritableStorage {
    let descriptor: FileDescriptor

    /// How the file was opened.
    public let access: FileAccess

    /// How far the storage goes to put a commit on the disk.
    public let durability: Durability

    /// The system calls the storage makes. Tests replace them to see which
    /// sync calls a durability level makes, and to make a write fail the way
    /// a full disk would; the benchmark counts them.
    package var calls = FileCalls()

    /// Opens a file as a storage.
    ///
    /// - Parameters:
    ///   - path: The path of the file.
    ///   - access: Whether to open the file for reading only, and whether to
    ///     create or empty it.
    ///   - durability: How far to go to put a commit on the disk.
    ///   - lock: An advisory lock to take on the file, or `nil` for none.
    ///     Holding a lock on a file in a shared container while an iOS app is
    ///     suspended gets the app terminated, which is why none is taken
    ///     unless asked for.
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the file cannot be
    ///   opened or the lock cannot be had at once. A path with a NUL byte in
    ///   it is refused with `EINVAL`, rather than opening the file that the
    ///   part before the NUL names.
    public init(
        path: String,
        access: FileAccess,
        durability: Durability = .full,
        lock: FileLock? = nil
    ) throws(XitDBError) {
        self.descriptor = try FileDescriptor(opening: path, access: access)
        self.access = access
        self.durability = durability
        // If either of these throws, the descriptor is closed as the storage
        // goes. The file is emptied only after the lock is held.
        if let lock {
            try Platform.lockFile(descriptor.rawValue, lock)
        }
        if case .truncate = access {
            try Platform.setFileLength(descriptor.rawValue, 0)
        }
    }

    var isReadOnly: Bool {
        if case .readOnly = access { true } else { false }
    }

    /// Reads the bytes of the file that start at `offset` into a part of
    /// `buffer`, as many as fit there.
    ///
    /// - Parameters:
    ///   - buffer: Where to put the bytes.
    ///   - range: The part of `buffer` to read into, which must lie within
    ///     it.
    ///   - offset: The position in the file of the first byte to read.
    /// - Returns: The number of bytes read, which is less than `range.count`
    ///   only when the file ends first.
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if reading fails.
    public func read(
        into buffer: inout MutableSpan<UInt8>,
        range: Range<Int>,
        at offset: UInt64
    ) throws(XitDBError) -> Int {
        try calls.read(descriptor.rawValue, &buffer, range, offset)
    }

    /// The length of the file.
    ///
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the file's length
    ///   cannot be read.
    public var length: UInt64 {
        get throws(XitDBError) {
            try calls.length(descriptor.rawValue)
        }
    }

    /// Writes `bytes` to the file at `offset`.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to write.
    ///   - offset: The position in the file of the first byte written.
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if writing fails. It
    ///   always does on a storage opened with ``FileAccess/readOnly``, and
    ///   for bytes that would lie beyond the largest offset a file can have.
    public func write(_ bytes: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        guard bytes.count > 0 else { return }
        try checkWritable(bytes, at: offset)
        try calls.write(descriptor.rawValue, bytes, offset)
    }

    /// Rejects a write that can only fail, before any of it is written: one
    /// to a file opened for reading only, or one that reaches beyond the
    /// largest offset a file can have. Both file storages check with this,
    /// so that they fail at the same moment with the same error.
    func checkWritable(_ bytes: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        if isReadOnly { throw .storageFailure(errno: Platform.notOpenForWriting) }
        let (end, overflow) = offset.addingReportingOverflow(UInt64(bytes.count))
        if overflow || end > Platform.maximumFileOffset { throw .storageFailure(errno: Platform.fileTooLarge) }
    }

    /// Cuts the file down to `length` bytes.
    ///
    /// On a storage opened with ``FileAccess/readOnly`` a length within the
    /// file leaves it as it is; a larger one is still ``XitDBError/invalidLength``.
    ///
    /// - Parameter length: The new length in bytes.
    /// - Throws: ``XitDBError/invalidLength`` if `length` is larger than the
    ///   file's length, or ``XitDBError/storageFailure(errno:)`` if the file
    ///   cannot be shortened.
    public func truncate(to length: UInt64) throws(XitDBError) {
        guard length <= (try self.length) else { throw .invalidLength }
        try resize(to: length)
    }

    /// Sets the file's length, shorter or longer, as Zig's `CoreFile` does.
    /// A longer file is filled with zeros. On a read-only file this does
    /// nothing.
    ///
    /// The buffered storage needs the growing half: when its window starts
    /// beyond the end of the file and is cut away, the gap before it has to
    /// become part of the file.
    func resize(to length: UInt64) throws(XitDBError) {
        if isReadOnly { return }
        try calls.setLength(descriptor.rawValue, length)
    }

    /// Does nothing: a file storage holds no bytes back.
    public func flush() throws(XitDBError) {}

    /// Asks the operating system to put the file's data on the disk, as far
    /// as ``durability`` calls for.
    ///
    /// - Parameter point: Which of a commit's two syncs this is.
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the sync fails.
    public func sync(_ point: SyncPoint) throws(XitDBError) {
        let order = Self.syncOrder(durability, point)
        for index in order.indices {
            guard let call = order[index] else { return }
            let error = calls.sync(descriptor.rawValue, call)
            if error == 0 { return }
            // A volume that does not offer this kind of sync gets the next
            // call in the order. Any other error is a real failure, and so
            // is running out of calls to try.
            let isLast = index + 1 == order.count || order[index + 1] == nil
            if isLast || !Platform.isUnsupported(error) {
                throw .storageFailure(errno: error)
            }
        }
    }

    /// The sync calls to try at a sync point, in order, each one only if the
    /// volume does not support the one before it.
    ///
    /// The order keeps the level's promise as far as the volume allows.
    /// Before the root header the promise is ordering: the data must be on
    /// the disk before the header that points at it. A full sync gives that
    /// too, so it comes before plain `fsync`, which does not. After the root
    /// header the `full` level promises that the commit is on stable
    /// storage, and the `ordered` level promises nothing more than it
    /// already has, so there a weaker call loses nothing.
    static func syncOrder(_ durability: Durability, _ point: SyncPoint) -> InlineArray<3, SyncCall?> {
        switch (durability, point) {
        case (.none, _): [nil, nil, nil]
        case (.ordered, .beforeRootHeader), (.full, .beforeRootHeader): [.barrier, .full, .plain]
        case (.full, .afterRootHeader): [.full, .barrier, .plain]
        case (.ordered, .afterRootHeader): [.barrier, .plain, nil]
        }
    }
}

@available(*, unavailable, message: "a file storage is used from one thread at a time")
extension FileStorage: Sendable {}
