// Following a path while writing: Zig's `readSlotPointer` in write mode. One
// function per path part, and `runParts`, which applies them in order.
//
// A part changes data in place if this transaction created it, and copies it
// to the end of the storage first if it is older (`isOld`). Where the copy is
// made, and in what order records are appended, decides the bytes of the
// file, so both follow Zig exactly.

extension Database {
    /// Applies the parts of `path` in order, starting at `start`, up to a
    /// final `ctx` part.
    ///
    /// The callback itself is not run here, because it may throw errors of
    /// its own. The caller runs it at the slot this returns.
    ///
    /// - Returns: The slot the path arrived at, and whether it stopped at a
    ///   `ctx` part.
    func runParts(
        _ path: Span<PathPart>,
        at start: SlotPointer,
        frozenAt: UInt64
    ) throws(XitDBError) -> (pointer: SlotPointer, callbackDue: Bool) {
        var pointer = start
        var index = 0
        while index < path.count {
            // In Zig a part that arrives at the root header's position
            // starts a transaction of its own. No part of a sound file leads
            // there, so this is a corrupt one.
            if pointer.position == RootHeader.position { throw .invalidDatabase }

            switch path[index] {
            case .arrayListInit:
                pointer = try arrayListInit(pointer, frozenAt: frozenAt)
            case .arrayListGet(let listIndex):
                pointer = try arrayListGet(pointer, index: listIndex, frozenAt: frozenAt)
            case .arrayListAppend:
                pointer = try arrayListAppend(pointer, frozenAt: frozenAt)
            case .arrayListSlice(let size):
                try arrayListSlice(pointer, size: size, frozenAt: frozenAt)
            case .hashMapInit(let counted, let set):
                pointer = try hashMapInit(pointer, counted: counted, set: set, frozenAt: frozenAt)
            case .hashMapGet(let kind, let hash):
                pointer = try hashMapGet(pointer, kind: kind, hash: hash, frozenAt: frozenAt)
            case .hashMapRemove(let hash):
                // A remove ends the path, whatever follows it.
                try hashMapRemove(pointer, hash: hash, frozenAt: frozenAt)
                return (pointer, false)
            case .write(let data):
                pointer = try writeData(pointer, data)
            case .ctx:
                if index != path.count - 1 { throw .pathPartMustBeAtEnd }
                return (pointer, true)
            }
            index += 1
        }
        return (pointer, false)
    }

    // MARK: Values

    func writeData(_ pointer: SlotPointer, _ data: WriteableData) throws(XitDBError) -> SlotPointer {
        guard let position = pointer.position else { throw .cursorNotWriteable }

        var slot: Slot
        switch data {
        case .slot(let given):
            slot = given ?? Slot(tag: .none)
        case .uint(let value):
            slot = Slot(value: value, tag: .uint)
        case .int(let value):
            slot = Slot(value: UInt64(bitPattern: value), tag: .int)
        case .float(let value):
            slot = Slot(value: value.bitPattern, tag: .float)
        case .bytes(let value):
            slot = try writeBytes(value.span, formatTag: nil, at: pointer)
        case .bytesObject(let bytes):
            slot = try writeBytes(bytes.value.span, formatTag: bytes.formatTag, at: pointer)
        }

        // The flag tells a slot explicitly set to nothing from one that has
        // not been written yet.
        if slot.tag == .none {
            slot.full = true
        }

        try write(slot, at: position)
        return SlotPointer(position: position, slot: slot)
    }

    /// Stores a byte array and returns the slot for it: the bytes themselves
    /// if they are short enough, or a pointer to a new record.
    private func writeBytes(
        _ value: Span<UInt8>,
        formatTag: InlineArray<2, UInt8>?,
        at pointer: SlotPointer
    ) throws(XitDBError) -> Slot {
        if ByteArrayFormat.isShort(value, hasFormatTag: formatTag != nil) {
            return ByteArrayFormat.shortSlot(value, formatTag: formatTag)
        }
        var writer = try ByteRecordWriter(database: self, at: pointer)
        writer.formatTag = formatTag
        try writer.write(value)
        return try writer.finish(slotPosition: pointer.position)
    }

