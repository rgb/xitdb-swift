// The path parts of a sorted map or set: Zig's `sorted_map_*` cases of
// `readSlotPointer` in write mode.

extension Database {
    func sortedMapInit(_ pointer: SlotPointer, set: Bool, frozenAt: UInt64) throws(XitDBError) -> SlotPointer {
        guard let position = pointer.position else { throw .cursorNotWriteable }
        let tag: Tag = set ? .sortedSet : .sortedMap

        var headerPtr: UInt64
        switch pointer.slot.tag {
        case .none:
            // An empty tree: one empty leaf, then the header.
            let rootPtr = try appendNode(SortedNode(kind: .leaf, num: 0))
            headerPtr = try storage.length
            try write(BTreeHeader(size: 0, rootPtr: rootPtr), at: headerPtr)
        case .sortedMap, .sortedSet:
            headerPtr = pointer.slot.value
            // Copy the header into this transaction unless it was made in
            // it.
            if try isOld(headerPtr, frozenAt: frozenAt) {
                let header = try reader.bTreeHeader(at: headerPtr)
                headerPtr = try storage.length
                try write(header, at: headerPtr)
            }
        default:
            throw .unexpectedTag
        }

        // The tag is the one asked for, which turns a map into a set or back.
        let slot = Slot(value: headerPtr, tag: tag)
        try write(slot, at: position)
        return SlotPointer(position: position, slot: slot)
    }

    func sortedMapGet(
        _ pointer: SlotPointer,
        kind: HashMapSlotKind,
        key: SortedKey,
        frozenAt: UInt64
    ) throws(XitDBError) -> SlotPointer {
        let header = try reader.sortedMapHeader(pointer.slot)
        // Only a set that is just touching the key can leave out the value.
        let keyOnly = pointer.slot.tag == .sortedSet && kind == .key
        let result = try key.withBytes { (bytes: Span<UInt8>) throws(XitDBError) in
            try sortedPut(rootPtr: header.rootPtr, key: bytes, keyOnly: keyOnly, frozenAt: frozenAt)
        }
        let newRootPtr = try sortedGrowRoot(result)

        // Update the header before the value is filled in, so that a
        // failure in the rest of the path leaves the tree and the header
        // consistent: the entry exists, with an empty value.
        var size = header.size
        if result.added {
            // A size that cannot grow comes from a damaged file.
            guard size < .max else { throw .invalidBTreeNode }
            size += 1
        }
        try write(BTreeHeader(size: size, rootPtr: newRootPtr), at: pointer.slot.value)
        return try reader.sortedTargetSlot(result.entry, kind)
    }

    func sortedMapRemove(_ pointer: SlotPointer, key: SortedKey, frozenAt: UInt64) throws(XitDBError) {
        let header = try reader.sortedMapHeader(pointer.slot)
        let result = try key.withBytes { (bytes: Span<UInt8>) throws(XitDBError) in
            try sortedRemove(rootPtr: header.rootPtr, key: bytes, frozenAt: frozenAt)
        }
        guard result.found else { throw .keyNotFound }
        // The key was found in a map whose header says it is empty.
        guard header.size > 0 else { throw .invalidBTreeNode }
        try write(BTreeHeader(size: header.size - 1, rootPtr: result.rootPtr), at: pointer.slot.value)
    }
}
