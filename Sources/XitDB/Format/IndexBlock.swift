/// Sixteen slots, the node of a hash trie and of an array list's radix trie.
struct IndexBlock: Sendable {
    var slots: InlineArray<16, Slot>

    /// The size of an index block on disk.
    static let byteCount: UInt64 = Slot.byteCount * Trie.slotsPerBlock

    /// The size of the entry count that precedes the root index block of a
    /// counted hash map or set.
    static let countByteCount: UInt64 = 8

    /// Creates a block of empty slots.
    init() {
        self.slots = InlineArray(repeating: Slot())
    }

    /// Creates a block of the given slots.
    init(slots: InlineArray<16, Slot>) {
        self.slots = slots
    }

    /// Decodes the block that starts at `offset`.
    ///
    /// - Throws: `endOfStream` if fewer than 144 bytes are available, or
    ///   `invalidEnumTag` at the first slot whose tag is unknown.
    init(decoding bytes: Span<UInt8>, at offset: Int = 0) throws(XitDBError) {
        try bytes.requireBytes(144, at: offset)
        self.slots = try SlotGroup.decode(bytes, at: offset)
    }

    /// Appends the block's 144 bytes.
    func encode(into output: inout OutputSpan<UInt8>) {
        SlotGroup.encode(slots, into: &output)
    }
}

/// Codecs for the groups of sixteen that index blocks and tree nodes are made
/// of.
enum SlotGroup {
    /// Decodes sixteen slots that start at `offset`.
    ///
    /// Each slot is checked on its own, in order, so the bytes running out
    /// and an unknown tag are reported in the order Zig meets them.
    ///
    /// - Throws: `endOfStream` if the bytes run out, or `invalidEnumTag` at
    ///   the first slot whose tag is unknown.
    static func decode(_ bytes: Span<UInt8>, at offset: Int) throws(XitDBError) -> InlineArray<16, Slot> {
        var slots = InlineArray<16, Slot>(repeating: Slot())
        for index in slots.indices {
            slots[index] = try Slot(decoding: bytes, at: offset + index * 9)
        }
        return slots
    }

    /// Checks sixteen slots that start at `offset` as ``decode(_:at:)``
    /// does, for a reader that needs one of them and the same errors.
    ///
    /// - Throws: `endOfStream` if the bytes run out, or `invalidEnumTag` at
    ///   the first slot whose tag is unknown.
    static func validate(_ bytes: Span<UInt8>, at offset: Int) throws(XitDBError) {
        if offset >= 0 && bytes.count - offset >= 144 {
            // all sixteen are there: one check of the bounds, then the tag
            // bytes, which a descent does at every node
            for index in 0..<Int(Trie.slotsPerBlock) where bytes[offset + index * 9] & 0x7F > Slot.Tag.largestRawValue {
                throw .invalidEnumTag
            }
            return
        }
        // the bytes run out somewhere: in order, so that a tag that is
        // not one before the end is reported first, as Zig reports it
        for index in 0..<Int(Trie.slotsPerBlock) {
            let start = offset + index * 9
            try bytes.requireBytes(9, at: start)
            _ = try Slot.Tag(validating: bytes[start] & 0x7F)
        }
    }

    /// Appends sixteen slots.
    static func encode(_ slots: InlineArray<16, Slot>, into output: inout OutputSpan<UInt8>) {
        for index in slots.indices {
            slots[index].encode(into: &output)
        }
    }

    /// Decodes sixteen subtree counts that start at `offset`.
    ///
    /// - Throws: `endOfStream` if fewer than 128 bytes are available.
    static func decodeCounts(_ bytes: Span<UInt8>, at offset: Int) throws(XitDBError) -> InlineArray<16, UInt64> {
        try bytes.requireBytes(128, at: offset)
        var counts = InlineArray<16, UInt64>(repeating: 0)
        for index in counts.indices {
            counts[index] = bytes.bigEndian(at: offset + index * 8)
        }
        return counts
    }

    /// Appends sixteen subtree counts.
    static func encodeCounts(_ counts: InlineArray<16, UInt64>, into output: inout OutputSpan<UInt8>) {
        for index in counts.indices {
            output.appendBigEndian(counts[index])
        }
    }
}
