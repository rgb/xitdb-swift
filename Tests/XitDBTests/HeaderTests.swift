import Testing

@testable import XitDB

@Suite struct DatabaseHeaderTests {
    /// magic "xit", padding, version 2, hash size 20, hash ID "sha1",
    /// file ID 0x0102030405060708: the header of a new database
    static let sha1Header: [UInt8] = [
        0x78, 0x69, 0x74, 0x00,
        0x00, 0x02,
        0x00, 0x14,
        0x73, 0x68, 0x61, 0x31,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    ]

    /// the same header as a version 1 file has it
    static let versionOneHeader: [UInt8] = {
        var bytes = sha1Header
        bytes[5] = 1
        return bytes
    }()

    @Test func sizeOnDisk() {
        #expect(DatabaseHeader.byteCount == 20)
        #expect(Self.sha1Header.count == 20)
    }

    @Test func decodesHandWrittenBytes() throws {
        let header = try DatabaseHeader(decoding: Self.sha1Header.span)
        #expect(header.version == 2)
        #expect(header.hashSize == 20)
        #expect(header.hashID == HashID(rawValue: 0x7368_6131))
        #expect(header.fileID == 0x0102_0304_0506_0708)
    }

    @Test func encodesHandWrittenBytes() {
        let header = DatabaseHeader(
            fileID: 0x0102_0304_0506_0708,
            hashID: "sha1",
            hashSize: 20
        )
        #expect(header.version == DatabaseHeader.currentVersion)
        #expect(header.version == 2)
        #expect(encoded(capacity: 20) { header.encode(into: &$0) } == Self.sha1Header)
    }

    @Test func aVersionOneHeaderDecodesAndEncodesAsVersionOne() throws {
        let header = try DatabaseHeader(decoding: Self.versionOneHeader.span)
        #expect(header.version == 1)
        #expect(header.hashSize == 20)
        #expect(header.hashID == HashID(rawValue: 0x7368_6131))
        #expect(header.fileID == 0x0102_0304_0506_0708)
        #expect(encoded(capacity: 20) { header.encode(into: &$0) } == Self.versionOneHeader)
    }

    @Test func theVersionsReadAndWrittenAreOneAndTwo() {
        #expect(DatabaseHeader.supports(version: 1))
        #expect(DatabaseHeader.supports(version: 2))
        for version in [UInt16(0), 3, 0x0100, 0x0101, 0x0200, .max] {
            #expect(!DatabaseHeader.supports(version: version), "\(version)")
        }
    }

    @Test func roundTrips() throws {
        let header = DatabaseHeader(fileID: .max, hashID: HashID(rawValue: 0), hashSize: 8)
        let bytes = encoded(capacity: 20) { header.encode(into: &$0) }
        #expect(bytes.count == 20)
        #expect(try DatabaseHeader(decoding: bytes.span) == header)

        let padded = [0xEE] + bytes
        #expect(try DatabaseHeader(decoding: padded.span, at: 1) == header)
    }

    @Test func wrongMagicIsInvalidDatabase() {
        for index in 0..<3 {
            var bytes = Self.sha1Header
            bytes[index] ^= 0x01
            #expect(throws: XitDBError.invalidDatabase) { try DatabaseHeader(decoding: bytes.span) }
        }
    }

    @Test func wrongVersionIsInvalidVersion() {
        for version in [UInt8(0), 3, 0xFF] {
            var bytes = Self.sha1Header
            bytes[5] = version
            #expect(throws: XitDBError.invalidVersion) { try DatabaseHeader(decoding: bytes.span) }
        }
        // the version is two bytes: 0x0101 and 0x0102 are neither 1 nor 2
        for header in [Self.sha1Header, Self.versionOneHeader] {
            var highByte = header
            highByte[4] = 1
            #expect(throws: XitDBError.invalidVersion) { try DatabaseHeader(decoding: highByte.span) }
        }
    }

    @Test func magicIsCheckedBeforeVersion() {
        var bytes = Self.sha1Header
        bytes[0] = 0
        bytes[5] = 9
        #expect(throws: XitDBError.invalidDatabase) { try DatabaseHeader(decoding: bytes.span) }
    }

    @Test func paddingIsNotChecked() throws {
        var bytes = Self.sha1Header
        bytes[3] = 0xFF
        #expect(try DatabaseHeader(decoding: bytes.span).fileID == 0x0102_0304_0506_0708)
    }

    @Test func tooFewBytesIsEndOfStream() {
        let short = Array(Self.sha1Header.dropLast())
        #expect(throws: XitDBError.endOfStream) { try DatabaseHeader(decoding: short.span) }
    }
}

@Suite struct HashIDTests {
    @Test func bytesAreTheBigEndianFormOfTheNumber() {
        let sha1: HashID = "sha1"
        #expect(sha1.rawValue == 0x7368_6131)
        #expect(array(sha1.bytes) == [0x73, 0x68, 0x61, 0x31])
        #expect(array(HashID(rawValue: 0x0102_0304).bytes) == [1, 2, 3, 4])
        #expect(array(HashID(rawValue: 0).bytes) == [0, 0, 0, 0])
        #expect(HashID(bytes: [0xFF, 0xFF, 0xFF, 0xFF]).rawValue == .max)
    }

