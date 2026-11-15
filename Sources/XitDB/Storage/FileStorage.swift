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
/// After the root header, ``full`` tries a full sync, then a barrier, then
/// plain `fsync`, and ``ordered`` a barrier, then plain `fsync`.
///
/// Off Apple platforms there are no such calls, and every call the storage
/// makes is plain `fsync`, so ``ordered`` and ``full`` are the same there:
/// one `fsync` at each of the two points, promising what `fsync` promises
/// on that system. On Linux `fsync` waits for the drive to flush, so both
/// levels there give what ``full`` gives on Apple platforms, and cost as
/// much. ``none`` makes no call anywhere.
public enum Durability: Sendable {
    /// Never sync.
    ///
    /// After a power loss or a system crash the file may hold anything,
    /// including a database that cannot be opened. A crash of the process
    /// alone loses nothing that was committed.
    case none

    /// Keep writes in order, without waiting for the drive to flush.
    ///
    /// After a power loss the latest commits may be missing, and a root
    /// header whose write the power loss tore has to be recovered with
    /// ``Database/recover(_:)`` before the database opens.
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

    /// Maps a part of the file into memory for reading, from an offset and
    /// of a length, and returns the mapping's address and zero, or the
    /// error the system refused it with.
    package var map: (Int32, UInt64, Int) -> (address: UInt, error: Int32) = Platform.mapFile

    /// Whether the file is on a volume of this machine, which is asked
    /// once, when a storage that is to read through a memory map opens its
    /// file.
    package var isLocal: (Int32) -> Bool = Platform.volumeIsLocal

    /// Opens a file and returns its descriptor: the call that makes the
    /// file a full copy is written into, beside the one it replaces.
    package var open: (String, FileAccess) throws(XitDBError) -> Int32 = Platform.openFile

    /// Takes an advisory lock on a file without waiting for it.
    package var lock: (Int32, FileLock) throws(XitDBError) -> Void = Platform.lockFile

    /// Gives a file another name, in place of any file that has it.
    package var rename: (String, String) throws(XitDBError) -> Void = Platform.renameFile

    /// Syncs the directory a path's last component lies in, and returns
    /// zero or the error it reported.
    package var syncDirectory: (String, SyncCall) -> Int32 = Platform.syncDirectory

    /// Removes a name from its directory, and says whether there was a
    /// file of that name.
    package var remove: (String) throws(XitDBError) -> Bool = Platform.removeFile

    package init() {}
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
/// The storage owns its file descriptor and closes it when the storage and
/// every ``Snapshot`` of a database in it have gone, which also releases
/// its lock: a snapshot reads through the same descriptor, so the file stays
/// open, and any lock held, until the last snapshot is released. A snapshot
/// is told of a rewrite of the file below its committed size through this
/// storage object only; a second storage on the same path, or another
/// process, rewrites it unseen.
///
/// Opened with `memoryMapped: true`, the storage reads through a memory
/// map of the file: a read is then a copy from memory that the system
/// keeps for the file, where it is a system call otherwise, and readers on
/// several threads, which read through snapshots, no longer wait for one
/// another in the system. Nothing else changes: writes are file writes,
/// and what is read is the same. The map asks more of the file than file
/// calls do, and the initialiser says what; ``isMemoryMapped`` says
/// whether the map was had.
public final class FileStorage: WritableStorage {
    let descriptor: FileDescriptor

    /// The largest committed size that a snapshot of this storage reads up
    /// to. A write below it outside the root header's committed size, or a
    /// truncation below it, trips the fence first.
    private(set) var pinnedSize: UInt64 = 0

    /// Where the root header's committed size is in the file the snapshots
    /// taken so far read: the eight bytes a commit rewrites, which no
    /// snapshot reads from the file. The format's version decides it, so
    /// the database that takes a snapshot says where it is.
    private var committedSizePosition: UInt64 = 0

    /// The fence the snapshots taken so far check; replaced once tripped.
    private(set) var fence = SnapshotFence()

    /// The memory map the storage reads through: there when it was asked
    /// for and the file is on a volume that is mapped.
    private var map: FileMap?

