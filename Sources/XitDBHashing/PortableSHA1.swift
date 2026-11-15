// SHA-1 as FIPS 180-4 defines it, in Swift that needs only the standard
// library: what ``Insecure/SHA1`` computes everywhere but on Apple silicon,
// where the processor's instructions are taken.

/// The module's portable SHA-1, which needs nothing of the platform: the
/// code behind ``Insecure/SHA1`` where the processor's SHA instructions are
/// not taken. The tests hold it to the vectors on every platform, Apple
/// silicon included, and to CryptoKit where CryptoKit exists.
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
    ///
    /// The two helpers, `word(_:of:)` and `round`, are given the schedule
    /// and the five working words as parameters.
    /// As functions nested here that captured those six variables they
    /// cost a run-time check of exclusive access for each, every block:
    /// 13 to 17% of the hash.
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

        // Rounds 0 to 19: Ch, the choice of `c` or `d` by `b`.
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, schedule[0], &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, schedule[1], &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, schedule[2], &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, schedule[3], &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, schedule[4], &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, schedule[5], &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, schedule[6], &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, schedule[7], &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, schedule[8], &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, schedule[9], &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, schedule[10], &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, schedule[11], &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, schedule[12], &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, schedule[13], &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, schedule[14], &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, schedule[15], &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, Self.word(16, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, Self.word(17, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, Self.word(18, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (~b & d), 0x5a82_7999, Self.word(19, of: &schedule), &a, &b, &c, &d, &e)

        // Rounds 20 to 39: Parity.
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(20, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(21, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(22, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(23, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(24, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(25, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(26, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(27, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(28, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(29, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(30, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(31, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(32, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(33, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(34, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(35, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(36, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(37, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(38, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0x6ed9_eba1, Self.word(39, of: &schedule), &a, &b, &c, &d, &e)

        // Rounds 40 to 59: Maj, the majority of the three.
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(40, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(41, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(42, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(43, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(44, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(45, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(46, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(47, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(48, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(49, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(50, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(51, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(52, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(53, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(54, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(55, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(56, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(57, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(58, of: &schedule), &a, &b, &c, &d, &e)
        Self.round((b & c) ^ (b & d) ^ (c & d), 0x8f1b_bcdc, Self.word(59, of: &schedule), &a, &b, &c, &d, &e)

        // Rounds 60 to 79: Parity.
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(60, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(61, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(62, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(63, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(64, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(65, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(66, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(67, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(68, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(69, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(70, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(71, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(72, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(73, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(74, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(75, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(76, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(77, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(78, of: &schedule), &a, &b, &c, &d, &e)
        Self.round(b ^ c ^ d, 0xca62_c1d6, Self.word(79, of: &schedule), &a, &b, &c, &d, &e)

        words[0] &+= a
        words[1] &+= b
        words[2] &+= c
        words[3] &+= d
        words[4] &+= e
    }

    /// Word `t` of the schedule, for `t` from 16 on, which takes the place
    /// of word `t - 16`.
    @inline(__always)
    static func word(_ t: Int, of schedule: inout InlineArray<16, UInt32>) -> UInt32 {
        let word =
            (schedule[(t &+ 13) & 15] ^ schedule[(t &+ 8) & 15] ^ schedule[(t &+ 2) & 15] ^ schedule[t & 15])
            .rotatedLeft(by: 1)
        schedule[t & 15] = word
        return word
    }

    /// One round on the five working words: `f` is the round's function of
    /// `b`, `c` and `d`, `k` its constant and `w` its word of the schedule.
    @inline(__always)
    static func round(
        _ f: UInt32, _ k: UInt32, _ w: UInt32,
        _ a: inout UInt32, _ b: inout UInt32, _ c: inout UInt32, _ d: inout UInt32, _ e: inout UInt32
    ) {
        let temp = a.rotatedLeft(by: 5) &+ f &+ e &+ k &+ w
        e = d
        d = c
        c = b.rotatedLeft(by: 30)
        b = a
        a = temp
    }
}
