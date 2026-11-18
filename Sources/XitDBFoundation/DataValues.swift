public import Foundation
public import XitDB

/// `Data` as a value: written as the format's byte array without a format
/// tag, exactly what `[UInt8]` of the same bytes writes, and read from any
/// byte array.
///
/// What was written as `Data` reads back as `[UInt8]`, as `Bytes` or as a
/// `String` if it is one, and the reverse, in this library and in any
/// other: the file does not say which type wrote it. A `Data` costs one
/// copy more than a `[UInt8]` in each direction, into an array to be
/// written and out of one when it is read.
extension Data: StorableValue {
    /// The byte array at the cursor, whatever its format tag. A slot set
    /// to nothing reads as empty data.
    ///
    /// - Throws: `unexpectedTag` if the slot holds a number or a
    ///   collection.
    public init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        self.init(try cursor.readBytes())
    }

    /// Writes the data's bytes as a byte array without a format tag. A
    /// slice writes its own bytes, wherever it starts.
    public func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.bytes(Array(self)))
    }
}

/// `Data` as a key: its bytes, so that it is the same key as the `[UInt8]`
/// of the same bytes, hashed and, where a key is stored, stored alike.
extension Data: KeyRepresentable {
    /// The data's bytes. A slice gives its own, wherever it starts.
    public var keyBytes: [UInt8] {
        Array(self)
    }
}
