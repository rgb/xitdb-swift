/// Two bytes stored with a byte array that say how to interpret it.
///
/// A format tag means nothing to XitDB; it is there for whoever reads the
/// bytes. A number too large for sixty-four bits could be stored as bytes
/// with the tag `"bi"`, for example. By convention the two bytes are ASCII
/// letters, and a tag can be written as a string literal: `"bi"`.
public struct FormatTag: Hashable, Sendable {
    /// The two bytes, the first in the high byte.
    private let packed: UInt16

    /// Creates a tag from its two bytes, in the order they are stored.
    public init(_ first: UInt8, _ second: UInt8) {
        packed = UInt16(first) << 8 | UInt16(second)
    }

    /// Creates a tag from a string of exactly two bytes in UTF-8, such as
    /// `"bi"`, or `nil` if the string has any other length: for a string
    /// computed at run time.
    ///
    /// A literal needs no init: `"bi"` is a `FormatTag` wherever one is
    /// expected, and so is `FormatTag("bi")`. A literal of any other length
    /// is a programming error and stops the program; this init is the one
    /// that reports a wrong length instead.
    public init?(string: some StringProtocol) {
        var bytes: [UInt8] = []
        for byte in string.utf8 {
            if bytes.count == 2 { return nil }
            bytes.append(byte)
        }
        guard bytes.count == 2 else { return nil }
        self.init(bytes[0], bytes[1])
    }

    /// The two bytes, in the order they are stored.
    public var bytes: InlineArray<2, UInt8> {
        [UInt8(truncatingIfNeeded: packed >> 8), UInt8(truncatingIfNeeded: packed)]
    }

    /// Creates a tag from two bytes read from a file.
    init(bytes: InlineArray<2, UInt8>) {
        self.init(bytes[0], bytes[1])
    }
}

extension FormatTag: ExpressibleByStringLiteral {
    /// Creates a tag from a literal of exactly two bytes in UTF-8.
    ///
    /// - Precondition: The literal is two bytes long. A literal is part of
    ///   the program, not of a file, so a wrong one is a programming error.
    public init(stringLiteral value: String) {
        guard let tag = FormatTag(string: value) else {
            preconditionFailure("a format tag is exactly two bytes, not \"\(value)\"")
        }
        self = tag
    }
}

extension FormatTag: CustomStringConvertible {
    /// The two bytes as text when both are printable ASCII, otherwise as
    /// hexadecimal.
    public var description: String {
        let bytes = self.bytes
        if bytes[0] >= 0x20 && bytes[0] < 0x7F && bytes[1] >= 0x20 && bytes[1] < 0x7F {
            return String(decoding: [bytes[0], bytes[1]], as: UTF8.self)
        }
        return "0x" + String(packed, radix: 16, uppercase: true).leftPadded(to: 4)
    }
}

extension String {
    /// The string padded with zeros on the left to `width` characters.
    fileprivate func leftPadded(to width: Int) -> String {
        String(repeating: "0", count: max(0, width - count)) + self
    }
}

/// A byte array with an optional format tag, as read from a database.
public struct Bytes: Hashable, Sendable {
    /// The bytes.
    public var value: [UInt8]

    /// The format tag, or `nil` for none.
    public var formatTag: FormatTag?

    /// Creates a byte array.
    ///
    /// - Parameters:
    ///   - value: The bytes.
    ///   - formatTag: A format tag stored with them, or `nil` for none.
    public init(_ value: [UInt8], formatTag: FormatTag? = nil) {
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

/// A value that can be written to a slot.
public enum WritableData: Sendable {
    /// A slot, written as it is, or `nil` to clear the slot.
    ///
    /// Writing a slot that points at a collection or a byte array does not
    /// copy what it points at. Both slots then share it, which is how one
    /// moment of a database is cloned into the next. The slot must have
    /// been read from the same database.
    ///
    /// A cleared slot is not empty: it is marked as holding nothing, which
    /// ``Slot/isEmpty`` tells apart from never having been written.
    case slot(Slot?)

    /// An unsigned integer.
    case uint(UInt64)

    /// A signed integer.
    case int(Int64)

    /// A floating-point number, stored bit for bit.
    case double(Double)

    /// A byte array, with a format tag stored alongside if one is given.
    case bytes(_ value: [UInt8], formatTag: FormatTag? = nil)
}
