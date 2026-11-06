import Testing

@testable import XitDB

@Suite struct CRC64XZTests {
    @Test func standardCheckValue() {
        let input = Array("123456789".utf8)
        #expect(CRC64XZ.checksum(of: input.span) == 0x995D_C9BB_DF19_39FA)
    }

    @Test func emptyInputIsZero() {
        let input: [UInt8] = []
        #expect(CRC64XZ.checksum(of: input.span) == 0)
        #expect(CRC64XZ().checksum == 0)
    }

    @Test func feedingInPiecesGivesTheSameChecksum() {
        let input = Array("123456789".utf8)
        var crc = CRC64XZ()
        crc.update(input[0])
        crc.update(input.span, at: 1, count: 3)
        crc.update(input.span, at: 4, count: 5)
        #expect(crc.checksum == 0x995D_C9BB_DF19_39FA)
    }

    @Test func integersAreFedBigEndian() {
        let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        var crc = CRC64XZ()
        crc.updateBigEndian(0x0102_0304_0506_0708)
        #expect(crc.checksum == CRC64XZ.checksum(of: bytes.span))
    }
}

@Suite struct RootTrailerTests {
    /// The file ID of the shared fixture `test.db`.
    static let fileID: UInt64 = 0x172A_756F_2208_A5EC

    /// The fixture's first trailer, at offset 37: an empty root, commit ID 0.
    static let firstTrailer: [UInt8] =
        zeros(9) + zeros(8) + [0x41, 0xAC, 0x24, 0x97, 0x72, 0x4F, 0xED, 0x51]

    /// The fixture's last trailer, at offset 8525: an array list at 4847.
    static let lastTrailer: [UInt8] =
        [0x02, 0, 0, 0, 0, 0, 0, 0x12, 0xEF]
        + [0x3D, 0x3A, 0xE7, 0x69, 0xEB, 0x52, 0x19, 0x91]
        + [0x95, 0xC9, 0x21, 0x27, 0x3A, 0x36, 0x1D, 0x84]

    @Test func sizeOnDisk() {
        #expect(RootTrailer.byteCount == 25)
        #expect(Self.firstTrailer.count == 25)
        #expect(Self.lastTrailer.count == 25)
    }

    @Test func checksumMatchesWhatZigWrote() {
        #expect(
            RootTrailer.checksum(fileID: Self.fileID, position: 37, root: Slot(), commitID: 0)
                == 0x41AC_2497_724F_ED51
        )
        #expect(
            RootTrailer.checksum(
                fileID: Self.fileID,
                position: 8525,
                root: Slot(value: 4847, tag: .arrayList),
                commitID: 0x3D3A_E769_EB52_1991
            ) == 0x95C9_2127_3A36_1D84
        )
    }

    @Test func checksumCoversThe33BytesInOrder() {
        let root = Slot(value: 0x1122_3344_5566_7788, tag: .bytes, full: true)
        let input = bigEndianBytes(1) + bigEndianBytes(2) + slotBytes(root) + bigEndianBytes(3)
        #expect(input.count == 33)
        #expect(
            RootTrailer.checksum(fileID: 1, position: 2, root: root, commitID: 3)
                == CRC64XZ.checksum(of: input.span)
        )
    }

    @Test func decodesAndEncodesBytesWrittenByZig() throws {
        let first = try RootTrailer(decoding: Self.firstTrailer.span, fileID: Self.fileID, position: 37)
        #expect(first.root.isEmpty)
        #expect(first.commitID == 0)
        #expect(first.checksum == 0x41AC_2497_724F_ED51)
        #expect(first == RootTrailer(fileID: Self.fileID, position: 37, root: Slot(), commitID: 0))
        #expect(encoded(capacity: 25) { first.encode(into: &$0) } == Self.firstTrailer)

        let last = try RootTrailer(decoding: Self.lastTrailer.span, fileID: Self.fileID, position: 8525)
        #expect(last.root == Slot(value: 4847, tag: .arrayList))
        #expect(last.commitID == 0x3D3A_E769_EB52_1991)
        #expect(encoded(capacity: 25) { last.encode(into: &$0) } == Self.lastTrailer)
    }

    @Test func roundTripsAtAnOffset() throws {
        let trailer = RootTrailer(fileID: 9, position: 1000, root: Slot(value: 77, tag: .hashMap), commitID: 5)
        let bytes = [0xEE, 0xEE] + encoded(capacity: 25) { trailer.encode(into: &$0) }
        #expect(try RootTrailer(decoding: bytes.span, at: 2, fileID: 9, position: 1000) == trailer)
    }

    @Test func anyMismatchIsInvalidDatabase() {
        let bytes = Self.lastTrailer
        #expect(throws: XitDBError.invalidDatabase) {
            try RootTrailer(decoding: bytes.span, fileID: Self.fileID, position: 8524)
        }
        #expect(throws: XitDBError.invalidDatabase) {
            try RootTrailer(decoding: bytes.span, fileID: Self.fileID &+ 1, position: 8525)
        }
        for index in bytes.indices {
            var corrupt = bytes
            corrupt[index] ^= 0x01
            #expect(throws: XitDBError.invalidDatabase) {
                try RootTrailer(decoding: corrupt.span, fileID: Self.fileID, position: 8525)
            }
        }
    }

    @Test func checksumIsVerifiedBeforeTheTag() {
        // an unknown tag (0x7F) under a checksum that matches the bytes
        let body: [UInt8] = [0x7F] + zeros(8) + bigEndianBytes(4)
        let input = bigEndianBytes(Self.fileID) + bigEndianBytes(100) + body
        let valid = body + bigEndianBytes(CRC64XZ.checksum(of: input.span))
        #expect(throws: XitDBError.invalidEnumTag) {
            try RootTrailer(decoding: valid.span, fileID: Self.fileID, position: 100)
        }

        // the same unknown tag under a checksum that does not match
        let invalid = body + bigEndianBytes(0)
        #expect(throws: XitDBError.invalidDatabase) {
            try RootTrailer(decoding: invalid.span, fileID: Self.fileID, position: 100)
        }
    }

    @Test func tooFewBytesIsEndOfStream() {
        let short = Array(Self.firstTrailer.dropLast())
        #expect(throws: XitDBError.endOfStream) {
            try RootTrailer(decoding: short.span, fileID: Self.fileID, position: 37)
        }
    }
}
