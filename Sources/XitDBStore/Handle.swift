// A handle: a path from a moment's root, resolved when it is used.

public import XitDB

/// A place in a moment, named by the path from the moment's root: a key
/// through each map and an index through each list on the way.
///
/// A handle names a place, not a thing: it resolves its path when it is
/// used, so after the thing at the place was replaced, say by a join that
/// put another list there, the handle sees the new one, and a handle kept
/// across writes is never stale. In a writable moment every operation
/// resolves the path from the moment's element, the transaction's own
/// cursor, through the moment's map, which the moment's handles share while
/// the transaction's epoch holds; in a read-only moment, where nothing
/// moves, the handle keeps the cursor it resolved. Descending with the
/// subscripts, `handle[key]` and `handle[index:]`, treats the place as a
/// plain hash map or an array list and makes one if the place is empty;
/// through a counted map, a set or a linked list, descend from the typed
/// collection instead. The moment's root place is its map and takes no
/// value: ``set(_:)`` there is refused with `XitDBError.unexpectedTag`,
/// while ``clear()`` there empties the moment, which a write then makes a
/// map again. Writing through a handle of a read-only moment is refused
/// with `XitDBError.expectedTxStart`.
public struct Handle {
    let base: Root
    let hasher: KeyHasher
    let index: Int
    let steps: [Step]
    let cache: Cache
    /// The writable moment's shared cache; nil in a read-only moment, which
    /// has no use for it and no allocation.
    let shared: SharedCache?

    /// One level of the path.
    enum Step {
        /// Through a hash map, by the key's hash; `counted` says which kind
        /// to make if the place is empty.
        case key([UInt8], counted: Bool)
        /// Through an array list, by index, negative from the end.
        case index(Int)
    }

    /// The cursor a read-only handle resolved, kept for good: a read-only
    /// moment's bytes are committed, and nothing moves them.
    final class Cache {
        var resolved: (cursor: Cursor<ReadOnly>?, done: Bool) = (nil, false)
    }

    /// What every handle of a writable moment shares: the moment's own map,
    /// made from the moment's element, kept with the epoch it was made in.
    /// The map's root block is the transaction's own, so it stays where it is
    /// while its content changes, which the write paths read again; a freeze
    /// moves the epoch, and the map is made anew through the element, the
    /// transaction's cursor, which the engine lets go on after a freeze. The
    /// levels below, where a trie split moves an entry, resolve on every use.
    final class SharedCache {
        var map: (map: HashMap<ReadWrite>, epoch: Epoch)?
    }

    init(base: Root, hasher: KeyHasher, index: Int, steps: [Step], shared: SharedCache?) {
        self.base = base
        self.hasher = hasher
        self.index = index
        self.steps = steps
        self.shared = shared
        cache = Cache()
    }

    /// The handle one level down, through the hash map at this place, for
    /// a key.
    public subscript(key: some KeyRepresentable) -> Handle {
        self[key, counted: false]
    }

    /// The handle one level down through a hash map, plain or counted, which
    /// is made if the place is empty.
    subscript(key: some KeyRepresentable, counted counted: Bool) -> Handle {
        Handle(
            base: base, hasher: hasher, index: index, steps: steps + [.key(hasher.hash(key), counted: counted)],
            shared: shared)
    }

    /// The handle one level down, through the array list at this place, at
    /// an index, negative from the end. The label tells it from a key that
    /// is an integer: `handle[index: 0]` is the first element, `handle[0]`
    /// the entry for the key `0`.
    public subscript(index index: Int) -> Handle {
        Handle(base: base, hasher: hasher, index: self.index, steps: steps + [.index(index)], shared: shared)
    }

    // MARK: Resolving

    /// The cursor at this place for reading, or nil if a map or list on
    /// the way has no such entry.
    func read() throws(XitDBError) -> Cursor<ReadOnly>? {
        switch base {
        case .reading(let root):
            if cache.resolved.done { return cache.resolved.cursor }
            let cursor = try Self.resolve(from: root, steps)
            cache.resolved = (cursor, true)
            return cursor
        case .writing(let element):
            // The element's cursor keeps the slot it was made with; what is
            // there now is read from the storage.
            return try Self.resolve(from: try element.refreshed(), steps)
        }
    }

    private static func resolve(from root: Cursor<ReadOnly>, _ steps: [Step]) throws(XitDBError) -> Cursor<ReadOnly>? {
        var cursor = root
        for step in steps {
            let next: Cursor<ReadOnly>?
            switch step {
            case .key(let hash, _):
                switch try cursor.slot.tag {
                case .countedHashMap: next = try CountedHashMap<ReadOnly>(cursor).cursor(forHash: hash)
                default: next = try HashMap<ReadOnly>(cursor).cursor(forHash: hash)
                }
            case .index(let index):
                switch try cursor.slot.tag {
                case .linkedArrayList: next = try LinkedArrayList<ReadOnly>(cursor).cursor(at: index)
                default: next = try ArrayList<ReadOnly>(cursor).cursor(at: index)
                }
            }
            guard let next else { return nil }
            cursor = next
        }
        return cursor
    }

    /// The moment's map, for a writable moment whose element holds a plain
    /// hash map, as the transaction made it: the cached wrapper while the
    /// epoch holds, made anew through the element otherwise.
    private func momentMap(at element: Cursor<ReadWrite>) throws(XitDBError) -> HashMap<ReadWrite>? {
        let epoch = element.database.epoch
        if let cached = shared?.map, cached.epoch == epoch { return cached.map }
        switch try element.slot.tag {
        case .none, .hashMap:
            let map = try HashMap<ReadWrite>(element)
            shared?.map = (map, epoch)
            return map
        default:
            return nil
        }
    }

