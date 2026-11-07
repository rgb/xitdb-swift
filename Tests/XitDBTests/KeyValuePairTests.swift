import Testing

@testable import XitDB

@Suite struct KeyValuePairTests {
    static let hash: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
    /// short_bytes "key"
    static let keySlot: [UInt8] = [0x07, 0x6B, 0x65, 0x79, 0, 0, 0, 0, 0]
    /// uint 42
    static let valueSlot: [UInt8] = [0x08, 0, 0, 0, 0, 0, 0, 0, 0x2A]

    static let pair = KeyValuePair(
        keySlot: Slot(value: 0x6B65_7900_0000_0000, tag: .shortBytes),
        valueSlot: Slot(value: 42, tag: .uint)
    )

    @Test func sizesOnDisk() {
        #expect(KeyValuePair.sortedByteCount == 18)
        #expect(KeyValuePair.byteCount(hashSize: 20) == 38)
        #expect(KeyValuePair.byteCount(hashSize: 8) == 26)
        #expect(KeyValuePair.byteCount(hashSize: 0) == 18)
        #expect(KeyValuePair.byteCount(hashSize: .max) == 65553)
    }

    @Test func hashedFormIsHashThenKeyThenValue() throws {
        let bytes = Self.hash + Self.keySlot + Self.valueSlot
        #expect(try KeyValuePair(decodingHashed: bytes.span, hashSize: 4) == Self.pair)
        let hash = Self.hash
        #expect(encoded(capacity: 22) { Self.pair.encodeHashed(hash: hash.span, into: &$0) } == bytes)
    }

    @Test func hashedFormWithSHA1SizedHash() throws {
        let hash = (1...20).map { UInt8($0) }
        let bytes = encoded(capacity: 38) { Self.pair.encodeHashed(hash: hash.span, into: &$0) }
        #expect(bytes == hash + Self.keySlot + Self.valueSlot)
        #expect(try KeyValuePair(decodingHashed: bytes.span, hashSize: 20) == Self.pair)

        let padded = [0xEE] + bytes
        #expect(try KeyValuePair(decodingHashed: padded.span, at: 1, hashSize: 20) == Self.pair)
    }

    @Test func sortedFormIsKeyThenValue() throws {
        let bytes = Self.keySlot + Self.valueSlot
        #expect(try KeyValuePair(decodingSorted: bytes.span) == Self.pair)
        #expect(encoded(capacity: 18) { Self.pair.encodeSorted(into: &$0) } == bytes)

        let padded = [0xEE, 0xEE] + bytes
        #expect(try KeyValuePair(decodingSorted: padded.span, at: 2) == Self.pair)
    }

    @Test func aSetLeavesTheValueSlotEmpty() throws {
        let bytes = Self.hash + Self.keySlot + zeros(9)
        #expect(try KeyValuePair(decodingHashed: bytes.span, hashSize: 4).valueSlot.isEmpty)
    }

    @Test func rejectsBadInput() {
        let shortHashed = Array((Self.hash + Self.keySlot + Self.valueSlot).dropLast())
        #expect(throws: XitDBError.endOfStream) { try KeyValuePair(decodingHashed: shortHashed.span, hashSize: 4) }
        let shortSorted = Array((Self.keySlot + Self.valueSlot).dropLast())
        #expect(throws: XitDBError.endOfStream) { try KeyValuePair(decodingSorted: shortSorted.span) }

        let badKey = Self.hash + [0x7F] + zeros(8) + Self.valueSlot
        #expect(throws: XitDBError.invalidEnumTag) { try KeyValuePair(decodingHashed: badKey.span, hashSize: 4) }
        let badValue = Self.keySlot + [0x7F] + zeros(8)
        #expect(throws: XitDBError.invalidEnumTag) { try KeyValuePair(decodingSorted: badValue.span) }
    }