    /// What every snapshot that reads through the map holds with the
    /// storage. While a second reference to it exists such a snapshot is
    /// alive, and the file is not cut below what it reads.
    private var mapLease = MapLease()

    /// The storage's side of its memory map.
    private struct FileMap {
        /// The segments mapped so far.
        var view: FileMapView

        /// The number of bytes at the start of the file that are known to
        /// be in it, and so may be read through the map: the file's length
        /// when the storage opened it, raised by what the storage has
        /// itself written, and lowered before the storage cuts the file.
        /// The one thread that may cut the file is the one that reads
        /// through this.
        var limit: UInt64

        /// The end of what the storage has written, which becomes the
        /// limit at a commit when only committed bytes are to be read
        /// through the map.
        var writtenEnd: UInt64

        /// Whether the system has refused a segment. No further segment is
        /// asked for then; the ones that are mapped go on being read.
        var refused = false
    }

    /// Whether the map's limit follows only what is committed, and not
    /// each write: the brief's first wording of the rule, kept as a switch
    /// so that the two can be measured against each other.
    package var mapsCommittedBytesOnly = false

    /// The size of the segments a file is mapped in.
    package static let defaultSegmentSize = 64 * 1024 * 1024

    /// The bytes at the start of a file that are never read through the
    /// map: the database header and the root header, as long as the longer
    /// of the two format versions has them.
    static let headerBytes: UInt64 = 37

    /// Told by the engine that the file's first `size` bytes are committed,
    /// which it has verified by the trailer that ends them: a storage that
    /// only reads may read that much through its map from now on. It is
    /// what a reader's limit is made of. Committed bytes are not cut by the
    /// file's writer, as long as that writer replaces the file where it
    /// takes a full copy, which a writer on a mapped storage does; what
    /// lies past them can be, by a writer that rolls back or recovers.
    ///
    /// A storage that writes follows its own writes and takes nothing from
    /// this.
    func committedBytesVerified(upTo size: UInt64) {
        guard map != nil, isReadOnly, size > map!.limit else { return }
        map!.limit = size
        map!.writtenEnd = size
    }

    /// Whether the engine is to tell this storage what it has verified:
    /// only a storage that reads through a map and cannot write.
    var takesItsLimitFromTheEngine: Bool { map != nil && isReadOnly }

    /// Whether the storage's reads go through a memory map.
    ///
    /// It is `true` only while all of this holds: the map was asked for
    /// when the storage was opened, the file is on a volume the library
    /// maps, and the system has refused no part of the map so far. A file
    /// on a volume that is not this machine's, as far as the system says,
    /// is read by file calls though the map was asked for, and this is
    /// `false` from the start, with no error. `false` after it was `true`
    /// means partly: the system refused to map a further part of the file,
    /// as it does when the address space is used up; that part and what
    /// follows are read by file calls, and what is mapped goes on being
    /// read through the map.
    public var isMemoryMapped: Bool {
        guard let map else { return false }
        return !map.refused
    }

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
    ///   - memoryMapped: Whether to read the file through a memory map,
    ///     which makes a read a copy from memory where it is a system call
    ///     otherwise. Writes are file writes either way. It needs a lock:
    ///     ``FileLock/exclusive``, or ``FileLock/shared`` for a file opened
    ///     with ``FileAccess/readOnly``. See ``isMemoryMapped`` for whether
    ///     the map was had.
    ///
    ///     With the map, a file that something else shortens ends the
    ///     process: a read of a part that is no longer there is not an
    ///     error but a signal. The library never shortens a file below
    ///     what a snapshot reads (see ``XitDBError/snapshotStillMapped``),
    ///     and the lock keeps a second opener that asks for one out. What
    ///     neither can stop is a program that takes no lock: replace such
    ///     a file by a new file and a rename, never in place. The same
    ///     holds for a volume that goes away, and on iOS for a file whose
    ///     data protection makes it unreadable while the device is locked.
    /// - Throws: ``XitDBError/memoryMapNeedsLock`` if the map is asked for
    ///   without the lock it needs, before the file is opened;
    ///   ``XitDBError/storageFailure(errno:)`` if the file cannot be
    ///   opened or the lock cannot be had at once. A path with a NUL byte in
    ///   it is refused with `EINVAL`, rather than opening the file that the
    ///   part before the NUL names.
    public convenience init(
        path: String,
        access: FileAccess,
        durability: Durability = .full,
        lock: FileLock? = nil,
        memoryMapped: Bool = false
    ) throws(XitDBError) {
        try self.init(
            path: path, access: access, durability: durability, lock: lock, memoryMapped: memoryMapped,
            segmentSize: FileStorage.defaultSegmentSize)
    }