    // MARK: Array list

    private func arrayListInit(_ pointer: SlotPointer, frozenAt: UInt64) throws(XitDBError) -> SlotPointer {
        guard let position = pointer.position else { throw .cursorNotWriteable }

        var listStart: UInt64
        switch pointer.slot.tag {
        case .none:
            // The slot was empty: make a new list, its root index block
            // directly after its header.
            listStart = try storage.length()
            let blockPosition = try listStart.offset(by: ArrayListHeader.byteCount)
            try write(ArrayListHeader(size: 0, ptr: blockPosition), at: listStart)
            try writeEmptyIndexBlock(at: blockPosition)
        case .arrayList:
            listStart = pointer.slot.value
            // Copy the header and the root block to the end unless this
            // transaction made them.
            if try isOld(listStart, frozenAt: frozenAt) {
                var header = try reader.arrayListHeader(at: listStart)
                let block = try reader.indexBlockBytes(at: header.ptr)
                listStart = try storage.length()
                header.ptr = try listStart.offset(by: ArrayListHeader.byteCount)
                try write(header, at: listStart)
                try storage.write(block.span, at: header.ptr)
            }
        default:
            throw .unexpectedTag
        }

        // Point the slot at the list.
        let slot = Slot(value: listStart, tag: .arrayList)
        try write(slot, at: position)
        return SlotPointer(position: position, slot: slot)
    }

    private func arrayListGet(
        _ pointer: SlotPointer,
        index: Int64,
        frozenAt: UInt64
    ) throws(XitDBError) -> SlotPointer {
        switch pointer.slot.tag {
        case .none: throw .keyNotFound
        case .arrayList: break
        default: throw .unexpectedTag
        }
        let header = try reader.arrayListHeader(at: pointer.slot.value)
        guard let key = DatabaseReader.arrayListKey(index: index, size: header.size) else { throw .keyNotFound }
        let lastKey = header.size - 1
        let shift: UInt8 = lastKey < Trie.slotsPerBlock ? 0 : Trie.arrayListShift(lastIndex: lastKey)
        return try arrayListSlot(indexPosition: header.ptr, key: key, shift: shift, frozenAt: frozenAt)
    }

    private func arrayListAppend(_ pointer: SlotPointer, frozenAt: UInt64) throws(XitDBError) -> SlotPointer {
        if pointer.slot.tag != .arrayList { throw .unexpectedTag }
        let listStart = pointer.slot.value
        let header = try reader.arrayListHeader(at: listStart)
        let appended = try arrayListAppendSlot(header, frozenAt: frozenAt)
        // The header is updated before the rest of the path runs, so that a
        // callback can freeze it.
        try write(appended.header, at: listStart)
        return appended.pointer
    }

    private func arrayListSlice(_ pointer: SlotPointer, size: UInt64, frozenAt: UInt64) throws(XitDBError) {
        if pointer.slot.tag != .arrayList { throw .unexpectedTag }
        let listStart = pointer.slot.value
        let header = try reader.arrayListHeader(at: listStart)
        let sliced = try arrayListSliceHeader(header, size: size, frozenAt: frozenAt)
        try write(sliced, at: listStart)
    }

    /// Makes room for one more element and returns its slot, cleared, with
    /// the list's new header.
    private func arrayListAppendSlot(
        _ header: ArrayListHeader,
        frozenAt: UInt64
    ) throws(XitDBError) -> (header: ArrayListHeader, pointer: SlotPointer) {
        var indexPosition = header.ptr
        let key = header.size
        // A size that cannot grow comes from a corrupt file.
        if key == .max { throw .invalidDatabase }

        let previousShift: UInt8 = key < Trie.slotsPerBlock ? 0 : Trie.arrayListShift(lastIndex: key - 1)
        let nextShift: UInt8 = key < Trie.slotsPerBlock ? 0 : Trie.arrayListShift(lastIndex: key)

        if previousShift != nextShift {
            // The root block is full: a new root goes above it.
            let rootPosition = try storage.length()
            try writeEmptyIndexBlock(at: rootPosition)
            try write(Slot(value: indexPosition, tag: .index), at: rootPosition)
            indexPosition = rootPosition
        }

        var pointer = try arrayListSlot(indexPosition: indexPosition, key: key, shift: nextShift, frozenAt: frozenAt)
        // Clear a value left there by a rollback or a slice.
        pointer.slot = Slot()
        if let position = pointer.position {
            try write(pointer.slot, at: position)
        }

        return (ArrayListHeader(size: key + 1, ptr: indexPosition), pointer)
    }

