import Testing

@testable import XitDB

@Suite struct ByteArrayFormatTests {
    private func isShort(_ value: [UInt8], hasFormatTag: Bool) -> Bool {
        ByteArrayFormat.isShort(value.span, hasFormatTag: hasFormatTag)
    }

    private func shortSlot(_ value: [UInt8], formatTag: FormatTag? = nil) -> Slot {
        ByteArrayFormat.shortSlot(value.span, formatTag: formatTag)
    }

    private func formatTag(of slot: Slot) -> [UInt8]? {
        ByteArrayFormat.shortFormatTag(of: slot).map { array($0.bytes) }
    }

    @Test func recordSizes() {
        #expect(ByteArrayFormat.lengthByteCount == 8)
        #expect(ByteArrayFormat.formatTagByteCount == 2)
        #expect(ByteArrayFormat.shortCapacity(hasFormatTag: false) == 8)
        #expect(ByteArrayFormat.shortCapacity(hasFormatTag: true) == 6)
    }

    @Test func exactlyEightBytesWithoutAZeroIsShort() {
        #expect(isShort([1, 2, 3, 4, 5, 6, 7, 8], hasFormatTag: false))
        #expect(!isShort([1, 2, 3, 4, 5, 6, 7, 8, 9], hasFormatTag: false))
    }

    @Test func aValueContainingAZeroByteIsNotShort() {
        #expect(!isShort([1, 0, 3], hasFormatTag: false))
        #expect(!isShort([0], hasFormatTag: false))
        #expect(!isShort([1, 2, 0], hasFormatTag: true))
        #expect(!isShort([1, 2, 3, 4, 5, 6, 7, 0], hasFormatTag: false))
    }

    @Test func sixBytesWithAFormatTagIsShortAndSevenIsNot() {
        #expect(isShort([1, 2, 3, 4, 5, 6], hasFormatTag: true))
        #expect(!isShort([1, 2, 3, 4, 5, 6, 7], hasFormatTag: true))
        #expect(isShort([1, 2, 3, 4, 5, 6, 7], hasFormatTag: false))
    }

    @Test func theEmptyValueIsShort() {
        #expect(isShort([], hasFormatTag: false))
        #expect(isShort([], hasFormatTag: true))
    }

    @Test func packsBytesFromTheFirstValueByteDown() {
        // "abc", zero padded
        let slot = shortSlot([0x61, 0x62, 0x63])
        #expect(slot == Slot(value: 0x6162_6300_0000_0000, tag: .shortBytes, full: false))
        #expect(slotBytes(slot) == [0x07, 0x61, 0x62, 0x63, 0, 0, 0, 0, 0])
        #expect(ByteArrayFormat.shortByteCount(of: slot) == 3)
        #expect(formatTag(of: slot) == nil)
        #expect(array(ByteArrayFormat.valueBytes(of: slot)) == [0x61, 0x62, 0x63, 0, 0, 0, 0, 0])
    }

    @Test func theFormatTagTakesTheLastTwoBytes() {
        // "abc" with the format tag "bi"
        let slot = shortSlot([0x61, 0x62, 0x63], formatTag: "bi")
        #expect(slot == Slot(value: 0x6162_6300_0000_6269, tag: .shortBytes, full: true))
        #expect(slotBytes(slot) == [0x87, 0x61, 0x62, 0x63, 0, 0, 0, 0x62, 0x69])
        #expect(ByteArrayFormat.shortByteCount(of: slot) == 3)
        #expect(formatTag(of: slot) == [0x62, 0x69])
    }

    @Test func aValueThatFillsTheSlotHasNoTerminator() {
        let eight = shortSlot([1, 2, 3, 4, 5, 6, 7, 8])
        #expect(eight.value == 0x0102_0304_0506_0708)
        #expect(ByteArrayFormat.shortByteCount(of: eight) == 8)
        #expect(formatTag(of: eight) == nil)

        let six = shortSlot([1, 2, 3, 4, 5, 6], formatTag: FormatTag(0xAA, 0xBB))
        #expect(six.value == 0x0102_0304_0506_AABB)
        #expect(ByteArrayFormat.shortByteCount(of: six) == 6)
        #expect(formatTag(of: six) == [0xAA, 0xBB])
    }

    @Test func theEmptyValuePacksToZero() {
        let plain = shortSlot([])
        #expect(plain == Slot(value: 0, tag: .shortBytes, full: false))
        #expect(ByteArrayFormat.shortByteCount(of: plain) == 0)
        #expect(formatTag(of: plain) == nil)

        let tagged = shortSlot([], formatTag: "bi")
        #expect(tagged == Slot(value: 0x6269, tag: .shortBytes, full: true))
        #expect(ByteArrayFormat.shortByteCount(of: tagged) == 0)
        #expect(formatTag(of: tagged) == [0x62, 0x69])
    }

    @Test func aFormatTagMayContainZeroBytes() {
        // the length is found in the first six bytes only, so a zero in the
        // tag does not shorten a six-byte value
        let slot = shortSlot([1, 2, 3, 4, 5, 6], formatTag: FormatTag(0, 0))
        #expect(slot.full)
        #expect(ByteArrayFormat.shortByteCount(of: slot) == 6)
        #expect(formatTag(of: slot) == [0, 0])

        let endsInZero = shortSlot([1, 2, 3, 4, 5, 6], formatTag: FormatTag(0x62, 0))
        #expect(ByteArrayFormat.shortByteCount(of: endsInZero) == 6)
        #expect(formatTag(of: endsInZero) == [0x62, 0])
    }

    @Test func everyShortLengthRoundTrips() {
        for hasFormatTag in [false, true] {
            for length in 0...ByteArrayFormat.shortCapacity(hasFormatTag: hasFormatTag) {
                let value = (0..<length).map { UInt8($0 + 1) }
                let slot = shortSlot(value, formatTag: hasFormatTag ? FormatTag(0x74, 0x67) : nil)
                #expect(slot.tag == .shortBytes)
                #expect(slot.full == hasFormatTag)
                #expect(ByteArrayFormat.shortByteCount(of: slot) == length)
                #expect(Array(array(ByteArrayFormat.valueBytes(of: slot)).prefix(length)) == value)
                #expect(formatTag(of: slot) == (hasFormatTag ? [0x74, 0x67] : nil))
            }
        }
    }
}