    /// Opens a file as a storage, with the size of the segments its memory
    /// map is made of and the system calls it makes: the tests map in
    /// segments of one page, so that reads cross from one segment to the
    /// next, and replace the call that asks the volume, which is made
    /// here.
    ///
    /// - Precondition: `segmentSize` is a power of two and a multiple of
    ///   the page size.
    package init(
        path: String,
        access: FileAccess,
        durability: Durability = .full,
        lock: FileLock? = nil,
        memoryMapped: Bool,
        segmentSize: Int,
        calls: FileCalls = FileCalls()
    ) throws(XitDBError) {
        if memoryMapped {
            // The map needs the lock that keeps a second opener from
            // cutting the file: an exclusive one, or a shared one where
            // this opener cannot write and a writer that asks for its lock
            // is kept out by it.
            switch (access, lock) {
            case (_, .exclusive?), (.readOnly, .shared?): break
            default: throw .memoryMapNeedsLock
            }
        }
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
        self.calls = calls
        if memoryMapped, calls.isLocal(descriptor.rawValue) {
            // A writer holds the lock, so what is in the file now stays
            // there until this storage cuts it. A reader holds none: what
            // lies past the last commit may be cut by the file's writer, so
            // its limit starts at nothing and is raised by the engine, to
            // each committed size it has verified.
            let length = try Platform.fileLength(descriptor.rawValue)
            let limit: UInt64 = if case .readOnly = access { 0 } else { length }
            map = FileMap(view: FileMapView(segmentSize: segmentSize), limit: limit, writtenEnd: limit)
        }
    }

    var isReadOnly: Bool {
        if case .readOnly = access { true } else { false }
    }

    /// What a snapshot of the file's first `size` bytes reads through: the
    /// storage's descriptor and the fence it checks. From now on the storage
    /// trips that fence before it changes any of those bytes other than the
    /// root header's committed size, or cuts the file below them.
    ///
    /// - Parameter position: Where the root header's committed size is in
    ///   this file, which is the same for every snapshot of one file: a
    ///   file changes its format version only by being replaced, which
    ///   trips the fence.
    ///
    /// With a memory map the snapshot also gets the segments that hold
    /// those bytes, mapped now if they were not, and the storage's lease:
    /// from now on the storage refuses to cut the file below `size` while
    /// the snapshot, or a copy of it, is alive.
    func snapshotSource(upTo size: UInt64, committedSizeAt position: UInt64) -> (
        descriptor: FileDescriptor, fence: SnapshotFence, map: FileMapView?
    ) {
        pinnedSize = max(pinnedSize, size)
        committedSizePosition = position
        var view: FileMapView?
        if map != nil, size > 0 {
            let last = map!.view.segmentIndex(of: size - 1)
            for index in 0...last { _ = segment(at: index) }
            var copy = map!.view
            copy.lease = mapLease
            view = copy
        }
        return (descriptor, fence, view)
    }

    /// The segment at `index`, mapped now if it was not: `nil` if the
    /// system refuses it, after which no further segment is asked for.
    ///
    /// - Precondition: The storage has a memory map.
    private func segment(at index: Int) -> MappedSegment? {
        if index < map!.view.segments.count, let segment = map!.view.segments[index] { return segment }
        if map!.refused { return nil }
        let size = map!.view.segmentSize
        guard
            let segment = MappedSegment(
                descriptor: descriptor.rawValue, offset: UInt64(index) * UInt64(size), length: size,
                map: calls.map)
        else {
            map!.refused = true
            return nil
        }
        while map!.view.segments.count <= index { map!.view.segments.append(nil) }
        map!.view.segments[index] = segment
        return segment
    }

