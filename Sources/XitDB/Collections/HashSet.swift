/// A hash set in a database.
///
/// A set holds keys, each under its hash. Every call comes in two kinds.
/// The calls that take a key, a string or bytes or anything
/// ``KeyRepresentable``, hash it with the hasher the database was given,
/// and ``insert(_:)`` stores the key's bytes as the member. The calls with
/// a hash take one the caller made, with a hasher's
/// ``KeyHashing/keyHash(of:)`` or with any function whose result has as
/// many bytes as the database's hash size, and work on every database;
/// ``insert(_:forHash:)-(_,Span<UInt8>)`` takes the key to store beside the
/// hash as well. A keyed call is its call by hash with the key hashed. Two
/// keys with the same hash are the same key to the set.
///
/// A set is a view of a slot. Making one that can only read checks that
/// the slot holds a set of this kind, or nothing. Making one that can
/// write makes the slot a set if it holds nothing, and readies it for
/// this transaction's writes.
///
/// Writing needs a transaction: see ``Database/withTransaction(_:)``. A set at
/// the root of the database is the exception: there, every write is a
/// transaction of its own.
///
/// **What the calls throw.** A call that reads throws
/// ``XitDBError/unexpectedTag`` if the slot holds something other than a hash
/// map or set, ``XitDBError/staleCursor`` if the set is not at the root and its
/// cursor is from a transaction that did not commit, or an error of the storage
/// or of a damaged file. A call that writes throws
/// ``XitDBError/expectedTxStart`` if the set's cursor is not the root cursor
/// and no transaction is in progress, ``XitDBError/nestedTopLevelWrite`` if it
/// is the root cursor and one is, ``XitDBError/staleCursor`` if it is from
/// before the last freeze of this transaction or from an earlier transaction,
/// ``XitDBError/poisonedTransaction`` if an earlier operation of the
/// transaction failed after writing, ``XitDBError/unexpectedTag`` if the slot
/// no longer holds a hash map or set, or an error of the storage or of a
/// damaged file. A call that takes a hash throws ``XitDBError/invalidHashSize``
/// as well, if the hash does not have as many bytes as the database's hash
/// size; a read checks that once the slot holds a map or set, since a slot that
/// holds nothing checks no hash and has no entry for it, as in the original. A
/// call that takes a key throws ``XitDBError/noKeyHashing`` before anything
/// else is looked at, if the database was given no hasher. A call's own comment
/// says what it throws beyond these.
public struct HashSet<Access: CursorAccess> {
    /// The cursor at the slot that holds the set.
    public let cursor: Cursor<Access>

    /// The slot that holds the set.
    ///
    /// - Throws: Only for a set at the root of the database, if the root
    ///   cannot be read.
    public var slot: Slot {
        get throws(XitDBError) {
            try cursor.slot
        }
    }

    /// An iterator over the set's entries. Each cursor it gives is at an
    /// entry; ``Cursor/readEntry()`` reads the entry's key.
    ///
    /// The order is that of the hashes' last bits, which has nothing to do
    /// with the order of insertion.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something that
    ///   is not a collection, ``XitDBError/staleCursor`` if the set is not at
    ///   the root and its cursor is from a transaction that did not commit, or
    ///   an error of the storage or of a damaged file.
    public func iterator() throws(XitDBError) -> CollectionIterator {
        try cursor.iterator()
    }

    /// A cursor at the key stored under a hash, or `nil` if the set has no
    /// entry for it or the entry's key was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: What a read by hash throws: see ``HashSet``.
    public func cursor(forHash hash: Span<UInt8>) throws(XitDBError) -> Cursor<ReadOnly>? {
        try cursor(forHash: KeyHash(hash))
    }

