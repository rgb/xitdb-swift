/// A key of a sorted map or set: bytes, compared as unsigned bytes in
/// lexicographic order, a shorter key before a longer one it is a prefix
/// of.
///
/// Like ``KeyHash``, it keeps up to sixty-four bytes inline, so that a path
/// part can carry a key and a lookup allocates nothing for keys of the
/// common sizes. A longer key is kept in an array.
package struct SortedKey: Sendable {
    /// The longest key kept inline.
    static let inlineCapacity = 64

    private var inline: InlineArray<64, UInt8>
    private var overflow: [UInt8]

    /// The number of bytes in the key.
    package let count: Int

    /// Creates a key from its bytes.
    package init(_ bytes: Span<UInt8>) {
        count = bytes.count
        inline = InlineArray(repeating: 0)
        overflow = []
        if count <= Self.inlineCapacity {
            for index in bytes.indices {
                inline[index] = bytes[index]
            }
        } else {
            overflow.reserveCapacity(count)
            for index in bytes.indices {
                overflow.append(bytes[index])
            }
        }
    }

    /// Creates a key from its bytes.
    package init(_ bytes: [UInt8]) {
        self.init(bytes.span)
    }

    /// Calls `body` with the key's bytes.
    func withBytes<Result, Failure: Error>(
        _ body: (Span<UInt8>) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        if count <= Self.inlineCapacity {
            return try body(inline.span.extracting(0..<count))
        }
        return try body(overflow.span)
    }

    /// The key's bytes as an array.
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

/// How two keys compare.
enum KeyOrder {
    case less
    case equal
    case greater
}
