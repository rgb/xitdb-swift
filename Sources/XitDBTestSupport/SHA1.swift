// SHA-1 as FIPS 180-4 defines it, in Swift that needs only the standard
// library. It is here because the original's files hash with it by
// default, and CryptoKit is not on Linux.

/// Algorithms that are not secure against collisions. They are kept for
/// files made by the original, whose default is SHA-1; anything new should
/// use ``SHA256``.
public enum Insecure {
    /// SHA-1 (FIPS 180-4).
    ///
    /// Collisions have been published, so a digest is a fingerprint of data
    /// that is trusted already, not a defence against data made to match.
    /// One shot only: there is no incremental update. A `String` is hashed
    /// through its `utf8`; a `Data` or an array slice passes as it is.
    public enum SHA1: Sendable {
        /// The number of bytes in a digest: 20.
        public static let byteCount = 20

        /// The digest of `data`.
        ///
        /// The sequence is read once, in full, before the hashing starts, so
        /// a sequence that can be read only once is fine, and a large one
        /// costs its size in memory while it is hashed.
        public static func hash(data: some Sequence<UInt8>) -> Insecure.SHA1Digest {
            var state = SHA1State()
            state.absorb(Array(data))
            return SHA1Digest(state)
        }
    }

    /// The 20 bytes of a SHA-1 digest.
    ///
    /// It iterates over its bytes in order. `description` is the digest as
    /// lowercase hex and nothing more, where CryptoKit's puts "SHA1 digest: "
    /// in front; a caller that parses the printed form must not expect that
    /// prefix.
    public struct SHA1Digest: Sequence, Equatable, Hashable, Sendable, CustomStringConvertible {
        let storage: DigestStorage<20>

        init(_ state: SHA1State) {
            storage = DigestStorage { stateByte($0, of: state.words) }
        }

        /// The bytes, copied into a new array.
        public var bytes: [UInt8] { storage.bytes }

        /// The digest as 40 lowercase hex characters.
        public var description: String { storage.hex }

        /// An iterator over the bytes in order: the same iterator type as
        /// CryptoKit's digests have, over a copy of the bytes.
        public func makeIterator() -> IndexingIterator<[UInt8]> { bytes.makeIterator() }
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
