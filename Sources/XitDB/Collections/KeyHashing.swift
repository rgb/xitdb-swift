/// A hash function that turns a key's bytes into the hash a hash map stores
/// the key by.
///
/// The faithful collections take a hash and never compute one; a conformer
/// is what the store layer and a caller's own code compute it with. The
/// `XitDBHashing` target has SHA-256, SHA-1 and SipHash-128. ``size`` is the
/// number of bytes every digest has, and it must equal the database's hash
/// size, the one ``Database/init(creating:hashSize:hashID:fileID:)``
/// recorded: a store opened with a hash of another size refuses the
/// database with ``XitDBError/hashSizeMismatch`` before anything is read or
/// written. A hash of the wrong size given to a collection directly is
/// refused by that call. Two keys with the same digest name one entry, so a
/// hash that is not secure against collisions is for keys the caller
/// controls.
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