    /// ``cursor(forHash:)-(Span<UInt8>)`` for a hash held as any sequence of
    /// bytes: an array, a digest, a slice. Anything but an array is copied
    /// once.
    @inlinable
    public func cursor(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Cursor<ReadOnly>? {
        let bytes = Array(hash)
        return try cursor(forHash: bytes.span)
    }

    /// A cursor at a key of the set, or `nil` if the set does not have it.
    ///
    /// The key is hashed by the hasher the database was given, and this is
    /// ``cursor(forHash:)-(Span<UInt8>)`` with that hash.
    ///
    /// - Parameter key: The key.
    /// - Throws: ``XitDBError/noKeyHashing`` if the database was given no
    ///   hasher, before anything else is looked at, and what
    ///   ``cursor(forHash:)-(Span<UInt8>)`` throws.
    public func cursor(forKey key: some KeyRepresentable) throws(XitDBError) -> Cursor<ReadOnly>? {
        try cursor(forHash: try cursor.keyHash(of: key))
    }

    /// The slot of the key stored under a hash, or `nil` if the set has no
    /// entry for it or the entry's key was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: What a read by hash throws: see ``HashSet``.
    public func slot(forHash hash: Span<UInt8>) throws(XitDBError) -> Slot? {
        try slot(forHash: KeyHash(hash))
    }

    /// ``slot(forHash:)-(Span<UInt8>)`` for a hash held as any sequence of
    /// bytes: an array, a digest, a slice. Anything but an array is copied
    /// once.
    @inlinable
    public func slot(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Slot? {
        let bytes = Array(hash)
        return try slot(forHash: bytes.span)
    }

    /// The slot of a key of the set, or `nil` if the set does not have it.
    ///
    /// The key is hashed by the hasher the database was given, and this is
    /// ``slot(forHash:)-(Span<UInt8>)`` with that hash.
    ///
    /// - Parameter key: The key.
    /// - Throws: ``XitDBError/noKeyHashing`` if the database was given no
    ///   hasher, before anything else is looked at, and what
    ///   ``slot(forHash:)-(Span<UInt8>)`` throws.
    public func slot(forKey key: some KeyRepresentable) throws(XitDBError) -> Slot? {
        try slot(forHash: try cursor.keyHash(of: key))
    }

    /// Whether a key is stored under a hash.
    ///
    /// An entry whose key was never written, from
    /// ``insertCursor(forHash:)-(Sequence<UInt8>)`` with nothing written through
    /// the cursor, does not count.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: What a read by hash throws: see ``HashSet``.
    public func contains(hash: Span<UInt8>) throws(XitDBError) -> Bool {
        try contains(hash: KeyHash(hash))
    }

    /// ``contains(hash:)-(Span<UInt8>)`` for a hash held as any sequence of
    /// bytes: an array, a digest, a slice. Anything but an array is copied
    /// once.
    @inlinable
    public func contains(hash: some Sequence<UInt8>) throws(XitDBError) -> Bool {
        let bytes = Array(hash)
        return try contains(hash: bytes.span)
    }

    /// Whether the set has a key.
    ///
    /// An entry whose key was never written, from ``insertCursor(forKey:)``
    /// with nothing written through the cursor, does not count.
    ///
    /// The key is hashed by the hasher the database was given, and this is
    /// ``contains(hash:)-(Span<UInt8>)`` with that hash.
    ///
    /// - Parameter key: The key.
    /// - Throws: ``XitDBError/noKeyHashing`` if the database was given no
    ///   hasher, before anything else is looked at, and what
    ///   ``contains(hash:)-(Span<UInt8>)`` throws.
    public func contains(_ key: some KeyRepresentable) throws(XitDBError) -> Bool {
        try contains(hash: try cursor.keyHash(of: key))
    }

}

extension HashSet where Access == ReadOnly {
    /// A view of the set at a cursor's slot, for reading.
    ///
    /// A slot that holds nothing is an empty set.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a hash map or set that keeps no count.
    public init(_ cursor: Cursor<ReadOnly>) throws(XitDBError) {
        switch try cursor.resolved().slot.tag {
        case .none, .hashMap, .hashSet:
            self.cursor = cursor
        default:
            throw .unexpectedTag
        }
    }

    /// A view of the set at a cursor's slot, for reading, from a cursor of
    /// either access: one that can write is read through as its
    /// ``Cursor/readOnly``, so that a reader need not take it first.
    ///
    /// A slot that holds nothing is an empty set.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a hash map or set that keeps no count.
    public init(_ cursor: Cursor<some CursorAccess>) throws(XitDBError) {
        try self.init(Cursor<ReadOnly>(viewing: cursor))
    }
}

extension HashSet where Access == ReadWrite {
    /// A view of the set at a cursor's slot, for reading and writing.
    ///
    /// A slot that holds nothing becomes an empty set. A set from an
    /// earlier transaction is readied for this one: its first block is
    /// copied, so that writing to it leaves earlier moments as they were.
    ///
    /// **A hash map becomes a hash set.** A map and a set that keep no
    /// count are one kind to the slot, as in the original: the slot's tag
    /// is written as a set and the entries stay, values included, though a
    /// set reads only their keys. On the root, where this is a transaction
    /// of its own, a map is a set from then on; a map is opened with
    /// ``HashMap``.
    ///
    /// On the root cursor this is a transaction of its own, unless the root
    /// is such a set already, in which case nothing is written.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something other
    ///   than a hash map or set that keeps no count,
    ///   ``XitDBError/expectedTxStart`` if no transaction is in progress and
    ///   `cursor` is not the root cursor, ``XitDBError/nestedTopLevelWrite`` if
    ///   `cursor` is the root cursor and one is,
    ///   ``XitDBError/cursorNotWritable`` if `cursor` has no position, as the
    ///   key cursor of a sorted map's entry has not, ``XitDBError/staleCursor``
    ///   if `cursor` is from an earlier transaction, or from before the last
    ///   freeze or join of this one unless it is at the slot of the
    ///   transaction's cursor,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, or an error of the storage or of a
    ///   damaged file.
    public init(_ cursor: Cursor<ReadWrite>) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.hashMapInit(counted: false, set: true)]
        self.cursor = try cursor.writePath(path.span)
    }

