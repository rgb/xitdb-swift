/// A hash function that turns a key's bytes into the hash a hash map stores
/// the key by.
///
/// XitDB hashes nothing by itself. A database is given a conformer when it
/// is made, with ``Database/init(creating:hashing:hashID:fileID:)`` or
/// ``Database/init(opening:hashing:)``, and its snapshots and the target of
/// a compaction take the conformer from it; a database made without one
/// takes hashes alone, which its caller computes with a conformer or in any
/// other way. The `XitDBHashing` target has SHA-256, SHA-1 and SipHash-128.
///
/// ``size`` is the number of bytes every digest has. It is the hash size of
/// a database created with the conformer, and a database of another hash
/// size is refused with ``XitDBError/hashSizeMismatch`` when it is opened
/// with it, before anything but its header is read. A hash of the wrong
/// size given to a collection directly is refused by that call. Two keys
/// with the same digest name one entry, so a hash that is not secure
/// against collisions is for keys the caller controls.
public protocol KeyHashing: Sendable {
    /// What ``hash(_:)`` returns: the digest's bytes, ``size`` of them, in
    /// order.
    associatedtype Digest: Sequence<UInt8>

    /// The number of bytes in every digest, and the hash size a database
    /// must have for this hash.
    static var size: Int { get }

    /// The digest of `bytes`.
    static func hash(_ bytes: some Collection<UInt8>) -> Digest
}

/// The hasher a database was given, as a value: its size, and the hash of
/// a key's bytes. The hashing is captured from the type while the type is
/// known, so that the database, its snapshots and its cursors hold one
/// value and no type parameter.
package struct KeyHasher: Sendable {
    /// The number of bytes in every hash: the conformer's
    /// ``KeyHashing/size``.
    package let size: Int

    private let digest: @Sendable ([UInt8]) -> KeyHash

    /// The hasher of a conformer.
    package init<Hashing: KeyHashing>(_ type: Hashing.Type) {
        size = Hashing.size
        digest = { (bytes: [UInt8]) in KeyHash(Array(Hashing.hash(bytes))) }
    }

    /// The hash of a key's bytes: what the conformer's digest holds, which
    /// is ``size`` bytes for a conformer that keeps its word.
    package func hash(_ bytes: [UInt8]) -> KeyHash {
        digest(bytes)
    }
}
