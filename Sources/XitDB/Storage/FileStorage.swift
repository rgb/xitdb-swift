/// How a file storage opens its file.
public enum FileAccess: Sendable {
    /// Open an existing file for reading only.
    ///
    /// Writing to the storage fails, and a request to shorten it is ignored.
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
/// On Apple platforms the levels use `F_BARRIERFSYNC` and `F_FULLFSYNC`.
/// Plain `fsync` is not a level there, because it promises neither that
/// writes reach the disk in order nor that the drive flushes them. Where a
/// volume does not support a call, the storage falls back to the next
/// strongest one that it does.
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

    /// The call that asks the operating system to sync. Tests replace it to
    /// see which calls a durability level makes.
    let syncCall: (Int32, SyncCall) -> Int32

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
    ///   opened or the lock cannot be had at once.
    public convenience init(
        path: String,
        access: FileAccess = .create,
        durability: Durability = .full,
        lock: FileLock? = nil
    ) throws(XitDBError) {
        try self.init(path: path, access: access, durability: durability, lock: lock, syncCall: Platform.syncFile)
    }

    init(
        path: String,
        access: FileAccess,
        durability: Durability,
        lock: FileLock?,
        syncCall: @escaping (Int32, SyncCall) -> Int32
    ) throws(XitDBError) {
        self.descriptor = try FileDescriptor(opening: path, access: access)
        self.access = access
        self.durability = durability
        self.syncCall = syncCall
        // If either of these throws, the descriptor is closed as the storage
        // goes. The file is emptied only after the lock is held.
        if let lock {
            try Platform.lockFile(descriptor.rawValue, lock)
        }
        if case .truncate = access {
            try Platform.setFileLength(descriptor.rawValue, 0)
        }
    }

    private var isReadOnly: Bool {
        if case .readOnly = access { true } else { false }
    }

    /// Reads the bytes of the file that start at `offset` into `buffer`, as
    /// many as fit.
    ///
    /// - Parameters:
    ///   - buffer: Where to put the bytes.
    ///   - offset: The position in the file of the first byte to read.
    /// - Returns: The number of bytes read, which is less than `buffer.count`
    ///   only when the file ends first.
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if reading fails.
    public func read(into buffer: inout MutableSpan<UInt8>, at offset: UInt64) throws(XitDBError) -> Int {
        try read(into: &buffer, range: 0..<buffer.count, at: offset)
    }

    /// Reads into `buffer[range]`, for the buffered storage, which fills a
    /// buffer piece by piece.
    func read(into buffer: inout MutableSpan<UInt8>, range: Range<Int>, at offset: UInt64) throws(XitDBError) -> Int {
        try Platform.readFile(descriptor.rawValue, into: &buffer, range: range, at: offset)
    }

    /// The length of the file.
    ///
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the file's length
    ///   cannot be read.
    public func length() throws(XitDBError) -> UInt64 {
        try Platform.fileLength(descriptor.rawValue)
    }

    /// Writes `bytes` to the file at `offset`.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to write.
    ///   - offset: The position in the file of the first byte written.
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if writing fails,
    ///   which it always does on a storage opened with
    ///   ``FileAccess/readOnly``.
    public func write(_ bytes: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        guard bytes.count > 0 else { return }
        try Platform.writeFile(descriptor.rawValue, bytes, at: offset)
    }

    /// Cuts the file down to `length` bytes.
    ///
    /// On a storage opened with ``FileAccess/readOnly`` this does nothing.
    ///
    /// - Parameter length: The new length in bytes.
    /// - Throws: ``XitDBError/invalidLength`` if `length` is larger than the
    ///   file's length, or ``XitDBError/storageFailure(errno:)`` if the file
    ///   cannot be shortened.
    public func setLength(_ length: UInt64) throws(XitDBError) {
        guard length <= (try self.length()) else { throw .invalidLength }
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
        try Platform.setFileLength(descriptor.rawValue, length)
    }

    /// Does nothing: a file storage holds no bytes back.
    public func flush() throws(XitDBError) {}

    /// Asks the operating system to put the file's data on the disk, as far
    /// as ``durability`` calls for.
    ///
    /// - Parameter point: Which of a commit's two syncs this is.
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the sync fails.
    public func sync(_ point: SyncPoint) throws(XitDBError) {
        var call: SyncCall
        switch (durability, point) {
        case (.none, _): return
        case (.full, .afterRootHeader): call = .full
        case (.full, .beforeRootHeader), (.ordered, _): call = .barrier
        }
        while true {
            let error = syncCall(descriptor.rawValue, call)
            if error == 0 { return }
            // A volume that does not offer this kind of sync gets the next
            // strongest. Any other error is a real failure.
            guard Platform.isUnsupported(error), let weaker = call.nextWeaker else {
                throw .storageFailure(errno: error)
            }
            call = weaker
        }
    }
}