    /// A view of the same set that can only read.
    public var readOnly: HashSet<ReadOnly> {
        HashSet<ReadOnly>(unchecked: cursor.readOnly)
    }

    /// Adds a key to the set under its hash. If the set already has a key
    /// under that hash, nothing is changed.
    ///
    /// - Parameters:
    ///   - key: The key.
    ///   - hash: The key's hash, as many bytes as the database's hash size.
    /// - Throws: What a write by hash throws: see ``HashSet``.
    public func insert(_ key: WritableData, forHash hash: Span<UInt8>) throws(XitDBError) {
        try insert(key, forHash: KeyHash(hash))
    }

    /// ``insert(_:forHash:)-(_,Span<UInt8>)`` for a hash held as any sequence
    /// of bytes: an array, a digest, a slice. Anything but an array is copied
    /// once.
    @inlinable
    public func insert(_ key: WritableData, forHash hash: some Sequence<UInt8>) throws(XitDBError) {
        let bytes = Array(hash)
        try insert(key, forHash: bytes.span)
    }

    /// Adds a key to the set. If the set already has it, nothing is changed.
    ///
    /// The member of a set is its key, so the key's bytes are written, as a
    /// byte array, and with them the format tag of a ``Bytes`` key that has
    /// one. The key is hashed by the hasher the database was given, and this
    /// is ``insert(_:forHash:)-(_,Span<UInt8>)`` with those bytes and that
    /// hash.
    ///
    /// - Parameter key: The key.
    /// - Throws: ``XitDBError/noKeyHashing`` if the database was given no
    ///   hasher, before anything else is looked at, and what
    ///   ``insert(_:forHash:)-(_,Span<UInt8>)`` throws.
    public func insert(_ key: some KeyRepresentable) throws(XitDBError) {
        // The key's bytes are asked for once: they are hashed, and they
        // are the member that is stored.
        let stored = try cursor.keyHashAndData(of: key)
        try insert(stored.data, forHash: stored.hash)
    }

    /// A cursor at the key stored under a hash, for writing it. The set
    /// gets an entry for the hash if it has none.
    ///
    /// Use it in a transaction. On a collection at the root the call is a
    /// transaction of its own, committed by the time it returns, so a new
    /// entry holds nothing and a write through the cursor throws
    /// ``XitDBError/expectedTxStart``.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: What a write by hash throws: see ``HashSet``.
    public func insertCursor(forHash hash: Span<UInt8>) throws(XitDBError) -> Cursor<ReadWrite> {
        try insertCursor(forHash: KeyHash(hash))
    }

