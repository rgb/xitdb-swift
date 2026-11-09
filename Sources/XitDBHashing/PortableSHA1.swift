// SHA-1 as FIPS 180-4 defines it, in Swift that needs only the standard
// library. Where CryptoKit exists, ``Insecure/SHA1`` is CryptoKit's and this
// stands behind it only in the tests; elsewhere it is what it computes.

/// The portable SHA-1: the algorithm behind ``Insecure/SHA1`` where
/// CryptoKit is absent, compiled everywhere so that the tests can hold it
/// against CryptoKit where it exists.
package enum PortableSHA1: Sendable {
    /// The number of bytes in a digest: 20.
    package static let byteCount = 20

    /// The digest of `message`, read once and in full before the hashing
    /// starts.
    package static func hash(_ message: some Sequence<UInt8>) -> DigestStorage<20> {
        var state = SHA1State()
        state.absorb(Array(message))
        return DigestStorage { stateByte($0, of: state.words) }
    }
}

/// The working state of SHA-1: the five words H0 to H4 of FIPS 180-4,
/// section 6.1, at their initial values of section 5.3.1.
struct SHA1State: BlockHash {
    var words: InlineArray<5, UInt32> = [
        0x6745_2301, 0xefcd_ab89, 0x98ba_dcfe, 0x1032_5476, 0xc3d2_e1f0,
    ]

    /// One block through the 80 rounds of section 6.1.2, with the functions
    /// and constants of sections 4.1.1 and 4.2.1, one pair for each twenty
    /// rounds.
    mutating func compress(_ block: BlockWords) {
        var schedule = InlineArray<80, UInt32>(repeating: 0)
        for t in 0..<16 {
            schedule[t] = block[t]
        }
        for t in 16..<80 {
            let mixed = schedule[t - 3] ^ schedule[t - 8] ^ schedule[t - 14] ^ schedule[t - 16]
            schedule[t] = mixed.rotatedLeft(by: 1)
        }

        var a = words[0]
        var b = words[1]
        var c = words[2]
        var d = words[3]
        var e = words[4]
        for t in 0..<80 {
            let function: UInt32
            let constant: UInt32
            switch t {
            case 0..<20:
                function = (b & c) | (~b & d)
                constant = 0x5a82_7999
            case 20..<40:
                function = b ^ c ^ d
                constant = 0x6ed9_eba1
            case 40..<60:
                function = (b & c) | (b & d) | (c & d)
                constant = 0x8f1b_bcdc
            default:
                function = b ^ c ^ d
                constant = 0xca62_c1d6
            }
            let temp = a.rotatedLeft(by: 5) &+ function &+ e &+ constant &+ schedule[t]
            e = d
            d = c
            c = b.rotatedLeft(by: 30)
            b = a
            a = temp
        }
        words[0] &+= a
        words[1] &+= b
        words[2] &+= c
        words[3] &+= d
        words[4] &+= e
    }
}