    /// Descends an array list's trie to the element slot for `key`, making
    /// the blocks that are missing and copying the ones that are old.
    private func arrayListSlot(
        indexPosition: UInt64,
        key: UInt64,
        shift: UInt8,
        frozenAt: UInt64
    ) throws(XitDBError) -> SlotPointer {
        var indexPosition = indexPosition
        var shift = shift
        while true {
            if UInt64(shift) >= Trie.slotsPerBlock { throw .maxShiftExceeded }
            let slotPosition = try indexPosition.offset(
                by: Slot.byteCount * DatabaseReader.arrayListSlotIndex(key: key, shift: shift)
            )
            let slot = try reader.slot(at: slotPosition)
            if shift == 0 {
                return SlotPointer(position: slotPosition, slot: slot)
            }
            switch slot.tag {
            case .none:
                let blockPosition = try storage.length()
                try writeEmptyIndexBlock(at: blockPosition)
                try write(Slot(value: blockPosition, tag: .index), at: slotPosition)
                indexPosition = blockPosition
            case .index:
                let blockPosition = try copyIndexBlockIfOld(slot.value, frozenAt: frozenAt)
                if blockPosition != slot.value {
                    // Point the slot at the copy.
                    try write(Slot(value: blockPosition, tag: .index), at: slotPosition)
                }
                indexPosition = blockPosition
            default:
                throw .unexpectedTag
            }
            shift -= 1
        }
    }

    /// The header of a list cut down to its first `size` elements.
    private func arrayListSliceHeader(
        _ header: ArrayListHeader,
        size: UInt64,
        frozenAt: UInt64
    ) throws(XitDBError) -> ArrayListHeader {
        if size > header.size { throw .keyNotFound }

        let previousShift: UInt8 =
            header.size < Trie.slotsPerBlock + 1 ? 0 : Trie.arrayListShift(lastIndex: header.size - 1)
        let nextShift: UInt8 = size < Trie.slotsPerBlock + 1 ? 0 : Trie.arrayListShift(lastIndex: size - 1)

        if previousShift == nextShift {
            // The root block does not need to change.
            return ArrayListHeader(size: size, ptr: header.ptr)
        }

        // Follow the first slot down until the block at the right depth.
        var shift = previousShift
        var indexPosition = header.ptr
        while shift > nextShift {
            let slot = try reader.slot(at: indexPosition)
            shift -= 1
            indexPosition = slot.value
        }

        // The new root may still belong to a past moment. Unlike the blocks
        // below a root, a root is written to directly, so copy it now.
        indexPosition = try copyIndexBlockIfOld(indexPosition, frozenAt: frozenAt)
        return ArrayListHeader(size: size, ptr: indexPosition)
    }

    // MARK: Hash map

