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
    /// where the system has a routine: two blocks. See ``SystemHashes``.
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
        /// where the system has a routine: five blocks. See
        /// ``SystemHashes``.
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
    /// by byte.
    ///
    /// The system's routine costs more to call than the module's own code,
    /// the copy included, and less for each block, since it uses the
    /// processor's instructions for SHA where there are any. The module's
    /// own code is therefore taken up to a limit and the system's routine
    /// above it: ``SHA256/ownCodeLimit`` and ``Insecure/SHA1/ownCodeLimit``.
    /// PROVISIONAL, from a rough look on an Apple M-series machine and
    /// before the measurement: for a message of n blocks SHA-256 takes about
    /// 27 + 136 n ns by the module's code and 282 + 22 n by the system's
    /// routine, which cross between two and three blocks; SHA-1 takes about
    /// 27 + 66 n against 282 + 22 n, which cross between five and six.
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
