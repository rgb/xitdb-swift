// The hash maps over a handle: plain and counted.

public import XitDB

/// A hash map at a handle, keyed by `K` hashed with the store's hash, with
/// values of type `V`.
///
/// Two keys with one hash name one entry, as in the original; the keys
/// themselves are not stored, only their hashes, so the map gives back
/// values and not keys: for keys, see ``KeySet`` or keep the key in the
/// value. A read through a map that does not exist yet finds nothing; the
/// first write makes it. Reads are the subscript, which throws; writes are
/// ``put(_:forKey:)`` and ``remove(_:)``.
public struct Map<K: KeyRepresentable, V: StorableValue> {
    /// The handle the map stands on.
    public let handle: Handle

    func reading() throws(XitDBError) -> HashMap<ReadOnly>? {
        guard let cursor = try handle.read() else { return nil }
        return try HashMap<ReadOnly>(cursor)
    }

    func writing() throws(XitDBError) -> HashMap<ReadWrite> {
        try HashMap<ReadWrite>(try handle.write(as: .map))
    }

    /// The value for a key, or nil if there is none.
    ///
    /// - Throws: `XitDBError.unexpectedTag` if the place holds
    ///   something other than a hash map, or the entry a value of another
    ///   kind.
    public subscript(key: K) -> V? {
        get throws(XitDBError) {
            guard let cursor = try reading()?.cursor(forHash: handle.hasher.hash(key)) else { return nil }
            return try V(reading: cursor)
        }
    }

    /// Stores a value under a key, in place of any value that was there,
    /// making the map first if the place is empty.
    public func put(_ value: V, forKey key: K) throws(XitDBError) {
        var cursor = try writing().putCursor(forHash: handle.hasher.hash(key))
        try value.write(to: &cursor)
    }

    /// Removes the entry for a key; whether there was one.
    public func remove(_ key: K) throws(XitDBError) -> Bool {
        try writing().remove(forHash: handle.hasher.hash(key))
    }

    /// Whether the key has an entry.
    public func contains(_ key: K) throws(XitDBError) -> Bool {
        try reading()?.slot(forHash: handle.hasher.hash(key)) != nil
    }

    /// The handle one level down, for a nested collection under a key.
    public subscript(handleFor key: K) -> Handle {
        handle[key]
    }

    /// The values, in the order the map keeps its entries, which looks
    /// random.
    public func values() throws(XitDBError) -> ValueIterator<V> {
        ValueIterator(try reading()?.iterator()) { (entry) throws(XitDBError) in
            try V(reading: try entry.readEntry().value)
        }
    }
}

/// A hash map that keeps its count: ``Map`` with ``count``.
///
/// What ``Map`` says holds here too; the count costs one extra write per
/// insertion and removal.
public struct CountedMap<K: KeyRepresentable, V: StorableValue> {
    /// The handle the map stands on.
    public let handle: Handle

    func reading() throws(XitDBError) -> CountedHashMap<ReadOnly>? {
        guard let cursor = try handle.read() else { return nil }
        return try CountedHashMap<ReadOnly>(cursor)
    }

    func writing() throws(XitDBError) -> CountedHashMap<ReadWrite> {
        try CountedHashMap<ReadWrite>(try handle.write(as: .countedMap))
    }

    /// How many entries the map has; zero if it does not exist yet.
    public var count: Int {
        get throws(XitDBError) {
            try exactInt(try reading()?.count ?? 0)
        }
    }

    /// The value for a key, or nil if there is none.
    public subscript(key: K) -> V? {
        get throws(XitDBError) {
            guard let cursor = try reading()?.cursor(forHash: handle.hasher.hash(key)) else { return nil }
            return try V(reading: cursor)
        }
    }

    /// Stores a value under a key, in place of any value that was there,
    /// making the map first if the place is empty.
    public func put(_ value: V, forKey key: K) throws(XitDBError) {
        var cursor = try writing().putCursor(forHash: handle.hasher.hash(key))
        try value.write(to: &cursor)
    }

    /// Removes the entry for a key; whether there was one.
    public func remove(_ key: K) throws(XitDBError) -> Bool {
        try writing().remove(forHash: handle.hasher.hash(key))
    }

    /// Whether the key has an entry.
    public func contains(_ key: K) throws(XitDBError) -> Bool {
        try reading()?.slot(forHash: handle.hasher.hash(key)) != nil
    }

    /// The handle one level down, for a nested collection under a key; the
    /// counted map is made if the place is empty.
    public subscript(handleFor key: K) -> Handle {
        handle[key, counted: true]
    }

    /// The values, in the order the map keeps its entries.
    public func values() throws(XitDBError) -> ValueIterator<V> {
        ValueIterator(try reading()?.iterator()) { (entry) throws(XitDBError) in
            try V(reading: try entry.readEntry().value)
        }
    }
}
