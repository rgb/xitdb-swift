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
    /// The file does not start with the xitdb magic bytes, its recorded size
    /// is too small to hold a database, or the checksum of the trailer that
    /// ends its committed data does not match.
    case invalidDatabase

    /// The file was written with a format version this implementation does
    /// not read.
    case invalidVersion

    /// The hash size requested by the caller differs from the one recorded in
    /// the file.
    case invalidHashSize

    /// The file is shorter than the committed size it records.
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

    /// A cursor that cannot be used any more: for a write, one made before
    /// the last freeze of this transaction (``Database/freeze()`` or
    /// ``LinkedArrayList/append(contentsOf:)-(Slot)``) or in an earlier
    /// transaction, since a write through it would change bytes that other
    /// things refer to or that are committed; for a read, one made in a
    /// transaction that did not commit, whose bytes are gone. The way on
    /// after a freeze is a new cursor from the transaction's root cursor.
    /// A path that begins with a collection's init part is still allowed
    /// through a cursor from before a freeze in the same transaction, but
    /// it writes the cursor's slot in place, so it is safe only for the
    /// cloned structure itself, or for a handle into nothing that was
    /// cloned.
    case staleCursor

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
