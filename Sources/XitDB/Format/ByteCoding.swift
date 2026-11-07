// The byte primitives every record codec is built from. All integers in the
// file format are big endian. These go through the bounds-checked span APIs.
// The two `unsafe` calls are the load and the store of a whole integer, each
// behind a bounds check of its own; a byte at a time, the load was a tenth
// of iterating over a hash map.

extension Span where Element == UInt8 {
    /// Throws `endOfStream` unless `count` bytes are available at `offset`.
    ///
    /// This is the port of Zig's `takeInt` failing on a reader that runs out.
    func requireBytes(_ count: Int, at offset: Int) throws(XitDBError) {
        guard offset >= 0, count <= self.count - offset else { throw .endOfStream }
    }

    /// Reads a big-endian integer that starts at `offset`, in one load of
    /// the integer's width.
    ///
    /// The bytes must be present; call ``requireBytes(_:at:)`` first.
    ///
    /// - Precondition: The integer's bytes lie within the span.
    func bigEndian<T: FixedWidthInteger & UnsignedInteger & BitwiseCopyable>(
        _ type: T.Type = T.self,
        at offset: Int
    ) -> T {
        precondition(offset >= 0 && MemoryLayout<T>.size <= count - offset, "the integer is out of bounds")
        // Safe: the range was checked above, and every bit pattern of the
        // bytes is a value of an unsigned integer.
        return T(bigEndian: unsafe bytes.unsafeLoadUnaligned(fromByteOffset: offset, as: T.self))
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
