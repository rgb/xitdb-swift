// The hex the vectors are written in, as bytes, and the messages the tests
// hash.

import XitDB
import XitDBHashing

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
/// boundary (63, 64, 65), and of the same in the second block (119, 120,
/// 127, 128).
let boundaryLengths = [55, 56, 63, 64, 65, 119, 120, 127, 128]

/// A message of `count` bytes that depends on its length and on a seed:
/// bytes of the same generator as the pattern's, the same on every run and
/// platform. `scripts/pin-digests.py` makes the same bytes.
func seededMessage(count: Int, seed: UInt64) -> [UInt8] {
    var state = seed &* 0x9e37_79b9_7f4a_7c15 &+ UInt64(count)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(count)
    for _ in 0..<count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        bytes.append(UInt8(truncatingIfNeeded: state >> 33))
    }
    return bytes
}

/// The seeded messages that are hashed beyond the pattern, as their
/// lengths and seeds: three thousand, up to 64 KB long, most of them under
/// a kilobyte so that a run without optimisation stays quick.
let seededMessages: [(length: Int, seed: UInt64)] = {
    var state: UInt64 = 42
    return (0..<3000).map { round in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let bound: UInt64 = round % 50 == 0 ? 65_537 : (round % 5 == 0 ? 8_193 : 1_025)
        return (Int((state >> 40) % bound), UInt64(round))
    }
}()

/// The portable code's SHA-256 of `message`, as bytes.
func appendedSHA256(_ message: [UInt8]) -> [UInt8] {
    Array(capacity: PortableSHA256.byteCount) { output in PortableSHA256.hash(message.span, into: &output) }
}

/// The portable code's SHA-1 of `message`, as bytes.
func appendedSHA1(_ message: [UInt8]) -> [UInt8] {
    Array(capacity: PortableSHA1.byteCount) { output in PortableSHA1.hash(message.span, into: &output) }
}

/// The SHA-256 of `message` by one of the module's ways of computing it,
/// as bytes.
func sha256(_ message: [UInt8], by path: HashPath) -> [UInt8] {
    Array(capacity: 32) { output in path.sha256(message.span, &output) }
}

/// The SHA-1 of `message` by one of the module's ways of computing it, as
/// bytes.
func sha1(_ message: [UInt8], by path: HashPath) -> [UInt8] {
    Array(capacity: 20) { output in path.sha1(message.span, &output) }
}

/// The hash of `message` by a hasher's requirement, the call a database
/// makes, as bytes.
func required<Hashing: KeyHashing>(_ hashing: Hashing.Type, _ message: [UInt8]) -> [UInt8] {
    Array(capacity: Hashing.size) { output in Hashing.hash(message.span, into: &output) }
}

/// Bytes as lowercase hex, two characters each: how the vectors are written.
func hex(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var characters: [UInt8] = []
    for byte in bytes {
        characters.append(digits[Int(byte >> 4)])
        characters.append(digits[Int(byte & 0x0F)])
    }
    return String(decoding: characters, as: UTF8.self)
}
