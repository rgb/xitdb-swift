// The path parts of a linked array list: Zig's `linked_array_list_*` cases
// of `readSlotPointer` in write mode. Each reads the list's header, works on
// the tree, and writes the header back before the rest of the path runs, so
// that a failure further on leaves the tree and the header consistent.

extension Database {
    /// Writes a list's header at `position`.
    func write(_ header: BTreeHeader, at position: UInt64) throws(XitDBError) {
        let bytes = InlineArray<16, UInt8> { (output: inout OutputSpan<UInt8>) in
            header.encode(into: &output)
        }
        try storage.write(bytes.span, at: position)
    }

    /// The header of the list a slot holds.
    ///
    /// - Throws: `unexpectedTag` if the slot holds something else.
    private func linkedArrayListHeader(_ pointer: SlotPointer) throws(XitDBError) -> BTreeHeader {
        if pointer.slot.tag != .linkedArrayList { throw .unexpectedTag }
        return try reader.bTreeHeader(at: pointer.slot.value)
    }

    func linkedArrayListInit(_ pointer: SlotPointer, frozenAt: UInt64) throws(XitDBError) -> SlotPointer {
        guard let position = pointer.position else { throw .cursorNotWriteable }

        var headerPtr: UInt64
        switch pointer.slot.tag {
        case .none:
            // An empty tree: one empty leaf, then the header.
            let rootPtr = try bTreeNewRoot()
            headerPtr = try storage.length()
            try write(BTreeHeader(size: 0, rootPtr: rootPtr), at: headerPtr)
        case .linkedArrayList:
            headerPtr = pointer.slot.value
            // Copy the header into this transaction unless it was made in
            // it, so that past moments still pointing at the old header are
            // unaffected. Only the header is updated in place by later
            // operations; a node is copied when it is old.
            if try isOld(headerPtr, frozenAt: frozenAt) {
                let header = try reader.bTreeHeader(at: headerPtr)
                headerPtr = try storage.length()
                try write(header, at: headerPtr)
            }
        default:
            throw .unexpectedTag
        }

        let slot = Slot(value: headerPtr, tag: .linkedArrayList)
        try write(slot, at: position)
        return SlotPointer(position: position, slot: slot)
    }

    func linkedArrayListGet(_ pointer: SlotPointer, index: Int64, frozenAt: UInt64) throws(XitDBError) -> SlotPointer {
        switch pointer.slot.tag {
        case .none: throw .keyNotFound
        case .linkedArrayList: break
        default: throw .unexpectedTag
        }
        let headerPtr = pointer.slot.value
        let header = try reader.bTreeHeader(at: headerPtr)
        guard let rank = DatabaseReader.linkedArrayListRank(index: index, size: header.size) else {
            throw .keyNotFound
        }
        // Copy the way down to the slot, so that the write is kept.
        let found = try bTreeGetForWrite(rootPtr: header.rootPtr, rank: rank, frozenAt: frozenAt)
        // Update the header before a callback can freeze it.
        if found.rootPtr != header.rootPtr {
            try write(BTreeHeader(size: header.size, rootPtr: found.rootPtr), at: headerPtr)
        }
        return SlotPointer(position: found.valuePosition, slot: found.slot)
    }

    func linkedArrayListAppend(_ pointer: SlotPointer, frozenAt: UInt64) throws(XitDBError) -> SlotPointer {
        let header = try linkedArrayListHeader(pointer)
        return try linkedArrayListInsert(pointer, header: header, rank: header.size, frozenAt: frozenAt)
    }

    func linkedArrayListInsert(_ pointer: SlotPointer, index: Int64, frozenAt: UInt64) throws(XitDBError) -> SlotPointer
    {
        let header = try linkedArrayListHeader(pointer)
        guard let rank = DatabaseReader.linkedArrayListRank(index: index, size: header.size) else {
            throw .keyNotFound
        }
        return try linkedArrayListInsert(pointer, header: header, rank: rank, frozenAt: frozenAt)
    }

