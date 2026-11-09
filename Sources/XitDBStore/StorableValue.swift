// Values as types: how a value is written to a slot and read back from it.

public import XitDB

/// A value the store writes to a place and reads back from it.
///
/// The format has scalars (unsigned and signed integers, doubles), byte
/// arrays, and collections; a conformer says which of the scalars or byte
/// arrays it is written as. `UInt64`, `Int64` and `Double` are the scalars,
/// `String` is its UTF-8 as a byte array, `[UInt8]` a byte array as it is,
/// `Bool` an unsigned integer 0 or 1 (and reads back as `true` from any
/// non-zero one), and an optional writes nothing for `nil`. The store's
/// collections are not values: a collection inside a collection is reached
/// through a ``Handle``, by `handleFor:` on a map or `handleAt:` on a
/// list. Reading a value from a place that holds another kind throws
/// `XitDBError.unexpectedTag`.
public protocol StorableValue {
    /// Reads the value at the cursor.
    init(reading cursor: Cursor<ReadOnly>) throws(XitDBError)

    /// Writes the value at the cursor, replacing what was there.
    func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError)
}

extension UInt64: StorableValue {
    /// The unsigned integer at the cursor.
    public init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        self = try cursor.readUInt64()
    }

    /// An unsigned integer.
    public func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.uint(self))
    }
}

extension Int64: StorableValue {
    /// The signed integer at the cursor.
    public init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        self = try cursor.readInt64()
    }

    /// A signed integer.
    public func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.int(self))
    }
}

extension Double: StorableValue {
    /// The double at the cursor.
    public init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        self = try cursor.readDouble()
    }

    /// A double, bit for bit.
    public func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.double(self))
    }
}

extension Bool: StorableValue {
    /// `true` for any unsigned integer but zero.
    public init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        self = try cursor.readUInt64() != 0
    }

    /// An unsigned integer, 1 or 0.
    public func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.uint(self ? 1 : 0))
    }
}

extension String: StorableValue {
    /// The bytes decoded as UTF-8; invalid sequences become the replacement
    /// character.
    public init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        self = String(decoding: try cursor.readBytes(), as: UTF8.self)
    }

    /// The UTF-8 bytes, as a byte array without a format tag.
    public func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.bytes(Array(utf8)))
    }
}

extension [UInt8]: StorableValue {
    /// The byte array at the cursor, whatever its format tag.
    public init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        self = try cursor.readBytes()
    }

    /// A byte array without a format tag.
    public func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.bytes(self))
    }
}

extension Optional: StorableValue where Wrapped: StorableValue {
    /// `nil` where the place holds nothing, the wrapped value otherwise.
    public init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        if try cursor.slot.tag == .none {
            self = nil
        } else {
            self = try Wrapped(reading: cursor)
        }
    }

    /// Nothing for `nil`: the place is set to hold nothing.
    public func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        switch self {
        case nil: try cursor.write(.slot(nil))
        case let value?: try value.write(to: &cursor)
        }
    }
}