    @Test func keyAndValuePositions() {
        let hashed = Slot(value: 1000, tag: .kvPair)
        #expect(KeyValuePair.keyPosition(of: hashed, hashSize: 20) == 1020)
        #expect(KeyValuePair.valuePosition(of: hashed, hashSize: 20) == 1029)
        #expect(KeyValuePair.keyPosition(of: hashed, hashSize: 8) == 1008)
        #expect(KeyValuePair.valuePosition(of: hashed, hashSize: 8) == 1017)

        let sorted = Slot(value: 1000, tag: .sortedKvPair)
        #expect(KeyValuePair.keyPosition(of: sorted, hashSize: 20) == 1000)
        #expect(KeyValuePair.valuePosition(of: sorted, hashSize: 20) == 1009)
    }

    /// A position that does not fit a number is a damaged slot: there is no
    /// such position, so the result is `nil` rather than a wrapped offset.
    @Test func positionsThatOverflowAreNil() {
        // the hash does not fit after the record's offset
        let hashedAtTheEnd = Slot(value: .max, tag: .kvPair)
        #expect(KeyValuePair.keyPosition(of: hashedAtTheEnd, hashSize: 20) == nil)
        #expect(KeyValuePair.valuePosition(of: hashedAtTheEnd, hashSize: 20) == nil)
        #expect(KeyValuePair.keyPosition(of: Slot(value: .max - 19, tag: .kvPair), hashSize: 20) == nil)
        #expect(KeyValuePair.valuePosition(of: Slot(value: .max - 19, tag: .kvPair), hashSize: 20) == nil)

        // the key slot fits exactly, and the value slot after it does not
        let keyFits = Slot(value: .max - 20, tag: .kvPair)
        #expect(KeyValuePair.keyPosition(of: keyFits, hashSize: 20) == .max)
        #expect(KeyValuePair.valuePosition(of: keyFits, hashSize: 20) == nil)
        #expect(KeyValuePair.keyPosition(of: hashedAtTheEnd, hashSize: 0) == .max)
        #expect(KeyValuePair.valuePosition(of: hashedAtTheEnd, hashSize: 0) == nil)
        #expect(KeyValuePair.keyPosition(of: Slot(value: .max - 65535, tag: .kvPair), hashSize: .max) == .max)
        #expect(KeyValuePair.keyPosition(of: Slot(value: .max - 65534, tag: .kvPair), hashSize: .max) == nil)

        // the sorted form has no hash before its key slot
        let sortedAtTheEnd = Slot(value: .max, tag: .sortedKvPair)
        #expect(KeyValuePair.keyPosition(of: sortedAtTheEnd, hashSize: 20) == .max)
        #expect(KeyValuePair.valuePosition(of: sortedAtTheEnd, hashSize: 20) == nil)
        let sortedValueFits = Slot(value: UInt64.max - 9, tag: .sortedKvPair)
        #expect(KeyValuePair.keyPosition(of: sortedValueFits, hashSize: 20) == UInt64.max - 9)
        #expect(KeyValuePair.valuePosition(of: sortedValueFits, hashSize: 20) == .max)
        let sortedValueOverflows = Slot(value: UInt64.max - 8, tag: .sortedKvPair)
        #expect(KeyValuePair.keyPosition(of: sortedValueOverflows, hashSize: 20) == UInt64.max - 8)
        #expect(KeyValuePair.valuePosition(of: sortedValueOverflows, hashSize: 20) == nil)
    }

    @Test func aKeyOnlyEntryHasNoPositions() {
        for tag in [Tag.bytes, .shortBytes] {
            let entry = Slot(value: 1000, tag: tag)
            #expect(KeyValuePair.isKeyOnlyEntry(entry))
            #expect(KeyValuePair.keyPosition(of: entry, hashSize: 20) == nil)
            #expect(KeyValuePair.valuePosition(of: entry, hashSize: 20) == nil)
        }
        #expect(!KeyValuePair.isKeyOnlyEntry(Slot(value: 1000, tag: .kvPair)))
        #expect(!KeyValuePair.isKeyOnlyEntry(Slot(value: 1000, tag: .sortedKvPair)))
        #expect(!KeyValuePair.isKeyOnlyEntry(Slot()))
    }
}
