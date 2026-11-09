// Keys as values: what a key is as bytes, which the store hashes for a hash
// map and stores as it is in a sorted collection.

public import XitDB

/// A key as the bytes the store hashes or sorts by.
///
/// A hash map stores an entry by the hash of these bytes; a sorted map or
/// set stores the bytes themselves and orders entries by them, so two keys
/// compare as their bytes do. `String` is its UTF-8; the integers are
/// big-endian, the signed ones with the sign bit flipped, so that their
/// bytes order as their values do and name the same key on every machine;
/// `[UInt8]` and `Bytes` are themselves. A type of your own gives
/// its bytes; a composite key is a struct whose bytes are its parts with a
/// separator or a length in front, since the store invents no encoding for
/// tuples. An enum with a raw value of one of these types conforms by
/// declaring the conformance, through the raw value. The key comes back
/// from its bytes through ``init(keyBytes:)``, which is nil for bytes that
/// are no value of the type, such as the wrong number of them.
public protocol KeyRepresentable {
    /// The bytes that stand for the key.
    var keyBytes: [UInt8] { get }

    /// The key the bytes stand for, or nil if they stand for none.
    init?(keyBytes: [UInt8])
}

extension String: KeyRepresentable {
    /// The UTF-8 bytes.
    public var keyBytes: [UInt8] { Array(utf8) }

    /// The string the bytes spell in UTF-8, or nil if they are not valid
    /// UTF-8.
    public init?(keyBytes: [UInt8]) {
        self.init(validating: keyBytes, as: UTF8.self)
    }
}

extension Substring: KeyRepresentable {
    /// The UTF-8 bytes.
    public var keyBytes: [UInt8] { Array(utf8) }

    /// The string the bytes spell in UTF-8, or nil if they are not valid
    /// UTF-8.
    public init?(keyBytes: [UInt8]) {
        guard let string = String(validating: keyBytes, as: UTF8.self) else { return nil }
        self = Substring(string)
    }
}

extension [UInt8]: KeyRepresentable {
    /// The array itself.
    public var keyBytes: [UInt8] { self }

    /// The bytes themselves.
    public init?(keyBytes: [UInt8]) {
        self = keyBytes
    }
}

extension Bytes: KeyRepresentable {
    /// The value's bytes; the format tag is not part of the key.
    public var keyBytes: [UInt8] { value }

    /// The bytes, without a format tag.
    public init?(keyBytes: [UInt8]) {
        self.init(keyBytes)
    }
}

extension RawRepresentable where RawValue: KeyRepresentable {
    /// The raw value's bytes.
    public var keyBytes: [UInt8] { rawValue.keyBytes }

    /// The case whose raw value the bytes stand for, or nil if there is
    /// none.
    public init?(keyBytes: [UInt8]) {
        guard let raw = RawValue(keyBytes: keyBytes) else { return nil }
        self.init(rawValue: raw)
    }
}

/// The big-endian bytes of an unsigned integer.
private func bigEndianBytes<Value: FixedWidthInteger & UnsignedInteger>(_ value: Value) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: Value.bitWidth / 8)
    var remaining = value
    for index in stride(from: bytes.count - 1, through: 0, by: -1) {
        bytes[index] = UInt8(truncatingIfNeeded: remaining)
        remaining >>= 8
    }
    return bytes
}

/// The unsigned integer whose big-endian bytes these are, or nil if there
/// are not exactly as many as the type has.
private func unsignedValue<Value: FixedWidthInteger & UnsignedInteger>(_ bytes: [UInt8], as type: Value.Type) -> Value?
{
    guard bytes.count == Value.bitWidth / 8 else { return nil }
    var value: Value = 0
    for byte in bytes {
        value = value << 8 | Value(byte)
    }
    return value
}

/// The big-endian bytes of a signed integer with its sign bit flipped: the
/// most negative value becomes all zeros and the most positive all ones, so
/// the bytes order as the values do.
private func orderedBytes<Value: FixedWidthInteger & SignedInteger>(_ value: Value) -> [UInt8] {
    bigEndianBytes(Value.Magnitude(truncatingIfNeeded: value) ^ (Value.Magnitude(1) << (Value.bitWidth - 1)))
}

/// The signed integer whose ordered bytes these are, or nil if there are
/// not exactly as many as the type has.
private func signedValue<Value: FixedWidthInteger & SignedInteger>(_ bytes: [UInt8], as type: Value.Type) -> Value? {
    guard let magnitude = unsignedValue(bytes, as: Value.Magnitude.self) else { return nil }
    return Value(truncatingIfNeeded: magnitude ^ (Value.Magnitude(1) << (Value.bitWidth - 1)))
}