    /// A string init takes exactly four bytes of UTF-8; the description
    /// gives them back when they are printable, and the number otherwise.
    @Test func aStringIsFourBytes() {
        #expect(HashID("sha1") == HashID(rawValue: 0x7368_6131))
        #expect(HashID(string: "sha1") == HashID(rawValue: 0x7368_6131))
        #expect(HashID(string: "sha") == nil)
        #expect(HashID(string: "sha256") == nil)
        #expect(HashID(string: "ab\u{E9}") == HashID(rawValue: 0x6162_C3A9))
        #expect(HashID("sha1").description == "sha1")
        #expect(HashID(rawValue: 0).description == "0")
        #expect(HashID(rawValue: 0x0102_0304).description == "16909060")
    }
}

@Suite struct FormatTagTests {
    /// A tag is its two bytes: from a string of two bytes, a literal, or
    /// the bytes themselves; a string of any other length is nil.
    @Test func aTagIsTwoBytes() {
        let bi: FormatTag = "bi"
        #expect(bi == FormatTag(0x62, 0x69))
        #expect(array(bi.bytes) == [0x62, 0x69])
        #expect(FormatTag("bi") == bi)
        #expect(FormatTag(string: "bi") == bi)
        #expect(FormatTag(string: "b") == nil)
        #expect(FormatTag(string: "big") == nil)
        #expect(FormatTag(string: "") == nil)
        #expect(FormatTag(string: "\u{E9}") == FormatTag(0xC3, 0xA9))
        #expect(bi.description == "bi")
        #expect(FormatTag(0, 0x69).description == "0x0069")
        #expect(FormatTag(0x62, 0x7F).description == "0x627F")
        var seen: Set<FormatTag> = [bi]
        seen.insert(FormatTag(0x62, 0x69))
        #expect(seen.count == 1)
    }
}

@Suite struct RootHeaderTests {
    private static func header(version: UInt16) -> DatabaseHeader {
        DatabaseHeader(fileID: 1, hashID: HashID(rawValue: 0), hashSize: 20, version: version)
    }

    @Test func theRootHeaderStartsAfterTheDatabaseHeaderInBothVersions() {
        #expect(RootHeader.position == 20)
    }

    /// Version 1: a copy of the root slot, nine bytes, and then the
    /// committed size; the data starts after seventeen bytes.
    @Test func positionsInAVersionOneFile() {
        let header = Self.header(version: 1)
        #expect(header.fileSizePosition == 29)
        #expect(header.dataStart == 37)
        #expect(header.minimumFileSize == 62)
    }

    /// Version 2: four bytes of padding and then the committed size, at a
    /// multiple of eight; the data starts after twelve bytes.
    @Test func positionsInAVersionTwoFile() {
        let header = Self.header(version: 2)
        #expect(header.fileSizePosition == 24)
        #expect(header.fileSizePosition % 8 == 0)
        #expect(header.dataStart == 32)
        #expect(header.minimumFileSize == 57)
    }

    @Test func aNewHeaderHasTheLayoutOfVersionTwo() {
        let header = DatabaseHeader(fileID: 1, hashID: HashID(rawValue: 0), hashSize: 20)
        #expect(header.fileSizePosition == 24)
        #expect(header.dataStart == 32)
    }
}

@Suite struct CollectionHeaderTests {
    @Test func arrayListHeader() throws {
        #expect(ArrayListHeader.byteCount == 16)
        // size 2, then the offset of the root index block, 4863 = 0x12FF
        let bytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0x02] + [0, 0, 0, 0, 0, 0, 0x12, 0xFF]
        let header = try ArrayListHeader(decoding: bytes.span)
        #expect(header == ArrayListHeader(size: 2, ptr: 4863))
        #expect(encoded(capacity: 16) { header.encode(into: &$0) } == bytes)

        let large = ArrayListHeader(size: .max, ptr: 0x0102_0304_0506_0708)
        let largeBytes = encoded(capacity: 16) { large.encode(into: &$0) }
        #expect(try ArrayListHeader(decoding: largeBytes.span) == large)

        let short = zeros(15)
        #expect(throws: XitDBError.endOfStream) { try ArrayListHeader(decoding: short.span) }
    }

    @Test func bTreeHeader() throws {
        #expect(BTreeHeader.byteCount == 16)
        // size 5, then the offset of the root node, 256
        let bytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0x05] + [0, 0, 0, 0, 0, 0, 0x01, 0x00]
        let header = try BTreeHeader(decoding: bytes.span)
        #expect(header == BTreeHeader(size: 5, rootPtr: 256))
        #expect(encoded(capacity: 16) { header.encode(into: &$0) } == bytes)

        let large = BTreeHeader(size: 0x0102_0304_0506_0708, rootPtr: .max)
        let largeBytes = encoded(capacity: 16) { large.encode(into: &$0) }
        #expect(try BTreeHeader(decoding: largeBytes.span) == large)

        let short = zeros(15)
        #expect(throws: XitDBError.endOfStream) { try BTreeHeader(decoding: short.span) }
    }
}
