// A handle: a path from a moment's root, resolved when it is used.

public import XitDB

/// A place in a moment, named by the path from the moment's root: a key
/// through each map and an index through each list on the way.
///
/// A handle names a place, not a thing: it resolves its path when it is
/// used, so after the thing at the place was replaced, say by a join that
/// put another list there, the handle sees the new one, and a handle kept
/// across writes is never stale. In a writable moment every operation
/// resolves the path from the transaction's cursor, the moment's element
/// first; in a read-only moment, where nothing
/// moves, the handle keeps the cursor it resolved. Descending with the
/// subscripts, `handle[key]` and `handle[index:]`, treats the place as a
/// plain hash map or an array list and makes one if the place is empty; through a counted map, a set or a
/// linked list, descend from the typed collection instead. Writing through
/// a handle of a read-only moment is refused with
/// `XitDBError.expectedTxStart`.
public struct Handle {
    let base: Root
    let hasher: KeyHasher
    let index: Int
    let steps: [Step]
    let cache: Cache

    /// One level of the path.
    enum Step {
        /// Through a hash map, by the key's hash.
        case key([UInt8])
        /// Through an array list, by index, negative from the end.
        case index(Int)
    }

    /// The cursor a read-only handle resolved, kept while the database's
    /// epoch holds; a snapshot's never changes.
    final class Cache {
        var resolved: (cursor: Cursor<ReadOnly>?, epoch: Epoch?)?
    }

    init(base: Root, hasher: KeyHasher, index: Int, steps: [Step]) {
        self.base = base
        self.hasher = hasher
        self.index = index
        self.steps = steps
        cache = Cache()
    }

    /// The handle one level down, through the hash map at this place, for
    /// a key.
    public subscript(key: some KeyRepresentable) -> Handle {
        Handle(base: base, hasher: hasher, index: index, steps: steps + [.key(hasher.hash(key))])
    }

    /// The handle one level down, through the array list at this place, at
    /// an index, negative from the end. The label tells it from a key that
    /// is an integer: `handle[index: 0]` is the first element, `handle[0]`
    /// the entry for the key `0`.
    public subscript(index index: Int) -> Handle {
        Handle(base: base, hasher: hasher, index: self.index, steps: steps + [.index(index)])
    }

    // MARK: Resolving

    /// The cursor at this place for reading, or nil if a map or list on
    /// the way has no such entry.
    func read() throws(XitDBError) -> Cursor<ReadOnly>? {
        if case .reading(let root) = base {
            let epoch = (root.database as? Database)?.epoch
            if let resolved = cache.resolved, resolved.epoch == epoch { return resolved.cursor }
            let cursor = try Self.resolve(from: root, steps)
            cache.resolved = (cursor, epoch)
            return cursor
        }
        guard case .writing(let root) = base else { return nil }
        // The transaction's cursor keeps the slot it was made with; what is
        // there now is read from the storage, then the moment's element.
        guard let element = try ArrayList<ReadOnly>(try root.refreshed()).cursor(at: index) else { return nil }
        return try Self.resolve(from: element, steps)
    }

    private static func resolve(from root: Cursor<ReadOnly>, _ steps: [Step]) throws(XitDBError) -> Cursor<ReadOnly>? {
        var cursor = root
        for step in steps {
            let next: Cursor<ReadOnly>?
            switch step {
            case .key(let hash):
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

    /// The cursor at this place for writing, making the maps and lists on
    /// the way if they are empty.
    ///
    /// - Throws: `XitDBError.expectedTxStart` if the moment is
    ///   read-only; `XitDBError.indexOutOfRange` if an index on the
    ///   way names no element.
    func write() throws(XitDBError) -> Cursor<ReadWrite> {
        guard case .writing(let root) = base else { throw .expectedTxStart }
        // Down from the transaction's own cursor, the one the engine lets go
        // on after a freeze, to the moment's element: a write path reads its
        // starting slot again, so the cursors below come fresh.
        var cursor = try ArrayList<ReadWrite>(root).putCursor(at: index)
        for step in steps {
            let tag = try cursor.slot.tag
            switch step {
            case .key(let hash):
                switch tag {
                case .countedHashMap: cursor = try CountedHashMap<ReadWrite>(cursor).putCursor(forHash: hash)
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

    // MARK: Values

    /// The value at this place as `V`, or nil if there is nothing there or
    /// no entry on the way.
    ///
    /// - Throws: `XitDBError.unexpectedTag` if the place holds a
    ///   value of another kind.
    public func value<V: StorableValue>(_ type: V.Type = V.self) throws(XitDBError) -> V? {
        guard let cursor = try read(), try cursor.slot.tag != .none else { return nil }
        return try V(reading: cursor)
    }

    /// Writes a value at this place, in place of whatever was there.
    public func set(_ value: some StorableValue) throws(XitDBError) {
        var cursor = try write()
        try value.write(to: &cursor)
    }

    /// Removes what is at this place: the place then holds nothing.
    public func clear() throws(XitDBError) {
        var cursor = try write()
        try cursor.write(.slot(nil))
    }

    /// Whether something is at this place.
    public var exists: Bool {
        get throws(XitDBError) {
            guard let cursor = try read() else { return false }
            return try cursor.slot.tag != .none
        }
    }
}
