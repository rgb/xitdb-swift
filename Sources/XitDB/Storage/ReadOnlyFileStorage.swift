/// A file opened to be read: the storage of a database that another
/// database writes, in this process or another, and of any file a program
/// only looks at.
///
/// It has no way to write. It is a ``ReadableStorage`` and no
/// ``WritableStorage``, so it opens under a ``ReadOnlyDatabase`` and not
/// under a ``Database``: what the original refuses on a read-only file
/// when the program runs, a transaction, a recovery, a sync onto it, does
/// not compile here.
///
/// ```swift
/// let storage = try ReadOnlyFileStorage(path: "main.db")
/// let database = try ReadOnlyDatabase(opening: storage, hashing: SHA256.self)
/// let list = try ArrayList(database.rootCursor)
/// ```
///
/// The file is opened for reading alone, so one that this process may not
/// write opens too. A reader needs no lock, also with a memory map: it
/// reads a consistent state beside a writer without one, and through a map
/// it reads only what is committed. Every read looks at the file as it is
/// then, so the commits a writer makes are seen as they come.
///
/// A reader keeps the file it opened. A writer's full copy, a restore or a
/// deployment brings a new file under the name, and the reader goes on
/// reading the old one, whole, until it asks ``isStillAtPath`` and opens
/// the path again.
///
/// Reads are not buffered: where the file is not read through a map, each
/// is a system call. There is no buffered reading type; a buffer serves
/// what is written.
///
/// Like the other storages, it is not `Sendable`: it belongs to one thread
/// or task at a time. Another task opens the file again, or reads a
/// ``Snapshot``.
public final class ReadOnlyFileStorage: ReadableStorage {
    /// The file storage this is the face of, in its reading mode: the same
    /// object that reads the file under a ``FileStorage``, which a write
    /// through it fails on and which the engine under a
    /// ``ReadOnlyDatabase`` holds by its class.
    package let file: FileStorage

    /// Opens a file to be read.
    ///
    /// - Parameters:
    ///   - path: The path of the file, which must exist.
    ///   - lock: An advisory lock to take on the file, or `nil` for none,
    ///     which is what a reader wants: see ``FileLock/shared`` for what a
    ///     reader's lock does to the file's writer.
    ///   - reading: How the file is read: by file calls, or through a
    ///     memory map, which makes a read a copy from memory where it is a
    ///     system call otherwise, in either of the two ways ``FileReading``
    ///     says. No lock is needed for a map. See ``isMemoryMapped`` for
    ///     whether the map was had.
    ///
    ///     With the map, a file that something shortens ends the process:
    ///     a read of a part that is no longer there is not an error but a
    ///     signal. The library's own writer does not shorten a file below
    ///     what is committed, and a database opened over this storage
    ///     reads nothing through the map beyond that. What it cannot stop
    ///     is a program that shortens or rewrites the file in place: an
    ///     earlier version of this library, or the original, making a full
    ///     copy; a tool that copies onto the file. Replace such a file by
    ///     a new file and a rename, never in place. The same holds for a
    ///     volume that goes away, and on iOS for a file whose data
    ///     protection makes it unreadable while the device is locked.
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the file cannot
    ///   be opened, `ENOENT` where there is none at the path, or the lock
    ///   cannot be had at once. A path with a NUL byte in it is refused
    ///   with `EINVAL`, rather than opening the file that the part before
    ///   the NUL names.
    public convenience init(
        path: String,
        lock: FileLock? = nil,
        reading: FileReading = .fileCalls
    ) throws(XitDBError) {
        try self.init(path: path, lock: lock, reading: reading, segmentSize: FileStorage.defaultSegmentSize)
    }