    /// The cursor at this place for writing, making the maps and lists on
    /// the way if they are empty; the moment's element itself for the root
    /// place.
    ///
    /// - Throws: `XitDBError.expectedTxStart` if the moment is read-only;
    ///   `XitDBError.indexOutOfRange` if an index on the way names no
    ///   element.
    func write() throws(XitDBError) -> Cursor<ReadWrite> {
        guard case .writing(let element) = base else { throw .expectedTxStart }
        // Down from the element, the transaction's own cursor, through the
        // moment's map, cached on the epoch; a write path reads its starting
        // slot again, so the cursors below come fresh.
        var cursor = element
        var remaining = steps[...]
        if case .key(let hash, _)? = remaining.first, let map = try momentMap(at: element) {
            cursor = try map.putCursor(forHash: hash)
            remaining = remaining.dropFirst()
        }
        for step in remaining {
            let tag = try cursor.slot.tag
            switch step {
            case .key(let hash, let counted):
                switch tag {
                case .countedHashMap: cursor = try CountedHashMap<ReadWrite>(cursor).putCursor(forHash: hash)
                case .none where counted: cursor = try CountedHashMap<ReadWrite>(cursor).putCursor(forHash: hash)
                default: cursor = try HashMap<ReadWrite>(cursor).putCursor(forHash: hash)
                }
            case .index(let index):
                switch tag {
                case .linkedArrayList: cursor = try LinkedArrayList<ReadWrite>(cursor).putCursor(at: index)
                default: cursor = try ArrayList<ReadWrite>(cursor).putCursor(at: index)
                }
            }
        }
        return cursor
    }

    // MARK: Elements

    /// Appends an empty element to the array list at this place, making the
    /// list if the place is empty, and gives the element's handle.
    func appendElement() throws(XitDBError) -> Handle {
        let list = try ArrayList<ReadWrite>(try write())
        _ = try list.appendCursor()
        return self[index: try exactInt(try list.count) - 1]
    }

    // MARK: Values

    /// The value at this place as `V`, or nil if there is nothing there or
    /// no entry on the way.
    ///
    /// - Throws: `XitDBError.unexpectedTag` if the place holds a value of
    ///   another kind.
    public func value<V: StorableValue>(_ type: V.Type = V.self) throws(XitDBError) -> V? {
        guard let cursor = try read(), try cursor.slot.tag != .none else { return nil }
        return try V(reading: cursor)
    }

    /// Writes a value at this place, in place of whatever was there.
    ///
    /// - Throws: `XitDBError.unexpectedTag` for the moment's root place,
    ///   which is its map and takes no value; `XitDBError.expectedTxStart` in
    ///   a read-only moment.
    public func set(_ value: some StorableValue) throws(XitDBError) {
        guard !steps.isEmpty else { throw .unexpectedTag }
        var cursor = try write()
        try value.write(to: &cursor)
    }

    /// Removes what is at this place: the place then holds nothing. At the
    /// moment's root place it empties the moment.
    ///
    /// - Throws: `XitDBError.expectedTxStart` in a read-only moment.
    public func clear() throws(XitDBError) {
        var cursor = try write()
        try cursor.write(.slot(nil))
        // The moment's map is gone with its root; the next write makes a new one.
        if steps.isEmpty { shared?.map = nil }
    }

    // MARK: Collections

    /// Makes an empty collection of a kind at this place, as the format's
    /// own init does: a place that holds nothing gets the collection, one
    /// that holds a collection of the kind keeps it as it is. The
    /// collections are otherwise made by their first write, so this is for
    /// one that must exist while it is empty, say a record's list with no
    /// elements yet.
    ///
    /// - Throws: `XitDBError.unexpectedTag` if the place holds a value or a
    ///   collection of another kind, or for any kind but ``CollectionKind/map``
    ///   at the moment's root place, which is its map;
    ///   `XitDBError.expectedTxStart` in a read-only moment.
    public func make(_ kind: CollectionKind) throws(XitDBError) {
        if steps.isEmpty, kind != .map { throw .unexpectedTag }
        let cursor = try write()
        switch kind {
        case .map: _ = try HashMap<ReadWrite>(cursor)
        case .countedMap: _ = try CountedHashMap<ReadWrite>(cursor)
        case .keySet: _ = try HashSet<ReadWrite>(cursor)
        case .countedKeySet: _ = try CountedHashSet<ReadWrite>(cursor)
        case .list: _ = try ArrayList<ReadWrite>(cursor)
        case .linkedList: _ = try LinkedArrayList<ReadWrite>(cursor)
        case .sortedMap: _ = try XitDB.SortedMap<ReadWrite>(cursor)
        case .sortedSet: _ = try XitDB.SortedSet<ReadWrite>(cursor)
        }
    }

    /// Whether something is at this place.
    public var exists: Bool {
        get throws(XitDBError) {
            guard let cursor = try read() else { return false }
            return try cursor.slot.tag != .none
        }
    }
}

/// The kinds of collection a place can hold, named as the store's types
/// are, for ``Handle/make(_:)``.
public enum CollectionKind: Sendable {
    /// A ``Map``.
    case map
    /// A ``CountedMap``.
    case countedMap
    /// A ``KeySet``.
    case keySet
    /// A ``CountedKeySet``.
    case countedKeySet
    /// A ``List``.
    case list
    /// A ``LinkedList``.
    case linkedList
    /// A ``SortedMap``.
    case sortedMap
    /// A ``SortedSet``.
    case sortedSet
}
