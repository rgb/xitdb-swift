/// Identifies the hash algorithm a database's keys were hashed with.
///
/// XitDB never interprets this value, because it never hashes anything
/// itself. It is recorded in the file for the benefit of whoever reads it.
/// By convention it is four ASCII characters such as `"sha1"`, which is how
/// it can be written, or zero when no algorithm was recorded.
public struct HashID: RawRepresentable, Hashable, Sendable {
    /// The identifier as a number: the four bytes read as a big-endian
    /// integer.
    public var rawValue: UInt32

    /// Creates an identifier from its numeric form.
    ///
    /// - Parameter rawValue: The four bytes of the identifier as a
    ///   big-endian integer.
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Creates an identifier from a string of exactly four bytes in UTF-8,
    /// such as `"sha1"`, or `nil` if the string has any other length: for a
    /// string computed at run time.
    ///
    /// A literal needs no init: `"sha1"` is a `HashID` wherever one is
    /// expected, and so is `HashID("sha1")`. A literal of any other length
    /// is a programming error and stops the program; this init is the one
    /// that reports a wrong length instead.
    public init?(string: some StringProtocol) {
        var bytes: [UInt8] = []
        for byte in string.utf8 {
            if bytes.count == 4 { return nil }
            bytes.append(byte)
        }
        guard bytes.count == 4 else { return nil }
        self.init(bytes: [bytes[0], bytes[1], bytes[2], bytes[3]])
    }

    /// Creates an identifier from four bytes, in the order they are written
    /// to the file.
    init(bytes: InlineArray<4, UInt8>) {
        self.rawValue = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    /// The identifier's four bytes, in the order they are written to the
    /// file.
    var bytes: InlineArray<4, UInt8> {
        [
            UInt8(truncatingIfNeeded: rawValue >> 24),
            UInt8(truncatingIfNeeded: rawValue >> 16),
            UInt8(truncatingIfNeeded: rawValue >> 8),
            UInt8(truncatingIfNeeded: rawValue),
        ]
    }
}

extension HashID: ExpressibleByStringLiteral {
    /// Creates an identifier from a literal of exactly four bytes in UTF-8.
    ///
    /// - Precondition: The literal is four bytes long. A literal is part of
    ///   the program, not of a file, so a wrong one is a programming error.
    public init(stringLiteral value: String) {
        guard let id = HashID(string: value) else {
            preconditionFailure("a hash ID is exactly four bytes, not \"\(value)\"")
        }
        self = id
    }
}

extension HashID: CustomStringConvertible {
    /// The four bytes as text when all are printable ASCII, otherwise the
    /// number.
    public var description: String {
        let bytes = self.bytes
        var printable = true
        for index in 0..<4 where bytes[index] < 0x20 || bytes[index] >= 0x7F {
            printable = false
        }
        if printable {
            return String(decoding: [bytes[0], bytes[1], bytes[2], bytes[3]], as: UTF8.self)
        }
        return String(rawValue)
    }
}

/// The header at the start of every database file.
///
/// It is written once, when the database is created, and never changes.
public struct DatabaseHeader: Hashable, Sendable {
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
        self.hashID = HashID(rawValue: bytes.bigEndian(at: offset + 8))
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
        output.appendBigEndian(hashID.rawValue)
        output.appendBigEndian(fileID)
    }
}
