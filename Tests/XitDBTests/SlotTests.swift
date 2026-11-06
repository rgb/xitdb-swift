import Testing

@testable import XitDB

@Suite struct TagTests {
    @Test func rawValuesAreTheOnesInTheFileFormat() {
        let expected: [(Tag, UInt8)] = [
            (.none, 0), (.index, 1), (.arrayList, 2), (.linkedArrayList, 3), (.hashMap, 4), (.kvPair, 5),
            (.bytes, 6), (.shortBytes, 7), (.uint, 8), (.int, 9), (.float, 10), (.hashSet, 11),
            (.countedHashMap, 12), (.countedHashSet, 13), (.sortedMap, 14), (.sortedSet, 15), (.sortedKvPair, 16),
        ]
        #expect(expected.count == 17)
        for (tag, rawValue) in expected {
            #expect(tag.rawValue == rawValue)
        }
    }

    @Test func everySevenBitValueIsEitherAKnownTagOrRejected() throws {
        for rawValue in UInt8(0)...16 {
            #expect(try Tag(validating: rawValue).rawValue == rawValue)
        }
        for rawValue in UInt8(17)...127 {
            #expect(throws: XitDBError.invalidEnumTag) { try Tag(validating: rawValue) }
        }
    }

    /// Port of the Zig test "validate tag": a slot bit-cast from value 0,
    /// tag 127 and a clear flag is rejected with `InvalidEnumTag`.
    @Test func validateTag() {
        let invalid: [UInt8] = [0x7F, 0, 0, 0, 0, 0, 0, 0, 0]
        #expect(throws: XitDBError.invalidEnumTag) { try Slot(decoding: invalid.span) }
    }
}

@Suite struct SlotTests {
    @Test func sizeOnDisk() {
        #expect(Slot.byteCount == 9)
    }

    @Test func decodesAndEncodesHandWrittenBytes() throws {
        // tag array_list (2), value 4847 = 0x12EF
        let arrayList: [UInt8] = [0x02, 0, 0, 0, 0, 0, 0, 0x12, 0xEF]
        #expect(try Slot(decoding: arrayList.span) == Slot(value: 4847, tag: .arrayList))
        #expect(slotBytes(Slot(value: 4847, tag: .arrayList)) == arrayList)

        // the full flag is bit 7 of the first byte; tag short_bytes (7)
        let taggedShortBytes: [UInt8] = [0x87, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        let slot = Slot(value: 0x0102_0304_0506_0708, tag: .shortBytes, full: true)
        #expect(try Slot(decoding: taggedShortBytes.span) == slot)
        #expect(slotBytes(slot) == taggedShortBytes)

        // a slot explicitly set to nothing: tag none with the flag set
        let explicitNone: [UInt8] = [0x80, 0, 0, 0, 0, 0, 0, 0, 0]
        #expect(try Slot(decoding: explicitNone.span) == Slot(tag: .none, full: true))
        #expect(slotBytes(Slot(tag: .none, full: true)) == explicitNone)

        // the largest tag (sorted_kv_pair, 16) and the largest value
        let largest: [UInt8] = [0x10, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        #expect(try Slot(decoding: largest.span) == Slot(value: .max, tag: .sortedKvPair))
        #expect(slotBytes(Slot(value: .max, tag: .sortedKvPair)) == largest)
    }

    @Test func roundTripsEveryTagAndFlag() throws {
        let values: [UInt64] = [0, 1, 0xFF, 0x0102_0304_0506_0708, 0x8000_0000_0000_0000, .max]
        for rawValue in UInt8(0)...16 {
            let tag = try #require(Tag(rawValue: rawValue))
            for full in [false, true] {
                for value in values {
                    let slot = Slot(value: value, tag: tag, full: full)
                    let bytes = slotBytes(slot)
                    #expect(bytes.count == 9)
                    #expect(try Slot(decoding: bytes.span) == slot)
                }
            }
        }
    }

    /// The first byte is the flag in bit 7 and the tag in the seven bits below
    /// it. Every one of its 256 values either decodes to that flag and tag or
    /// is rejected because the seven bits are not a known tag.
    @Test func everyFirstByteIsDecodedOrRejected() throws {
        for first in UInt8.min...UInt8.max {
            let bytes: [UInt8] = [first, 0, 0, 0, 0, 0, 0, 0, 0x2A]
            let tagBits = first & 0x7F
            if tagBits <= 16 {
                let slot = try Slot(decoding: bytes.span)
                #expect(slot.tag.rawValue == tagBits)
                #expect(slot.full == (first >= 0x80))
                #expect(slot.value == 42)
            } else {
                #expect(throws: XitDBError.invalidEnumTag) { try Slot(decoding: bytes.span) }
            }
        }
    }

    @Test func emptyMeansNeverWritten() throws {
        #expect(Slot().isEmpty)
        #expect(slotBytes(Slot()) == zeros(9))
        #expect(try Slot(decoding: zeros(9).span).isEmpty)

        #expect(!Slot(tag: .none, full: true).isEmpty)
        #expect(!Slot(tag: .uint).isEmpty)
        #expect(!Slot(value: 1, tag: .index).isEmpty)
        // only the tag and the flag decide, as in Zig
        #expect(Slot(value: 5, tag: .none).isEmpty)
    }

    @Test func equalityComparesEveryField() {
        let slot = Slot(value: 7, tag: .uint, full: false)
        #expect(slot == Slot(value: 7, tag: .uint))
        #expect(slot != Slot(value: 8, tag: .uint))
        #expect(slot != Slot(value: 7, tag: .int))
        #expect(slot != Slot(value: 7, tag: .uint, full: true))
    }

    @Test func decodesAtAnOffset() throws {
        let bytes: [UInt8] = [0xAA, 0xBB] + [0x08, 0, 0, 0, 0, 0, 0, 0, 0x2A] + [0xCC]
        #expect(try Slot(decoding: bytes.span, at: 2) == Slot(value: 42, tag: .uint))
    }

    @Test func tooFewBytesIsEndOfStream() {
        let eight = zeros(8)
        #expect(throws: XitDBError.endOfStream) { try Slot(decoding: eight.span) }
        let ten = zeros(10)
        #expect(throws: XitDBError.endOfStream) { try Slot(decoding: ten.span, at: 2) }
        #expect(throws: XitDBError.endOfStream) { try Slot(decoding: ten.span, at: 11) }
        let none: [UInt8] = []
        #expect(throws: XitDBError.endOfStream) { try Slot(decoding: none.span) }
    }

    @Test func slotPointerKeepsThePosition() {
        let pointer = SlotPointer(position: 29, slot: Slot(value: 1, tag: .uint))
        #expect(pointer.position == 29)
        #expect(SlotPointer(position: nil, slot: Slot()).position == nil)
        #expect(pointer != SlotPointer(position: nil, slot: pointer.slot))
    }
}
