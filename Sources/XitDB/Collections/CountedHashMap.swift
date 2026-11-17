/// A counted hash map in a database.
///
/// A map holds values, each under the hash of its key. A call takes the
/// key or the hash. The calls with `forKey:` take the key, a string or
/// bytes or anything ``KeyRepresentable``, and hash it with the hasher the
/// database was given. The calls with `forHash:` take a hash the caller
/// made, with a hasher's ``KeyHashing/keyHash(of:)`` or with any function
/// whose result has as many bytes as the database's hash size: they work
/// on every database, and are the way in for a key that is a hash
/// already. A keyed call is its call by hash with the key hashed, and
/// writes nothing more, with one exception: a put or a put cursor given
/// `storingKey: true` is two calls by hash in one walk, the one that
/// stores the key and its own. The two calls that take or
/// give a value as a type, the typed put and `value(forKey:as:)`, take a
/// key and have no form by hash. Two keys with the same hash are the same
/// key to the map.
///
/// **The map does not keep its keys.** A hash cannot be turned back into
/// its key, and a put stores the value alone, as in the original. To be
/// able to read the keys of a map, for instance when iterating over it,
/// store each key beside its value: give `storingKey: true` to the keyed
/// put (``put(_:forKey:storingKey:)-(WritableData,_,_)``) and to the put
/// cursor (``putCursor(forKey:storingKey:)``), which are the two keyed
/// calls that make an entry with a value, or call ``putKey(_:)``, or
/// ``putKey(_:forHash:)-(_,Sequence<UInt8>)`` where the key to keep is
/// not the bytes that were hashed. An entry whose key was not stored, read
/// with ``Cursor/readEntry()``, has a key at an empty slot, which reads as
/// no bytes and as `""`, while ``keyCursor(forKey:)`` gives `nil` for it:
/// look at the slot's `isEmpty` before taking an entry's key for a name.
///
/// A counted map keeps the number of its entries, which ``count`` reads
/// without going through them. It costs eight bytes each time the map's
/// first block is copied, which is once in every transaction that writes
/// to it, and one more write for each entry added or removed.
///
/// A map is a view of a slot. Making one that can only read checks that
/// the slot holds a map of this kind, or nothing. Making one that can
/// write makes the slot a map if it holds nothing, and readies it for
/// this transaction's writes.
///
/// Writing needs a transaction: see ``Database/withTransaction(_:)``. A map at
/// the root of the database is the exception: there, every write is a
/// transaction of its own.
///
/// **What the calls throw.** A call that reads throws
/// ``XitDBError/unexpectedTag`` if the slot holds something other than a hash
/// map or set, ``XitDBError/staleCursor`` if the map is not at the root and its
/// cursor is from a transaction that did not commit, or an error of the storage
/// or of a damaged file. A call that writes throws
/// ``XitDBError/expectedTxStart`` if the map's cursor is not the root cursor
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
public struct CountedHashMap<Access: CursorAccess> {
    /// The cursor at the slot that holds the map.
    public let cursor: Cursor<Access>

    /// The slot that holds the map.
    ///
    /// - Throws: Only for a map at the root of the database, if the root
    ///   cannot be read.
    public var slot: Slot {
        get throws(XitDBError) {
            try cursor.slot
        }
    }

    /// The number of entries in the map.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something that
    ///   has no count, ``XitDBError/endOfStream`` if the count cannot be read,
    ///   or ``XitDBError/staleCursor`` if the map is not at the root and its
    ///   cursor is from a transaction that did not commit.
    public var count: UInt64 {
        get throws(XitDBError) {
            try cursor.count
        }
    }

    /// An iterator over the map's entries. Each cursor it gives is at an
    /// entry; ``Cursor/readEntry()`` reads the entry's key and value.
    ///
    /// The order is that of the hashes' last bits, which has nothing to do
    /// with the order of insertion.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something that
    ///   is not a collection, ``XitDBError/staleCursor`` if the map is not at
    ///   the root and its cursor is from a transaction that did not commit, or
    ///   an error of the storage or of a damaged file.
    public func iterator() throws(XitDBError) -> CollectionIterator {
        try cursor.iterator()
    }

