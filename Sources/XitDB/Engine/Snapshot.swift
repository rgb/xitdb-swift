/// One commit of a database, readable from any thread or task.
///
/// A snapshot pins one commit: its committed size and its root, read and
/// verified once by ``Database/snapshot()``, and the bytes below that size,
/// which a database never changes except for its root header. It is a few
/// words and `Sendable`; what it is not is a database. Where it is used,
/// ``rootCursor`` or ``Database/init(reading:)`` makes a read-only database
/// over it at no I/O cost, and that database, its cursors and collections
/// belong to the task that made them, as every database does. Two tasks
/// reading one snapshot share nothing but the snapshot.
///
/// Every write through a snapshot's database is refused with
/// ``XitDBError/cursorNotWritable`` before anything is done. Nothing read
/// from one is ever stale in the sense of ``XitDBError/staleCursor``: a
/// snapshot's database has no transactions.
///
/// What a snapshot costs depends on the storage. In a ``MemoryStorage`` it
/// shares the array, and the writer copies the array once at its next write
/// while the snapshot lives. On a ``FileStorage`` or ``BufferedFileStorage``
/// it shares the storage's descriptor, so the file stays open, and any lock
/// held, until the storage and the last snapshot have gone; a replication
/// from zero through the writer then rewrites the file under it, and its
/// reads report ``XitDBError/snapshotOverwritten`` from then on. On a
/// storage of the caller's own it is a copy of the committed bytes, made
/// when the snapshot is taken.
///
/// A snapshot never refreshes. To see a later commit, take a new one.
public struct Snapshot: Sendable {
    /// The header of the database the commit belongs to: its file ID, hash
    /// size and hash ID.
    public let header: DatabaseHeader

    /// The size of the database at the commit. Every byte the snapshot
    /// reads lies below it.
    public let committedSize: UInt64

    /// The root the snapshot's reads start from: the commit's root slot, or
    /// the slot of the sub-collection the snapshot was made from.
    let root: Slot

    /// The read half of the storage, bounded at the committed size.
    let storage: SnapshotStorage
}

extension Database {
    /// Whether this database reads a ``Snapshot`` and is never written.
    var readsSnapshot: Bool {
        reader.pinnedRoot != nil
    }

    /// Takes a snapshot of the last commit: its committed size and root,
    /// read and verified once, and the bytes below that size.
    ///
    /// Called inside a transaction, this pins the last commit, not the
    /// transaction's work. Called on a database made with
    /// ``init(reading:)``, it gives that database's snapshot back without
    /// reading anything.
    ///
    /// On a ``MemoryStorage`` this is one retain of the array, and the next
    /// write to the database copies the array while the snapshot lives. On
    /// the file storages it is a read of the root header and the trailer
    /// and shares the storage's descriptor; the file then stays open until
    /// the storage and the last snapshot have gone. On a storage of the
    /// caller's own it copies the committed bytes, which costs their size.
    ///
    /// - Throws: ``XitDBError/invalidDatabase`` if the committed size is
    ///   too small to hold a database or the trailer at it does not verify,
    ///   ``XitDBError/truncatedDatabase`` if the storage is shorter than the
    ///   committed size, ``XitDBError/endOfStream`` if the storage ends
    ///   inside the root header, and ``XitDBError/storageFailure(errno:)``
    ///   if the storage fails. A root header that a concurrent writer in
    ///   another process is halfway through rewriting reports one of the
    ///   first two, never a wrong snapshot; try again.
    public func snapshot() throws(XitDBError) -> Snapshot {
        let pinned = try reader.rootHeader()
        let readHalf: SnapshotStorage
        switch storage {
        case .snapshot(let existing):
            readHalf = existing
        case .memory(let memory):
            readHalf = SnapshotStorage(bytes: memory.bytes, committedSize: pinned.fileSize)
        case .file(let file):
            let source = file.snapshotSource(upTo: pinned.fileSize)
            readHalf = SnapshotStorage(file: source.descriptor, fence: source.fence, committedSize: pinned.fileSize)
        case .bufferedFile(let buffered):
            let source = buffered.file.snapshotSource(upTo: pinned.fileSize)
            readHalf = SnapshotStorage(file: source.descriptor, fence: source.fence, committedSize: pinned.fileSize)
        case .custom(let custom):
            readHalf = SnapshotStorage(
                bytes: try Self.copyCommittedBytes(of: custom, count: pinned.fileSize), committedSize: pinned.fileSize)
        }
        return Snapshot(header: header, committedSize: pinned.fileSize, root: pinned.root, storage: readHalf)
    }

    /// The first `count` bytes of a storage of the caller's own, which has
    /// no read half the engine can share.
    ///
    /// - Throws: `truncatedDatabase` if the storage gives fewer bytes than
    ///   the root header said it holds, and the storage's own errors.
    private static func copyCommittedBytes(of storage: any WritableStorage, count: UInt64) throws(XitDBError) -> [UInt8]
    {
        guard let size = Int(exactly: count) else { throw .maxSizeExceeded }
        var bytes = [UInt8](repeating: 0, count: size)
        var span = bytes.mutableSpan
        let read = try storage.read(into: &span, at: 0)
        guard read == size else { throw .truncatedDatabase }
        return bytes
    }
}
