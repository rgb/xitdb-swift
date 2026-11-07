/// An error thrown by XitDB.
///
/// The cases mirror the error names of the original Zig implementation, so a
/// failure means the same thing in both, with one case of its own:
/// ``indexOutOfRange`` is what Zig reports as `KeyNotFound` for a list
/// index. Two are comparable only loosely: ``callerError(_:)`` carries an
/// error of the caller's own, and two of them are equal when their
/// descriptions are.
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

    /// The storage a database was to be created in already contains data.
    case storageNotEmpty

    /// A hash trie is deeper than a hash of the database's hash size allows.
    case keyOffsetExceeded

    /// An array list is deeper than the format allows.
    case maxShiftExceeded

    /// A write would grow an in-memory database beyond its size limit.
    case maxSizeExceeded

    /// A byte array is larger than the limit or the buffer given for reading
    /// it.
    case streamTooLong

    /// Data ended before a complete value could be read.
    case endOfStream

    /// A byte array being written is no longer at the end of the file, so it
    /// cannot be finished.
    case unexpectedWriterPosition

    /// The operation needs to know where a slot is stored, and the cursor
    /// does not have that position.
    case expectedSlotPosition

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
        case (.callerError, _), (_, .callerError), (.storageFailure, _), (_, .storageFailure):
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
