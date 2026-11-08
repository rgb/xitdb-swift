// SHA-256 as FIPS 180-4 defines it, in Swift that needs only the standard
// library. It is here because CryptoKit is not on Linux.

/// SHA-256 (FIPS 180-4).
///
/// One shot only: there is no incremental update. A `String` is hashed
/// through its `utf8`; a `Data` or an array slice passes as it is.
public enum SHA256: Sendable {
    /// The number of bytes in a digest: 32.
    public static let byteCount = 32

    /// The digest of `data`.
    ///
    /// The sequence is read once, in full, before the hashing starts, so a
    /// sequence that can be read only once is fine, and a large one costs
    /// its size in memory while it is hashed.
    public static func hash(data: some Sequence<UInt8>) -> SHA256Digest {
        var state = SHA256State()
        state.absorb(Array(data))
        return SHA256Digest(state)
    }
}

/// The 32 bytes of a SHA-256 digest.
///
/// It iterates over its bytes in order. `description` is the digest as
/// lowercase hex and nothing more, where CryptoKit's puts "SHA256 digest: "
/// in front; a caller that parses the printed form must not expect that
/// prefix.
public struct SHA256Digest: Sequence, Equatable, Hashable, Sendable, CustomStringConvertible {
    let storage: DigestStorage<32>

    init(_ state: SHA256State) {
        storage = DigestStorage { stateByte($0, of: state.words) }
    }

    /// The bytes, copied into a new array.
    public var bytes: [UInt8] { storage.bytes }

    /// The digest as 64 lowercase hex characters.
    public var description: String { storage.hex }

    /// An iterator over the bytes in order: the same iterator type as
    /// CryptoKit's digests have, over a copy of the bytes.
    public func makeIterator() -> IndexingIterator<[UInt8]> { bytes.makeIterator() }
}

/// The working state of SHA-256: the eight words H0 to H7 of FIPS 180-4,
/// section 6.2, at their initial values of section 5.3.3.
struct SHA256State: BlockHash {
    var words: InlineArray<8, UInt32> = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
        0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]

    /// The round constants K0 to K63 of section 4.2.2: the first 32 bits of
    /// the fractional parts of the cube roots of the first 64 primes.
    static let roundConstants: InlineArray<64, UInt32> = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    /// One block through the 64 rounds of section 6.2.2.
    mutating func compress(_ block: BlockWords) {
        var schedule = InlineArray<64, UInt32>(repeating: 0)
        for t in 0..<16 {
            schedule[t] = block[t]
        }
        for t in 16..<64 {
            let w15 = schedule[t - 15]
            let w2 = schedule[t - 2]
            let sigma0 = w15.rotatedRight(by: 7) ^ w15.rotatedRight(by: 18) ^ (w15 >> 3)
            let sigma1 = w2.rotatedRight(by: 17) ^ w2.rotatedRight(by: 19) ^ (w2 >> 10)
            schedule[t] = sigma1 &+ schedule[t - 7] &+ sigma0 &+ schedule[t - 16]
        }

        var a = words[0]
        var b = words[1]
        var c = words[2]
        var d = words[3]
        var e = words[4]
        var f = words[5]
        var g = words[6]
        var h = words[7]
        for t in 0..<64 {
            let bigSigma1 = e.rotatedRight(by: 6) ^ e.rotatedRight(by: 11) ^ e.rotatedRight(by: 25)
            let choice = (e & f) ^ (~e & g)
            let temp1 = h &+ bigSigma1 &+ choice &+ Self.roundConstants[t] &+ schedule[t]
            let bigSigma0 = a.rotatedRight(by: 2) ^ a.rotatedRight(by: 13) ^ a.rotatedRight(by: 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = bigSigma0 &+ majority
            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }
        words[0] &+= a
        words[1] &+= b
        words[2] &+= c
        words[3] &+= d
        words[4] &+= e
        words[5] &+= f
        words[6] &+= g
        words[7] &+= h
    }
}
