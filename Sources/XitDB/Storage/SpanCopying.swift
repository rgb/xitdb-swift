// The standard library has no bulk copy between spans yet, and copying a byte
// at a time through their subscripts is too slow for the storage layer, which
// moves blocks of up to a few megabytes.

extension MutableSpan where Element == UInt8 {
    /// Copies `count` bytes of `source`, starting at `sourceOffset`, to this
    /// span at `offset`.
    ///
    /// - Precondition: Both ranges lie within their spans.
    mutating func copyBytes(from source: Span<UInt8>, at sourceOffset: Int = 0, count: Int, to offset: Int = 0) {
        precondition(count >= 0 && sourceOffset >= 0 && offset >= 0, "negative range")
        precondition(count <= source.count - sourceOffset, "the source range is out of bounds")
        precondition(count <= self.count - offset, "the destination range is out of bounds")
        guard count > 0 else { return }
        // Safe: both ranges were checked against their spans above, and the
        // spans cannot overlap because this one is held exclusively.
        withUnsafeMutableBytes { destination in
            source.withUnsafeBytes { bytes in
                let target = unsafe UnsafeMutableRawBufferPointer(rebasing: destination[offset..<(offset + count)])
                let origin = unsafe UnsafeRawBufferPointer(rebasing: bytes[sourceOffset..<(sourceOffset + count)])
                unsafe target.copyMemory(from: origin)
            }
        }
    }
}

extension Array where Element == UInt8 {
    /// Appends the bytes of `source` in one copy.
    mutating func append(bytesOf source: Span<UInt8>) {
        // Safe: the pointer is only read from, inside the call that provides
        // it, and the array being appended to cannot be the span's storage,
        // because it is held exclusively here.
        source.withUnsafeBytes { bytes in
            unsafe append(contentsOf: bytes)
        }
    }
}
