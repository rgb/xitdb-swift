// The hashes a database can be given: SHA-256 and SHA-1, each a conformer of
// XitDB's `KeyHashing` and nothing more.
//
// Where each platform's hashes are computed: on Apple silicon with the
// processor's SHA instructions (`InstructionHashes.swift`); everywhere else
// by the module's portable code, which needs only the standard library
// (`PortableSHA256.swift`, `PortableSHA1.swift`). That is Linux on any
// processor, an Intel Mac, the Intel simulator, and an Apple silicon
// toolchain without the compiler's module of the instructions. Either way
// there is one path for a key of any length, nothing is allocated, and the
// module calls no routine of the system's: it imports XitDB alone. The
// digests are the same, so nothing but the time can tell which code was
// taken.

public import XitDB

// The choice, made once, when the module is compiled. The condition is the
// one `InstructionHashes.swift` is compiled under, where its three parts are
// explained.
#if arch(arm64) && canImport(Darwin) && canImport(_Builtin_intrinsics.arm.neon)
    typealias KeySHA256 = InstructionSHA256
    typealias KeySHA1 = InstructionSHA1
#else
    typealias KeySHA256 = PortableSHA256
    typealias KeySHA1 = PortableSHA1
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
/// modules a bare `SHA256` is whichever one the code around it can use:
/// `SHA256.keyHash(of:)` and `hashing: SHA256.self` are this module's,
/// `SHA256.hash(data:)` is CryptoKit's. Where nothing tells the two apart
/// it does not compile: in a type annotation, a type alias, an extension,
/// or `let hasher = SHA256.self`. `XitDBHashing.SHA256` and
/// `CryptoKit.SHA256` always say which, and ``SHA256KeyHashing`` is this
/// type under a name CryptoKit does not have.
public enum SHA256: KeyHashing {
    /// 32: the number of bytes in a hash.
    public static var size: Int { 32 }

    /// Appends the SHA-256 of `bytes` to `output`: 32 bytes.
    ///
    /// Nothing is allocated, whatever the length. On Apple silicon the hash
    /// is computed with the processor's SHA instructions, and everywhere
    /// else by the module's portable code; the bytes are the same.
    public static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
        KeySHA256.hash(bytes, into: &output)
    }
}

/// Algorithms that are not secure against collisions. They are kept for
/// files whose keys are hashed with SHA-1, as they are in the original's
/// tests and by default in a xit repository; anything new should use
/// ``SHA256``.
///
/// CryptoKit has a namespace of this name too. In a file that imports both
/// modules a bare `Insecure.SHA1` is this module's where the code around it
/// can use no other, as in `hashing: Insecure.SHA1.self` and
/// `Insecure.SHA1.keyHash(of:)`, and does not compile where nothing tells
/// the two apart; `XitDBHashing.Insecure` always says which, and
/// ``SHA1KeyHashing`` is its SHA-1 under a name CryptoKit does not have.
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

        /// Appends the SHA-1 of `bytes` to `output`: 20 bytes.
        ///
        /// Nothing is allocated, whatever the length. On Apple silicon the
        /// hash is computed with the processor's SHA instructions, and
        /// everywhere else by the module's portable code; the bytes are the
        /// same.
        public static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
            KeySHA1.hash(bytes, into: &output)
        }
    }
}

/// ``SHA256`` under a name that CryptoKit does not have, for a file that
/// imports both modules.
///
/// It is the same type, not another: `SHA256KeyHashing.self` is
/// `SHA256.self`, and a database is given either. The name says what the
/// type is, a `KeyHashing`, and so can stand where a bare `SHA256` does
/// not compile beside CryptoKit's, because nothing there tells the two
/// apart: a type annotation, a type alias, an extension, or
/// `let hasher = SHA256KeyHashing.self`.
public typealias SHA256KeyHashing = SHA256

/// ``Insecure/SHA1`` under a name that CryptoKit does not have, for a file
/// that imports both modules.
///
/// It is the same type, not another, and no safer for the shorter name:
/// SHA-1 is insecure against collisions, which is why the type is in
/// ``Insecure``, and the alias leaves the namespace's word out of the name
/// and not out of the fact. Use it for files whose keys were hashed with
/// SHA-1; anything new should use ``SHA256KeyHashing``, or ``SHA256``.
public typealias SHA1KeyHashing = Insecure.SHA1
