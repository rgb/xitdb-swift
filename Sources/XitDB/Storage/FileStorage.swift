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

    /// Tells the system how a segment of the map that was just made is
    /// read, given its address and its length: in no order. Made once for
    /// each segment; its answer is not looked at.
    package var advise: (UInt, Int) -> Void = Platform.adviseRandom

    /// Gives a new open file what an old one has beyond its bytes: the
    /// permission bits and what else the system lets a process carry.
    package var carryAttributes: (Int32, Int32) throws(XitDBError) -> Void = {
        (old: Int32, new: Int32) throws(XitDBError) in
        try Platform.carryAttributes(from: old, to: new)
    }

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

    /// Takes over a descriptor that is open already, which this owner
    /// closes when it goes.
    init(adopting rawValue: Int32) {
        self.rawValue = rawValue
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
/// every ``Snapshot`` of a database in it have gone: a snapshot reads
/// through the same descriptor, so the file stays open until the last
/// snapshot is released. A lock is the storage's, and is let go when the
/// storage goes, whatever snapshots are left. A snapshot is told of a
/// rewrite of the file below its committed size through this storage
/// object only; a second storage on the same path, or another process,
/// rewrites it unseen.
///
/// A full copy from a replica's source, ``Database/applyReplicated(at:from:count:)``
/// at 0, does not rewrite the file. It is written into a new file beside
/// it, named after it with `.incoming` added, which is given the file's
/// name when the copy's committed size has been written and synced. A copy
/// that fails, or a process that ends in the middle of one, leaves the
/// database that was there; a snapshot taken before reads the old file on.
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
    /// The open file. It is another one while a replacement is under way,
    /// and from the replacement's end on: the new file's.
    private(set) var descriptor: FileDescriptor

    /// The path the storage was opened with, as it was given.
    let path: String

    /// The path of the file itself, every symbolic link in ``path``
    /// followed once, when the storage opened it. A replacement gives this
    /// name to the new file, so that a link stays a link.
    let realPath: String

    /// The lock the storage holds on its file, if it asked for one.
    private let lock: FileLock?

    /// What a replacement that has begun keeps of the file it is to
    /// replace, until it ends one way or the other.
    private var replacement: Replacement?

    /// The file a replacement is to replace, as the storage had it: its
    /// descriptor, its map, and what its snapshots were given.
    private struct Replacement {
        let old: FileDescriptor
        let oldMap: FileMap?
        let oldPinnedSize: UInt64
        let oldCommittedSizePosition: UInt64
        let oldFence: SnapshotFence
        /// The new file's name until it is given the old one's.
        let incomingPath: String
    }

    /// What is added to a file's path to name the new file that a full
    /// copy is written into, beside the file it replaces.
    static let incomingSuffix = ".incoming"

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

    deinit {
        // The lock is the storage's: let go now, though a snapshot may keep
        // the file open after it. During a replacement the storage holds
        // the old file's lock and the new file's, and lets both go.
        guard lock != nil else { return }
        Platform.unlockFile(descriptor.rawValue)
        if let replacement { Platform.unlockFile(replacement.old.rawValue) }
    }

    // MARK: A read in file order

    /// A read of the stream of committed bytes, which feeds a replica: as
    /// ``read(into:range:at:)``, but by a file call whether or not the
    /// file is read through a map.
    ///
    /// The map is advised as read in no order, and a read in file order
    /// through it brings the file in a page at a time. The stream is the
    /// one read the library knows to be in file order, and the system
    /// reads ahead of a file call: a stream of a file that was not in
    /// memory took between a sixth and a tenth of the time this way that
    /// it took through the advised map, on macOS and on Linux in a
    /// container.
    func readForStream(
        into buffer: inout MutableSpan<UInt8>, range: Range<Int>, at offset: UInt64
    ) throws(XitDBError) -> Int {
        try calls.read(descriptor.rawValue, &buffer, range, offset)
    }

    // MARK: Replacing the file

    /// Whether the path the storage was opened with, its symbolic links
    /// followed now, still leads to the file the storage has open. It does
    /// not once that file has been replaced by another under its name, as
    /// a full copy by the file's writer replaces it, or removed, or once a
    /// link in the path has been changed to lead elsewhere: opening the
    /// path again would then give another file than this storage reads.
    ///
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the system cannot
    ///   be asked about the open file or the path.
    func leadsToItsFile() throws(XitDBError) -> Bool {
        try Platform.leads(path, to: descriptor.rawValue)
    }

    /// Whether the path this storage was opened with still leads to the
    /// file the storage reads.
    ///
    /// A file can be replaced under its name while a storage has it open:
    /// another file is renamed over it, as a restore or a deployment does;
    /// it is removed; or a symbolic link in the path is changed to lead
    /// elsewhere. A storage that was open before keeps the file it opened.
    /// It goes on reading what it read, whole, and sees nothing of what is
    /// written under the name from then on. `false` says that this has
    /// happened: opening the path again would give another file than this
    /// storage reads, or none. A reader in another process than the one
    /// that replaces the file asks, to learn that it has to open the path
    /// again.
    ///
    /// It says where a path leads, and not whether the file changed: bytes
    /// that a writer writes into the same file leave it `true`, and this
    /// storage reads them.
    ///
    /// The path is the one given at opening, as it was given: its symbolic
    /// links are followed anew at each asking, and a relative path is read
    /// against the working directory of that moment. The answer is about
    /// that moment too: the file can be replaced right after it.
    ///
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the system cannot
    ///   be asked about the open file or about the path. That no file is at
    ///   the path is not an error: it is `false`.
    public var isStillAtPath: Bool {
        get throws(XitDBError) {
            // While this storage itself brings a new file, the file under
            // the name is still the old one, which every other opener has.
            try Platform.leads(path, to: (replacement?.old ?? descriptor).rawValue)
        }
    }

    /// Whether a replacement has begun and not ended.
    var isReplacing: Bool { replacement != nil }

    /// Begins the replacement of the file by a new one: a file beside it,
    /// named with ``incomingSuffix``, is made, locked as this storage's
    /// file is, given what the old file has beyond its bytes, the
    /// permission bits first, and emptied; and from here on this storage
    /// reads and writes the new file. The old file is untouched and keeps
    /// its name, so that every other opener, and every snapshot taken
    /// before, has the old file until ``commitReplacement()`` and after it.
    ///
    /// A file of that name left by a copy that did not end is removed
    /// first: this storage holds the old file's lock, so nobody is writing
    /// it.
    ///
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the storage cannot
    ///   write, or if the new file cannot be made, locked, given the old
    ///   file's attributes or emptied; nothing is begun then, and no file
    ///   is left.
    func beginReplacement() throws(XitDBError) {
        precondition(replacement == nil, "a replacement of this file has begun already")
        if isReadOnly { throw .storageFailure(errno: Platform.notOpenForWriting) }
        let incomingPath = realPath + Self.incomingSuffix
        _ = try calls.remove(incomingPath)
        let incoming = FileDescriptor(adopting: try calls.open(incomingPath, .create))
        do {
            // The new file is locked before a byte is written to it, and
            // while the old one's lock is held: across the rename the path
            // never names a file without its writer's lock.
            if let lock { try calls.lock(incoming.rawValue, lock) }
            try calls.carryAttributes(descriptor.rawValue, incoming.rawValue)
            try calls.setLength(incoming.rawValue, 0)
        } catch {
            _ = try? calls.remove(incomingPath)
            throw error
        }
        replacement = Replacement(
            old: descriptor, oldMap: map, oldPinnedSize: pinnedSize,
            oldCommittedSizePosition: committedSizePosition, oldFence: fence, incomingPath: incomingPath)
        descriptor = incoming
        // The new file has a map of its own, with nothing known to be in
        // it, and no snapshot reads it: the snapshots taken so far keep the
        // old file's descriptor, segments and fence.
        if map != nil {
            map = FileMap(view: FileMapView(segmentSize: map!.view.segmentSize), limit: 0, writtenEnd: 0)
        }
        pinnedSize = 0
        committedSizePosition = 0
        fence = SnapshotFence()
    }

    /// Ends a replacement by giving the new file the old one's name. Call
    /// it when the new file is whole and synced. Until the name is given,
    /// the path is the old file's; from then on it is the new file's,
    /// whatever fails afterwards. Then the directory is synced, as the
    /// storage's durability asks, which is what puts the new name on the
    /// disk, and the old file's lock is let go: whoever has the old file
    /// open, a snapshot or another reader, goes on reading it, and nothing
    /// cuts it any more.
    ///
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the name cannot be
    ///   given, or if the new file is no longer the one under the name it
    ///   was made under ("no such file"), in which cases the replacement is
    ///   still under way and ``abandonReplacement()`` ends it; or if the
    ///   directory cannot be
    ///   synced, in which case the new file has the name all the same and
    ///   the replacement has ended.
    func commitReplacement() throws(XitDBError) {
        guard let replacement else { return }
        // The name the new file was made under must still be the new
        // file's. A second writer of the same database, which "one writer"
        // forbids and which no lock kept out, takes a new file it finds
        // for one left behind, removes it and makes its own under that
        // name; to give that name's file the database's name now would put
        // a copy that is not finished there.
        guard try Platform.leads(replacement.incomingPath, to: descriptor.rawValue) else {
            throw .storageFailure(errno: Platform.noSuchFile)
        }
        try calls.rename(replacement.incomingPath, realPath)
        self.replacement = nil
        defer {
            if lock != nil { Platform.unlockFile(replacement.old.rawValue) }
        }
        let order = Self.syncOrder(durability, .afterRootHeader)
        for index in order.indices {
            guard let call = order[index] else { return }
            let error = calls.syncDirectory(realPath, call)
            if error == 0 { return }
            let isLast = index + 1 == order.count || order[index + 1] == nil
            if isLast || !Platform.isUnsupported(error) {
                throw .storageFailure(errno: error)
            }
        }
    }

    /// Ends a replacement by going back to the old file, which is as it
    /// was: this storage reads and writes it again, with its map and its
    /// snapshots as they were, and the new file is removed. If the new
    /// file cannot be removed it stays under its own name, where the next
    /// replacement, or the next writer that opens the file with its lock,
    /// removes it.
    func abandonReplacement() {
        guard let replacement else { return }
        // The new file is removed if its name still leads to it. A file
        // that another writer has since made under that name is not this
        // storage's to remove.
        let isStillItsOwn = (try? Platform.leads(replacement.incomingPath, to: descriptor.rawValue)) == true
        descriptor = replacement.old
        map = replacement.oldMap
        pinnedSize = replacement.oldPinnedSize
        committedSizePosition = replacement.oldCommittedSizePosition
        fence = replacement.oldFence
        self.replacement = nil
        if isStillItsOwn { _ = try? calls.remove(replacement.incomingPath) }
    }

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
    ///     otherwise. Writes are file writes either way. A storage that
    ///     can write needs ``FileLock/exclusive`` for it, which says that
    ///     it is the file's one writer; one opened with
    ///     ``FileAccess/readOnly`` needs no lock, and reads through the
    ///     map only what is committed. See ``isMemoryMapped`` for whether
    ///     the map was had.
    ///
    ///     With the map, a file that something shortens ends the process:
    ///     a read of a part that is no longer there is not an error but a
    ///     signal. The library does not shorten a file below what is
    ///     committed: a full copy is written into a new file, and what a
    ///     failed transaction leaves is cut off beyond the committed size.
    ///     What it cannot stop is a program that shortens or rewrites the
    ///     file in place: an earlier version of this library, or the
    ///     original, making a full copy; a tool that copies onto the file;
    ///     and your own call of ``truncate(to:)`` below what a ``Snapshot``
    ///     reads, which a snapshot being read on another thread at that
    ///     moment does not survive. Replace such a file by a new file and
    ///     a rename, never in place. The same holds for a volume that goes
    ///     away, and on iOS for a file whose data protection makes it
    ///     unreadable while the device is locked.
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
            // With the map the lock says "I am the writer": two writers
            // that read through maps end each other's process. A storage
            // that only reads needs none: it reads through the map only
            // what its engine has verified to be committed.
            switch (access, lock) {
            case (.readOnly, _), (_, .exclusive?): break
            default: throw .memoryMapNeedsLock
            }
        }
        self.descriptor = try FileDescriptor(opening: path, access: access)
        self.access = access
        self.durability = durability
        self.path = path
        self.lock = lock
        // The file is there now, so its own path can be asked for.
        self.realPath = try Platform.realPath(path)
        // If either of these throws, the descriptor is closed as the storage
        // goes. The file is emptied only after the lock is held.
        if let lock {
            try Platform.lockFile(descriptor.rawValue, lock)
        }
        if case .truncate = access {
            try Platform.setFileLength(descriptor.rawValue, 0)
        }
        self.calls = calls
        // What a full copy that did not end left beside the file: this
        // storage is the file's writer and holds the lock that says so, so
        // nobody is writing that file, and it is removed. An opener without
        // the lock leaves it alone. If it cannot be removed it stays, and
        // the next full copy says why.
        if case .exclusive? = lock, !isReadOnly {
            _ = try? calls.remove(realPath + Self.incomingSuffix)
        }
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
    /// those bytes, mapped now if they were not.
    func snapshotSource(upTo size: UInt64, committedSizeAt position: UInt64) -> (
        descriptor: FileDescriptor, fence: SnapshotFence, map: FileMapView?
    ) {
        pinnedSize = max(pinnedSize, size)
        committedSizePosition = position
        var view: FileMapView?
        if map != nil, size > 0 {
            let last = map!.view.segmentIndex(of: size - 1)
            for index in 0...last { _ = segment(at: index) }
            view = map!.view
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
                map: calls.map, advise: calls.advise)
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
    /// A length below what a ``Snapshot`` of a database in this file reads
    /// takes those bytes from under it: every read through the snapshot
    /// throws ``XitDBError/snapshotOverwritten`` from then on. The library
    /// itself never asks for that. On a storage that reads through a
    /// memory map, do not ask for it while such a snapshot is being read on
    /// another thread: a read under way then reaches a part of the file
    /// that is gone, which is a signal that ends the process, and not an
    /// error.
    ///
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
    ///
    /// A cut below what a snapshot reads trips the snapshots' fence first,
    /// so that their reads refuse from then on: a snapshot that reads
    /// through the map looks at the fence before it reads as well as
    /// after. Every cut the library makes comes through here, and none of
    /// its own goes below a snapshot.
    ///
    /// - Throws: What setting the file's length throws.
    func resize(to length: UInt64) throws(XitDBError) {
        if isReadOnly { return }
        if length < pinnedSize {
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
