import XitDB

// Hashers of the tests' own, for sizes and behaviours that SHA-1 and SHA-256
// do not have.

/// A hash of the tests' own with a size no hash in use has. Byte `index` of
/// the digest is the key's length, the sum of its bytes and the index,
/// mixed, so that two keys and two positions seldom agree.
func appendMixed(_ bytes: Span<UInt8>, count: Int, to output: inout OutputSpan<UInt8>) {
    var sum = UInt64(bytes.count)
    for index in bytes.indices {
        sum = sum &* 31 &+ UInt64(bytes[index])
    }
    // The shift binds tighter than the product: without the parentheses
    // every byte came from the sum's low byte alone, and keys collided.
    for index in 0..<count {
        output.append(UInt8(truncatingIfNeeded: ((sum &+ UInt64(index)) &* 0x9E37_79B9_7F4A_7C15) >> 56))
    }
}

/// The same hash as an array, for a test that says what a hasher should
/// have given.
func mixedDigest(_ bytes: [UInt8], count: Int) -> [UInt8] {
    [UInt8](capacity: count) { output in appendMixed(bytes.span, count: count, to: &output) }
}

/// Two bytes: the smallest hash the fuzzer's samples use.
enum TinyHash: KeyHashing {
    static let size = 2
    static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
        appendMixed(bytes, count: size, to: &output)
    }
}

/// Sixty-five bytes: one more than a key hash keeps inline.
enum WideHash: KeyHashing {
    static let size = 65
    static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
        appendMixed(bytes, count: size, to: &output)
    }
}

/// A size no database can have.
enum ZeroHash: KeyHashing {
    static let size = 0
    static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {}
}

/// A size one more than a header can record.
enum OversizedHash: KeyHashing {
    static let size = 65536
    static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {}
}

/// A hasher that does not keep its word: twenty bytes promised, three
/// given.
enum ShortDigestHash: KeyHashing {
    static let size = 20
    static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
        appendMixed(bytes, count: 3, to: &output)
    }
}

/// A hasher that appends more than it promised: two bytes promised, three
/// given, which the engine finds when the hasher returns.
enum GreedyHash: KeyHashing {
    static let size = 2
    static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
        appendMixed(bytes, count: 3, to: &output)
    }
}

/// The same past the hashes the engine keeps inline: sixty-five bytes
/// promised, sixty-six given, of which the last does not fit.
enum GreedyWideHash: KeyHashing {
    static let size = 65
    static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
        appendMixed(bytes, count: 66, to: &output)
    }
}

/// A hasher of a hash longer than the engine keeps inline that does not
/// keep its word: sixty-five bytes promised, three given.
enum ShortWideHash: KeyHashing {
    static let size = 65
    static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
        appendMixed(bytes, count: 3, to: &output)
    }
}
