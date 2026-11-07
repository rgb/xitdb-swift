// Following a path without writing: Zig's `readSlotPointer` in read mode,
// with the read-only halves of the hash trie and the array list trie.

extension DatabaseReader {
    /// Follows `path` from `start` and returns the slot it arrives at.
    ///
    /// - Throws: `keyNotFound` if something on the way does not exist or the
    ///   path arrives at an empty slot, `writeNotAllowed` at a part that
    ///   writes, `unexpectedTag` at a part applied to the wrong kind of slot.
    func readSlotPointer(_ path: Span<PathPart>, at start: SlotPointer) throws(XitDBError) -> SlotPointer {
        var pointer = start
        var index = 0
        while index < path.count {
            // A path that starts at the root reads the root as it is now.
            // The position must not stay the root's, so it has none.
            if pointer.position == RootHeader.position {
                pointer = SlotPointer(position: nil, slot: try rootSlot())
            }
            switch path[index] {
            case .arrayListGet(let listIndex):
                pointer = try arrayListGet(pointer.slot, index: listIndex)
            case .hashMapGet(let kind, let hash):
                pointer = try hashMapGet(pointer.slot, kind: kind, hash: hash)
            case .linkedArrayListGet(let listIndex):
                pointer = try linkedArrayListGet(pointer.slot, index: listIndex)
            case .arrayListInit, .arrayListAppend, .arrayListSlice, .hashMapInit, .hashMapRemove, .write, .ctx,
                .linkedArrayListInit, .linkedArrayListAppend, .linkedArrayListSlice, .linkedArrayListConcat,
                .linkedArrayListInsert, .linkedArrayListRemove:
                throw .writeNotAllowed
            }
            index += 1
        }
        if pointer.slot.isEmpty { throw .keyNotFound }
        return pointer
    }

    // MARK: Array list

    /// The position in a list of `size` elements that `index` names, or
    /// `nil` if it names none. A negative index counts from the end.
    static func arrayListKey(index: Int64, size: UInt64) -> UInt64? {
        if index >= 0 {
            let key = UInt64(index)
            return key < size ? key : nil
        }
        let fromEnd = index.magnitude
        return fromEnd <= size ? size - fromEnd : nil
    }

    /// The slot a key selects in an index block of an array list at a shift.
    static func arrayListSlotIndex(key: UInt64, shift: UInt8) -> UInt64 {
        (key >> (UInt64(shift) * Trie.bitsPerLevel)) & Trie.mask
    }

    func arrayListGet(_ slot: Slot, index: Int64) throws(XitDBError) -> SlotPointer {
        switch slot.tag {
        case .none: throw .keyNotFound
        case .arrayList: break
        default: throw .unexpectedTag
        }
        let header = try arrayListHeader(at: slot.value)
        guard let key = Self.arrayListKey(index: index, size: header.size) else { throw .keyNotFound }
        let lastKey = header.size - 1
        let shift: UInt8 = lastKey < Trie.slotsPerBlock ? 0 : Trie.arrayListShift(lastIndex: lastKey)
        return try arrayListSlot(indexPosition: header.ptr, key: key, shift: shift)
    }

    /// Descends an array list's trie to the element slot for `key`.
    func arrayListSlot(indexPosition: UInt64, key: UInt64, shift: UInt8) throws(XitDBError) -> SlotPointer {
        var indexPosition = indexPosition
        var shift = shift
        while true {
            if UInt64(shift) >= Trie.slotsPerBlock { throw .maxShiftExceeded }
            let slotPosition = try indexPosition.offset(
                by: Slot.byteCount * Self.arrayListSlotIndex(key: key, shift: shift)
            )
            let slot = try slot(at: slotPosition)
            if shift == 0 {
                return SlotPointer(position: slotPosition, slot: slot)
            }
            switch slot.tag {
            case .none: throw .keyNotFound
            case .index:
                indexPosition = slot.value
                shift -= 1
            default: throw .unexpectedTag
            }
        }
    }

    // MARK: Linked array list

    /// The rank an index names in a list of `size` elements, or `nil` if it
    /// names none. A negative index counts from the end.
    static func linkedArrayListRank(index: Int64, size: UInt64) -> UInt64? {
        arrayListKey(index: index, size: size)
    }

    func linkedArrayListGet(_ slot: Slot, index: Int64) throws(XitDBError) -> SlotPointer {
        switch slot.tag {
        case .none: throw .keyNotFound
        case .linkedArrayList: break
        default: throw .unexpectedTag
        }
        let header = try bTreeHeader(at: slot.value)
        guard let rank = Self.linkedArrayListRank(index: index, size: header.size) else { throw .keyNotFound }
        return try linkedArrayListSlot(rootPtr: header.rootPtr, rank: rank)
    }

    // MARK: Hash map

    /// Where a map's root index block is: at the slot's offset, or after the
    /// count for a counted map.
    ///
    /// - Throws: `keyNotFound` for an empty slot, `unexpectedTag` for one
    ///   that is not a hash map or set.
    static func hashMapIndexPosition(_ slot: Slot) throws(XitDBError) -> (position: UInt64, counted: Bool) {
        switch slot.tag {
        case .none: throw .keyNotFound
        case .hashMap, .hashSet: return (slot.value, false)
        case .countedHashMap, .countedHashSet: return (try slot.value.offset(by: IndexBlock.countByteCount), true)
        default: throw .unexpectedTag
        }
    }

    /// A hash given to a map must have the database's hash size. Zig makes
    /// sure of that with a type; here it is checked.
    func checkHashSize(_ hash: KeyHash) throws(XitDBError) {
        if hash.count != Int(hashSize) { throw .invalidHashSize }
    }

    /// The slot pointer for one of the slots of a hashed pair.
    static func pairSlotPointer(
        _ kind: HashMapSlotKind,
        trieSlotPosition: UInt64,
        trieSlot: Slot,
        pairPosition: UInt64,
        pair: KeyValuePair,
        hashSize: UInt16
    ) throws(XitDBError) -> SlotPointer {
        switch kind {
        case .kvPair:
            return SlotPointer(position: trieSlotPosition, slot: trieSlot)
        case .key:
            return SlotPointer(position: try pairPosition.offset(by: UInt64(hashSize)), slot: pair.keySlot)
        case .value:
            let keyPosition = try pairPosition.offset(by: UInt64(hashSize))
            return SlotPointer(position: try keyPosition.offset(by: Slot.byteCount), slot: pair.valueSlot)
        }
    }

    func hashMapGet(_ slot: Slot, kind: HashMapSlotKind, hash: KeyHash) throws(XitDBError) -> SlotPointer {
        var indexPosition = try Self.hashMapIndexPosition(slot).position
        try checkHashSize(hash)
        var level = 0
        while true {
            let slotIndex = try hash.index(atLevel: level)
            let slotPosition = try indexPosition.offset(by: Slot.byteCount * UInt64(slotIndex))
            let trieSlot = try self.slot(at: slotPosition)
            switch trieSlot.tag {
            case .none:
                throw .keyNotFound
            case .index:
                indexPosition = trieSlot.value
                level += 1
            case .kvPair:
                let existing = try hashedPair(at: trieSlot.value)
                guard existing.hash == hash else { throw .keyNotFound }
                return try Self.pairSlotPointer(
                    kind,
                    trieSlotPosition: slotPosition,
                    trieSlot: trieSlot,
                    pairPosition: trieSlot.value,
                    pair: existing.pair,
                    hashSize: hashSize
                )
            default:
                throw .unexpectedTag
            }
        }
    }
}
