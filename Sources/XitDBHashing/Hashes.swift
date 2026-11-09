// The hashes a store can name, with CryptoKit's spelling and one set of
// names on every platform: where CryptoKit exists the types forward to it
// and hand out its digests, so nothing of this package is on the path;
// where it does not, the portable implementations compute them. Each type
// conforms to XitDB's `KeyHashing`. SipHash-128 is in its own file.

public import XitDB

#if canImport(CryptoKit)
    public import CryptoKit
#endif

/// SHA-256 (FIPS 180-4): the default hash for a store.
///
/// 32 bytes, so the database's hash size is 32. Where CryptoKit exists the
/// digest is CryptoKit's own, computed by it; elsewhere it is computed here.
/// One shot only: there is no incremental update. A `String` is hashed
/// through its `utf8`; an array passes as it is, any other sequence is
/// copied into one first.
public enum SHA256: Sendable, KeyHashing {
    /// The number of bytes in a digest: 32.
    public static let byteCount = 32

    /// 32.
    public static var size: Int { byteCount }

    /// The digest of `data`.
    ///
    /// The sequence is read once, in full, before the hashing starts, so a
    /// sequence that can be read only once is fine, and a large one costs
    /// its size in memory while it is hashed.
    public static func hash(data: some Sequence<UInt8>) -> SHA256Digest {
        #if canImport(CryptoKit)
            if let array = data as? [UInt8] { return CryptoKit.SHA256.hash(data: array) }
            return CryptoKit.SHA256.hash(data: Array(data))
        #else
            return SHA256Digest(storage: PortableSHA256.hash(data))
        #endif
    }

    /// The digest of `bytes`: ``hash(data:)`` under the name `KeyHashing`
    /// asks for.
    public static func hash(_ bytes: some Collection<UInt8>) -> SHA256Digest {
        hash(data: bytes)
    }
}

#if canImport(CryptoKit)
    /// The 32 bytes of a SHA-256 digest: CryptoKit's type, a sequence of its
    /// bytes that prints as "SHA256 digest: " and the hex.
    public typealias SHA256Digest = CryptoKit.SHA256Digest
#else
    /// The 32 bytes of a SHA-256 digest.
    ///
    /// It iterates over its bytes in order, so `Array(digest)` is the bytes,
    /// and `description` is "SHA256 digest: " followed by the digest as
    /// lowercase hex, as CryptoKit's prints where that is the type.
    public struct SHA256Digest: Sequence, Equatable, Hashable, Sendable, CustomStringConvertible {
        /// The number of bytes in a digest: 32.
        public static let byteCount = 32

        let storage: DigestStorage<32>

        /// "SHA256 digest: " and 64 lowercase hex characters.
        public var description: String { "SHA256 digest: " + storage.hex }

        /// An iterator over the bytes in order, over a copy of them.
        public func makeIterator() -> IndexingIterator<[UInt8]> { storage.bytes.makeIterator() }
    }
#endif

/// Algorithms that are not secure against collisions. They are kept for
/// files made by the original, whose default is SHA-1; anything new should
/// use ``SHA256``.
public enum Insecure {
    /// SHA-1 (FIPS 180-4).
    ///
    /// Collisions have been published, so a digest is a fingerprint of data
    /// that is trusted already, not a defence against data made to match.
    /// 20 bytes, so the database's hash size is 20. Where CryptoKit exists
    /// the digest is CryptoKit's own, computed by it; elsewhere it is
    /// computed here. One shot only: there is no incremental update.
    public enum SHA1: Sendable, KeyHashing {
        /// The number of bytes in a digest: 20.
        public static let byteCount = 20

        /// 20.
        public static var size: Int { byteCount }

        /// The digest of `data`.
        ///
        /// The sequence is read once, in full, before the hashing starts, so
        /// a sequence that can be read only once is fine, and a large one
        /// costs its size in memory while it is hashed.
        public static func hash(data: some Sequence<UInt8>) -> Insecure.SHA1Digest {
            #if canImport(CryptoKit)
                if let array = data as? [UInt8] { return CryptoKit.Insecure.SHA1.hash(data: array) }
                return CryptoKit.Insecure.SHA1.hash(data: Array(data))
            #else
                return SHA1Digest(storage: PortableSHA1.hash(data))
            #endif
        }

        /// The digest of `bytes`: ``hash(data:)`` under the name
        /// `KeyHashing` asks for.
        public static func hash(_ bytes: some Collection<UInt8>) -> Insecure.SHA1Digest {
            hash(data: bytes)
        }
    }

    #if canImport(CryptoKit)
        /// The 20 bytes of a SHA-1 digest: CryptoKit's type, a sequence of
        /// its bytes that prints as "SHA1 digest: " and the hex.
        public typealias SHA1Digest = CryptoKit.Insecure.SHA1Digest
    #else
        /// The 20 bytes of a SHA-1 digest.
        ///
        /// It iterates over its bytes in order, so `Array(digest)` is the
        /// bytes, and `description` is "SHA1 digest: " followed by the digest
        /// as lowercase hex, as CryptoKit's prints where that is the type.
        public struct SHA1Digest: Sequence, Equatable, Hashable, Sendable, CustomStringConvertible {
            /// The number of bytes in a digest: 20.
            public static let byteCount = 20

            let storage: DigestStorage<20>

            /// "SHA1 digest: " and 40 lowercase hex characters.
            public var description: String { "SHA1 digest: " + storage.hex }

            /// An iterator over the bytes in order, over a copy of them.
            public func makeIterator() -> IndexingIterator<[UInt8]> { storage.bytes.makeIterator() }
        }
    #endif
}
