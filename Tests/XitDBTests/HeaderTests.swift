import Testing

@testable import XitDB

@Suite struct DatabaseHeaderTests {
    /// magic "xit", padding, version 1, hash size 20, hash ID "sha1",
    /// file ID 0x0102030405060708
    static let sha1Header: [UInt8] = [
        0x78, 0x69, 0x74, 0x00,
        0x00, 0x01,
        0x00, 0x14,
        0x73, 0x68, 0x61, 0x31,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    ]

    @Test func sizeOnDisk() {
        #expect(DatabaseHeader.byteCount == 20)
        #expect(Self.sha1Header.count == 20)
    }

    @Test func decodesHandWrittenBytes() throws {
        let header = try DatabaseHeader(decoding: Self.sha1Header.span)
        #expect(header.version == 1)
        #expect(header.hashSize == 20)
        #expect(header.hashID == HashID(id: 0x7368_6131))
        #expect(header.fileID == 0x0102_0304_0506_0708)
    }

    @Test func encodesHandWrittenBytes() {
        let header = DatabaseHeader(
            fileID: 0x0102_0304_0506_0708,
            hashID: HashID(bytes: [0x73, 0x68, 0x61, 0x31]),
            hashSize: 20
        )
        #expect(header.version == DatabaseHeader.currentVersion)
        #expect(encoded(capacity: 20) { header.encode(into: &$0) } == Self.sha1Header)
    }

    @Test func roundTrips() throws {
        let header = DatabaseHeader(fileID: .max, hashID: HashID(id: 0), hashSize: 8)
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
        for version in [UInt8(0), 2] {
            var bytes = Self.sha1Header
            bytes[5] = version
            #expect(throws: XitDBError.invalidVersion) { try DatabaseHeader(decoding: bytes.span) }
        }
        var highByte = Self.sha1Header
        highByte[4] = 1
        #expect(throws: XitDBError.invalidVersion) { try DatabaseHeader(decoding: highByte.span) }
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
        let sha1 = HashID(bytes: [0x73, 0x68, 0x61, 0x31])
        #expect(sha1.id == 0x7368_6131)
        #expect(array(sha1.bytes) == [0x73, 0x68, 0x61, 0x31])
        #expect(array(HashID(id: 0x0102_0304).bytes) == [1, 2, 3, 4])
        #expect(array(HashID(id: 0).bytes) == [0, 0, 0, 0])
        #expect(HashID(bytes: [0xFF, 0xFF, 0xFF, 0xFF]).id == .max)
    }
}

@Suite struct RootHeaderTests {
    @Test func positionsInTheFile() {
        #expect(RootHeader.byteCount == 17)
        #expect(RootHeader.position == 20)
        #expect(RootHeader.fileSizePosition == 29)
        #expect(RootHeader.endPosition == 37)
        #expect(RootHeader.minimumFileSize == 62)
    }

    @Test func decodesAndEncodesHandWrittenBytes() throws {
        // root slot: array_list at 4847; file size 8550 = 0x2166
        let bytes: [UInt8] = [0x02, 0, 0, 0, 0, 0, 0, 0x12, 0xEF] + [0, 0, 0, 0, 0, 0, 0x21, 0x66]
        let header = try RootHeader(decoding: bytes.span)
        #expect(header.root == Slot(value: 4847, tag: .arrayList))
        #expect(header.fileSize == 8550)
        #expect(encoded(capacity: 17) { header.encode(into: &$0) } == bytes)
    }

    @Test func roundTrips() throws {
        let header = RootHeader(root: Slot(value: .max, tag: .hashMap), fileSize: 0x0102_0304_0506_0708)
        let bytes = encoded(capacity: 17) { header.encode(into: &$0) }
        #expect(bytes.count == 17)
        #expect(try RootHeader(decoding: bytes.span) == header)
    }

    @Test func rejectsBadInput() {
        let short = zeros(16)
        #expect(throws: XitDBError.endOfStream) { try RootHeader(decoding: short.span) }
        let badTag: [UInt8] = [0x11] + zeros(16)
        #expect(throws: XitDBError.invalidEnumTag) { try RootHeader(decoding: badTag.span) }
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
