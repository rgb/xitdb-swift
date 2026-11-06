/// A byte array with an optional format tag.
///
/// A format tag is two bytes stored with a byte array. They mean nothing to
/// XitDB. They are there for whoever reads the bytes to tell how to
/// interpret them: a number too large for sixty-four bits could be stored as
/// bytes with the tag `"bi"`, for example.
public struct Bytes: Sendable {
    /// The bytes.
    public var value: [UInt8]

    /// The format tag, or `nil` for none.
    public var formatTag: InlineArray<2, UInt8>?

    /// Creates a byte array.
    ///
    /// - Parameters:
    ///   - value: The bytes.
    ///   - formatTag: A format tag to store with them, or `nil` for none.
    public init(_ value: [UInt8], formatTag: InlineArray<2, UInt8>? = nil) {
        self.value = value
        self.formatTag = formatTag
    }

    /// Whether the value is stored inside its slot, without a record of its
    /// own.
    ///
    /// It is when it has no zero byte and at most eight bytes, or at most
    /// six with a format tag.
    public var isShort: Bool {
        ByteArrayFormat.isShort(value.span, hasFormatTag: formatTag != nil)
    }
}

extension Bytes: Equatable {
    /// Whether two byte arrays have the same bytes and the same format tag,
    /// or both have none.
    public static func == (left: Bytes, right: Bytes) -> Bool {
        guard left.value == right.value else { return false }
        switch (left.formatTag, right.formatTag) {
        case (nil, nil): return true
        case (let leftTag?, let rightTag?): return leftTag[0] == rightTag[0] && leftTag[1] == rightTag[1]
        default: return false
        }
    }
}

/// A value that can be written to a slot.
public enum WriteableData: Sendable {
    /// A slot, written as it is, or `nil` to clear the slot.
    ///
    /// Writing a slot that points at a collection or a byte array does not
    /// copy what it points at. Both slots then share it, which is how one
    /// moment of a database is cloned into the next.
    ///
    /// A cleared slot is not empty: it is marked as holding nothing, which
    /// ``Slot/isEmpty`` tells apart from never having been written.
    case slot(Slot?)

    /// An unsigned integer.
    case uint(UInt64)

    /// A signed integer.
    case int(Int64)

    /// A floating-point number, stored bit for bit.
    case float(Double)

    /// A byte array.
    case bytes([UInt8])

    /// A byte array with an optional format tag.
    case bytesObject(Bytes)
}