    /// Inserts a placeholder at `rank` and moves to it. An append is an
    /// insert at the end.
    private func linkedArrayListInsert(
        _ pointer: SlotPointer,
        header: BTreeHeader,
        rank: UInt64,
        frozenAt: UInt64
    ) throws(XitDBError) -> SlotPointer {
        // A size that cannot grow comes from a damaged file.
        guard header.size < .max else { throw .invalidBTreeNode }
        let result = try bTreeInsert(rootPtr: header.rootPtr, rank: rank, frozenAt: frozenAt)
        let newRootPtr = try bTreeGrowRoot(result)
        // Update the header before the value is filled in, so that a
        // failure in the rest of the path leaves the tree and the header
        // consistent.
        try write(BTreeHeader(size: header.size + 1, rootPtr: newRootPtr), at: pointer.slot.value)
        return SlotPointer(position: result.valuePosition, slot: Slot())
    }

    func linkedArrayListSlice(_ pointer: SlotPointer, offset: UInt64, size: UInt64) throws(XitDBError) {
        let header = try linkedArrayListHeader(pointer)
        // Checked without overflow: the offset and the size together could
        // wrap.
        if offset > header.size || size > header.size - offset { throw .keyNotFound }

        // Drop the elements before the offset, then keep `size` of the rest.
        let afterOffset = try bTreeSplit(rootPtr: header.rootPtr, rank: offset)
        let sliced = try bTreeSplit(rootPtr: afterOffset.right, rank: size)
        try write(BTreeHeader(size: size, rootPtr: sliced.left), at: pointer.slot.value)
    }

    func linkedArrayListConcat(_ pointer: SlotPointer, other: Slot) throws(XitDBError) {
        let headerA = try linkedArrayListHeader(pointer)
        if other.tag != .linkedArrayList { throw .unexpectedTag }
        let headerB = try reader.bTreeHeader(at: other.value)
        // A total that does not fit comes from a damaged file.
        let (total, overflow) = headerA.size.addingReportingOverflow(headerB.size)
        if overflow { throw .invalidBTreeNode }

        // The joined tree shares subtrees with both lists, and the other
        // list stays in use, so everything written so far is frozen: later
        // writes copy those nodes instead of changing a node that is still
        // referred to elsewhere. (Zig freezes before the join; the joined
        // nodes themselves are therefore not frozen. That is reproduced
        // until parity; decision D18 changes it afterwards.)
        guard transactionStart != nil else { throw .expectedTxStart }
        transactionStart = try storage.length()
        let newRootPtr = try bTreeJoin(headerA.rootPtr, headerB.rootPtr)
        try write(BTreeHeader(size: total, rootPtr: newRootPtr), at: pointer.slot.value)
    }

    func linkedArrayListRemove(_ pointer: SlotPointer, index: Int64, frozenAt: UInt64) throws(XitDBError) {
        let header = try linkedArrayListHeader(pointer)
        guard let rank = DatabaseReader.linkedArrayListRank(index: index, size: header.size) else {
            throw .keyNotFound
        }

        let newRootPtr: UInt64
        if header.size == 1 {
            newRootPtr = try bTreeNewRoot()
        } else {
            var root = try bTreeRemove(rootPtr: header.rootPtr, rank: rank, frozenAt: frozenAt)
            var rootPtr = try bTreeWriteNode(root, oldPtr: header.rootPtr, frozenAt: frozenAt)
            // A root left with one child is replaced by it.
            var levels = 0
            while root.kind == .branch, root.num == 1 {
                guard root.children[0].tag == .index, levels < BTree.maxHeight else { throw .invalidBTreeNode }
                rootPtr = root.children[0].value
                root = try reader.bTreeNode(at: rootPtr)
                levels += 1
            }
            newRootPtr = rootPtr
        }
        try write(BTreeHeader(size: header.size - 1, rootPtr: newRootPtr), at: pointer.slot.value)
    }
}
