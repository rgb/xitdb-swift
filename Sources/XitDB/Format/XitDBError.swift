/// An error thrown by XitDB.
///
/// The cases mirror the error names of the original Zig implementation, so a
/// failure means the same thing in both.
public enum XitDBError: Error, Sendable, Equatable {
    /// A slot holds a kind of value that the operation cannot work with.
    ///
    /// For example, a hash map operation was applied to a slot that holds an
    /// array list.
    case unexpectedTag

    /// The key or index does not exist.
    case keyNotFound

    /// A step that writes was used while reading.
    case writeNotAllowed

    /// The cursor has no position in the file, so nothing can be written
    /// through it.
    case cursorNotWriteable

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

    /// A slot's tag byte is not one of the values in ``Tag``.
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
    case pathPartMustBeAtEnd

    /// The operation is not implemented.
    case notImplemented

    /// The storage underneath the database reported a failure.
    ///
    /// - Parameter errno: The error number reported by the operating system.
    case storageFailure(errno: Int32)
}