    private func hashMapInit(
        _ pointer: SlotPointer,
        counted: Bool,
        set: Bool,
        frozenAt: UInt64
    ) throws(XitDBError) -> SlotPointer {
        let tag: Tag =
            if counted {
                set ? .countedHashSet : .countedHashMap
            } else {
                set ? .hashSet : .hashMap
            }

        guard let position = pointer.position else { throw .cursorNotWriteable }

        var mapStart: UInt64
        switch pointer.slot.tag {
        case .none:
            // The slot was empty: make a new map. A counted map starts with
            // its count.
            mapStart = try storage.length()
            if counted {
                try write(0 as UInt64, at: mapStart)
                try writeEmptyIndexBlock(at: try mapStart.offset(by: IndexBlock.countByteCount))
            } else {
                try writeEmptyIndexBlock(at: mapStart)
            }
        case .hashMap, .hashSet, .countedHashMap, .countedHashSet:
            let isCounted = pointer.slot.tag == .countedHashMap || pointer.slot.tag == .countedHashSet
            if counted != isCounted { throw .unexpectedTag }

            mapStart = pointer.slot.value
            // Copy the root block to the end unless this transaction made
            // it.
            if try isOld(mapStart, frozenAt: frozenAt) {
                if counted {
                    let count = try reader.uint64(at: mapStart)
                    let block = try reader.indexBlockBytes(at: try mapStart.offset(by: IndexBlock.countByteCount))
                    mapStart = try storage.length()
                    try write(count, at: mapStart)
                    try storage.write(block.span, at: try mapStart.offset(by: IndexBlock.countByteCount))
                } else {
                    let block = try reader.indexBlockBytes(at: mapStart)
                    mapStart = try storage.length()
                    try storage.write(block.span, at: mapStart)
                }
            }
        default:
            throw .unexpectedTag
        }

        // Point the slot at the map. The tag is the one asked for, which
        // turns a map into a set or back.
        let slot = Slot(value: mapStart, tag: tag)
        try write(slot, at: position)
        return SlotPointer(position: position, slot: slot)
    }

    private func hashMapGet(
        _ pointer: SlotPointer,
        kind: HashMapSlotKind,
        hash: KeyHash,
        frozenAt: UInt64
    ) throws(XitDBError) -> SlotPointer {
        let map = try DatabaseReader.hashMapIndexPosition(pointer.slot)
        try reader.checkHashSize(hash)

        let found = try mapSlot(indexPosition: map.position, hash: hash, kind: kind, frozenAt: frozenAt)

        if map.counted && found.isNew {
            let count = try reader.uint64(at: pointer.slot.value)
            if count == .max { throw .invalidDatabase }
            try write(count + 1, at: pointer.slot.value)
        }

        return found.pointer
    }

    private func hashMapRemove(_ pointer: SlotPointer, hash: KeyHash, frozenAt: UInt64) throws(XitDBError) {
        let map = try DatabaseReader.hashMapIndexPosition(pointer.slot)
        try reader.checkHashSize(hash)

        var keyFound = true
        do throws(XitDBError) {
            try removeMapSlot(indexPosition: map.position, hash: hash, frozenAt: frozenAt)
        } catch {
            guard error == .keyNotFound else { throw error }
            keyFound = false
        }

        if map.counted && keyFound {
            let count = try reader.uint64(at: pointer.slot.value)
            // A count of nothing with something in the map is a corrupt
            // file.
            if count == 0 { throw .invalidDatabase }
            try write(count - 1, at: pointer.slot.value)
        }

        if !keyFound { throw .keyNotFound }
    }