    /// Reads through the memory map the bytes at `offset` that are known
    /// to be in the file, from the first on, mapping the segments they are
    /// in where they were not.
    ///
    /// - Returns: The number of bytes read, less than `range.count` where
    ///   the limit comes first or the system refuses a segment.
    /// - Precondition: The storage has a memory map.
    private func readThroughMap(into buffer: inout MutableSpan<UInt8>, range: Range<Int>, at offset: UInt64) -> Int {
        let limit = map!.limit
        // A read that starts in the two headers takes nothing from the map
        // and is a file call for all of it: the root header's committed
        // size is rewritten in place by every commit, of this process or
        // another, and a reader that takes it by a file call takes it
        // whole.
        guard offset >= Self.headerBytes, offset < limit, range.count > 0 else { return 0 }
        let end = offset + min(UInt64(range.count), limit - offset)
        let first = map!.view.segmentIndex(of: offset)
        let last = map!.view.segmentIndex(of: end - 1)
        for index in first...last where index >= map!.view.segments.count || map!.view.segments[index] == nil {
            if segment(at: index) == nil { break }
        }
        return map!.view.read(into: &buffer, range: range, at: offset, limit: limit)
    }

    /// Trips the fence of every snapshot taken so far, before a write or a
    /// truncation changes bytes they read, and starts a new fence for the
    /// snapshots that come after.
    private func invalidateSnapshots() {
        fence.trip()
        fence = SnapshotFence()
        pinnedSize = 0
    }

    /// Whether a write of `count` bytes at `offset` changes bytes a
    /// snapshot reads: any below the pinned size except the root header's
    /// committed size, which every commit rewrites and no snapshot reads
    /// from the file.
    private func overwritesSnapshot(_ count: Int, at offset: UInt64) -> Bool {
        guard offset < pinnedSize else { return false }
        let end = offset &+ UInt64(count)
        return offset < committedSizePosition || end > committedSizePosition + 8
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
        guard map != nil else { return try calls.read(descriptor.rawValue, &buffer, range, offset) }
        // What is known to be in the file comes from the map, and anything
        // after it by a file call, which is also what says where the file
        // ends.
        let mapped = readThroughMap(into: &buffer, range: range, at: offset)
        if mapped == range.count { return mapped }
        let rest = (range.lowerBound + mapped)..<range.upperBound
        return mapped + (try calls.read(descriptor.rawValue, &buffer, rest, offset + UInt64(mapped)))
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
        if overwritesSnapshot(bytes.count, at: offset) { invalidateSnapshots() }
        try calls.write(descriptor.rawValue, bytes, offset)
        if map != nil {
            // The bytes are in the file now. They may be read through the
            // map at once, or from the commit on.
            map!.writtenEnd = max(map!.writtenEnd, offset + UInt64(bytes.count))
            if !mapsCommittedBytesOnly { map!.limit = map!.writtenEnd }
        }
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
    ///   file's length; ``XitDBError/snapshotStillMapped`` if the storage
    ///   reads through a memory map and `length` is below what a snapshot
    ///   that is still alive reads, in which case nothing is changed; or
    ///   ``XitDBError/storageFailure(errno:)`` if the file cannot be
    ///   shortened.
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
    ///
    /// With a memory map, a cut below what a live snapshot reads is
    /// refused: the snapshot's next read of a part that is gone would end
    /// the process. Every cut the library makes comes through here.
    ///
    /// - Throws: `snapshotStillMapped` for such a cut, before anything is
    ///   changed, and what setting the file's length throws.
    func resize(to length: UInt64) throws(XitDBError) {
        if isReadOnly { return }
        if length < pinnedSize {
            if map != nil, !isKnownUniquelyReferenced(&mapLease) { throw .snapshotStillMapped }
            invalidateSnapshots()
        }
        if map != nil {
            // Before the cut: nothing is read through the map beyond the
            // new end from here on.
            map!.limit = min(map!.limit, length)
            map!.writtenEnd = min(map!.writtenEnd, length)
        }
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
        if case .afterRootHeader = point, map != nil {
            // The commit is in the file: all that was written is committed.
            map!.limit = map!.writtenEnd
        }
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
