// The hash sets over a handle, which store their keys: plain and counted.

public import XitDB

/// A hash set of keys at a handle: each key is stored as its bytes under
/// its hash, so the keys come back.
///
/// Two keys with one hash are one member, as in the original. Reading a
/// set that does not exist yet finds nothing; the first insertion makes
/// it.
public struct KeySet<K: KeyRepresentable> {
    /// The handle the set stands on.
    public let handle: Handle

    func reading() throws(XitDBError) -> HashSet<ReadOnly>? {
        guard let cursor = try handle.read() else { return nil }
        return try HashSet<ReadOnly>(cursor)
    }

    func writing() throws(XitDBError) -> HashSet<ReadWrite> {
        try HashSet<ReadWrite>(try handle.write())
    }

    /// Adds a key, making the set first if the place is empty; a key that
    /// is there already stays as it is.
    public func insert(_ key: K) throws(XitDBError) {
        try writing().insert(.bytes(key.keyBytes), forHash: handle.hasher.hash(key))
    }

    /// Removes a key; whether it was there.
    public func remove(_ key: K) throws(XitDBError) -> Bool {
        try writing().remove(forHash: handle.hasher.hash(key))
    }

    /// Whether the key is a member.
    public func contains(_ key: K) throws(XitDBError) -> Bool {
        try reading()?.contains(hash: handle.hasher.hash(key)) ?? false
    }

    /// The keys, in the order the set keeps them, which looks random.
    ///
    /// - Throws: `XitDBError.unexpectedTag` from `next()` for a
    ///   stored key that is no value of `K`.
    public func keys() throws(XitDBError) -> ValueIterator<K> {
        ValueIterator(try reading()?.iterator(), read: decodeKey)
    }
}

/// A hash set of keys that keeps its count: ``KeySet`` with ``count``.
public struct CountedKeySet<K: KeyRepresentable> {
    /// The handle the set stands on.
    public let handle: Handle

    func reading() throws(XitDBError) -> CountedHashSet<ReadOnly>? {
        guard let cursor = try handle.read() else { return nil }
        return try CountedHashSet<ReadOnly>(cursor)
    }

    func writing() throws(XitDBError) -> CountedHashSet<ReadWrite> {
        try CountedHashSet<ReadWrite>(try handle.write())
    }

    /// How many keys the set has; zero if it does not exist yet.
    public var count: Int {
        get throws(XitDBError) {
            try exactInt(try reading()?.count ?? 0)
        }
    }

    /// Adds a key, making the set first if the place is empty.
    public func insert(_ key: K) throws(XitDBError) {
        try writing().insert(.bytes(key.keyBytes), forHash: handle.hasher.hash(key))
    }

    /// Removes a key; whether it was there.
    public func remove(_ key: K) throws(XitDBError) -> Bool {
        try writing().remove(forHash: handle.hasher.hash(key))
    }

    /// Whether the key is a member.
    public func contains(_ key: K) throws(XitDBError) -> Bool {
        try reading()?.contains(hash: handle.hasher.hash(key)) ?? false
    }

    /// The keys, in the order the set keeps them.
    public func keys() throws(XitDBError) -> ValueIterator<K> {
        ValueIterator(try reading()?.iterator(), read: decodeKey)
    }
}

/// The key a set's or a sorted collection's entry stores, as `K`.
///
/// - Throws: `XitDBError.unexpectedTag` for stored bytes that are
///   no value of `K`.
func decodeKey<K: KeyRepresentable>(_ entry: Cursor<ReadOnly>) throws(XitDBError) -> K {
    guard let key = K(keyBytes: try entry.readEntry().key.readBytes()) else { throw .unexpectedTag }
    return key
}