    /// Finds the entry for a hash in a map's trie, or makes it.
    ///
    /// - Returns: The slot asked for, and whether the entry is new.
    private func mapSlot(
        indexPosition: UInt64,
        hash: KeyHash,
        kind: HashMapSlotKind,
        frozenAt: UInt64
    ) throws(XitDBError) -> (pointer: SlotPointer, isNew: Bool) {
        var indexPosition = indexPosition
        var level = 0
        while true {
            let slotIndex = try hash.index(atLevel: level)
            let slotPosition = try indexPosition.offset(by: Slot.byteCount * UInt64(slotIndex))
            let slot = try reader.slot(at: slotPosition)

            switch slot.tag {
            case .none:
                // Nothing here yet: append a pair and point the slot at it.
                let pointer = try appendPair(hash: hash, trieSlotPosition: slotPosition, kind: kind)
                return (pointer, true)

            case .index:
                let blockPosition = try copyIndexBlockIfOld(slot.value, frozenAt: frozenAt)
                if blockPosition != slot.value {
                    // Point the slot at the copy.
                    try write(Slot(value: blockPosition, tag: .index), at: slotPosition)
                }
                indexPosition = blockPosition
                level += 1

            case .kvPair:
                let existing = try reader.hashedPair(at: slot.value)
                if existing.hash == hash {
                    if try isOld(slot.value, frozenAt: frozenAt) {
                        // The pair is older than this transaction: copy it,
                        // and point the slot at the copy.
                        let pairPosition = try storage.length()
                        try write(existing.pair, hash: hash, at: pairPosition)
                        let copySlot = Slot(value: pairPosition, tag: .kvPair)
                        try write(copySlot, at: slotPosition)
                        let pointer = try DatabaseReader.pairSlotPointer(
                            kind,
                            trieSlotPosition: slotPosition,
                            trieSlot: copySlot,
                            pairPosition: pairPosition,
                            pair: existing.pair,
                            hashSize: header.hashSize
                        )
                        return (pointer, false)
                    }
                    let pointer = try DatabaseReader.pairSlotPointer(
                        kind,
                        trieSlotPosition: slotPosition,
                        trieSlot: slot,
                        pairPosition: slot.value,
                        pair: existing.pair,
                        hashSize: header.hashSize
                    )
                    return (pointer, false)
                }
                // Another key's pair is in the way.
                let pointer = try splitPair(
                    slot,
                    existingHash: existing.hash,
                    at: slotPosition,
                    level: level,
                    hash: hash,
                    kind: kind
                )
                return (pointer, true)

            default:
                throw .unexpectedTag
            }
        }
    }

    /// Appends a pair for `hash` with empty key and value slots, and points
    /// the trie slot at `trieSlotPosition` to it.
    private func appendPair(
        hash: KeyHash,
        trieSlotPosition: UInt64,
        kind: HashMapSlotKind
    ) throws(XitDBError) -> SlotPointer {
        let pairPosition = try storage.length()
        let pair = KeyValuePair(keySlot: Slot(), valueSlot: Slot())
        try write(pair, hash: hash, at: pairPosition)
        let trieSlot = Slot(value: pairPosition, tag: .kvPair)
        try write(trieSlot, at: trieSlotPosition)
        return try DatabaseReader.pairSlotPointer(
            kind,
            trieSlotPosition: trieSlotPosition,
            trieSlot: trieSlot,
            pairPosition: pairPosition,
            pair: pair,
            hashSize: header.hashSize
        )
    }

    /// Makes room for a new key where another key's pair occupies its trie
    /// slot: the existing pair moves down into a new index block, and so on
    /// level by level until the two hashes select different slots.
    ///
    /// Zig does this by recursion, writing the link to each new block after
    /// the levels below it are done. The blocks are appended one after
    /// another with nothing in between, so the links can be written
    /// afterwards from their positions alone, deepest first as Zig does.
    /// Doing it without recursion keeps the depth of a trie, which a file
    /// decides, from becoming the depth of the call stack.
    private func splitPair(
        _ existingSlot: Slot,
        existingHash: KeyHash,
        at slotPosition: UInt64,
        level: Int,
        hash: KeyHash,
        kind: HashMapSlotKind
    ) throws(XitDBError) -> SlotPointer {
        let levels = Int(header.hashSize) * 2
        var firstBlockPosition: UInt64 = 0
        var blockCount: UInt64 = 0
        var level = level
        var result: SlotPointer

        while true {
            // The next level down must exist for both hashes.
            if level + 1 >= levels { throw .keyOffsetExceeded }
            let existingIndex = try existingHash.index(atLevel: level + 1)

            let blockPosition = try storage.length()
            if blockCount == 0 { firstBlockPosition = blockPosition }
            blockCount += 1
            try writeEmptyIndexBlock(at: blockPosition)
            try write(existingSlot, at: try blockPosition.offset(by: Slot.byteCount * UInt64(existingIndex)))

            level += 1
            let newIndex = try hash.index(atLevel: level)
            if newIndex != existingIndex {
                // The hashes part ways here: the new pair gets a slot of its
                // own in this block.
                result = try appendPair(
                    hash: hash,
                    trieSlotPosition: try blockPosition.offset(by: Slot.byteCount * UInt64(newIndex)),
                    kind: kind
                )
                break
            }
        }

        // Link each new block from the slot above it, deepest first. Block
        // `n` hangs from the slot the new key selects in block `n - 1`, and
        // the first from the slot this started at.
        var blockIndex = blockCount
        while blockIndex > 0 {
            blockIndex -= 1
            let blockPosition = try firstBlockPosition.offset(by: IndexBlock.byteCount * blockIndex)
            let linkPosition: UInt64
            if blockIndex == 0 {
                linkPosition = slotPosition
            } else {
                let parentPosition = try firstBlockPosition.offset(by: IndexBlock.byteCount * (blockIndex - 1))
                let parentLevel = level - Int(blockCount - blockIndex)
                let parentIndex = try hash.index(atLevel: parentLevel)
                linkPosition = try parentPosition.offset(by: Slot.byteCount * UInt64(parentIndex))
            }
            try write(Slot(value: blockPosition, tag: .index), at: linkPosition)
        }

        return result
    }

