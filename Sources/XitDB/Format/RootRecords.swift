/// What the root header says: the size of the committed bytes, with the root
/// slot from the trailer that ends them.
///
/// On disk the root header follows the database header and holds the
/// committed size alone, at the position the format's version decides
/// (``DatabaseHeader/fileSizePosition``). A commit rewrites those eight
/// bytes, and they are the only bytes of a file that ever change. The root
/// slot is never read from there: it comes from the trailer that ends at
/// the size, which no commit rewrites, so that a root header a concurrent
/// commit is halfway through writing cannot mislead a reader.
struct RootHeader: Sendable, Equatable {
    var root: Slot
    var fileSize: UInt64

    /// Where the root header starts: directly after the database header.
    /// It is also the position a cursor at the root of a database has,
    /// which names no slot in the file.
    static let position: UInt64 = DatabaseHeader.byteCount
}

/// The record appended at the end of every transaction. The committed bytes
/// of a database always end with one.
struct RootTrailer: Sendable, Equatable {
    var root: Slot

    /// Zero for the trailer of a new database, random for every transaction
    /// after it, so that separately written copies of a file cannot end up
    /// with the same trailers.
    var commitID: UInt64

    var checksum: UInt64

    /// The size of a trailer on disk.
    static let byteCount: UInt64 = 25

    /// Creates the trailer for a transaction, computing its checksum.
    ///
    /// - Parameter position: The file offset the trailer will be written at.
    init(fileID: UInt64, position: UInt64, root: Slot, commitID: UInt64) {
        self.root = root
        self.commitID = commitID
        self.checksum = Self.checksum(fileID: fileID, position: position, root: root, commitID: commitID)
    }

    /// The CRC-64/XZ of the file ID, the trailer's position, the root slot
    /// and the commit ID, each big endian: 33 bytes.
    ///
    /// Covering the file ID and the position means a trailer cannot be
    /// mistaken for one written elsewhere.
    static func checksum(fileID: UInt64, position: UInt64, root: Slot, commitID: UInt64) -> UInt64 {
        var crc = CRC64XZ()
        crc.updateBigEndian(fileID)
        crc.updateBigEndian(position)
        crc.update(root.tag.rawValue | (root.full ? 0x80 : 0))
        crc.updateBigEndian(root.value)
        crc.updateBigEndian(commitID)
        return crc.checksum
    }

    /// Decodes the trailer that starts at `offset` and verifies it.
    ///
    /// The checksum is verified before the root slot's tag is looked at, as
    /// in Zig, so corrupt bytes are reported as `invalidDatabase`.
    ///
    /// - Parameters:
    ///   - fileID: The file ID from the database header.
    ///   - position: The file offset the trailer was read from.
    /// - Throws: `endOfStream` if fewer than twenty-five bytes are available,
    ///   `invalidDatabase` if the checksum does not match, or
    ///   `invalidEnumTag` if the root slot's tag is unknown.
    init(decoding bytes: Span<UInt8>, at offset: Int = 0, fileID: UInt64, position: UInt64) throws(XitDBError) {
        try bytes.requireBytes(25, at: offset)
        let checksum: UInt64 = bytes.bigEndian(at: offset + 17)
        var crc = CRC64XZ()
        crc.updateBigEndian(fileID)
        crc.updateBigEndian(position)
        // The root slot and the commit ID, exactly as they are on disk.
        crc.update(bytes, at: offset, count: 17)
        guard crc.checksum == checksum else { throw .invalidDatabase }
        self.root = try Slot(decoding: bytes, at: offset)
        self.commitID = bytes.bigEndian(at: offset + 9)
        self.checksum = checksum
    }

    /// Appends the trailer's twenty-five bytes.
    func encode(into output: inout OutputSpan<UInt8>) {
        root.encode(into: &output)
        output.appendBigEndian(commitID)
        output.appendBigEndian(checksum)
    }
}
