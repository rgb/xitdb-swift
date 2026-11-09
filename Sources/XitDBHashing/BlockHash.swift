// What the portable SHA-1 and SHA-256 share: the block loop with its
// padding, the words of a block, the bytes a digest is made of and the hex
// they print as. The portable implementations are compiled on every
// platform and tested against CryptoKit where it exists; they stand behind
// the public names only where it does not.

/// The bytes of a digest, with everything a digest type does with them:
/// comparison, hashing, copying out and printing.
package struct DigestStorage<let byteCount: Int>: Equatable, Hashable, Sendable {
    let storage: InlineArray<byteCount, UInt8>

    /// The bytes, `byte(index)` for each index in order.
    init(_ byte: (Int) -> UInt8) {
        storage = InlineArray(byte)
    }

    /// The bytes, copied into a new array.
    package var bytes: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for index in storage.indices {
            bytes[index] = storage[index]
        }
        return bytes
    }

    /// The bytes as lowercase hex, two characters a byte.
    package var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var characters: [UInt8] = []
        characters.reserveCapacity(2 * byteCount)
        for index in storage.indices {
            let byte = storage[index]
            characters.append(digits[Int(byte >> 4)])
            characters.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: characters, as: UTF8.self)
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        for index in lhs.storage.indices where lhs.storage[index] != rhs.storage[index] {
            return false
        }
        return true
    }

    package func hash(into hasher: inout Hasher) {
        for index in storage.indices {
            hasher.combine(storage[index])
        }
    }
}

/// A 64-byte block of the message as the sixteen big-endian 32-bit words
/// the round functions read (FIPS 180-4, section 5.2.1).
typealias BlockWords = InlineArray<16, UInt32>

/// A hash that works through 64-byte blocks, as SHA-1 and SHA-256 do.
///
/// The conformer holds the working state and folds one block into it;
/// ``absorb(_:)`` pads the message and feeds it block by block.
protocol BlockHash {
    /// Folds one block into the state.
    mutating func compress(_ block: BlockWords)
}

extension BlockHash {
    /// Feeds the whole message to ``compress(_:)``, padded as FIPS 180-4,
    /// section 5.1.1 says: a 1 bit, zeros up to 8 bytes short of a block
    /// boundary, and the length in bits as a 64-bit big-endian number.
    ///
    /// The last block is where an implementation goes wrong: a message
    /// with 56 to 63 bytes past its last full block needs two more blocks,
    /// one that ends on a boundary needs one whole block of padding.
    mutating func absorb(_ message: [UInt8]) {
        let fullBlocks = message.count / 64
        for block in 0..<fullBlocks {
            compress(BlockWords { word in bigEndianWord(message, at: block * 64 + word * 4) })
        }
        var tail = Array(message[(fullBlocks * 64)...])
        tail.append(0x80)
        while tail.count % 64 != 56 {
            tail.append(0)
        }
        let bitLength = UInt64(truncatingIfNeeded: message.count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        for block in 0..<(tail.count / 64) {
            compress(BlockWords { word in bigEndianWord(tail, at: block * 64 + word * 4) })
        }
    }
}

/// The big-endian 32-bit word that starts at `offset` in `bytes`.
func bigEndianWord(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24
        | UInt32(bytes[offset + 1]) << 16
        | UInt32(bytes[offset + 2]) << 8
        | UInt32(bytes[offset + 3])
}

/// Byte `index` of the state's words laid end to end, each big-endian:
/// how both algorithms turn their final state into the digest.
func stateByte<let words: Int>(_ index: Int, of state: InlineArray<words, UInt32>) -> UInt8 {
    UInt8(truncatingIfNeeded: state[index / 4] >> (24 - 8 * (index % 4)))
}

extension UInt32 {
    /// The bits moved right by `count` places, those pushed off the end
    /// coming back in on the left: ROTR of FIPS 180-4, section 3.2.
    /// `count` is 1 to 31.
    func rotatedRight(by count: UInt32) -> UInt32 {
        (self &>> count) | (self &<< (32 &- count))
    }

    /// The bits moved left by `count` places, those pushed off the end
    /// coming back in on the right: ROTL of FIPS 180-4, section 3.2.
    /// `count` is 1 to 31.
    func rotatedLeft(by count: UInt32) -> UInt32 {
        (self &<< count) | (self &>> (32 &- count))
    }
}
