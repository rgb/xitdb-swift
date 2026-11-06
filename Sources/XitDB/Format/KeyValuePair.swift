/// The key and value slots of an entry in a hash map, a hash set or a sorted
/// map.
///
/// There are two forms on disk. The hashed form, which a `kvPair` slot points
/// at, starts with the key's hash and so has a size that depends on the
/// database's hash size. The sorted form, which a `sortedKvPair` slot points
/// at, has no hash.
///
/// The hash is not part of this value, because its size is only known at run
/// time and a decoded record must not allocate. Code that needs it reads it
/// from the first `hashSize` bytes of the record.
struct KeyValuePair: Sendable, Equatable {
    var keySlot: Slot
    var valueSlot: Slot

    /// The size of the sorted form on disk.
    static let sortedByteCount: UInt64 = 18

    /// The size of the hashed form on disk for a given hash size.
    static func byteCount(hashSize: UInt16) -> UInt64 {
        UInt64(hashSize) + 18
    }

    init(keySlot: Slot, valueSlot: Slot) {
        self.keySlot = keySlot
        self.valueSlot = valueSlot
    }

    /// Decodes the slots of the hashed form that starts at `offset`.
    ///
    /// - Throws: `endOfStream` if fewer than `hashSize + 18` bytes are
    ///   available, or `invalidEnumTag` if the key slot's or the value slot's
    ///   tag is unknown, checked in that order.
    init(decodingHashed bytes: Span<UInt8>, at offset: Int = 0, hashSize: UInt16) throws(XitDBError) {
        try bytes.requireBytes(Int(hashSize) + 18, at: offset)
        self.keySlot = try Slot(decoding: bytes, at: offset + Int(hashSize))
        self.valueSlot = try Slot(decoding: bytes, at: offset + Int(hashSize) + 9)
    }

    /// Appends the hashed form: the hash, the key slot, the value slot.
    ///
    /// - Parameter hash: The key's hash, in the order it is stored. Its
    ///   length is the database's hash size.
    func encodeHashed(hash: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
        for index in hash.indices {
            output.append(hash[index])
        }
        keySlot.encode(into: &output)
        valueSlot.encode(into: &output)
    }

    /// Decodes the sorted form that starts at `offset`.
    ///
    /// - Throws: `endOfStream` if fewer than eighteen bytes are available, or
    ///   `invalidEnumTag` if the key slot's or the value slot's tag is
    ///   unknown, checked in that order.
    init(decodingSorted bytes: Span<UInt8>, at offset: Int = 0) throws(XitDBError) {
        try bytes.requireBytes(18, at: offset)
        self.keySlot = try Slot(decoding: bytes, at: offset)
        self.valueSlot = try Slot(decoding: bytes, at: offset + 9)
    }

    /// Appends the sorted form: the key slot, the value slot.
    func encodeSorted(into output: inout OutputSpan<UInt8>) {
        keySlot.encode(into: &output)
        valueSlot.encode(into: &output)
    }
}

extension KeyValuePair {
    /// Whether an entry of a sorted leaf is a key on its own, stored directly
    /// in the leaf, as opposed to a pointer to a key-value pair.
    static func isKeyOnlyEntry(_ entry: Slot) -> Bool {
        entry.tag == .bytes || entry.tag == .shortBytes
    }

    /// Where the key slot of the pair that `entry` points at is stored.
    ///
    /// A key-only entry has no separate key slot, so the result is `nil`. For
    /// a `kvPair` entry the key slot follows the hash; for any other entry it
    /// is at the start of the record.
    static func keyPosition(of entry: Slot, hashSize: UInt16) -> UInt64? {
        if isKeyOnlyEntry(entry) { return nil }
        return entry.value + (entry.tag == .kvPair ? UInt64(hashSize) : 0)
    }

    /// Where the value slot of the pair that `entry` points at is stored:
    /// directly after the key slot. `nil` for a key-only entry.
    static func valuePosition(of entry: Slot, hashSize: UInt16) -> UInt64? {
        guard let keyPosition = keyPosition(of: entry, hashSize: hashSize) else { return nil }
        return keyPosition + Slot.byteCount
    }
}