    /// A cursor at the value stored under a hash, or `nil` if the map has no
    /// entry for it or the entry's value was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: What a read by hash throws: see ``CountedHashMap``.
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

    /// A cursor at the value stored under a key, or `nil` if the map has no
    /// entry for it or the entry's value was never written.
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

    /// The slot of the value stored under a hash, or `nil` if the map has no
    /// entry for it or the entry's value was never written.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: What a read by hash throws: see ``CountedHashMap``.
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

    /// The slot of the value stored under a key, or `nil` if the map has no
    /// entry for it or the entry's value was never written.
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

    /// A cursor at the key stored beside the value under a hash, or `nil`
    /// if the map has no entry for it or no key was stored with it.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: What a read by hash throws: see ``CountedHashMap``.
    public func keyCursor(forHash hash: Span<UInt8>) throws(XitDBError) -> Cursor<ReadOnly>? {
        try keyCursor(forHash: KeyHash(hash))
    }

    /// ``keyCursor(forHash:)-(Span<UInt8>)`` for a hash held as any sequence of
    /// bytes: an array, a digest, a slice. Anything but an array is copied
    /// once.
    @inlinable
    public func keyCursor(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Cursor<ReadOnly>? {
        let bytes = Array(hash)
        return try keyCursor(forHash: bytes.span)
    }

    /// A cursor at the key stored beside the value of a key, or `nil` if the
    /// map has no entry for it or no key was stored with it. A key is stored
    /// by a put or a put cursor given `storingKey: true`, by ``putKey(_:)``
    /// or by ``putKey(_:forHash:)-(_,Sequence<UInt8>)``.
    ///
    /// The key is hashed by the hasher the database was given, and this is
    /// ``keyCursor(forHash:)-(Span<UInt8>)`` with that hash.
    ///
    /// - Parameter key: The key.
    /// - Throws: ``XitDBError/noKeyHashing`` if the database was given no
    ///   hasher, before anything else is looked at, and what
    ///   ``keyCursor(forHash:)-(Span<UInt8>)`` throws.
    public func keyCursor(forKey key: some KeyRepresentable) throws(XitDBError) -> Cursor<ReadOnly>? {
        try keyCursor(forHash: try cursor.keyHash(of: key))
    }

    /// The slot of the key stored beside the value under a hash, or `nil`
    /// if the map has no entry for it or no key was stored with it.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: What a read by hash throws: see ``CountedHashMap``.
    public func keySlot(forHash hash: Span<UInt8>) throws(XitDBError) -> Slot? {
        try keySlot(forHash: KeyHash(hash))
    }

    /// ``keySlot(forHash:)-(Span<UInt8>)`` for a hash held as any sequence of
    /// bytes: an array, a digest, a slice. Anything but an array is copied
    /// once.
    @inlinable
    public func keySlot(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Slot? {
        let bytes = Array(hash)
        return try keySlot(forHash: bytes.span)
    }

    /// The slot of the key stored beside the value of a key, or `nil` if the
    /// map has no entry for it or no key was stored with it. A key is stored
    /// by a put or a put cursor given `storingKey: true`, by ``putKey(_:)``
    /// or by ``putKey(_:forHash:)-(_,Sequence<UInt8>)``.
    ///
    /// The key is hashed by the hasher the database was given, and this is
    /// ``keySlot(forHash:)-(Span<UInt8>)`` with that hash.
    ///
    /// - Parameter key: The key.
    /// - Throws: ``XitDBError/noKeyHashing`` if the database was given no
    ///   hasher, before anything else is looked at, and what
    ///   ``keySlot(forHash:)-(Span<UInt8>)`` throws.
    public func keySlot(forKey key: some KeyRepresentable) throws(XitDBError) -> Slot? {
        try keySlot(forHash: try cursor.keyHash(of: key))
    }

    /// The entry stored under a hash, as a cursor for its key and one for
    /// its value, or `nil` if the map has no entry for it.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: What a read by hash throws: see ``CountedHashMap``.
    public func entry(forHash hash: Span<UInt8>) throws(XitDBError) -> Entry? {
        try entry(forHash: KeyHash(hash))
    }

    /// ``entry(forHash:)-(Span<UInt8>)`` for a hash held as any sequence of
    /// bytes: an array, a digest, a slice. Anything but an array is copied
    /// once.
    @inlinable
    public func entry(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Entry? {
        let bytes = Array(hash)
        return try entry(forHash: bytes.span)
    }

    /// The entry stored under a key, as a cursor for its key and one for its
    /// value, or `nil` if the map has no entry for it.
    ///
    /// The key is hashed by the hasher the database was given, and this is
    /// ``entry(forHash:)-(Span<UInt8>)`` with that hash.
    ///
    /// - Parameter key: The key.
    /// - Throws: ``XitDBError/noKeyHashing`` if the database was given no
    ///   hasher, before anything else is looked at, and what
    ///   ``entry(forHash:)-(Span<UInt8>)`` throws.
    public func entry(forKey key: some KeyRepresentable) throws(XitDBError) -> Entry? {
        try entry(forHash: try cursor.keyHash(of: key))
    }

}

extension CountedHashMap where Access == ReadOnly {
    /// A view of the map at a cursor's slot, for reading.
    ///
    /// A slot that holds nothing is an empty map.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a counted hash map or set.
    public init(_ cursor: Cursor<ReadOnly>) throws(XitDBError) {
        switch try cursor.resolved().slot.tag {
        case .none, .countedHashMap, .countedHashSet:
            self.cursor = cursor
        default:
            throw .unexpectedTag
        }
    }

    /// A view of the map at a cursor's slot, for reading, from a cursor of
    /// either access: one that can write is read through as its
    /// ``Cursor/readOnly``, so that a reader need not take it first.
    ///
    /// A slot that holds nothing is an empty map.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something
    ///   other than a counted hash map or set.
    public init(_ cursor: Cursor<some CursorAccess>) throws(XitDBError) {
        try self.init(Cursor<ReadOnly>(viewing: cursor))
    }
}

extension CountedHashMap where Access == ReadWrite {
    /// A view of the map at a cursor's slot, for reading and writing.
    ///
    /// A slot that holds nothing becomes an empty map. A map from an
    /// earlier transaction is readied for this one: its count and first
    /// block are copied, so that writing to it leaves earlier moments as
    /// they were.
    ///
    /// **A counted hash set becomes a counted hash map.** A counted map
    /// and a counted set are one kind to the slot, as in the original: the
    /// slot's tag is written as a map, and the count and the entries stay.
    /// On the root, where this is a transaction of its own, a set is a map
    /// from then on; a set is opened with ``CountedHashSet``. A map or set
    /// that keeps no count is another kind, and is refused.
    ///
    /// On the root cursor this is a transaction of its own, unless the root
    /// is such a map already, in which case nothing is written.
    ///
    /// - Parameter cursor: A cursor at the slot.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds something other
    ///   than a counted hash map or set, ``XitDBError/expectedTxStart`` if no
    ///   transaction is in progress and `cursor` is not the root cursor,
    ///   ``XitDBError/nestedTopLevelWrite`` if `cursor` is the root cursor and
    ///   one is, ``XitDBError/cursorNotWritable`` if `cursor` has no position,
    ///   as the key cursor of a sorted map's entry has not,
    ///   ``XitDBError/staleCursor`` if `cursor` is from an earlier transaction,
    ///   or from before the last freeze or join of this one unless it is at
    ///   the slot of the transaction's cursor,
    ///   ``XitDBError/poisonedTransaction`` if an earlier operation of the
    ///   transaction failed after writing, or an error of the storage or of a
    ///   damaged file.
    public init(_ cursor: Cursor<ReadWrite>) throws(XitDBError) {
        let path: InlineArray<1, PathPart> = [.hashMapInit(counted: true, set: false)]
        self.cursor = try cursor.writePath(path.span)
    }

    /// A view of the same map that can only read.
    public var readOnly: CountedHashMap<ReadOnly> {
        CountedHashMap<ReadOnly>(unchecked: cursor.readOnly)
    }

    /// Stores a value under a hash, in place of any value that was there.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - hash: The key's hash, as many bytes as the database's hash size.
    /// - Throws: What a write by hash throws: see ``CountedHashMap``.
    public func put(_ value: WritableData, forHash hash: Span<UInt8>) throws(XitDBError) {
        try put(value, forHash: KeyHash(hash))
    }

    /// ``put(_:forHash:)-(_,Span<UInt8>)`` for a hash held as any sequence of
    /// bytes: an array, a digest, a slice. Anything but an array is copied
    /// once.
    @inlinable
    public func put(_ value: WritableData, forHash hash: some Sequence<UInt8>) throws(XitDBError) {
        let bytes = Array(hash)
        try put(value, forHash: bytes.span)
    }

    /// Stores a value under a key, in place of any value that was there.
    ///
    /// **The key is not stored unless you ask.** Its hash names the entry
    /// and nothing else of it is written, as in the original, so the file
    /// holds what the same put by hash writes, and this is
    /// ``put(_:forHash:)-(_,Span<UInt8>)`` with the key's hash.
    ///
    /// With `storingKey` the key is stored beside the value, as
    /// ``putKey(_:)`` stores it, in the one walk to the entry. The file is
    /// the one that ``putKey(_:)`` and then this put leave inside one
    /// transaction; the key is hashed once; and on a map at the root it is
    /// one transaction where those two calls are two. A key that the entry
    /// has already is left as it is, as ``putKey(_:)`` leaves it.
    ///
    /// The argument is given call by call, and the map does not remember
    /// it. An entry that is made without it has no key, and a later put
    /// without it leaves it so, as it leaves a key that is there. Nothing
    /// says that an entry has no key: iterating gives it like the others,
    /// and the key of its ``Cursor/readEntry()`` is at an empty slot, which
    /// reads as no bytes and as `""` and throws nothing, while
    /// ``keyCursor(forKey:)`` gives `nil` for it. A map whose keys are to
    /// be listed wants the argument on every call that can make an entry:
    /// every put, and every ``putCursor(forKey:storingKey:)``. So does a
    /// file that programs in the original's other ports write too: their
    /// keyed put and put cursor always store the key, and a file written
    /// here without becomes one where some entries have a key and some
    /// have none, though a read by key works on both sides all the same.
    ///
    /// The key is hashed by the hasher the database was given.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - key: The key.
    ///   - storingKey: Whether the key is stored beside the value, if the
    ///     entry has no key yet. `false` unless given.
    /// - Throws: ``XitDBError/noKeyHashing`` if the database was given no
    ///   hasher, before anything else is looked at, and what
    ///   ``put(_:forHash:)-(_,Span<UInt8>)`` throws.
    public func put(
        _ value: WritableData, forKey key: some KeyRepresentable, storingKey: Bool = false
    ) throws(XitDBError) {
        guard storingKey else {
            try put(value, forHash: try cursor.keyHash(of: key))
            return
        }
        // The key's bytes are asked for once: they are hashed, and they
        // are what is stored.
        let stored = try cursor.keyHashAndData(of: key)
        try put(value, storingKey: stored.data, forHash: stored.hash)
    }

    /// A cursor at the value stored under a hash, for writing it or for
    /// making a collection there. The map gets an entry for the hash if it
    /// has none.
    ///
    /// Use it in a transaction. On a collection at the root the call is a
    /// transaction of its own, committed by the time it returns, so a new
    /// entry holds nothing and a write through the cursor throws
    /// ``XitDBError/expectedTxStart``.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: What a write by hash throws: see ``CountedHashMap``.
    public func putCursor(forHash hash: Span<UInt8>) throws(XitDBError) -> Cursor<ReadWrite> {
        try putCursor(forHash: KeyHash(hash))
    }

    /// ``putCursor(forHash:)-(Span<UInt8>)`` for a hash held as any sequence of
    /// bytes: an array, a digest, a slice. Anything but an array is copied
    /// once.
    @inlinable
    public func putCursor(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Cursor<ReadWrite> {
        let bytes = Array(hash)
        return try putCursor(forHash: bytes.span)
    }

    /// A cursor at the value stored under a key, for writing it or for making a
    /// collection there. The map gets an entry for the key if it has none.
    ///
    /// **The key is not stored unless you ask.** Without `storingKey` this
    /// is ``putCursor(forHash:)-(Span<UInt8>)`` with the key's hash, and an
    /// entry it makes has no key. With it the key is stored beside the
    /// value, if the entry has none, as ``putKey(_:)`` stores it, in the
    /// one walk to the entry: the file is the one that ``putKey(_:)`` and
    /// then this call leave inside one transaction, and the key is hashed
    /// once. What ``put(_:forKey:storingKey:)-(WritableData,_,_)`` says of
    /// an entry made without the argument holds for one made here.
    ///
    /// Use it in a transaction. On a collection at the root the call is a
    /// transaction of its own, committed by the time it returns, so a new entry
    /// holds no value, and a write through the cursor throws
    /// ``XitDBError/expectedTxStart``.
    ///
    /// The key is hashed by the hasher the database was given.
    ///
    /// - Parameters:
    ///   - key: The key.
    ///   - storingKey: Whether the key is stored beside the value, if the
    ///     entry has no key yet. `false` unless given.
    /// - Throws: ``XitDBError/noKeyHashing`` if the database was given no
    ///   hasher, before anything else is looked at, and what
    ///   ``putCursor(forHash:)-(Span<UInt8>)`` throws.
    public func putCursor(
        forKey key: some KeyRepresentable, storingKey: Bool = false
    ) throws(XitDBError) -> Cursor<ReadWrite> {
        guard storingKey else {
            return try putCursor(forHash: try cursor.keyHash(of: key))
        }
        // The key's bytes are asked for once: they are hashed, and they
        // are what is stored.
        let stored = try cursor.keyHashAndData(of: key)
        return try putCursor(storingKey: stored.data, forHash: stored.hash)
    }

    /// Stores a key beside the value under its hash, unless a key is there
    /// already. The map gets an entry for the hash if it has none.
    ///
    /// A key is only written once, because the key under one hash should
    /// always be the same.
    ///
    /// - Parameters:
    ///   - key: The key.
    ///   - hash: The key's hash, as many bytes as the database's hash size.
    /// - Throws: What a write by hash throws: see ``CountedHashMap``.
    public func putKey(_ key: WritableData, forHash hash: Span<UInt8>) throws(XitDBError) {
        try putKey(key, forHash: KeyHash(hash))
    }

    /// ``putKey(_:forHash:)-(_,Span<UInt8>)`` for a hash held as any sequence
    /// of bytes: an array, a digest, a slice. Anything but an array is copied
    /// once.
    @inlinable
    public func putKey(_ key: WritableData, forHash hash: some Sequence<UInt8>) throws(XitDBError) {
        let bytes = Array(hash)
        try putKey(key, forHash: bytes.span)
    }

    /// Stores a key beside its value, unless a key is there already: the
    /// call that stores a key and nothing else. A put or a put cursor given
    /// `storingKey: true` stores it in the same walk as its own work. The
    /// map gets an entry for the key if it has none.
    ///
    /// What is written is the key's bytes as a byte array, and with them the
    /// format tag of a ``Bytes`` key that has one. The key is hashed by the
    /// hasher the database was given, and this is
    /// ``putKey(_:forHash:)-(_,Span<UInt8>)`` with those bytes and that hash.
    /// To store other data as the key than the bytes that are hashed, give
    /// both to that call.
    ///
    /// - Parameter key: The key.
    /// - Throws: ``XitDBError/noKeyHashing`` if the database was given no
    ///   hasher, before anything else is looked at, and what
    ///   ``putKey(_:forHash:)-(_,Span<UInt8>)`` throws.
    public func putKey(_ key: some KeyRepresentable) throws(XitDBError) {
        // The key's bytes are asked for once: they are hashed, and they
        // are what is stored.
        let stored = try cursor.keyHashAndData(of: key)
        try putKey(stored.data, forHash: stored.hash)
    }

    /// A cursor at the key stored beside the value under a hash, for
    /// writing it. The map gets an entry for the hash if it has none.
    ///
    /// Use it in a transaction. On a collection at the root the call is a
    /// transaction of its own, committed by the time it returns, so a new
    /// entry holds nothing and a write through the cursor throws
    /// ``XitDBError/expectedTxStart``.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Throws: What a write by hash throws: see ``CountedHashMap``.
    public func putKeyCursor(forHash hash: Span<UInt8>) throws(XitDBError) -> Cursor<ReadWrite> {
        try putKeyCursor(forHash: KeyHash(hash))
    }

    /// ``putKeyCursor(forHash:)-(Span<UInt8>)`` for a hash held as any sequence
    /// of bytes: an array, a digest, a slice. Anything but an array is copied
    /// once.
    @inlinable
    public func putKeyCursor(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Cursor<ReadWrite> {
        let bytes = Array(hash)
        return try putKeyCursor(forHash: bytes.span)
    }

    /// A cursor at the key stored beside the value of a key, for writing it.
    /// The map gets an entry for the key if it has none.
    ///
    /// Use it in a transaction. On a collection at the root the call is a
    /// transaction of its own, committed by the time it returns, so a new entry
    /// holds nothing and a write through the cursor throws
    /// ``XitDBError/expectedTxStart``.
    ///
    /// The key is hashed by the hasher the database was given, and this is
    /// ``putKeyCursor(forHash:)-(Span<UInt8>)`` with that hash.
    ///
    /// - Parameter key: The key.
    /// - Throws: ``XitDBError/noKeyHashing`` if the database was given no
    ///   hasher, before anything else is looked at, and what
    ///   ``putKeyCursor(forHash:)-(Span<UInt8>)`` throws.
    public func putKeyCursor(forKey key: some KeyRepresentable) throws(XitDBError) -> Cursor<ReadWrite> {
        try putKeyCursor(forHash: try cursor.keyHash(of: key))
    }

    /// Removes the entry stored under a hash.
    ///
    /// - Parameter hash: The key's hash, as many bytes as the database's hash
    ///   size.
    /// - Returns: Whether there was an entry to remove.
    /// - Throws: What a write by hash throws: see ``CountedHashMap``.
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

    /// Removes the entry stored under a key.
    ///
    /// The key is hashed by the hasher the database was given, and this is
    /// ``remove(forHash:)-(Span<UInt8>)`` with that hash.
    ///
    /// - Parameter key: The key.
    /// - Returns: Whether there was an entry to remove.
    /// - Throws: ``XitDBError/noKeyHashing`` if the database was given no
    ///   hasher, before anything else is looked at, and what
    ///   ``remove(forHash:)-(Span<UInt8>)`` throws.
    @discardableResult
    public func remove(forKey key: some KeyRepresentable) throws(XitDBError) -> Bool {
        try remove(forHash: try cursor.keyHash(of: key))
    }

}

extension CountedHashMap {
    /// A view of the map at a cursor's slot, which the caller has made
    /// sure holds one.
    init(unchecked cursor: Cursor<Access>) {
        self.cursor = cursor
    }
}

extension CountedHashMap {
    /// The call by a hash the engine holds already: what the forms of `cursor`
    /// by a `Span` and by a key both come to.
    func cursor(forHash hash: KeyHash) throws(XitDBError) -> Cursor<ReadOnly>? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.value, hash)]
        return try cursor.readPath(path.span)
    }

    /// The call by a hash the engine holds already: what the forms of `slot` by
    /// a `Span` and by a key both come to.
    func slot(forHash hash: KeyHash) throws(XitDBError) -> Slot? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.value, hash)]
        return try cursor.readPathSlot(path.span)
    }

    /// The call by a hash the engine holds already: what the forms of
    /// `keyCursor` by a `Span` and by a key both come to.
    func keyCursor(forHash hash: KeyHash) throws(XitDBError) -> Cursor<ReadOnly>? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, hash)]
        return try cursor.readPath(path.span)
    }

    /// The call by a hash the engine holds already: what the forms of `keySlot`
    /// by a `Span` and by a key both come to.
    func keySlot(forHash hash: KeyHash) throws(XitDBError) -> Slot? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.key, hash)]
        return try cursor.readPathSlot(path.span)
    }

    /// The call by a hash the engine holds already: what the forms of `entry`
    /// by a `Span` and by a key both come to.
    func entry(forHash hash: KeyHash) throws(XitDBError) -> Entry? {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.kvPair, hash)]
        return try cursor.readPath(path.span)?.readEntry()
    }
}

