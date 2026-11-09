// SipHash-2-4 with a 128-bit result (Aumasson and Bernstein, 2012), in
// Swift that needs only the standard library, under one fixed key: the
// fast hash a store can name for keys the program itself produces. The
// constants and the order of operations are the reference implementation's
// `siphash` with an output of 16 bytes.

public import XitDB

/// SipHash-2-4 with a 128-bit result and a fixed key: a fast hash that is
/// not cryptographic.
///
/// 16 bytes, so the database's hash size is 16. The key is fixed, the
/// reference implementation's test key (the bytes 0 to 15), so every process
/// that opens a file computes the same hash; a caller cannot choose it. That
/// is also why it is no defence: SipHash resists made-to-order collisions
/// only while its key is secret, and with a public key anyone can make two
/// keys that collide. Two keys with one hash name one entry, so a collision
/// here is data loss. Use it only for keys the program itself produces,
/// never for keys that come from users or the network; `SHA256` is the
/// default and the safe choice. One shot only: there is no incremental
/// update. ``hash(_:)`` takes any collection of bytes, a string's `utf8`,
/// an array or a slice of one.
public enum SipHash128: Sendable, KeyHashing {
    /// The number of bytes in a digest: 16.
    public static let byteCount = 16

    /// 16.
    public static var size: Int { byteCount }

    /// The digest of `data`.
    ///
    /// The sequence is read once, in full, before the hashing starts, so a
    /// sequence that can be read only once is fine, and a large one costs
    /// its size in memory while it is hashed.
    public static func hash(data: some Sequence<UInt8>) -> SipHash128Digest {
        SipHash128Digest(storage: SipHashState.hash(Array(data)))
    }

    /// The digest of `bytes`: ``hash(data:)`` under the name `KeyHashing`
    /// asks for.
    public static func hash(_ bytes: some Collection<UInt8>) -> SipHash128Digest {
        hash(data: bytes)
    }
}

/// The 16 bytes of a SipHash-128 digest.
///
/// It iterates over its bytes in order, so `Array(digest)` is the bytes, as
/// with CryptoKit's digests; there is no `bytes` property. `description`
/// follows CryptoKit's form, "SipHash128 digest: " and then the digest as
/// 32 lowercase hex characters; a caller that wants the hex alone, to hold
/// against the reference implementation's vectors say, drops that prefix.
public struct SipHash128Digest: Sequence, Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The number of bytes in a digest: 16, as CryptoKit's digests say it.
    public static let byteCount = 16

    let storage: DigestStorage<16>

    /// "SipHash128 digest: " followed by the digest as 32 lowercase hex
    /// characters, the form CryptoKit's digests print in.
    public var description: String { "SipHash128 digest: " + storage.hex }

    /// An iterator over the bytes in order: the same iterator type as
    /// CryptoKit's digests have, over a copy of the bytes.
    public func makeIterator() -> IndexingIterator<[UInt8]> { storage.bytes.makeIterator() }
}

/// The working state of SipHash: the four words v0 to v3 of the paper's
/// section 2.1, with the key folded in and v1 marked for a 128-bit result.
struct SipHashState {
    /// The fixed key, the bytes 0 to 15, as the two little-endian words the
    /// algorithm reads it as.
    static let k0: UInt64 = 0x0706_0504_0302_0100
    static let k1: UInt64 = 0x0f0e_0d0c_0b0a_0908

    /// "somepseu" with k0 folded in.
    var v0: UInt64 = 0x736f_6d65_7073_6575 ^ Self.k0

    /// "dorandom" with k1 folded in, then 0xee: what tells a 128-bit result
    /// apart from a 64-bit one before the first block.
    var v1: UInt64 = 0x646f_7261_6e64_6f6d ^ Self.k1 ^ 0xee

    /// "lygenera" with k0 folded in.
    var v2: UInt64 = 0x6c79_6765_6e65_7261 ^ Self.k0

    /// "tedbytes" with k1 folded in.
    var v3: UInt64 = 0x7465_6462_7974_6573 ^ Self.k1

    /// The digest of `message`: its 8-byte blocks in turn, then the last
    /// block, then the two finalisations that give the two halves.
    ///
    /// The last block is where an implementation goes wrong: its top byte
    /// is the message's length modulo 256 and the rest is the 0 to 7 bytes
    /// left over, little-endian, so a message of whole blocks still has a
    /// last block, one with only the length in it.
    static func hash(_ message: [UInt8]) -> DigestStorage<16> {
        var state = SipHashState()
        let fullBlocks = message.count / 8
        for block in 0..<fullBlocks {
            state.compress(littleEndianWord(message, at: block * 8))
        }
        var last = UInt64(truncatingIfNeeded: message.count) << 56
        var shift: UInt64 = 0
        for byte in message[(fullBlocks * 8)...] {
            last |= UInt64(byte) << shift
            shift += 8
        }
        state.compress(last)
        state.v2 ^= 0xee
        let low = state.finalize()
        state.v1 ^= 0xdd
        let high = state.finalize()
        return DigestStorage { index in
            let word = index < 8 ? low : high
            return UInt8(truncatingIfNeeded: word >> (8 * UInt64(index % 8)))
        }
    }

    /// Folds one block in: v3 takes it, two rounds, v0 takes it (the
    /// compression of section 2.2, with c = 2).
    mutating func compress(_ block: UInt64) {
        v3 ^= block
        round()
        round()
        v0 ^= block
    }

    /// Four rounds and the four words folded into one: the finalisation of
    /// section 2.3, with d = 4, once for each half of the result. The
    /// constant that tells the halves apart (0xee into v2, then 0xdd into
    /// v1) is the caller's to put in first.
    mutating func finalize() -> UInt64 {
        for _ in 0..<4 {
            round()
        }
        return v0 ^ v1 ^ v2 ^ v3
    }

    /// One SipRound, the ARX network of section 2.1.
    mutating func round() {
        v0 &+= v1
        v1 = v1.rotatedLeft(by: 13)
        v1 ^= v0
        v0 = v0.rotatedLeft(by: 32)
        v2 &+= v3
        v3 = v3.rotatedLeft(by: 16)
        v3 ^= v2
        v0 &+= v3
        v3 = v3.rotatedLeft(by: 21)
        v3 ^= v0
        v2 &+= v1
        v1 = v1.rotatedLeft(by: 17)
        v1 ^= v2
        v2 = v2.rotatedLeft(by: 32)
    }
}

/// The little-endian 64-bit word that starts at `offset` in `bytes`.
private func littleEndianWord(_ bytes: [UInt8], at offset: Int) -> UInt64 {
    var word: UInt64 = 0
    for index in 0..<8 {
        word |= UInt64(bytes[offset + index]) << (8 * UInt64(index))
    }
    return word
}

extension UInt64 {
    /// The bits moved left by `count` places, those pushed off the end
    /// coming back in on the right: ROTL of the reference implementation.
    /// `count` is 1 to 63.
    fileprivate func rotatedLeft(by count: UInt64) -> UInt64 {
        (self &<< count) | (self &>> (64 &- count))
    }
}
