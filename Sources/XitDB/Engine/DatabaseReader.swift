extension UInt64 {
    /// This position moved forward by `distance`.
    ///
    /// Positions and sizes read from a file are added with this, so that a
    /// corrupt one is reported and cannot overflow.
    ///
    /// - Throws: `endOfStream` if the result is beyond any position a
    ///   storage has, which is what reading there would report.
    func offset(by distance: UInt64) throws(XitDBError) -> UInt64 {
        let (result, overflow) = addingReportingOverflow(distance)
        if overflow { throw .endOfStream }
        return result
    }
}

/// Everything the read side of the engine needs from a database: its bytes,
/// its hash size and its file ID.
///
/// Code that only reads depends on this and not on ``Database``, so that the
/// same code can later read a snapshot of committed data from any thread.
/// A key-value pair with the hash it is stored under. (A struct and not a
/// tuple, because a tuple of these needs its metadata looked up at run time
/// each time one is destroyed, which showed in iterating over a map.)
struct HashedPair {
    var hash: KeyHash
    var pair: KeyValuePair
}

/// What a replication from zero replaces: the database's header, shared
/// by the database and its reader, so that both stay `let` properties and
/// only this box is read through a dynamic exclusivity check.
final class DatabaseIdentity {
    var header: DatabaseHeader

    init(header: DatabaseHeader) {
        self.header = header
    }
}

struct DatabaseReader {
    let storage: any ReadableStorage
    /// The hash size, which a replication cannot change.
    let hashSize: UInt16
    private let identity: DatabaseIdentity

    /// The file ID, which the trailers' checksums cover.
    var fileID: UInt64 { identity.header.fileID }

    init(storage: any ReadableStorage, identity: DatabaseIdentity) {
        self.storage = storage
        hashSize = identity.header.hashSize
        self.identity = identity
    }

    // MARK: Records

    /// Reads exactly as many bytes as the result holds.
    ///
    /// - Throws: `endOfStream` if the storage ends first.
    func bytes<let count: Int>(at position: UInt64) throws(XitDBError) -> InlineArray<count, UInt8> {
        var buffer = InlineArray<count, UInt8>(repeating: 0)
        var span = buffer.mutableSpan
        let read = try storage.read(into: &span, at: position)
        guard read == count else { throw .endOfStream }
        return buffer
    }

    func slot(at position: UInt64) throws(XitDBError) -> Slot {
        let buffer: InlineArray<9, UInt8> = try bytes(at: position)
        return try Slot(decoding: buffer.span)
    }

    func uint64(at position: UInt64) throws(XitDBError) -> UInt64 {
        let buffer: InlineArray<8, UInt8> = try bytes(at: position)
        return buffer.span.bigEndian(at: 0)
    }

    func arrayListHeader(at position: UInt64) throws(XitDBError) -> ArrayListHeader {
        let buffer: InlineArray<16, UInt8> = try bytes(at: position)
        return try ArrayListHeader(decoding: buffer.span)
    }

    func bTreeHeader(at position: UInt64) throws(XitDBError) -> BTreeHeader {
        let buffer: InlineArray<16, UInt8> = try bytes(at: position)
        return try BTreeHeader(decoding: buffer.span)
    }

    /// The raw bytes of an index block, for copying it.
    func indexBlockBytes(at position: UInt64) throws(XitDBError) -> InlineArray<144, UInt8> {
        try bytes(at: position)
    }

    func indexBlock(at position: UInt64) throws(XitDBError) -> IndexBlock {
        let buffer = try indexBlockBytes(at: position)
        return try IndexBlock(decoding: buffer.span)
    }

    /// Reads the hashed key-value pair record at `position`: its hash and
    /// its two slots.
    ///
    /// The record is read in one call. For hashes of up to sixty-four bytes
    /// nothing is allocated.
    ///
    /// - Throws: `endOfStream` if the record is not all there, or
    ///   `invalidEnumTag` if one of its slots has an unknown tag.
    func hashedPair(at position: UInt64) throws(XitDBError) -> HashedPair {
        let size = Int(hashSize) + 18
        if size <= 82 {
            var buffer = InlineArray<82, UInt8>(repeating: 0)
            var span = buffer.mutableSpan
            // This may read past the record into what follows it, which is
            // harmless, or come back short because the storage ends.
            let read = try storage.read(into: &span, at: position)
            guard read >= size else { throw .endOfStream }
            return try Self.decodeHashedPair(buffer.span.extracting(0..<size), hashSize: hashSize)
        }
        var buffer = [UInt8](repeating: 0, count: size)
        var span = buffer.mutableSpan
        let read = try storage.read(into: &span, at: position)
        guard read == size else { throw .endOfStream }
        return try Self.decodeHashedPair(buffer.span, hashSize: hashSize)
    }

    private static func decodeHashedPair(_ record: Span<UInt8>, hashSize: UInt16) throws(XitDBError) -> HashedPair {
        let pair = try KeyValuePair(decodingHashed: record, hashSize: hashSize)
        return HashedPair(hash: KeyHash(record.extracting(0..<Int(hashSize))), pair: pair)
    }

    func sortedPair(at position: UInt64) throws(XitDBError) -> KeyValuePair {
        let buffer: InlineArray<18, UInt8> = try bytes(at: position)
        return try KeyValuePair(decodingSorted: buffer.span)
    }

    // MARK: The root

    /// The committed size from the root header, and the root slot from the
    /// trailer that ends there.
    ///
    /// Only the size is read from the root header. The root slot beside it
    /// is a cache that a concurrent commit may be halfway through
    /// rewriting, so it is never looked at.
    ///
    /// - Throws: `invalidDatabase` if the size is too small to hold a
    ///   database or the trailer's checksum does not match,
    ///   `truncatedDatabase` if the storage is shorter than the size, or
    ///   `endOfStream` if the storage ends inside the root header.
    func rootHeader() throws(XitDBError) -> RootHeader {
        let fileSize = try uint64(at: RootHeader.fileSizePosition)
        if fileSize < RootHeader.minimumFileSize { throw .invalidDatabase }
        if try storage.length() < fileSize { throw .truncatedDatabase }
        // The committed bytes must end with a trailer.
        return RootHeader(root: try rootTrailer(endingAt: fileSize).root, fileSize: fileSize)
    }

    /// The number of bytes that belong to committed transactions.
    func committedSize() throws(XitDBError) -> UInt64 {
        try rootHeader().fileSize
    }

    /// The most recently committed root slot.
    func rootSlot() throws(XitDBError) -> Slot {
        try rootHeader().root
    }

    /// The trailer that ends at `end`.
    func rootTrailer(endingAt end: UInt64) throws(XitDBError) -> RootTrailer {
        if end < RootTrailer.byteCount { throw .invalidDatabase }
        let position = end - RootTrailer.byteCount
        let buffer: InlineArray<25, UInt8> = try bytes(at: position)
        return try RootTrailer(decoding: buffer.span, fileID: fileID, position: position)
    }

    /// The slot pointer a root cursor stands for right now: the root slot in
    /// the newest trailer. A trailer never changes, so everything read
    /// through the result comes from one commit.
    func resolvedRoot() throws(XitDBError) -> SlotPointer {
        let header = try rootHeader()
        return SlotPointer(position: header.fileSize - RootTrailer.byteCount, slot: header.root)
    }
}
