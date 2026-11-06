/// The kind of value a ``Slot`` holds.
///
/// The raw values are part of the file format. They are stored in the low
/// seven bits of a slot's first byte, and reordering them would break every
/// existing file.
public enum Tag: UInt8, Sendable {
    /// No value. See ``Slot/full`` for how an unused slot differs from one
    /// that was explicitly set to nothing.
    case none = 0

    /// The offset of an index block or a tree node.
    case index = 1

    /// The offset of an array list.
    case arrayList = 2

    /// The offset of a linked array list.
    case linkedArrayList = 3

    /// The offset of a hash map.
    case hashMap = 4

    /// The offset of a key-value pair that belongs to a hash map or set.
    case kvPair = 5

    /// The offset of a byte array.
    case bytes = 6

    /// A byte array short enough to be stored in the slot itself.
    case shortBytes = 7

    /// An unsigned 64-bit integer, stored in the slot.
    case uint = 8

    /// A signed 64-bit integer, stored in the slot as its bit pattern.
    case int = 9

    /// A 64-bit floating-point number, stored in the slot as its bit pattern.
    case float = 10

    /// The offset of a hash set.
    case hashSet = 11

    /// The offset of a hash map that keeps a count of its entries.
    case countedHashMap = 12

    /// The offset of a hash set that keeps a count of its entries.
    case countedHashSet = 13

    /// The offset of a sorted map.
    case sortedMap = 14

    /// The offset of a sorted set.
    case sortedSet = 15

    /// The offset of a key-value pair that belongs to a sorted map.
    case sortedKvPair = 16
}

extension Tag {
    /// Creates a tag from the seven tag bits of a slot's first byte.
    ///
    /// Zig bit-casts any seven bits into a `Tag` and calls `validate` on it
    /// afterwards. A Swift enum cannot hold an unknown value, so validation
    /// happens here, where the bits become a `Tag`.
    ///
    /// - Throws: `invalidEnumTag` if `rawValue` is not a known tag.
    init(validating rawValue: UInt8) throws(XitDBError) {
        guard let tag = Tag(rawValue: rawValue) else { throw .invalidEnumTag }
        self = tag
    }
}
