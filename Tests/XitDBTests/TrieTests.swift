import Testing

@testable import XitDB

@Suite struct TrieTests {
    @Test func constants() {
        #expect(Trie.bitsPerLevel == 4)
        #expect(Trie.slotsPerBlock == 16)
        #expect(Trie.mask == 15)
    }

    /// The helper works on hash bytes. For an eight-byte hash it must agree
    /// with what Zig computes on the hash as an integer, at every level.
    @Test(
        arguments: [
            0x0000_0000_0000_0000, 0xFFFF_FFFF_FFFF_FFFF, 0x0123_4567_89AB_CDEF, 0xFEDC_BA98_7654_3210,
            0x8000_0000_0000_0001, 0x0F0F_0F0F_F0F0_F0F0,
        ] as [UInt64])
    func hashIndexAgreesWithIntegerArithmeticAtEveryLevel(hash: UInt64) throws {
        let bytes = bigEndianBytes(hash)
        for level in 0..<16 {
            let expected = Int((hash >> (UInt64(level) * Trie.bitsPerLevel)) & Trie.mask)
            #expect(try Trie.index(ofHash: bytes.span, level: level) == expected)
        }
    }

    @Test func hashIndexStartsAtTheLowNibbleOfTheLastByte() throws {
        // a 20-byte hash: 0xAB, seventeen zero bytes, 0xCD, 0xEF
        var hash = zeros(20)
        hash[0] = 0xAB
        hash[18] = 0xCD
        hash[19] = 0xEF
        #expect(try Trie.index(ofHash: hash.span, level: 0) == 0xF)
        #expect(try Trie.index(ofHash: hash.span, level: 1) == 0xE)
        #expect(try Trie.index(ofHash: hash.span, level: 2) == 0xD)
        #expect(try Trie.index(ofHash: hash.span, level: 3) == 0xC)
        #expect(try Trie.index(ofHash: hash.span, level: 4) == 0)
        #expect(try Trie.index(ofHash: hash.span, level: 38) == 0xB)
        #expect(try Trie.index(ofHash: hash.span, level: 39) == 0xA)
    }

    @Test func runningOutOfHashIsKeyOffsetExceeded() {
        let eight = zeros(8)
        #expect(throws: XitDBError.keyOffsetExceeded) { try Trie.index(ofHash: eight.span, level: 16) }
        let twenty = zeros(20)
        #expect(throws: XitDBError.keyOffsetExceeded) { try Trie.index(ofHash: twenty.span, level: 40) }
        #expect(throws: XitDBError.keyOffsetExceeded) { try Trie.index(ofHash: twenty.span, level: 255) }
        #expect(throws: XitDBError.keyOffsetExceeded) { try Trie.index(ofHash: twenty.span, level: -1) }
        let none: [UInt8] = []
        #expect(throws: XitDBError.keyOffsetExceeded) { try Trie.index(ofHash: none.span, level: 0) }
    }

    @Test(
        arguments: [
            (0, 0), (1, 0), (15, 0),
            (16, 1), (17, 1), (255, 1),
            (256, 2), (4095, 2),
            (4096, 3), (65535, 3),
            (65536, 4), (0xF_FFFF, 4),
            (0x10_0000, 5),
            (0xFFFF_FFFF, 7), (0x1_0000_0000, 8),
            (0x0FFF_FFFF_FFFF_FFFF, 14), (0x1000_0000_0000_0000, 15),
            (0xFFFF_FFFF_FFFF_FFFF, 15),
        ] as [(UInt64, UInt8)])
    func arrayListShiftAtBoundaries(lastIndex: UInt64, shift: UInt8) {
        #expect(Trie.arrayListShift(lastIndex: lastIndex) == shift)
    }

    @Test func arrayListShiftIsTheWholePartOfTheBase16Logarithm() {
        for shift in UInt8(1)...15 {
            let power = UInt64(1) << (UInt64(shift) * 4)
            #expect(Trie.arrayListShift(lastIndex: power - 1) == shift - 1)
            #expect(Trie.arrayListShift(lastIndex: power) == shift)
            #expect(Trie.arrayListShift(lastIndex: power + 1) == shift)
        }
    }
}
