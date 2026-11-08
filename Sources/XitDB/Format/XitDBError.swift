/// An error thrown by XitDB.
///
/// The cases mirror the error names of the original, so a failure means the
/// same thing in both, with one case of its own: ``indexOutOfRange`` is
/// what the original reports as `KeyNotFound` for a list index. Two are
/// comparable only loosely: ``callerError(_:)`` carries an error of the
/// caller's own, and two of them are equal when their descriptions are.
public enum XitDBError: Error, Sendable {
    /// A slot holds a kind of value that the operation cannot work with.
    ///
    /// For example, a hash map operation was applied to a slot that holds an
    /// array list.
    case unexpectedTag

    /// The key does not exist.
    case keyNotFound

    /// The index is not one of the list's elements.
    case indexOutOfRange

    /// A step that writes was used while reading.
    ///
    /// Only the package-level path API raises it; nothing public does.
    case writeNotAllowed

    /// The cursor has no position in the file, so nothing can be written
    /// through it.
    case cursorNotWritable

    /// A write below the root was attempted outside a transaction.
    case expectedTxStart

    /// A write to the root was started while another one was in progress.
    case nestedTopLevelWrite

    /// The data is not a valid xitdb database.
    ///
    /// The storage is empty or does not start with the magic bytes, no
    /// trailer in it verifies, or the bytes given to a sync do not end with
    /// a trailer that verifies. A file whose root header cannot be trusted
    /// while some trailer verifies is ``untrustedRootHeader(lastVerified:)``
    /// instead.
    case invalidDatabase

    /// The file was written with a format version this implementation does
    /// not read.
    case invalidVersion

    /// The hash size requested by the caller differs from the one recorded in
    /// the file.
    case invalidHashSize

    /// The storage of a database already open is shorter than the committed
    /// size it records, as a sync at zero that failed leaves it, or a sync at
    /// zero brought bytes that stop short of their own committed size. A
    /// file cut short before it is opened is
    /// ``untrustedRootHeader(lastVerified:)`` instead.
    case truncatedDatabase

    /// A slot's tag byte is not one of the values in ``Slot/Tag``.
    case invalidEnumTag

    /// A tree node records more entries than a node can hold, or a position
    /// in a node is out of range.
    case invalidBTreeNode

    /// A tree node is neither a leaf nor a branch.
    case invalidBTreeNodeKind

    /// A range of committed bytes is not one that can be read or applied.
    case invalidRange

    /// A length is larger than the data it applies to.
    case invalidLength

    /// The target of a compaction already contains data.
    case targetNotEmpty

    /// The root of the database being compacted is an array list whose
    /// last element is empty: the list has no elements, or its last element
    /// was appended and never written, whether the list is a history or any
    /// other list at the root. Compacting it would keep nothing of it,
    /// neither the list nor the elements before the empty one, so it is
    /// refused before anything is written to the target. A last element
    /// set to nothing is a moment, and compacts.
    case emptyLastMoment

    /// The storage a database was to be created in already contains data.
    case storageNotEmpty

    /// A hash trie is deeper than a hash of the database's hash size allows.
    case keyOffsetExceeded

    /// An array list is deeper than the format allows.
    case maxShiftExceeded

    /// A write would grow an in-memory database beyond its size limit, or,
    /// when it has none, beyond what an array can hold: a write whose bytes
    /// would end past `Int.max` is reported the same way.
    case maxSizeExceeded

    /// A byte array is larger than the limit or the buffer given for reading
    /// it.
    case streamTooLong

    /// Data ended before a complete value could be read.
    case endOfStream

    /// A byte array being written is no longer at the end of the file, so it
    /// cannot be finished.
    case unexpectedWriterPosition

    /// A step that must be the last one in a path is followed by another.
    ///
    /// Only the package-level path API raises it; nothing public does.
    case pathPartMustBeAtEnd

    /// The operation is not implemented.
    ///
    /// Only the package-level path API raises it; nothing public does.
    case notImplemented

    /// The storage underneath the database reported a failure.
    ///
    /// - Parameter errno: The error number reported by the operating system.
    case storageFailure(errno: Int32)

    /// A type of the caller's threw: a ``ByteSink``, a ``ByteSource`` or an
    /// ``OffsetMap`` that XitDB was calling. The error is carried as it was
    /// thrown.
    case callerError(any Error)

    /// A count recorded in the file disagrees with its tree: a counted hash
    /// map or set whose count says it is empty holds the key being removed,
    /// or whose count cannot grow is being added to.
    case invalidCount

