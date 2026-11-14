// SHA-256 and SHA-1 by the processor's SHA instructions: what the two
// hashers compute on Apple silicon.
//
// Every Apple silicon processor has the instructions of the Arm
// cryptography extension: four rounds of a hash in one instruction, and the
// next four words of the message schedule in two. Swift reaches them through
// the compiler's own module of NEON intrinsics, where each is a function of
// vectors of four words. Nothing here is unsafe.
//
// The condition has three parts, and each is needed:
//
// - `arch(arm64)`: the instructions are Arm's.
// - `canImport(Darwin)`: on Linux the compiler accepts the import, checks
//   this code, and then crashes while it generates it, because its Linux
//   target does not assume a processor that has the instructions. Telling it
//   so takes unsafe flags, and a check at run time beside them. Linux takes
//   the portable code instead.
// - `canImport(_Builtin_intrinsics.arm.neon)`: the module is the compiler's
//   own and underscored, not a promise of Swift's. A toolchain without it
//   builds the portable code, which `Hashes.swift` names on the condition's
//   other side, and the hashes are the same.

#if arch(arm64) && canImport(Darwin) && canImport(_Builtin_intrinsics.arm.neon)
    import _Builtin_intrinsics.arm.neon

    /// SHA-256 by the processor's instructions: what ``SHA256`` computes on
    /// Apple silicon, at every length.
    ///
    /// On long input CryptoKit's SHA-256 is faster than this by about an
    /// eighth, and the module does not turn to it. PROVISIONAL, from rough
    /// passes on an Apple M-series machine on 2026-11-14 and before the
    /// measurement: 64 KB takes about 23,300 ns here and 21,500 by CryptoKit
    /// given a copy of the bytes, which is how a module without unsafe code
    /// reaches it; a megabyte 371,000 against 330,000. A kilobyte takes 380
    /// against 700, and the two cross near 8 KB. One path for every key,
    /// with nothing allocated and no routine of the system's, was judged
    /// worth that eighth on input a key almost never is; who hashes
    /// megabytes for their own sake has CryptoKit. SHA-1 is within a tenth
    /// of CryptoKit's at every length.
    package enum InstructionSHA256: Sendable {
        /// Appends the digest of `message` to `output`: 32 bytes. Nothing is
        /// allocated.
        package static func hash(_ message: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
            var state = SHA256InstructionState()
            state.absorb(message)
            appendDigest(of: state.abcd, to: &output)
            appendDigest(of: state.efgh, to: &output)
        }
    }

    /// SHA-1 by the processor's instructions: what ``Insecure/SHA1``
    /// computes on Apple silicon, at every length.
    package enum InstructionSHA1: Sendable {
        /// Appends the digest of `message` to `output`: 20 bytes. Nothing is
        /// allocated.
        package static func hash(_ message: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
            var state = SHA1InstructionState()
            state.absorb(message)
            appendDigest(of: state.abcd, to: &output)
            output.append(UInt8(truncatingIfNeeded: state.e &>> 24))
            output.append(UInt8(truncatingIfNeeded: state.e &>> 16))
            output.append(UInt8(truncatingIfNeeded: state.e &>> 8))
            output.append(UInt8(truncatingIfNeeded: state.e))
        }
    }

    extension HashPath {
        /// The processor's SHA instructions: on Apple silicon.
        package static let instructions: HashPath? = HashPath(
            description: "the processor's instructions",
            sha256: { message, output in InstructionSHA256.hash(message, into: &output) },
            sha1: { message, output in InstructionSHA1.hash(message, into: &output) })
    }

    /// Sixteen bytes of a block as four big-endian words in a vector.
    ///
    /// The bytes are read one by one with their bounds checked, which the
    /// compiler makes one load of, and one instruction reverses them within
    /// each word.
    @inline(__always)
    func blockWords(_ block: Span<UInt8>, at offset: Int) -> SIMD4<UInt32> {
        var bytes = SIMD16<UInt8>()
        for index in 0..<16 {
            bytes[index] = block[offset &+ index]
        }
        return vreinterpretq_u32_u8(vrev32q_u8(bytes))
    }

    /// Appends four words of a digest, each big-endian.
    @inline(__always)
    func appendDigest(of words: SIMD4<UInt32>, to output: inout OutputSpan<UInt8>) {
        for lane in 0..<4 {
            let word = words[lane]
            output.append(UInt8(truncatingIfNeeded: word &>> 24))
            output.append(UInt8(truncatingIfNeeded: word &>> 16))
            output.append(UInt8(truncatingIfNeeded: word &>> 8))
            output.append(UInt8(truncatingIfNeeded: word))
        }
    }

    /// The working state of SHA-256 as the instructions take it: the words
    /// H0 to H3 of FIPS 180-4, section 6.2, in one vector and H4 to H7 in
    /// another, at their initial values of section 5.3.3.
    struct SHA256InstructionState: BlockHash {
        var abcd = SIMD4<UInt32>(0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a)
        var efgh = SIMD4<UInt32>(0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19)

        /// One block through the 64 rounds of section 6.2.2, four at a time.
        ///
        /// The message schedule is kept as its last sixteen words in four
        /// vectors, each index taken modulo 4. A group of four rounds takes
        /// the oldest vector with its four constants of section 4.2.2 added,
        /// and, while there are words to come, puts the four words sixteen
        /// further on in its place: `vsha256su0q_u32` and `vsha256su1q_u32`
        /// are the two halves of the schedule's formula. `vsha256hq_u32`
        /// gives the first half of the state after the four rounds and
        /// `vsha256h2q_u32` the second, each from both halves before them.
        ///
        /// The sixteen groups are written out, each with its constants
        /// beside it, so that they are operands in registers and not loads
        /// from a table: that halves the time of a block. The function is
        /// inlined into the loop over a message's blocks, which keeps the
        /// state in registers from one block to the next.
        @inline(__always)
        mutating func compress(_ block: Span<UInt8>) {
            var schedule: InlineArray<4, SIMD4<UInt32>> = [
                blockWords(block, at: 0), blockWords(block, at: 16),
                blockWords(block, at: 32), blockWords(block, at: 48),
            ]
            var abcd = self.abcd
            var efgh = self.efgh

            /// Rounds `4 * group` to `4 * group + 3`, with their constants.
            @inline(__always)
            func rounds(_ group: Int, _ constants: SIMD4<UInt32>) {
                let words = schedule[group & 3]
                if group < 12 {
                    schedule[group & 3] = vsha256su1q_u32(
                        vsha256su0q_u32(words, schedule[(group &+ 1) & 3]),
                        schedule[(group &+ 2) & 3], schedule[(group &+ 3) & 3])
                }
                let wordsAndConstants = words &+ constants
                let abcdBefore = abcd
                abcd = vsha256hq_u32(abcd, efgh, wordsAndConstants)
                efgh = vsha256h2q_u32(efgh, abcdBefore, wordsAndConstants)
            }
            rounds(0, SIMD4(0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5))
            rounds(1, SIMD4(0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5))
            rounds(2, SIMD4(0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3))
            rounds(3, SIMD4(0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174))
            rounds(4, SIMD4(0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc))
            rounds(5, SIMD4(0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da))
            rounds(6, SIMD4(0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7))
            rounds(7, SIMD4(0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967))
            rounds(8, SIMD4(0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13))
            rounds(9, SIMD4(0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85))
            rounds(10, SIMD4(0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3))
            rounds(11, SIMD4(0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070))
            rounds(12, SIMD4(0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5))
            rounds(13, SIMD4(0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3))
            rounds(14, SIMD4(0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208))
            rounds(15, SIMD4(0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2))

            self.abcd = self.abcd &+ abcd
            self.efgh = self.efgh &+ efgh
        }
    }

    /// The working state of SHA-1 as the instructions take it: the words H0
    /// to H3 of FIPS 180-4, section 6.1, in one vector and H4 beside them,
    /// at their initial values of section 5.3.1.
    struct SHA1InstructionState: BlockHash {
        var abcd = SIMD4<UInt32>(0x6745_2301, 0xefcd_ab89, 0x98ba_dcfe, 0x1032_5476)
        var e: UInt32 = 0xc3d2_e1f0

        /// One block through the 80 rounds of section 6.1.2, four at a time.
        ///
        /// The message schedule is kept as its last sixteen words in four
        /// vectors, each index taken modulo 4, as for SHA-256:
        /// `vsha1su0q_u32` and `vsha1su1q_u32` are the two halves of its
        /// formula. A group of four rounds is one instruction, which one
        /// depending on the rounds' function of section 4.1.1:
        /// `vsha1cq_u32` for Ch, `vsha1pq_u32` for Parity and `vsha1mq_u32`
        /// for Maj. It gives the first four words of the state; the fifth
        /// after the group is the first before it, rotated, which
        /// `vsha1h_u32` computes.
        ///
        /// The twenty groups are written out, and the function is inlined
        /// into the loop over a message's blocks, as for SHA-256.
        @inline(__always)
        mutating func compress(_ block: Span<UInt8>) {
            var schedule: InlineArray<4, SIMD4<UInt32>> = [
                blockWords(block, at: 0), blockWords(block, at: 16),
                blockWords(block, at: 32), blockWords(block, at: 48),
            ]
            var abcd = self.abcd
            var e = self.e

            /// The words of group `group` with the constant of its rounds
            /// added, and the schedule moved on four words while there are
            /// words to come.
            @inline(__always)
            func scheduled(_ group: Int, _ constant: UInt32) -> SIMD4<UInt32> {
                let words = schedule[group & 3]
                if group < 16 {
                    schedule[group & 3] = vsha1su1q_u32(
                        vsha1su0q_u32(words, schedule[(group &+ 1) & 3], schedule[(group &+ 2) & 3]),
                        schedule[(group &+ 3) & 3])
                }
                return words &+ SIMD4(repeating: constant)
            }
            /// Rounds `4 * group` to `4 * group + 3` of the first twenty.
            @inline(__always)
            func choice(_ group: Int) {
                let wordsAndConstant = scheduled(group, 0x5a82_7999)
                let eAfter = vsha1h_u32(abcd[0])
                abcd = vsha1cq_u32(abcd, e, wordsAndConstant)
                e = eAfter
            }
            /// The same of the second and the last twenty, which differ in
            /// their constant.
            @inline(__always)
            func parity(_ group: Int, _ constant: UInt32) {
                let wordsAndConstant = scheduled(group, constant)
                let eAfter = vsha1h_u32(abcd[0])
                abcd = vsha1pq_u32(abcd, e, wordsAndConstant)
                e = eAfter
            }
            /// The same of the third twenty.
            @inline(__always)
            func majority(_ group: Int) {
                let wordsAndConstant = scheduled(group, 0x8f1b_bcdc)
                let eAfter = vsha1h_u32(abcd[0])
                abcd = vsha1mq_u32(abcd, e, wordsAndConstant)
                e = eAfter
            }
            choice(0)
            choice(1)
            choice(2)
            choice(3)
            choice(4)
            parity(5, 0x6ed9_eba1)
            parity(6, 0x6ed9_eba1)
            parity(7, 0x6ed9_eba1)
            parity(8, 0x6ed9_eba1)
            parity(9, 0x6ed9_eba1)
            majority(10)
            majority(11)
            majority(12)
            majority(13)
            majority(14)
            parity(15, 0xca62_c1d6)
            parity(16, 0xca62_c1d6)
            parity(17, 0xca62_c1d6)
            parity(18, 0xca62_c1d6)
            parity(19, 0xca62_c1d6)

            self.abcd = self.abcd &+ abcd
            self.e = self.e &+ e
        }
    }
#else
    extension HashPath {
        /// Not in this build: the processor's SHA instructions are taken on
        /// Apple silicon alone, and only where the compiler has its module
        /// of them.
        package static let instructions: HashPath? = nil
    }
#endif
