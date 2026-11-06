/// The record that follows the database header and is rewritten at every
/// commit. It is the only region of the file that ever changes.
///
/// It caches the latest trailer. Readers take only `fileSize` from it and
/// read the root slot from the trailer that ends there, so that a root header
/// torn by a concurrent commit cannot mislead them.
struct RootHeader: Sendable, Equatable {
    var root: Slot
    var fileSize: UInt64

    /// The size of the root header on disk.
    static let byteCount: UInt64 = 17

    /// Where the root header starts: directly after the database header.
    static let position: UInt64 = DatabaseHeader.byteCount

    /// Where the `fileSize` field starts.
    static let fileSizePosition: UInt64 = position + Slot.byteCount

    /// Where the root header ends and appended data begins.
    static let endPosition: UInt64 = position + byteCount

    /// The size of the smallest valid database: both headers and one trailer.
    static let minimumFileSize: UInt64 = endPosition + RootTrailer.byteCount

    /// Decodes the root header that starts at `offset`.
    ///
    /// - Throws: `endOfStream` if fewer than seventeen bytes are available,
    ///   or `invalidEnumTag` if the root slot's tag is unknown.
    init(decoding bytes: Span<UInt8>, at offset: Int = 0) throws(XitDBError) {
        try bytes.requireBytes(17, at: offset)
        self.root = try Slot(decoding: bytes, at: offset)
        self.fileSize = bytes.bigEndian(at: offset + 9)
    }

    init(root: Slot, fileSize: UInt64) {
        self.root = root
        self.fileSize = fileSize
    }

    /// Appends the root header's seventeen bytes.
    func encode(into output: inout OutputSpan<UInt8>) {
        root.encode(into: &output)
        output.appendBigEndian(fileSize)
    }
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