    /// ``insertCursor(forHash:)-(Span<UInt8>)`` for a hash held as any sequence
    /// of bytes: an array, a digest, a slice. Anything but an array is copied
    /// once.
    @inlinable
    public func insertCursor(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Cursor<ReadWrite> {
        let bytes = Array(hash)
        return try insertCursor(forHash: bytes.span)
    }

    /// A cursor at a key of the set, for writing it. The set gets an entry for
    /// the key if it has none, and nothing is written there until the cursor
    /// writes.
    ///
    /// Use it in a transaction. On a collection at the root the call is a
    /// transaction of its own, committed by the time it returns, so a new entry
    /// holds nothing and a write through the cursor throws
    /// ``XitDBError/expectedTxStart``.
    ///
    /// The key is hashed by the hasher the database was given, and this is
    /// ``insertCursor(forHash:)-(Span<UInt8>)`` with that hash.
    ///
    /// - Parameter key: The key.
    /// - Throws: ``XitDBError/noKeyHashing`` if the database was given no
    ///   hasher, before anything else is looked at, and what
    ///   ``insertCursor(forHash:)-(Span<UInt8>)`` throws.
    public func insertCursor(forKey key: some KeyRepresentable) throws(XitDBError) -> Cursor<ReadWrite> {
        try insertCursor(forHash: try cursor.keyHash(of: key))
    }

    /// Removes the entry stored under a hash.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Returns: Whether there was an entry to remove.
    /// - Throws: What a write by hash throws: see ``HashSet``.
    @discardableResult
    public func remove(forHash hash: Span<UInt8>) throws(XitDBError) -> Bool {
        try remove(forHash: KeyHash(hash))
    }

    /// ``remove(forHash:)-(Span<UInt8>)`` for a hash held as any sequence of
    /// bytes: an array, a digest, a slice. Anything but an array is copied
    /// once.
    @discardableResult
    @inlinable
    public func remove(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Bool {
        let bytes = Array(hash)
        return try remove(forHash: bytes.span)
    }

    /// Removes a key from the set.
    ///
    /// The key is hashed by the hasher the database was given, and this is
    /// ``remove(forHash:)-(Span<UInt8>)`` with that hash.
    ///
    /// - Parameter key: The key.
    /// - Returns: Whether there was such a key to remove.
    /// - Throws: ``XitDBError/noKeyHashing`` if the database was given no
    ///   hasher, before anything else is looked at, and what
    ///   ``remove(forHash:)-(Span<UInt8>)`` throws.
    @discardableResult
    public func remove(forKey key: some KeyRepresentable) throws(XitDBError) -> Bool {
        try remove(forHash: try cursor.keyHash(of: key))
    }

}

extension HashSet {
    /// A view of the set at a cursor's slot, which the caller has made
    /// sure holds one.
    init(unchecked cursor: Cursor<Access>) {
        self.cursor = cursor
    }
}

extension HashSet {
    /// The call by a hash the engine holds already: what the forms of `cursor`
    /// by a `Span` and by a key both come to.
    func cursor(forHash hash: KeyHash) throws(XitDBError) -> Cursor<ReadOnly>? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, hash)]
        return try cursor.readPath(path.span)
    }

    /// The call by a hash the engine holds already: what the forms of `slot` by
    /// a `Span` and by a key both come to.
    func slot(forHash hash: KeyHash) throws(XitDBError) -> Slot? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, hash)]
        return try cursor.readPathSlot(path.span)
    }

    /// The call by a hash the engine holds already: what the forms of
    /// `contains` by a `Span` and by a key both come to.
    func contains(hash: KeyHash) throws(XitDBError) -> Bool {
        try slot(forHash: hash) != nil
    }
}

extension HashSet where Access == ReadWrite {
    /// The call by a hash the engine holds already: what the forms of `insert`
    /// by a `Span` and by a key both come to.
    func insert(_ key: WritableData, forHash hash: KeyHash) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.hashMapGet(.key, hash), .ctx]
        // The key is written inside the callback, so it is not a part of
        // the path: check it here, after the cursor's checks and before the
        // entry is made, as a write part would be checked.
        try cursor.checkWritable(path.span)
        try key.checkIsValue()
        _ = try cursor.writePath(
            path.span,
            typed: { (keyCursor: inout Cursor<ReadWrite>) throws(XitDBError) in
                try keyCursor.writeIfEmpty(key)
            })
    }

    /// The call by a hash the engine holds already: what the forms of
    /// `insertCursor` by a `Span` and by a key both come to.
    func insertCursor(forHash hash: KeyHash) throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, hash)]
        return try cursor.writePath(path.span)
    }

    /// The call by a hash the engine holds already: what the forms of `remove`
    /// by a `Span` and by a key both come to.
    @discardableResult
    func remove(forHash hash: KeyHash) throws(XitDBError) -> Bool {
        let path: InlineArray<1, PathPart> = [.hashMapRemove(hash)]
        do throws(XitDBError) {
            _ = try cursor.writePath(path.span)
        } catch {
            guard error == .keyNotFound else { throw error }
            return false
        }
        return true
    }
}
