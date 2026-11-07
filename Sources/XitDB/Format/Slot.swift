/// The nine-byte cell that every value in a database lives behind.
///
/// A slot holds either a small value directly or the offset of a larger
/// record elsewhere in the file. ``tag`` says which, and how to read
/// ``value``.
///
/// A client reads slots and writes them back, through ``WritableData/slot(_:)``,
/// to share what a slot points at; it does not make them, so that a slot
/// written is always one the same database gave.
public struct Slot: Hashable, Sendable {
    /// The value itself, or the file offset of the record that holds it,
    /// depending on ``tag``.
    ///
    /// For ``Tag/int`` and ``Tag/float`` this is the bit pattern of the
    /// number. For ``Tag/shortBytes`` the bytes are stored from the most
    /// significant byte down and padded with zeros.
    public internal(set) var value: UInt64

    /// The kind of value this slot holds.
    public internal(set) var tag: Tag

    /// A flag whose meaning depends on ``tag``.
    ///
    /// - With ``Tag/none``, it marks the slot as in use. This distinguishes a
    ///   slot that was explicitly set to nothing from one that was never
    ///   written; see ``isEmpty``.
    /// - With ``Tag/bytes`` or ``Tag/shortBytes``, it says that a two-byte
    ///   format tag is stored with the bytes.
    ///
    /// It has no meaning with any other tag.
    public internal(set) var full: Bool

    /// Creates a slot.
    ///
    /// With no arguments this is the empty slot, the one whose nine bytes on
    /// disk are all zero.
    ///
    /// - Parameters:
    ///   - value: The value, or the offset of the record that holds it.
    ///   - tag: The kind of value.
    ///   - full: The flag described at ``full``.
    init(value: UInt64 = 0, tag: Tag = .none, full: Bool = false) {
        self.value = value
        self.tag = tag
        self.full = full
    }

    /// Whether the slot has never been written.
    ///
    /// A slot set explicitly to nothing has the tag ``Tag/none`` too, but its
    /// ``full`` flag is set, so it is not empty.
    public var isEmpty: Bool {
        tag == .none && !full
    }
}

extension Slot {
    /// The size of a slot on disk.
    static let byteCount: UInt64 = 9

    /// Decodes the slot that starts at `offset`.
    ///
    /// - Throws: `endOfStream` if fewer than nine bytes are available, or
    ///   `invalidEnumTag` if the tag bits are not a known tag.
    init(decoding bytes: Span<UInt8>, at offset: Int = 0) throws(XitDBError) {
        try bytes.requireBytes(9, at: offset)
        let first = bytes[offset]
        self.tag = try Tag(validating: first & 0x7F)
        self.full = first & 0x80 != 0
        self.value = bytes.bigEndian(UInt64.self, at: offset + 1)
    }

    /// Appends the slot's nine bytes.
    func encode(into output: inout OutputSpan<UInt8>) {
        output.append(tag.rawValue | (full ? 0x80 : 0))
        output.appendBigEndian(value)
    }

    /// Stores the slot's nine bytes at `offset`.
    ///
    /// - Precondition: Nine bytes lie within the span at `offset`.
    func encode(into bytes: inout MutableSpan<UInt8>, at offset: Int) {
        bytes[offset] = tag.rawValue | (full ? 0x80 : 0)
        bytes.storeBigEndian(value, at: offset + 1)
    }
}

/// A slot together with where it is stored.
///
/// The position is `nil` for a slot that cannot be written back, such as the
/// key of a sorted entry.
struct SlotPointer: Sendable, Equatable {
    var position: UInt64?
    var slot: Slot
}