extension CountedHashMap where Access == ReadWrite {
    /// The call by a hash the engine holds already: what the forms of `put` by
    /// a `Span` and by a key both come to.
    func put(_ value: WritableData, forHash hash: KeyHash) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.hashMapGet(.value, hash), .write(value)]
        _ = try cursor.writePath(path.span)
    }

    /// The put that stores the key too, in one walk to the entry: the key
    /// is written if the entry has none, and then the value. It writes
    /// what `putKey(_:forHash:)` and then `put(_:forHash:)` write.
    func put(_ value: WritableData, storingKey key: WritableData, forHash hash: KeyHash) throws(XitDBError) {
        let path: InlineArray<2, PathPart> = [.hashMapGet(.value, hash), .ctx]
        // The key and the value are written inside the callback, so they
        // are no parts of the path: both are checked here, after the
        // cursor's checks and before the entry is made, as write parts are.
        try cursor.checkWritable(path.span)
        try key.checkIsValue()
        try value.checkIsValue()
        _ = try cursor.writePath(
            path.span,
            typed: { (valueCursor: inout Cursor<ReadWrite>) throws(XitDBError) in
                var keyCursor = try valueCursor.keyCursorBesideValue()
                try keyCursor.writeIfEmpty(key)
                try valueCursor.write(value)
            })
    }

    /// The call by a hash the engine holds already: what the forms of
    /// `putCursor` by a `Span` and by a key both come to.
    func putCursor(forHash hash: KeyHash) throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<1, PathPart> = [.hashMapGet(.value, hash)]
        return try cursor.writePath(path.span)
    }

    /// The put cursor that stores the key too, in one walk to the entry:
    /// the key is written if the entry has none, and the cursor at the
    /// value comes back. It writes what `putKey(_:forHash:)` and then
    /// `putCursor(forHash:)` write.
    func putCursor(storingKey key: WritableData, forHash hash: KeyHash) throws(XitDBError) -> Cursor<ReadWrite> {
        let path: InlineArray<2, PathPart> = [.hashMapGet(.value, hash), .ctx]
        // The key is written inside the callback, so it is not a part of
        // the path: check it here, after the cursor's checks and before the
        // entry is made, as a write part would be checked.
        try cursor.checkWritable(path.span)
        try key.checkIsValue()
        // What the callback leaves in its cursor is the path's result: the
        // value's slot, which the key's write does not touch.
        return try cursor.writePath(
            path.span,
            typed: { (valueCursor: inout Cursor<ReadWrite>) throws(XitDBError) in
                var keyCursor = try valueCursor.keyCursorBesideValue()
                try keyCursor.writeIfEmpty(key)
            })
    }

    /// The call by a hash the engine holds already: what the forms of `putKey`
    /// by a `Span` and by a key both come to.
    func putKey(_ key: WritableData, forHash hash: KeyHash) throws(XitDBError) {
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
    /// `putKeyCursor` by a `Span` and by a key both come to.
    func putKeyCursor(forHash hash: KeyHash) throws(XitDBError) -> Cursor<ReadWrite> {
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

// MARK: Typed values

extension CountedHashMap {
    /// The value stored under a key, read as a type, or `nil` if the map
    /// has no entry for the key or the entry's value was never written.
    ///
    /// The type can be given or left to what the result is assigned to:
    /// `try map.value(forKey: "name", as: String.self)`, or `let name:
    /// String? = try map.value(forKey: "name")`.
    ///
    /// `nil` means there is no value under the key: no entry, or an entry
    /// whose value was never written. A value that is there is read
    /// strictly, as ``StorableValue`` says: one of another kind than the
    /// type is written as is an error and not `nil`. A value that was set
    /// to nothing with `.slot(nil)` is there: read as a number it is that
    /// error, and read as a `String`, a `[UInt8]` or ``Bytes`` it is empty.
    ///
    /// - Parameters:
    ///   - key: The key.
    ///   - type: The type to read.
    /// - Throws: ``XitDBError/noKeyHashing`` if the database was given no
    ///   hasher, what ``cursor(forKey:)`` throws, and what
    ///   ``Cursor/read(_:)`` throws, ``XitDBError/unexpectedTag`` for a
    ///   value of another kind among them.
    public func value<Value: StorableValue>(forKey key: some KeyRepresentable, as type: Value.Type = Value.self)
        throws(XitDBError) -> Value?
    {
        guard let cursor = try cursor(forKey: key) else { return nil }
        return try Value(reading: cursor)
    }
}

extension CountedHashMap where Access == ReadWrite {
    /// Stores a value under a key, in place of any value that was there.
    ///
    /// The value writes itself where the put of ``WritableData`` writes
    /// its data, in the same transaction: a value of one of the library's
    /// types leaves the file that put leaves, and a type of your own
    /// writes what it says, a collection included. The key is not stored
    /// unless `storingKey` asks, and then as the put of ``WritableData``
    /// with that argument stores it: beside the value, if the entry has no
    /// key yet, in the same walk.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - key: The key.
    ///   - storingKey: Whether the key is stored beside the value, if the
    ///     entry has no key yet. `false` unless given.
    /// - Throws: ``XitDBError/noKeyHashing`` if the database was given no
    ///   hasher, before anything else is looked at; what the put of
    ///   ``WritableData`` throws; and what the value's own writing throws.
    ///   A value that fails once the map has made its entry poisons the
    ///   transaction, as any write that fails after it has written does.
    @inlinable
    public func put(
        _ value: some StorableValue, forKey key: some KeyRepresentable, storingKey: Bool = false
    ) throws(XitDBError) {
        // One of the library's own values is its data, and its typed write
        // is the write of that data. Where the caller's code knows the
        // value's type, the compiler settles which it is, and for the
        // library's six this call is that write and nothing else.
        if let data = WritableData(ownValue: value) {
            try put(data, forKey: key, storingKey: storingKey)
            return
        }
        try putWritingItself(value, forKey: key, storingKey: storingKey)
    }

    /// The put of a value of the caller's own, which writes itself in the
    /// entry the map makes for the key.
    @usableFromInline
    func putWritingItself(
        _ value: some StorableValue, forKey key: some KeyRepresentable, storingKey: Bool
    ) throws(XitDBError) {
        // The key that is stored, if it is, from the bytes that are
        // hashed: asked for once, and before the walk, so that nothing of
        // the key is looked at once the entry exists.
        let hash: KeyHash
        let keyData: WritableData?
        if storingKey {
            let stored = try cursor.keyHashAndData(of: key)
            hash = stored.hash
            keyData = stored.data
        } else {
            hash = try cursor.keyHash(of: key)
            keyData = nil
        }
        let path: InlineArray<2, PathPart> = [.hashMapGet(.value, hash), .ctx]
        _ = try cursor.writePath(
            path.span,
            typed: { (valueCursor: inout Cursor<ReadWrite>) throws(XitDBError) in
                // The value's cursor is the walk's own with the argument as
                // without it, so the value writes itself as it always did;
                // the key goes in first, if the entry has none.
                if let keyData {
                    var keyCursor = try valueCursor.keyCursorBesideValue()
                    try keyCursor.writeIfEmpty(keyData)
                }
                try value.write(to: &valueCursor)
            })
    }
}

@available(*, unavailable, message: "a counted hash map stays with its database's thread or task; send a snapshot")
extension CountedHashMap: Sendable {}
