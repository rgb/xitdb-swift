/// The record an `arrayList` slot points at.
struct ArrayListHeader: Sendable, Equatable {
    /// The number of elements.
    var size: UInt64

    /// The offset of the root index block.
    var ptr: UInt64

    /// The size of the header on disk.
    static let byteCount: UInt64 = 16

    init(size: UInt64, ptr: UInt64) {
        self.size = size
        self.ptr = ptr
    }

    /// Decodes the header that starts at `offset`.
    ///
    /// - Throws: `endOfStream` if fewer than sixteen bytes are available.
    init(decoding bytes: Span<UInt8>, at offset: Int = 0) throws(XitDBError) {
        try bytes.requireBytes(16, at: offset)
        self.size = bytes.bigEndian(at: offset)
        self.ptr = bytes.bigEndian(at: offset + 8)
    }

    /// Appends the header's sixteen bytes.
    func encode(into output: inout OutputSpan<UInt8>) {
        output.appendBigEndian(size)
        output.appendBigEndian(ptr)
    }
}

/// The record a `linkedArrayList`, `sortedMap` or `sortedSet` slot points at.
struct BTreeHeader: Sendable, Equatable {
    /// The number of elements.
    var size: UInt64

    /// The offset of the root node.
    var rootPtr: UInt64

    /// The size of the header on disk.
    static let byteCount: UInt64 = 16

    init(size: UInt64, rootPtr: UInt64) {
        self.size = size
        self.rootPtr = rootPtr
    }

    /// Decodes the header that starts at `offset`.
    ///
    /// - Throws: `endOfStream` if fewer than sixteen bytes are available.
    init(decoding bytes: Span<UInt8>, at offset: Int = 0) throws(XitDBError) {
        try bytes.requireBytes(16, at: offset)
        self.size = bytes.bigEndian(at: offset)
        self.rootPtr = bytes.bigEndian(at: offset + 8)
    }

    /// Appends the header's sixteen bytes.
    func encode(into output: inout OutputSpan<UInt8>) {
        output.appendBigEndian(size)
        output.appendBigEndian(rootPtr)
    }
}
