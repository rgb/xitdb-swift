/// How byte arrays are stored.
///
/// A byte array lives either in a record of its own, which a `bytes` slot
/// points at, or, when it is short enough, in the eight value bytes of a
/// `shortBytes` slot. Either way it can carry a two-byte format tag, which
/// means nothing to XitDB and is there for callers to say how the bytes are
/// to be interpreted. A slot's `full` flag says whether there is one.
enum ByteArrayFormat {
    /// The size of the length that starts a `bytes` record.
    static let lengthByteCount: UInt64 = 8

    /// The size of the format tag that ends a `bytes` record when there is
    /// one.
    static let formatTagByteCount: UInt64 = 2

    /// The most bytes a `shortBytes` slot can hold: eight, or six when the
    /// last two carry a format tag.
    static func shortCapacity(hasFormatTag: Bool) -> Int {
        hasFormatTag ? 6 : 8
    }

    /// Whether a value can be stored in a `shortBytes` slot.
    ///
    /// It can when it fits and contains no zero byte. The length of a short
    /// value is not stored; it is found again by looking for the first zero
    /// byte, which is why a value containing one cannot be short.
    static func isShort(_ value: Span<UInt8>, hasFormatTag: Bool) -> Bool {
        guard value.count <= shortCapacity(hasFormatTag: hasFormatTag) else { return false }
        for index in value.indices where value[index] == 0 {
            return false
        }
        return true
    }

    /// Packs a short value into a slot.
    ///
    /// The bytes are stored from the most significant byte of the slot's
    /// value down, padded with zeros, with the format tag in the last two
    /// bytes when there is one.
    ///
    /// - Precondition: `isShort(value, hasFormatTag: formatTag != nil)`.
    static func shortSlot(_ value: Span<UInt8>, formatTag: InlineArray<2, UInt8>?) -> Slot {
        precondition(isShort(value, hasFormatTag: formatTag != nil), "the value does not fit a shortBytes slot")
        var packed: UInt64 = 0
        for index in value.indices {
            packed |= UInt64(value[index]) << (56 - 8 * index)
        }
        if let formatTag {
            packed |= UInt64(formatTag[0]) << 8 | UInt64(formatTag[1])
        }
        return Slot(value: packed, tag: .shortBytes, full: formatTag != nil)
    }

    /// The eight value bytes of a slot, in the order they are on disk.
    static func valueBytes(of slot: Slot) -> InlineArray<8, UInt8> {
        var bytes = InlineArray<8, UInt8>(repeating: 0)
        for index in bytes.indices {
            bytes[index] = UInt8(truncatingIfNeeded: slot.value >> (56 - 8 * index))
        }
        return bytes
    }

    /// The length of the value in a `shortBytes` slot: the position of the
    /// first zero byte, or the slot's whole capacity if there is none.
    static func shortByteCount(of slot: Slot) -> Int {
        let bytes = valueBytes(of: slot)
        let capacity = shortCapacity(hasFormatTag: slot.full)
        for index in 0..<capacity where bytes[index] == 0 {
            return index
        }
        return capacity
    }

    /// The format tag in a `shortBytes` slot, or `nil` if it has none.
    static func shortFormatTag(of slot: Slot) -> InlineArray<2, UInt8>? {
        guard slot.full else { return nil }
        let bytes = valueBytes(of: slot)
        return [bytes[6], bytes[7]]
    }
}
