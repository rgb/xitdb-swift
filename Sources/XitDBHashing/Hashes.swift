// The hashes a database can be given: SHA-256 and SHA-1, each a conformer of
// XitDB's `KeyHashing` and nothing more.
//
// Both are computed by this module's own code, which needs only the standard
// library. Where the system has a routine, on Apple's platforms, input longer
// than a few blocks goes to it instead: it costs more to call and less a
// block. The two give the same hash, so nothing but the time can tell which
// was taken.

public import XitDB

#if canImport(CryptoKit)
    import CryptoKit
#endif

/// SHA-256 (FIPS 180-4): the hash to choose for a database when you have
/// no reason to choose another.
///
/// 32 bytes, so the database's hash size is 32. A database is given the
/// type, as in `Database(creating: storage, hashing: SHA256.self)`, and its
/// calls that take a key hash with it; `SHA256.keyHash(of:)` gives a key's
/// hash for a call that takes the hash.
///
/// CryptoKit has a type of this name too. In a file that imports both
/// modules a bare `SHA256` is neither, and does not compile: this one is
/// `XitDBHashing.SHA256` there, and CryptoKit's is `CryptoKit.SHA256`.
public enum SHA256: KeyHashing {
    /// 32: the number of bytes in a hash.
    public static var size: Int { 32 }

    /// The longest input, in bytes, that the module's own code hashes
    /// where the system has a routine: the longest message of two blocks.
    /// ``SystemHashes`` has the measurement it was set by.
    package static let ownCodeLimit = 119

    /// Appends the SHA-256 of `bytes` to `output`: 32 bytes.
    ///
    /// A key of up to 119 bytes is hashed by the module's own code, which
    /// allocates nothing. Where CryptoKit exists a longer one is hashed by
    /// it, from a copy of the bytes.
    public static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
        #if canImport(CryptoKit)
            if bytes.count > ownCodeLimit {
                SystemHashes.sha256(bytes, into: &output)
                return
            }
        #endif
        PortableSHA256.hash(bytes, into: &output)
    }
}

/// Algorithms that are not secure against collisions. They are kept for
/// files whose keys are hashed with SHA-1, as they are in the original's
/// tests and by default in a xit repository; anything new should use
/// ``SHA256``.
///
/// CryptoKit has a namespace of this name too: in a file that imports both
/// modules this one is `XitDBHashing.Insecure`.
public enum Insecure {
    /// SHA-1 (FIPS 180-4).
    ///
    /// Collisions have been published, so a hash is a fingerprint of keys
    /// that are trusted already, not a defence against keys made to match.
    /// 20 bytes, so the database's hash size is 20. A database is given the
    /// type, as in `Database(opening: storage, hashing: Insecure.SHA1.self)`.
    public enum SHA1: KeyHashing {
        /// 20: the number of bytes in a hash.
        public static var size: Int { 20 }

        /// The longest input, in bytes, that the module's own code hashes
        /// where the system has a routine: the longest message of five
        /// blocks. ``SystemHashes`` has the measurement it was set by.
        package static let ownCodeLimit = 311

        /// Appends the SHA-1 of `bytes` to `output`: 20 bytes.
        ///
        /// A key of up to 311 bytes is hashed by the module's own code,
        /// which allocates nothing. Where CryptoKit exists a longer one is
        /// hashed by it, from a copy of the bytes.
        public static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
            #if canImport(CryptoKit)
                if bytes.count > ownCodeLimit {
                    SystemHashes.sha1(bytes, into: &output)
                    return
                }
            #endif
            PortableSHA1.hash(bytes, into: &output)
        }
    }
}

#if canImport(CryptoKit)
    /// The system's routines for the two hashes, where CryptoKit exists,
    /// reached with nothing unsafe.
    ///
    /// CryptoKit takes its input as contiguous bytes it can point at, and a
    /// span gives a pointer only through an unsafe call, of which this
    /// module has none. So the bytes are copied into an array first, which
    /// the compiler makes a block copy of, and the digest is appended byte
    /// by byte. Against handing CryptoKit the bytes where they are and
    /// reading its digest where it is, that costs 111 ns at a kilobyte (698
    /// against 587 for SHA-256, 19%), 10% at 64 KB and 6% at a megabyte,
    /// which was weighed and found too little to buy the module its first
    /// unsafe expression. With the pointer the system's routine would be
    /// worth taking sooner: SHA-256's limit would fall to one block, and a
    /// key of 56 to 119 bytes would hash up to 100 ns faster; SHA-1's would
    /// fall to three or four. If the standard library one day gives
    /// CryptoKit a span's bytes without a copy and without unsafe code,
    /// this is what changes, and the two limits with it.
    ///
    /// **The limits.** The system's routine costs more to call than the
    /// module's own code, the copy included, and less for each block, since
    /// it uses the processor's instructions for SHA. So the module's code is
    /// taken up to a limit and the system's routine above it:
    /// ``SHA256/ownCodeLimit`` and ``Insecure/SHA1/ownCodeLimit``.
    ///
    /// They were measured on an Apple M-series machine on 2026-11-14, in
    /// nanoseconds a hash, the system's routine as it is reached here. For
    /// the longest message of one, two, three, four, five, six and eight
    /// blocks, SHA-256 takes 162, 294, 429, 565, 703, 837 and 1,108 by the
    /// module's code and 253, 276, 297, 324, 352, 373 and 419 by the
    /// system's routine; SHA-1 takes 95, 159, 223, 293, 359, 422 and 550
    /// against 250, 270, 295, 322, 348, 366 and 415.
    ///
    /// The module's code costs the same anywhere in a block. The system's
    /// routine costs less the nearer its input is to the end of its block,
    /// about 1.7 ns for each byte of padding it has to write, so those
    /// figures are its best: at a block's beginning it costs up to 95 more,
    /// 337 for 9 bytes of SHA-256 and 371 for 64. Read with that, SHA-256
    /// is the module's code through two blocks, where the system's routine
    /// wins only in the last eleven lengths and by 18 ns at most, and the
    /// system's routine from three, where it wins at every length. SHA-1 is
    /// the module's code through five blocks; in the sixth the two are level
    /// on average, and from the seventh the system's routine wins.
    package enum SystemHashes {
        /// Appends CryptoKit's SHA-256 of `bytes` to `output`: 32 bytes.
        package static func sha256(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
            for byte in CryptoKit.SHA256.hash(data: copy(of: bytes)) {
                output.append(byte)
            }
        }

        /// Appends CryptoKit's SHA-1 of `bytes` to `output`: 20 bytes.
        package static func sha1(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
            for byte in CryptoKit.Insecure.SHA1.hash(data: copy(of: bytes)) {
                output.append(byte)
            }
        }

        /// The bytes of a span as an array.
        private static func copy(of bytes: Span<UInt8>) -> [UInt8] {
            [UInt8](capacity: bytes.count) { (output: inout OutputSpan<UInt8>) in
                for index in bytes.indices {
                    output.append(bytes[index])
                }
            }
        }
    }
#endif
