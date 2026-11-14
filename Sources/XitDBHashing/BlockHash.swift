// What the module's SHA-1 and SHA-256 share: the block loop with its
// padding, and the words of a block and of a digest. The two are what the
// public names compute, on every platform, and are tested against CryptoKit
// where it exists.
//
// They are written for the hash of a key, which is short: nothing here
// makes an array or calls a closure. The message's full blocks are read
// where they are, the rest is padded into one block on the stack, and the
// digest is appended where the caller holds it.

/// A hash that works through 64-byte blocks, as SHA-1 and SHA-256 do.
///
/// The conformer holds the working state and folds one block into it;
/// ``absorb(_:)`` pads the message and feeds it block by block.
protocol BlockHash {
    /// Folds one block into the state: the 64 bytes of `block`, read as the
    /// sixteen big-endian 32-bit words of FIPS 180-4, section 5.2.1.
    mutating func compress(_ block: Span<UInt8>)
}

extension BlockHash {
    /// Feeds the whole message to ``compress(_:)``, padded as FIPS 180-4,
    /// section 5.1.1 says: a 1 bit, zeros up to 8 bytes short of a block
    /// boundary, and the length in bits as a 64-bit big-endian number.
    ///
    /// The full blocks are read where the message is. What is left goes
    /// into one block on the stack with the padding, or into two. The last
    /// block is where an implementation goes wrong: a message with 56 to 63
    /// bytes past its last full block has no room for the length after the
    /// 1 bit and needs a second block, and one that ends on a block
    /// boundary needs one whole block of padding.
    @inline(__always)
    mutating func absorb(_ message: Span<UInt8>) {
        let count = message.count
        var offset = 0
        while count &- offset >= 64 {
            compress(message.extracting(offset..<(offset &+ 64)))
            offset &+= 64
        }
        var block = InlineArray<64, UInt8>(repeating: 0)
        let remaining = count &- offset
        for index in 0..<remaining {
            block[index] = message[offset &+ index]
        }
        block[remaining] = 0x80
        if remaining >= 56 {
            compress(block.span)
            block = InlineArray(repeating: 0)
        }
        let bitLength = UInt64(truncatingIfNeeded: count) &* 8
        for index in 0..<8 {
            block[56 &+ index] = UInt8(truncatingIfNeeded: bitLength &>> UInt64(56 &- 8 &* index))
        }
        compress(block.span)
    }
}

/// The big-endian 32-bit word that starts at `offset` in `bytes`.
///
/// It is put together byte by byte, each read with its bounds checked. The
/// standard library reads a whole word with one check, by `RawSpan`'s
/// `load(fromByteOffset:as:_:)`, but that needs macOS 27 and iOS 27, above
/// the systems the package asks for: when the package's floor rises, that
/// call can take this function's place.
@inline(__always)
func bigEndianWord(_ bytes: Span<UInt8>, at offset: Int) -> UInt32 {
    UInt32(bytes[offset]) &<< 24
        | UInt32(bytes[offset &+ 1]) &<< 16
        | UInt32(bytes[offset &+ 2]) &<< 8
        | UInt32(bytes[offset &+ 3])
}

/// Appends the state's words laid end to end, each big-endian: how both
/// algorithms turn their final state into the digest.
@inline(__always)
func appendDigest<let count: Int>(of words: InlineArray<count, UInt32>, to output: inout OutputSpan<UInt8>) {
    for index in words.indices {
        let word = words[index]
        output.append(UInt8(truncatingIfNeeded: word &>> 24))
        output.append(UInt8(truncatingIfNeeded: word &>> 16))
        output.append(UInt8(truncatingIfNeeded: word &>> 8))
        output.append(UInt8(truncatingIfNeeded: word))
    }
}

extension UInt32 {
    /// The bits moved right by `count` places, those pushed off the end
    /// coming back in on the left: ROTR of FIPS 180-4, section 3.2.
    /// `count` is 1 to 31.
    @inline(__always)
    func rotatedRight(by count: UInt32) -> UInt32 {
        (self &>> count) | (self &<< (32 &- count))
    }

    /// The bits moved left by `count` places, those pushed off the end
    /// coming back in on the right: ROTL of FIPS 180-4, section 3.2.
    /// `count` is 1 to 31.
    @inline(__always)
    func rotatedLeft(by count: UInt32) -> UInt32 {
        (self &<< count) | (self &>> (32 &- count))
    }
}
