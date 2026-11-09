// The sizes of the format's records, for tools in the package that show a
// file as it is on disk.

/// The sizes and positions of the format's records, in bytes, for a tool
/// that reports where things are in a file; the format's types keep them
/// for the engine's own use.
package enum FormatSizes {
    /// The database header at the start of the file.
    package static let databaseHeader: UInt64 = DatabaseHeader.byteCount
    /// The root header after it: the root slot and the committed size.
    package static let rootHeader: UInt64 = RootHeader.byteCount
    /// A trailer, which ends every commit.
    package static let trailer: UInt64 = RootTrailer.byteCount
    /// Where the first trailer can begin.
    package static let firstTrailer: UInt64 = RootHeader.endPosition
    /// A slot.
    package static let slot: UInt64 = Slot.byteCount
    /// An index block of a trie: a block of slots.
    package static let indexBlock: UInt64 = IndexBlock.byteCount
    /// The count a counted map or set keeps before its first index block.
    package static let count: UInt64 = IndexBlock.countByteCount
    /// An array list's or a linked array list's header.
    package static let listHeader: UInt64 = ArrayListHeader.byteCount
    /// A sorted map's or set's header.
    package static let treeHeader: UInt64 = BTreeHeader.byteCount
    /// The length that precedes a byte array.
    package static let bytesLength: UInt64 = ByteArrayFormat.lengthByteCount
    /// The format tag a byte array may carry after its length.
    package static let bytesFormatTag: UInt64 = ByteArrayFormat.formatTagByteCount
    /// A sorted map's key-value pair.
    package static let sortedPair: UInt64 = KeyValuePair.sortedByteCount
}
