/// The hash of a key, as bytes in the order they are stored in the file.
///
/// A database's hash size is only known at run time, so a hash cannot be a
/// fixed-size value as it is in Zig. This one keeps up to sixty-four bytes
/// inline, which covers every hash in common use, so that looking up a key
/// allocates nothing. A longer hash is kept in an array.
package struct KeyHash: Sendable {
    /// The longest hash kept inline.
    static let inlineCapacity = 64

    private var inline: InlineArray<64, UInt8>
    /// Only a hash longer than the inline capacity has one, so that copying
    /// the common kind touches no reference count.
    private var overflow: [UInt8]?

    /// The number of bytes in the hash.
    package let count: Int

    /// Creates a hash from its bytes.
    package init(_ bytes: Span<UInt8>) {
        count = bytes.count
        inline = InlineArray(repeating: 0)
        if count <= Self.inlineCapacity {
            overflow = nil
            for index in bytes.indices {
                inline[index] = bytes[index]
            }
        } else {
            var copy: [UInt8] = []
            copy.reserveCapacity(count)
            for index in bytes.indices {
                copy.append(bytes[index])
            }
            overflow = copy
        }
    }

    /// Creates a hash from its bytes.
    package init(_ bytes: [UInt8]) {
        self.init(bytes.span)
    }

    /// A hash of `count` zero bytes, which allocates nothing: what a pair
    /// that has no hash, a sorted map's or a key-only entry, reports.
    init(zeros count: Int) {
        self.count = count
        inline = InlineArray(repeating: 0)
        overflow = count <= Self.inlineCapacity ? nil : [UInt8](repeating: 0, count: count)
    }

    /// Calls `body` with the hash's bytes.
    func withBytes<Result, Failure: Error>(
        _ body: (Span<UInt8>) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        if let overflow {
            return try body(overflow.span)
        }
        return try body(inline.span.extracting(0..<count))
    }

    /// Copies the hash's bytes to the start of `target`.
    ///
    /// - Precondition: `target` holds at least `count` bytes.
    func copyBytes(into target: inout MutableSpan<UInt8>) {
        if let overflow {
            target.copyBytes(from: overflow.span, count: count)
        } else {
            target.copyBytes(from: inline.span, count: count)
        }
    }

    /// The slot this hash selects at a level of a hash trie.
    ///
    /// - Throws: `keyOffsetExceeded` if the hash has no bits left for
    ///   `level`.
    func index(atLevel level: Int) throws(XitDBError) -> Int {
        try withBytes { (bytes: Span<UInt8>) throws(XitDBError) in
            try Trie.index(ofHash: bytes, level: level)
        }
    }

    /// The hash's bytes as an array.
    var bytes: [UInt8] {
        withBytes { (bytes: Span<UInt8>) in
            var result: [UInt8] = []
            result.reserveCapacity(bytes.count)
            for index in bytes.indices {
                result.append(bytes[index])
            }
            return result
        }
    }
}

extension KeyHash: Equatable {
    package static func == (left: KeyHash, right: KeyHash) -> Bool {
        guard left.count == right.count else { return false }
        return left.withBytes { (leftBytes: Span<UInt8>) in
            right.withBytes { (rightBytes: Span<UInt8>) in
                for index in leftBytes.indices where leftBytes[index] != rightBytes[index] {
                    return false
                }
                return true
            }
        }
    }
}
