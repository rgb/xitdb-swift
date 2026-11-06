// The byte primitives every record codec is built from. All integers in the
// file format are big endian. These work one byte at a time through the
// bounds-checked span APIs, so nothing here needs `unsafe`.

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
