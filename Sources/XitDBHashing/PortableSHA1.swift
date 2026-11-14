// SHA-1 as FIPS 180-4 defines it, in Swift that needs only the standard
// library. Where CryptoKit exists, ``Insecure/SHA1`` is CryptoKit's and this
// stands behind it only in the tests; elsewhere it is what it computes.

/// The portable SHA-1: the algorithm behind ``Insecure/SHA1`` where
/// CryptoKit is absent, compiled everywhere so that the tests can hold it
/// against CryptoKit where it exists.
package enum PortableSHA1: Sendable {
    /// The number of bytes in a digest: 20.
    package static let byteCount = 20

    /// Appends the digest of `message` to `output`: 20 bytes. Nothing is
    /// allocated.
    package static func hash(_ message: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
        var state = SHA1State()
        state.absorb(message)
        appendDigest(of: state.words, to: &output)
    }

    /// The digest of `message`, read once and in full before the hashing
    /// starts.
    package static func hash(_ message: some Sequence<UInt8>) -> DigestStorage<20> {
        let bytes = Array(message)
        return DigestStorage { output in hash(bytes.span, into: &output) }
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
    ///
    /// The message schedule is kept as its last sixteen words, each index
    /// taken modulo 16 (section 6.1.3): word `t` is made from words
    /// `t - 3`, `t - 8`, `t - 14` and `t - 16` and takes the place of the
    /// last of them.
    ///
    /// The eighty rounds are written out one by one. In a loop over `t`
    /// the schedule's indices are computed as it runs; written out, each
    /// is a constant and the sixteen words stay in registers, which takes
    /// a third off the time of a block.
    mutating func compress(_ block: Span<UInt8>) {
        var schedule = InlineArray<16, UInt32>(repeating: 0)
        for t in 0..<16 {
            schedule[t] = bigEndianWord(block, at: 4 &* t)
        }
        var a = words[0]
        var b = words[1]
        var c = words[2]
        var d = words[3]
        var e = words[4]

        /// Word `t` of the schedule, for `t` from 16 on.
        @inline(__always)
        func next(_ t: Int) -> UInt32 {
            let word =
                (schedule[(t &+ 13) & 15] ^ schedule[(t &+ 8) & 15] ^ schedule[(t &+ 2) & 15] ^ schedule[t & 15])
                .rotatedLeft(by: 1)
            schedule[t & 15] = word
            return word
        }
        /// One round: `f` is the round's function of `b`, `c` and `d`, `k`
        /// its constant and `w` its word of the schedule.
        @inline(__always)
        func round(_ f: UInt32, _ k: UInt32, _ w: UInt32) {
            let temp = a.rotatedLeft(by: 5) &+ f &+ e &+ k &+ w
            e = d
            d = c
            c = b.rotatedLeft(by: 30)
            b = a
            a = temp
        }

        // Rounds 0 to 19: Ch, the choice of `c` or `d` by `b`.
        round((b & c) ^ (~b & d), 0x5a82_7999, schedule[0])
        round((b & c) ^ (~b & d), 0x5a82_7999, schedule[1])
        round((b & c) ^ (~b & d), 0x5a82_7999, schedule[2])
        round((b & c) ^ (~b & d), 0x5a82_7999, schedule[3])
        round((b & c) ^ (~b & d), 0x5a82_7999, schedule[4])
        round((b & c) ^ (~b & d), 0x5a82_7999, schedule[5])
        round((b & c) ^ (~b & d), 0x5a82_7999, schedule[6])
        round((b & c) ^ (~b & d), 0x5a82_7999, schedule[7])
        round((b & c) ^ (~b & d), 0x5a82_7999, schedule[8])
        round((b & c) ^ (~b & d), 0x5a82_7999, schedule[9])
        round((b & c) ^ (~b & d), 0x5a82_7999, schedule[10])
        round((b & c) ^ (~b & d), 0x5a82_7999, schedule[11])
        round((b & c) ^ (~b & d), 0x5a82_7999, schedule[12])
        round((b & c) ^ (~b & d), 0x5a82_7999, schedule[13])
        round((b & c) ^ (~b & d), 0x5a82_7999, schedule[14])
        round((b & c) ^ (~b & d), 0x5a82_7999, schedule[15])
        round((b & c) ^ (~b & d), 0x5a82_7999, next(16))
        round((b & c) ^ (~b & d), 0x5a82_7999, next(17))
        round((b & c) ^ (~b & d), 0x5a82_7999, next(18))
        round((b & c) ^ (~b & d), 0x5a82_7999, next(19))

        // Rounds 20 to 39: Parity.
        round(b ^ c ^ d, 0x6ed9_eba1, next(20))
        round(b ^ c ^ d, 0x6ed9_eba1, next(21))
        round(b ^ c ^ d, 0x6ed9_eba1, next(22))
        round(b ^ c ^ d, 0x6ed9_eba1, next(23))
        round(b ^ c ^ d, 0x6ed9_eba1, next(24))
        round(b ^ c ^ d, 0x6ed9_eba1, next(25))
        round(b ^ c ^ d, 0x6ed9_eba1, next(26))
        round(b ^ c ^ d, 0x6ed9_eba1, next(27))
        round(b ^ c ^ d, 0x6ed9_eba1, next(28))
        round(b ^ c ^ d, 0x6ed9_eba1, next(29))
        round(b ^ c ^ d, 0x6ed9_eba1, next(30))
        round(b ^ c ^ d, 0x6ed9_eba1, next(31))
        round(b ^ c ^ d, 0x6ed9_eba1, next(32))
        round(b ^ c ^ d, 0x6ed9_eba1, next(33))
        round(b ^ c ^ d, 0x6ed9_eba1, next(34))
        round(b ^ c ^ d, 0x6ed9_eba1, next(35))
        round(b ^ c ^ d, 0x6ed9_eba1, next(36))
        round(b ^ c ^ d, 0x6ed9_eba1, next(37))
        round(b ^ c ^ d, 0x6ed9_eba1, next(38))
        round(b ^ c ^ d, 0x6ed9_eba1, next(39))

        // Rounds 40 to 59: Maj, the majority of the three.
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(40))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(41))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(42))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(43))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(44))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(45))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(46))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(47))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(48))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(49))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(50))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(51))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(52))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(53))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(54))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(55))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(56))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(57))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(58))
        round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, next(59))

        // Rounds 60 to 79: Parity.
        round(b ^ c ^ d, 0xca62_c1d6, next(60))
        round(b ^ c ^ d, 0xca62_c1d6, next(61))
        round(b ^ c ^ d, 0xca62_c1d6, next(62))
        round(b ^ c ^ d, 0xca62_c1d6, next(63))
        round(b ^ c ^ d, 0xca62_c1d6, next(64))
        round(b ^ c ^ d, 0xca62_c1d6, next(65))
        round(b ^ c ^ d, 0xca62_c1d6, next(66))
        round(b ^ c ^ d, 0xca62_c1d6, next(67))
        round(b ^ c ^ d, 0xca62_c1d6, next(68))
        round(b ^ c ^ d, 0xca62_c1d6, next(69))
        round(b ^ c ^ d, 0xca62_c1d6, next(70))
        round(b ^ c ^ d, 0xca62_c1d6, next(71))
        round(b ^ c ^ d, 0xca62_c1d6, next(72))
        round(b ^ c ^ d, 0xca62_c1d6, next(73))
        round(b ^ c ^ d, 0xca62_c1d6, next(74))
        round(b ^ c ^ d, 0xca62_c1d6, next(75))
        round(b ^ c ^ d, 0xca62_c1d6, next(76))
        round(b ^ c ^ d, 0xca62_c1d6, next(77))
        round(b ^ c ^ d, 0xca62_c1d6, next(78))
        round(b ^ c ^ d, 0xca62_c1d6, next(79))

        words[0] &+= a
        words[1] &+= b
        words[2] &+= c
        words[3] &+= d
        words[4] &+= e
    }
}
