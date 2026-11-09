// The sorted collections over a handle: keys as their bytes, in byte order.

public import XitDB

/// A sorted map at a handle: keys stored as their bytes and ordered by
/// them, with values of type `V`.
///
/// The keys come back, in order; ``rank(of:)`` and ``entry(at:)`` work by
/// position. Reading a map that does not exist yet finds nothing; the
/// first write makes it.
public struct SortedMap<K: KeyRepresentable, V: StorableValue> {
    /// The handle the map stands on.
    public let handle: Handle

    func reading() throws(XitDBError) -> XitDB.SortedMap<ReadOnly>? {
        guard let cursor = try handle.read() else { return nil }
        return try XitDB.SortedMap<ReadOnly>(cursor)
    }

    func writing() throws(XitDBError) -> XitDB.SortedMap<ReadWrite> {
        try XitDB.SortedMap<ReadWrite>(try handle.write())
    }

    /// How many entries the map has.
    public var count: Int {
        get throws(XitDBError) {
            try exactInt(try reading()?.count ?? 0)
        }
    }

    /// The value for a key, or nil if there is none.
    public subscript(key: K) -> V? {
        get throws(XitDBError) {
            guard let cursor = try reading()?.cursor(forKey: key.keyBytes) else { return nil }
            return try V(reading: cursor)
        }
    }

    /// Stores a value under a key, in place of any value that was there.
    public func put(_ value: V, forKey key: K) throws(XitDBError) {
        var cursor = try writing().putCursor(forKey: key.keyBytes)
        try value.write(to: &cursor)
    }

    /// Removes the entry for a key; whether there was one.
    public func remove(_ key: K) throws(XitDBError) -> Bool {
        try writing().remove(forKey: key.keyBytes)
    }

    /// Whether the key has an entry.
    public func contains(_ key: K) throws(XitDBError) -> Bool {
        try reading()?.slot(forKey: key.keyBytes) != nil
    }

    /// How many keys order before this one.
    public func rank(of key: K) throws(XitDBError) -> Int {
        try exactInt(try reading()?.rank(of: key.keyBytes) ?? 0)
    }

    /// The entry at a position in key order, negative from the end, or nil
    /// past either end.
    public func entry(at index: Int) throws(XitDBError) -> Entry<K, V>? {
        guard let entry = try reading()?.entry(at: index) else { return nil }
        return try Self.decode(entry)
    }

    /// The entries in key order, from the first key that is not before
    /// `key`, or all of them.
    public func entries(from key: K? = nil) throws(XitDBError) -> ValueIterator<Entry<K, V>> {
        let base: CollectionIterator?
        if let key {
            base = try reading()?.iterator(fromKey: key.keyBytes)
        } else {
            base = try reading()?.iterator()
        }
        return ValueIterator(base) { (cursor) throws(XitDBError) in try Self.decode(try cursor.readEntry()) }
    }

    private static func decode(_ entry: XitDB.Entry) throws(XitDBError) -> Entry<K, V> {
        guard let key = K(keyBytes: try entry.key.readBytes()) else { throw .unexpectedTag }
        return Entry(key: key, value: try V(reading: entry.value))
    }
}

/// A sorted set at a handle: keys stored as their bytes and ordered by
/// them.
///
/// Reading a set that does not exist yet finds nothing; the first
/// insertion makes it.
public struct SortedSet<K: KeyRepresentable> {
    /// The handle the set stands on.
    public let handle: Handle

    func reading() throws(XitDBError) -> XitDB.SortedSet<ReadOnly>? {
        guard let cursor = try handle.read() else { return nil }
        return try XitDB.SortedSet<ReadOnly>(cursor)
    }

    func writing() throws(XitDBError) -> XitDB.SortedSet<ReadWrite> {
        try XitDB.SortedSet<ReadWrite>(try handle.write())
    }

    /// How many keys the set has.
    public var count: Int {
        get throws(XitDBError) {
            try exactInt(try reading()?.count ?? 0)
        }
    }

    /// Adds a key; one that is there already stays.
    public func insert(_ key: K) throws(XitDBError) {
        try writing().insert(key.keyBytes)
    }

    /// Removes a key; whether it was there.
    public func remove(_ key: K) throws(XitDBError) -> Bool {
        try writing().remove(forKey: key.keyBytes)
    }

    /// Whether the key is a member.
    public func contains(_ key: K) throws(XitDBError) -> Bool {
        try reading()?.contains(key.keyBytes) ?? false
    }

    /// How many keys order before this one.
    public func rank(of key: K) throws(XitDBError) -> Int {
        try exactInt(try reading()?.rank(of: key.keyBytes) ?? 0)
    }

    /// The key at a position in order, negative from the end, or nil past
    /// either end.
    public func key(at index: Int) throws(XitDBError) -> K? {
        guard let entry = try reading()?.entry(at: index) else { return nil }
        guard let key = K(keyBytes: try entry.key.readBytes()) else { throw .unexpectedTag }
        return key
    }

    /// The keys in order, from the first that is not before `key`, or all
    /// of them.
    public func keys(from key: K? = nil) throws(XitDBError) -> ValueIterator<K> {
        let base: CollectionIterator?
        if let key {
            base = try reading()?.iterator(fromKey: key.keyBytes)
        } else {
            base = try reading()?.iterator()
        }
        return ValueIterator(base, read: decodeKey)
    }
}
