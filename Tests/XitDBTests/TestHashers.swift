import XitDB

// Hashers of the tests' own, for sizes and behaviours that SHA-1 and SHA-256
// do not have.

/// A hash of the tests' own with a size no hash in use has. Byte `index` of
/// the digest is the key's length, the sum of its bytes and the index,
/// mixed, so that two keys and two positions seldom agree.
func mixedDigest(_ bytes: some Collection<UInt8>, count: Int) -> [UInt8] {
    var sum: UInt64 = UInt64(bytes.count)
    for byte in bytes {
        sum = sum &* 31 &+ UInt64(byte)
    }
    // The shift binds tighter than the product: without the parentheses
    // every byte came from the sum's low byte alone, and keys collided.
    return (0..<count).map { UInt8(truncatingIfNeeded: ((sum &+ UInt64($0)) &* 0x9E37_79B9_7F4A_7C15) >> 56) }
}

/// Two bytes: the smallest hash the fuzzer's samples use.
enum TinyHash: KeyHashing {
    static let size = 2
    static func hash(_ bytes: some Collection<UInt8>) -> [UInt8] { mixedDigest(bytes, count: size) }
}

/// Sixty-five bytes: one more than a key hash keeps inline.
enum WideHash: KeyHashing {
    static let size = 65
    static func hash(_ bytes: some Collection<UInt8>) -> [UInt8] { mixedDigest(bytes, count: size) }
}

/// A size no database can have.
enum ZeroHash: KeyHashing {
    static let size = 0
    static func hash(_ bytes: some Collection<UInt8>) -> [UInt8] { [] }
}

/// A size one more than a header can record.
enum OversizedHash: KeyHashing {
    static let size = 65536
    static func hash(_ bytes: some Collection<UInt8>) -> [UInt8] { [] }
}

/// A hasher that does not keep its word: twenty bytes promised, three
/// given.
enum ShortDigestHash: KeyHashing {
    static let size = 20
    static func hash(_ bytes: some Collection<UInt8>) -> [UInt8] { mixedDigest(bytes, count: 3) }
}