    /// A cursor that cannot be used any more: for a write, one made before the
    /// last freeze of this transaction (``Database/freeze()`` or
    /// ``LinkedArrayList/append(contentsOf:)-(Slot)``) or in an earlier
    /// transaction, since a write through it would change bytes that other
    /// things refer to or that are committed; for a read, one made in a
    /// transaction that did not commit, whose bytes are gone. The way on after
    /// a freeze is the transaction's cursor, the one
    /// ``Database/withTransaction(_:)`` or a history append hands its body, or
    /// any cursor at the same slot, such as the cursor of a collection made
    /// from it: making a collection from it is allowed, since its slot is the
    /// engine's own record that nothing inside the transaction can copy, and
    /// every cursor taken from it is fresh. Through any other cursor from
    /// before the freeze every write is refused, making a collection included:
    /// made from a held cursor, the collection would rewrite its slot in place,
    /// in a record a copy may have left behind, and lose writes silently. A
    /// write that would land below the freeze by any other route is
    /// ``immutableBytes``, refused before that write; a write the operation
    /// made before it, as a hash map's get makes a new entry's record, poisons
    /// the transaction. <doc:CloningFreezeAndStaleHandles> has the whole of it.
    case staleCursor

    /// A write would change committed or frozen bytes in place: its position is
    /// below the transaction's frozen point, where every byte is either
    /// committed or was written before the last freeze and may be shared by a
    /// clone or another handle. The engine refuses it before it writes. A write
    /// into an old block that does not make its collection first reports this;
    /// a cursor from before the freeze reports ``staleCursor`` first. Through
    /// the public API nothing reaches it: the collections' initialisers make
    /// them first, and a freeze inside a byte writer's body is
    /// ``byteWriterOpen``.
    case immutableBytes

    /// ``Database/freeze()`` or a join was called while a byte writer's body
    /// was running, which would move the frozen point past the record the
    /// writer is filling and leave its completion nowhere to write. The freeze
    /// is refused before it moves anything; the body then ends with this error,
    /// and the transaction is poisoned as after any body that throws, since the
    /// writer had appended before the body ran. Finish byte writers before
    /// freezing.
    case byteWriterOpen

    /// The file a ``Snapshot`` reads was rewritten below the snapshot's
    /// committed size, so that its bytes are no longer the commit's: a
    /// replication from zero through the database that writes the file,
    /// ``Database/applyReplicated(at:bytes:)`` at 0, or a write or a
    /// truncation through the caller's own reference to the storage. Every
    /// read through the snapshot reports this from then on, the one under
    /// way included; take a new snapshot. A snapshot of a database in memory
    /// keeps the commit's bytes and never reports it. Only a rewrite through
    /// the storage object the snapshot was taken from is seen: one through
    /// another storage on the same path, or by another process, is not.
    case snapshotOverwritten

    /// The database reads a snapshot of one collection, made with
    /// ``Snapshot/init(_:)`` from a cursor inside a commit, and the
    /// operation needs the whole commit: compacting such a database is
    /// refused before anything is written to the target. Its replication
    /// reads serve the whole commit's bytes, the file being the unit.
    case subCollectionSnapshot

    /// A slot whose tag is `index`, `kvPair` or `sortedKvPair` was given to
    /// write as a value. Those tags are the trees' own; such a slot in a
    /// value builds a tree the engine cannot read.
    case structuralSlot

    /// A write in a transaction that an earlier operation poisoned: that
    /// operation failed after it had written to the storage, so what it
    /// left cannot be undone short of the whole transaction, and the
    /// transaction can only roll back. Its commit fails with this too.
    case poisonedTransaction

    /// The root header of a database being opened cannot be trusted: its
    /// size is past the end of the file, smaller than a database can be, or
    /// does not end at a trailer whose checksum verifies. `lastVerified` is
    /// the position after the last trailer that does verify, scanning back
    /// from the end; ``Database/recover(_:)`` cuts the file there.
    case untrustedRootHeader(lastVerified: UInt64)
}

extension XitDBError: Equatable {
    /// Whether two errors are the same case with the same values. Two
    /// ``callerError(_:)`` are equal when the errors they carry have the
    /// same description.
    public static func == (left: XitDBError, right: XitDBError) -> Bool {
        switch (left, right) {
        case (.callerError(let leftError), .callerError(let rightError)):
            String(describing: leftError) == String(describing: rightError)
        case (.storageFailure(let leftErrno), .storageFailure(let rightErrno)):
            leftErrno == rightErrno
        case (.untrustedRootHeader(let leftPosition), .untrustedRootHeader(let rightPosition)):
            leftPosition == rightPosition
        case (.callerError, _), (_, .callerError), (.storageFailure, _), (_, .storageFailure),
            (.untrustedRootHeader, _), (_, .untrustedRootHeader):
            false
        default:
            // The cases without values: the same case is the same error.
            String(describing: left) == String(describing: right)
        }
    }
}

extension XitDBError {
    /// Runs `body`, which calls a type of the caller's, and carries whatever
    /// it throws as ``callerError(_:)``.
    static func carrying<Result>(_ body: () throws -> Result) throws(XitDBError) -> Result {
        do {
            return try body()
        } catch {
            throw .callerError(error)
        }
    }
}
