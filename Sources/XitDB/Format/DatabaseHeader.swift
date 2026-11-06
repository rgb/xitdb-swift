/// Identifies the hash algorithm a database's keys were hashed with.
///
/// XitDB never interprets this value, because it never hashes anything
/// itself. It is recorded in the file for the benefit of whoever reads it.
/// By convention it is four ASCII characters such as `"sha1"`, or zero when
/// no algorithm was recorded.
public struct HashID: Sendable, Equatable {
    /// The identifier as a number: the four bytes read as a big-endian
    /// integer.
    public var id: UInt32

    /// Creates an identifier from its numeric form.
    ///
    /// - Parameter id: The four bytes of the identifier as a big-endian
    ///   integer.
    public init(id: UInt32) {
        self.id = id
    }

    /// Creates an identifier from four bytes, usually the ASCII name of a
    /// hash algorithm.
    ///
    /// - Parameter bytes: The identifier's bytes, in the order they are
    ///   written to the file.
    public init(bytes: InlineArray<4, UInt8>) {
        self.id = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    /// The identifier's four bytes, in the order they are written to the
    /// file.
    public var bytes: InlineArray<4, UInt8> {
        [
            UInt8(truncatingIfNeeded: id >> 24),
            UInt8(truncatingIfNeeded: id >> 16),
            UInt8(truncatingIfNeeded: id >> 8),
            UInt8(truncatingIfNeeded: id),
        ]
    }
}

/// The header at the start of every database file.
///
/// It is written once, when the database is created, and never changes.
public struct DatabaseHeader: Sendable, Equatable {
    /// A random identifier given to the file when it was created.
    ///
    /// It is part of the checksum of every transaction, so bytes from one
    /// database cannot be mistaken for a continuation of another.
    public let fileID: UInt64

    /// The hash algorithm the database's keys were hashed with, as recorded
    /// by whoever created the file.
    public let hashID: HashID

    /// The size in bytes of every hash in the database.
    public let hashSize: UInt16

    /// The version of the file format the database was written with.
    public let version: UInt16
}

extension DatabaseHeader {
    /// The size of the header on disk.
    static let byteCount: UInt64 = 20

    /// The file format version this implementation reads and writes.
    static let currentVersion: UInt16 = 1

    /// The three bytes every database starts with: `"xit"`.
    static let magic: InlineArray<3, UInt8> = [0x78, 0x69, 0x74]

    /// Creates the header of a new database, at the current format version.
    init(fileID: UInt64, hashID: HashID, hashSize: UInt16) {
        self.init(fileID: fileID, hashID: hashID, hashSize: hashSize, version: Self.currentVersion)
    }

    /// Decodes and validates the header that starts at `offset`.
    ///
    /// Zig reads the header and then calls `validate` on it. Both happen
    /// here, so a `DatabaseHeader` value is always a valid one. The padding
    /// byte is not checked, as in Zig. Whether the hash size is the one the
    /// caller expects is for the caller to check.
    ///
    /// - Throws: `endOfStream` if fewer than twenty bytes are available,
    ///   `invalidDatabase` if the magic bytes are wrong, or `invalidVersion`
    ///   if the version is not ``currentVersion``.
    init(decoding bytes: Span<UInt8>, at offset: Int = 0) throws(XitDBError) {
        try bytes.requireBytes(20, at: offset)
        for index in Self.magic.indices where bytes[offset + index] != Self.magic[index] {
            throw .invalidDatabase
        }
        let version: UInt16 = bytes.bigEndian(at: offset + 4)
        guard version == Self.currentVersion else { throw .invalidVersion }
        self.version = version
        self.hashSize = bytes.bigEndian(at: offset + 6)
        self.hashID = HashID(id: bytes.bigEndian(at: offset + 8))
        self.fileID = bytes.bigEndian(at: offset + 12)
    }

    /// Appends the header's twenty bytes.
    func encode(into output: inout OutputSpan<UInt8>) {
        for index in Self.magic.indices {
            output.append(Self.magic[index])
        }
        output.append(0)
        output.appendBigEndian(version)
        output.appendBigEndian(hashSize)
        output.appendBigEndian(hashID.id)
        output.appendBigEndian(fileID)
    }
}
