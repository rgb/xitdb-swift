// The byte primitives every record codec is built from. All integers in the
// file format are big endian. These go through the bounds-checked span APIs.
// The one `unsafe` call is the store of a whole integer, where it stands.

extension Span where Element == UInt8 {
    /// Throws `endOfStream` unless `count` bytes are available at `offset`.
    ///
    /// This is the port of Zig's `takeInt` failing on a reader that runs out.
    func requireBytes(_ count: Int, at offset: Int) throws(XitDBError) {
        guard offset >= 0, count <= self.count - offset else { throw .endOfStream }
    }

    /// Reads a big-endian integer that starts at `offset`.
    ///
    /// The bytes must be present; call ``requireBytes(_:at:)`` first.
    func bigEndian<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type = T.self, at offset: Int) -> T {
        var result: T = 0
        for index in 0..<MemoryLayout<T>.size {
            result = (result << 8) | T(truncatingIfNeeded: self[offset + index])
        }
        return result
    }
}

extension MutableSpan where Element == UInt8 {
    /// Stores an integer in big-endian byte order at `offset`, in one store
    /// of the integer's width.
    ///
    /// - Precondition: The integer's bytes lie within the span.
    mutating func storeBigEndian<T: FixedWidthInteger & UnsignedInteger & BitwiseCopyable>(
        _ value: T,
        at offset: Int
    ) {
        precondition(offset >= 0 && MemoryLayout<T>.size <= count - offset, "the integer is out of bounds")
        var bytes = mutableBytes
        // Safe: the range was checked above, and the bytes of an integer are
        // stored into a span of bytes, for which every bit pattern is a
        // value.
        unsafe bytes.storeBytes(of: value.bigEndian, toByteOffset: offset, as: T.self)
    }
}

extension OutputSpan where Element == UInt8 {
    /// Appends an integer in big-endian byte order.
    mutating func appendBigEndian<T: FixedWidthInteger & UnsignedInteger>(_ value: T) {
        var shift = T.bitWidth
        while shift > 0 {
            shift -= 8
            append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}