    /// Removes the entry for a hash from a map's trie.
    ///
    /// On the way back up, an index block left with nothing in it, or with a
    /// single pair, is dropped: its parent's slot takes the pair, or
    /// becomes empty. A block that stays is copied first if it is older than
    /// this transaction.
    ///
    /// Zig does this by recursion. Here the way down is remembered as a list
    /// of block positions, for the reason given at `splitPair`.
    ///
    /// - Throws: `keyNotFound` if the map has no entry for the hash.
    private func removeMapSlot(indexPosition: UInt64, hash: KeyHash, frozenAt: UInt64) throws(XitDBError) {
        // The way down: the position of the block at each level.
        var blockPositions: [UInt64] = []
        var position = indexPosition
        descent: while true {
            let level = blockPositions.count
            let slotIndex = try hash.index(atLevel: level)
            let block = try reader.indexBlock(at: position)
            blockPositions.append(position)
            let slot = block.slots[slotIndex]
            switch slot.tag {
            case .none:
                throw .keyNotFound
            case .index:
                position = slot.value
            case .kvPair:
                let existing = try reader.hashedPair(at: slot.value)
                guard existing.hash == hash else { throw .keyNotFound }
                break descent
            default:
                throw .unexpectedTag
            }
        }

        // The way back up. `replacement` is what the slot one level up must
        // hold in place of the block, or the pair, that was below it.
        var replacement = Slot()
        var level = blockPositions.count - 1
        while level > 0 {
            let blockPosition = blockPositions[level]
            let slotIndex = try hash.index(atLevel: level)
            var block = try reader.indexBlock(at: blockPosition)
            block.slots[slotIndex] = replacement

            // Find out whether the block still holds more than one thing.
            var onlySlot: Slot? = Slot()
            for index in block.slots.indices {
                let slot = block.slots[index]
                if slot.tag == .none { continue }
                if let found = onlySlot, found.tag != .none {
                    onlySlot = nil
                    break
                }
                onlySlot = slot
            }

            if let onlySlot, onlySlot.tag == .none || onlySlot.tag == .kvPair {
                // Nothing is left, or a single pair: the block is no longer
                // needed.
                replacement = onlySlot
            } else {
                // More than one slot is in use, or the one that is points at
                // another block. The block stays, with its slot updated.
                let keptPosition = try copyIndexBlockIfOld(blockPosition, frozenAt: frozenAt)
                try write(replacement, at: try keptPosition.offset(by: Slot.byteCount * UInt64(slotIndex)))
                replacement = Slot(value: keptPosition, tag: .index)
            }
            level -= 1
        }

        // The root block is written to directly.
        let rootIndex = try hash.index(atLevel: 0)
        try write(replacement, at: try indexPosition.offset(by: Slot.byteCount * UInt64(rootIndex)))
    }
}
