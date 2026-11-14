// The hashes a database can be given: SHA-256 and SHA-1, each a conformer of
// XitDB's `KeyHashing` and nothing more. Both are computed by this module's
// own code, which needs only the standard library, so they are the same on
// every platform.

public import XitDB

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

    /// Appends the SHA-256 of `bytes` to `output`: 32 bytes. Nothing is
    /// allocated.
    public static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
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

        /// Appends the SHA-1 of `bytes` to `output`: 20 bytes. Nothing is
        /// allocated.
        public static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
            PortableSHA1.hash(bytes, into: &output)
        }
    }
}
