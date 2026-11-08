// The hex the vectors are written in, as bytes.

/// The bytes that `hex` spells, two lowercase or uppercase characters each.
/// A test's vectors are well formed, so a bad string is a test bug and traps.
func bytes(fromHex hex: String) -> [UInt8] {
    let digits = Array(hex.utf8)
    precondition(digits.count % 2 == 0, "hex has an odd number of characters")
    var bytes: [UInt8] = []
    bytes.reserveCapacity(digits.count / 2)
    for index in stride(from: 0, to: digits.count, by: 2) {
        let pair = String(decoding: digits[index..<index + 2], as: UTF8.self)
        guard let byte = UInt8(pair, radix: 16) else { preconditionFailure("not hex: \(pair)") }
        bytes.append(byte)
    }
    return bytes
}

/// The test pattern that the lengths around the block boundaries are cut
/// from: `count` bytes of a linear congruential generator from a fixed
/// seed, the same on every run and platform.
func pattern(count: Int) -> [UInt8] {
    var state: UInt64 = 0x9e37_79b9_7f4a_7c15
    var bytes: [UInt8] = []
    bytes.reserveCapacity(count)
    for _ in 0..<count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        bytes.append(UInt8(truncatingIfNeeded: state >> 56))
    }
    return bytes
}

/// The lengths at which the padding changes shape: one byte each side of
/// where the length no longer fits in the first block (55, 56), of a block
/// boundary (63, 64, 65), and of the same in the second block (119, 120).
let boundaryLengths = [55, 56, 63, 64, 65, 119, 120]
