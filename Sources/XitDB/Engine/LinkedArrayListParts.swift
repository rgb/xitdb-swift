// The path parts of a linked array list: Zig's `linked_array_list_*` cases
// of `readSlotPointer` in write mode. Each reads the list's header, works on
// the tree, and writes the header back before the rest of the path runs, so
// that a failure further on leaves the tree and the header consistent.

extension Database {
    /// Writes a list's header at `position`.
    func write(_ header: BTreeHeader, at position: UInt64) throws(XitDBError) {
        try checkPosition(position)
        let bytes = InlineArray<16, UInt8> { (output: inout OutputSpan<UInt8>) in
            header.encode(into: &output)
        }
        try storage.write(bytes.span, at: position)
        noteWrite()
    }

    /// Writes a tree's header back, which a sorted get always does: one
    /// that is unchanged does not count as a write of the transaction's,
    /// as an init part's unchanged slot does not.
    func writeHeader(_ header: BTreeHeader, at position: UInt64, unchangedFrom old: BTreeHeader) throws(XitDBError) {
        if header != old { try checkPosition(position) }
        let bytes = InlineArray<16, UInt8> { (output: inout OutputSpan<UInt8>) in header.encode(into: &output) }
        try storage.write(bytes.span, at: position)
        if header != old { noteWrite() }
    }

    /// The header of the list a slot holds.
    ///
    /// - Throws: `unexpectedTag` if the slot holds something else.
    private func linkedArrayListHeader(_ pointer: SlotPointer) throws(XitDBError) -> BTreeHeader {
        if pointer.slot.tag != .linkedArrayList { throw .unexpectedTag }
        return try reader.bTreeHeader(at: pointer.slot.value)
    }

    func linkedArrayListInit(_ pointer: SlotPointer, frozenAt: UInt64) throws(XitDBError) -> SlotPointer {
        guard let position = pointer.position else { throw .cursorNotWritable }

        var headerPtr: UInt64
        switch pointer.slot.tag {
        case .none:
            // An empty tree: one empty leaf, then the header.
            let rootPtr = try bTreeNewRoot()
            headerPtr = try storage.length
            try write(BTreeHeader(size: 0, rootPtr: rootPtr), at: headerPtr)
        case .linkedArrayList:
            headerPtr = pointer.slot.value
            // Copy the header into this transaction unless it was made in
            // it, so that past moments still pointing at the old header are
            // unaffected. Only the header is updated in place by later
            // operations; a node is copied when it is old.
            if try isOld(headerPtr, frozenAt: frozenAt) {
                let header = try reader.bTreeHeader(at: headerPtr)
                headerPtr = try storage.length
                try write(header, at: headerPtr)
            }
        default:
            throw .unexpectedTag
        }

        let slot = Slot(value: headerPtr, tag: .linkedArrayList)
        try writeSlot(slot, at: position, unchangedFrom: pointer.slot)
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
        // In write mode the get rewrites the header for a copied leaf: a
        // frozen or committed header is refused here, before any node is
        // copied.
        try checkPosition(headerPtr)
        guard let rank = DatabaseReader.linkedArrayListRank(index: index, size: header.size) else {
            throw .indexOutOfRange
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
        // The part ends by writing the header back in place: a frozen or
        // committed header is refused here, before the tree is touched.
        try checkPosition(pointer.slot.value)
        return try linkedArrayListInsert(pointer, header: header, rank: header.size, frozenAt: frozenAt)
    }

    func linkedArrayListInsert(_ pointer: SlotPointer, index: Int64, frozenAt: UInt64) throws(XitDBError) -> SlotPointer
    {
        let header = try linkedArrayListHeader(pointer)
        // The part ends by writing the header back in place: a frozen or
        // committed header is refused here, before the tree is touched.
        try checkPosition(pointer.slot.value)
        guard let rank = DatabaseReader.linkedArrayListRank(index: index, size: header.size) else {
            throw .indexOutOfRange
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
        // The part ends by writing the header back in place: a frozen or
        // committed header is refused here, before the tree is touched.
        try checkPosition(pointer.slot.value)
        // Checked without overflow: the offset and the size together could
        // wrap.
        if offset > header.size || size > header.size - offset { throw .indexOutOfRange }

        // Drop the elements before the offset, then keep `size` of the rest.
        let afterOffset = try bTreeSplit(rootPtr: header.rootPtr, rank: offset)
        let sliced = try bTreeSplit(rootPtr: afterOffset.right, rank: size)
        try write(BTreeHeader(size: size, rootPtr: sliced.left), at: pointer.slot.value)
    }

    func linkedArrayListConcat(_ pointer: SlotPointer, other: Slot) throws(XitDBError) {
        let headerA = try linkedArrayListHeader(pointer)
        try checkPosition(pointer.slot.value)
        if other.tag != .linkedArrayList { throw .unexpectedTag }
        let headerB = try reader.bTreeHeader(at: other.value)
        // A total that does not fit comes from a damaged file.
        let (total, overflow) = headerA.size.addingReportingOverflow(headerB.size)
        if overflow { throw .invalidBTreeNode }

        guard transactionStart != nil else { throw .expectedTxStart }
        // The join ends in a freeze, which a byte writer's open record
        // cannot survive: refused before the join writes anything.
        guard openByteWriters == 0 else { throw .byteWriterOpen }
        let newRootPtr = try bTreeJoin(headerA.rootPtr, headerB.rootPtr)
        try write(BTreeHeader(size: total, rootPtr: newRootPtr), at: pointer.slot.value)
        // The joined tree shares subtrees with both lists, and the other
        // list stays in use, so everything written so far is frozen, the
        // joined nodes included: an init copies a frozen header, and the
        // copy shares its nodes, so nothing may change them in place. Zig
        // at 6b93af1 froze before the join; its fix branch freezes after it
        // (finding 22), and so does this.
        transactionStart = try storage.length
        noteFreeze()
    }

    func linkedArrayListRemove(_ pointer: SlotPointer, index: Int64, frozenAt: UInt64) throws(XitDBError) {
        let header = try linkedArrayListHeader(pointer)
        // The part ends by writing the header back in place: a frozen or
        // committed header is refused here, before the tree is touched.
        try checkPosition(pointer.slot.value)
        guard let rank = DatabaseReader.linkedArrayListRank(index: index, size: header.size) else {
            throw .indexOutOfRange
        }

        let newRootPtr: UInt64
        if header.size == 1 {
            newRootPtr = try bTreeNewRoot()
        } else {
            var root = try bTreeRemove(rootPtr: header.rootPtr, rank: rank, frozenAt: frozenAt)
            var rootPtr = try writeNodeVersion(root, oldPtr: header.rootPtr, frozenAt: frozenAt)
            // A root left with one child is replaced by it.
            var levels = 0
            while root.kind == .branch, root.num == 1 {
                guard root.child(0).tag == .index, levels < BTree.maxHeight else { throw .invalidBTreeNode }
                rootPtr = root.child(0).value
                root = try reader.bTreeNode(at: rootPtr)
                levels += 1
            }
            newRootPtr = rootPtr
        }
        try write(BTreeHeader(size: header.size - 1, rootPtr: newRootPtr), at: pointer.slot.value)
    }
}