extension UInt8: KeyRepresentable {
    /// The byte.
    public var keyBytes: [UInt8] { [self] }

    /// The integer whose big-endian bytes these are, or nil if there are
    /// not exactly 1.
    public init?(keyBytes: [UInt8]) {
        guard let value = unsignedValue(keyBytes, as: UInt8.self) else { return nil }
        self = value
    }
}

extension UInt16: KeyRepresentable {
    /// Two bytes, big-endian.
    public var keyBytes: [UInt8] { bigEndianBytes(self) }

    /// The integer whose big-endian bytes these are, or nil if there are
    /// not exactly 2.
    public init?(keyBytes: [UInt8]) {
        guard let value = unsignedValue(keyBytes, as: UInt16.self) else { return nil }
        self = value
    }
}

extension UInt32: KeyRepresentable {
    /// Four bytes, big-endian.
    public var keyBytes: [UInt8] { bigEndianBytes(self) }

    /// The integer whose big-endian bytes these are, or nil if there are
    /// not exactly 4.
    public init?(keyBytes: [UInt8]) {
        guard let value = unsignedValue(keyBytes, as: UInt32.self) else { return nil }
        self = value
    }
}

extension UInt64: KeyRepresentable {
    /// Eight bytes, big-endian.
    public var keyBytes: [UInt8] { bigEndianBytes(self) }

    /// The integer whose big-endian bytes these are, or nil if there are
    /// not exactly 8.
    public init?(keyBytes: [UInt8]) {
        guard let value = unsignedValue(keyBytes, as: UInt64.self) else { return nil }
        self = value
    }
}

extension UInt: KeyRepresentable {
    /// Eight bytes, big-endian, whatever the machine's word size.
    public var keyBytes: [UInt8] { bigEndianBytes(UInt64(self)) }

    /// The integer whose eight big-endian bytes these are, or nil for any
    /// other count or a value the machine's word cannot hold.
    public init?(keyBytes: [UInt8]) {
        guard let value = unsignedValue(keyBytes, as: UInt64.self), let narrowed = UInt(exactly: value) else {
            return nil
        }
        self = narrowed
    }
}

extension Int8: KeyRepresentable {
    /// The byte with its sign bit flipped.
    public var keyBytes: [UInt8] { orderedBytes(self) }

    /// The integer whose ordered bytes these are, or nil if there are not
    /// exactly 1.
    public init?(keyBytes: [UInt8]) {
        guard let value = signedValue(keyBytes, as: Int8.self) else { return nil }
        self = value
    }
}

extension Int16: KeyRepresentable {
    /// Two bytes, big-endian, the sign bit flipped.
    public var keyBytes: [UInt8] { orderedBytes(self) }

    /// The integer whose ordered bytes these are, or nil if there are not
    /// exactly 2.
    public init?(keyBytes: [UInt8]) {
        guard let value = signedValue(keyBytes, as: Int16.self) else { return nil }
        self = value
    }
}

extension Int32: KeyRepresentable {
    /// Four bytes, big-endian, the sign bit flipped.
    public var keyBytes: [UInt8] { orderedBytes(self) }

    /// The integer whose ordered bytes these are, or nil if there are not
    /// exactly 4.
    public init?(keyBytes: [UInt8]) {
        guard let value = signedValue(keyBytes, as: Int32.self) else { return nil }
        self = value
    }
}

extension Int64: KeyRepresentable {
    /// Eight bytes, big-endian, the sign bit flipped.
    public var keyBytes: [UInt8] { orderedBytes(self) }

    /// The integer whose ordered bytes these are, or nil if there are not
    /// exactly 8.
    public init?(keyBytes: [UInt8]) {
        guard let value = signedValue(keyBytes, as: Int64.self) else { return nil }
        self = value
    }
}

extension Int: KeyRepresentable {
    /// Eight bytes, big-endian, the sign bit flipped, whatever the
    /// machine's word size.
    public var keyBytes: [UInt8] { orderedBytes(Int64(self)) }

    /// The integer whose eight ordered bytes these are, or nil for any other
    /// count or a value the machine's word cannot hold.
    public init?(keyBytes: [UInt8]) {
        guard let value = signedValue(keyBytes, as: Int64.self), let narrowed = Int(exactly: value) else { return nil }
        self = narrowed
    }
}