    /// Opens a file to be read, with the size of the segments its memory
    /// map is made of and the system calls it makes, as
    /// ``FileStorage`` has them for the tests and the benchmark.
    ///
    /// - Precondition: `segmentSize` is a power of two and a multiple of
    ///   the page size.
    package init(
        path: String,
        lock: FileLock? = nil,
        reading: FileReading,
        segmentSize: Int,
        calls: FileCalls = FileCalls()
    ) throws(XitDBError) {
        // A reader never syncs: the level is the one that makes no call.
        file = try FileStorage(
            openedToBeReadAt: path, durability: .none, lock: lock, reading: reading, segmentSize: segmentSize,
            calls: calls)
    }

    /// How the storage was asked to read its file, which holds for its
    /// life: ``FileStorage/requestedReading`` of a file storage.
    /// ``isMemoryMapped`` says whether a map that was asked for was had.
    public var requestedReading: FileReading {
        file.requestedReading
    }

    /// Whether the storage's reads go through a memory map. A file on a
    /// volume that is not this machine's, as far as the system says, is
    /// read by file calls though the map was asked for, and this is
    /// `false` from the start, with no error. `false` after it was `true`
    /// means partly: the system refused to map a further part of the file,
    /// which is read by file calls with what follows it.
    public var isMemoryMapped: Bool {
        file.isMemoryMapped
    }

    /// Whether the path this storage was opened with still leads to the
    /// file the storage reads.
    ///
    /// A file can be replaced under its name while a storage has it open:
    /// a writer's full copy brings a new file and gives it the name;
    /// another file is renamed over it, as a restore or a deployment does;
    /// it is removed; or a symbolic link in the path is changed to lead
    /// elsewhere. A storage that was open before keeps the file it opened.
    /// It goes on reading what it read, whole, and sees nothing of what is
    /// written under the name from then on. `false` says that this has
    /// happened: opening the path again would give another file than this
    /// storage reads, or none. A reader asks, to learn that it has to open
    /// the path again.
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
    ///   ``XitDBError/storageClosed`` after ``close()``.
    public var isStillAtPath: Bool {
        get throws(XitDBError) {
            try file.isStillAtPath
        }
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
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if reading fails;
    ///   ``XitDBError/storageClosed`` after ``close()``.
    public func read(
        into buffer: inout MutableSpan<UInt8>,
        range: Range<Int>,
        at offset: UInt64
    ) throws(XitDBError) -> Int {
        try file.read(into: &buffer, range: range, at: offset)
    }

    /// The length of the file.
    ///
    /// - Throws: ``XitDBError/storageFailure(errno:)`` if the file's length
    ///   cannot be read; ``XitDBError/storageClosed`` after ``close()``.
    public var length: UInt64 {
        get throws(XitDBError) {
            try file.length
        }
    }

    /// Closes the storage, which gives up its file now.
    ///
    /// The lock, if the storage holds one, is let go at once. Every later
    /// read and write of the storage throws ``XitDBError/storageClosed``,
    /// and so does every call on a database opened over it and on the
    /// cursors, collections and iterators made from that database, as soon
    /// as it comes to read or write; nothing ends the process. What such an
    /// object read before and holds, it still gives: a number in a
    /// cursor's own slot, the elements an iterator had read. The file itself is
    /// closed, and its memory map unmapped, at once if no ``Snapshot`` of a
    /// database in it is alive, and otherwise when the last such snapshot
    /// goes: a snapshot is read on other threads, and a file is not taken
    /// from under a read. A snapshot taken before goes on reading its
    /// commit. A program that wants the file closed now lets its snapshots
    /// go first. Closing twice does nothing more.
    ///
    /// Without this call the file is closed when the storage and the last
    /// snapshot have gone, which is no sooner than the last reference to
    /// its database, a cursor or a collection.
    ///
    /// - Returns: `true` if the file is closed as the call returns, and
    ///   `false` if a snapshot holds it open still.
    @discardableResult
    public func close() -> Bool {
        file.close()
    }
}

@available(*, unavailable, message: "a read-only file storage is used from one thread at a time")
extension ReadOnlyFileStorage: Sendable {}
