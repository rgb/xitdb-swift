// The count-augmented B+tree of a sorted map or set: Zig's `sorted*`
// functions. Leaves hold entries in key order, branches hold their children
// with a separator key and a count for each, and a key is found by binary
// search at every level. It shares the linked array list's header, its
// constants, its rule for reusing a node and its descent by rank.
//
// As for the linked array list, Zig's recursion is a loop with an explicit
// stack, bounded by the greatest height a tree can have, and every rank,
// index and count is checked against its node before it is used.

/// Up to seventeen entries of a sorted node, with the separators and
/// counts of a branch: what a put assembles new nodes from.
struct SortedEntries {
    var slots: InlineArray<17, Slot> = InlineArray(repeating: Slot())
    var separators: InlineArray<17, Slot> = InlineArray(repeating: Slot())
    var counts: InlineArray<17, UInt64> = InlineArray(repeating: 0)
    var count = 0

    /// Appends the entries of a node from `from` up to `to`.
    mutating func append(_ node: SortedNode, from: Int, to: Int) {
        for index in from..<to {
            if node.kind == .leaf {
                append(node.entry(index))
            } else {
                append(node.child(index), separator: node.separator(index), count: node.count(index))
            }
        }
    }

    mutating func append(_ slot: Slot, separator: Slot = Slot(), count: UInt64 = 0) {
        slots[self.count] = slot
        separators[self.count] = separator
        counts[self.count] = count
        self.count += 1
    }

    /// A node of the given kind holding the entries from `from` up to `to`.
    func node(_ kind: BTreeNodeKind, from: Int, to: Int) -> SortedNode {
        var node = SortedNode(kind: kind, num: UInt8(to - from))
        for index in from..<to {
            if kind == .leaf {
                node.setEntry(slots[index], at: index - from)
            } else {
                node.setChild(slots[index], at: index - from)
                node.setSeparator(separators[index], at: index - from)
                node.setCount(counts[index], at: index - from)
            }
        }
        return node
    }
}

/// What a put gives back: the node now at the root of the subtree, the
/// elements beneath it, the entry to read or write, whether an entry was
/// added (as opposed to found), and the right sibling with its separator
/// if the node split.
struct SortedInsertResult {
    var nodePtr: UInt64
    var count: UInt64
    var entry: Slot
    var added: Bool
    var split: (nodePtr: UInt64, count: UInt64, separator: Slot)?
}

extension DatabaseReader {
    /// Reads the sorted node at `position` in one call, which asks for a
    /// branch's worth of bytes and may get fewer for a leaf near the end.
    ///
    /// - Throws: `invalidBTreeNodeKind` or `invalidBTreeNode` for a bad
    ///   header, `invalidEnumTag` for an unknown slot tag, `endOfStream` if
    ///   the file ends inside the node.
    func sortedNode(at position: UInt64) throws(XitDBError) -> SortedNode {
        var buffer = InlineArray<418, UInt8>(repeating: 0)
        var span = buffer.mutableSpan
        let read = try storage.read(into: &span, at: position)
        return try SortedNode(decoding: buffer.span.extracting(0..<read))
    }

    /// The slot of the entry at `rank` in a sorted map's tree.
    func sortedSlot(rootPtr: UInt64, rank: UInt64) throws(XitDBError) -> SlotPointer {
        try slotByRank(rootPtr: rootPtr, rank: rank, in: SortedNode.self)
    }

    /// The pair an entry of a sorted leaf stands for: Zig's `readKvPair`.
    /// A key-only entry is its own key slot, with an empty value.
    func sortedEntryPair(_ entry: Slot) throws(XitDBError) -> KeyValuePair {
        try keyValuePair(entry).pair
    }

    // MARK: Keys

    /// Compares two keys as bytes: the first difference decides, and a key
    /// that is a prefix of the other comes first.
    static func order(_ stored: Span<UInt8>, _ target: Span<UInt8>) -> KeyOrder {
        let common = min(stored.count, target.count)
        for index in 0..<common where stored[index] != target[index] {
            return stored[index] < target[index] ? .less : .greater
        }
        if stored.count == target.count { return .equal }
        return stored.count < target.count ? .less : .greater
    }

    /// Compares the key stored at `keySlot` with `target`: Zig's
    /// `compareKey`. A long key is streamed in chunks of 256 bytes, the
    /// length and the first chunk read together, so that no key allocates.
    ///
    /// - Throws: `unexpectedTag` if the slot does not hold bytes, or
    ///   `endOfStream` if the key's length reaches past the end of the file.
    func compareKey(_ keySlot: Slot, to target: Span<UInt8>) throws(XitDBError) -> KeyOrder {
        switch keySlot.tag {
        case .shortBytes:
            let bytes = ByteArrayFormat.valueBytes(of: keySlot)
            let count = ByteArrayFormat.shortByteCount(of: keySlot)
            return Self.order(bytes.span.extracting(0..<count), target)
        case .bytes:
            var chunk = InlineArray<256, UInt8>(repeating: 0)
            func fill(at position: UInt64) throws(XitDBError) -> Int {
                var span = chunk.mutableSpan
                return try storage.read(into: &span, at: position)
            }
            var read = try fill(at: keySlot.value)
            // A storage may give fewer bytes than the length itself takes,
            // at the end of the file or short of what its length promises;
            // either way there is no record to compare.
            guard read >= Int(ByteArrayFormat.lengthByteCount) else { throw .endOfStream }
            var remaining: UInt64 = chunk.span.bigEndian(at: 0)
            // A length that reaches past the file is a damaged record: it
            // is reported before any of it is compared. For a key that fits
            // the first chunk, the chunk itself says whether the bytes are
            // there; asking the storage for its length, which is a system
            // call on a file, is kept for the longer keys.
            var position = try keySlot.value.offset(by: ByteArrayFormat.lengthByteCount)
            let firstChunk = UInt64(read - Int(ByteArrayFormat.lengthByteCount))
            if remaining > firstChunk {
                if remaining <= UInt64(chunk.count - Int(ByteArrayFormat.lengthByteCount)) {
                    // the whole key would have fitted: the file ended inside it
                    throw .endOfStream
                }
                let length = try storage.length
                guard position <= length, remaining <= length - position else { throw .endOfStream }
            }

            var storedStart = Int(ByteArrayFormat.lengthByteCount)
            var targetStart = 0
            while true {
                let available = read - storedStart
                let n = Int(min(UInt64(available), remaining))
                let targetCount = min(n, target.count - targetStart)
                let order = Self.order(
                    chunk.span.extracting(storedStart..<(storedStart + n)),
                    target.extracting(targetStart..<(targetStart + targetCount))
                )
                if order != .equal { return order }
                targetStart += n
                remaining -= UInt64(n)
                if remaining == 0 { return targetStart < target.count ? .less : .equal }
                position = try position.offset(by: UInt64(available))
                read = try fill(at: position)
                // The length promised the bytes; a storage that does not
                // give them is reported rather than asked again.
                guard read > 0 else { throw .endOfStream }
                storedStart = 0
            }
        default:
            throw .unexpectedTag
        }
    }

    // MARK: Searching

    /// The child of a branch whose subtree may hold `key`: the last whose
    /// separator is at most the key, or the first. Zig's
    /// `sortedBranchSearch`; `separators[0]` is never compared.
    ///
    /// - Precondition: The branch has at least one child.
    func sortedBranchSearch(_ node: SortedNode, key: Span<UInt8>) throws(XitDBError) -> Int {
        var low = 1
        var high = Int(node.num)
        while low < high {
            let mid = (low + high) / 2
            switch try compareKey(node.separator(mid), to: key) {
            case .less, .equal: low = mid + 1
            case .greater: high = mid
            }
        }
        return low - 1
    }

    /// Where `key` is in a leaf, or where it would be put: the number of
    /// entries below it either way. Zig's `sortedLeafSearch`.
    func sortedLeafSearch(_ node: SortedNode, key: Span<UInt8>) throws(XitDBError) -> (index: Int, found: Bool) {
        var low = 0
        var high = Int(node.num)
        while low < high {
            let mid = (low + high) / 2
            let pair = try sortedEntryPair(node.entry(mid))
            switch try compareKey(pair.keySlot, to: key) {
            case .equal: return (mid, true)
            case .less: low = mid + 1
            case .greater: high = mid
            }
        }
        return (low, false)
    }

    /// The child a key's search leads to in a branch, checked.
    ///
    /// - Throws: `invalidBTreeNode` if the branch has no children or the
    ///   child is not a node.
    private func sortedChild(of node: SortedNode, key: Span<UInt8>) throws(XitDBError) -> (index: Int, position: UInt64)
    {
        guard node.num > 0 else { throw .invalidBTreeNode }
        let index = try sortedBranchSearch(node, key: key)
        guard node.child(index).tag == .index else { throw .invalidBTreeNode }
        return (index, node.child(index).value)
    }

    /// The entry for `key` in the tree at `rootPtr`, or `nil`: Zig's
    /// `sortedGet`.
    func sortedGet(rootPtr: UInt64, key: Span<UInt8>) throws(XitDBError) -> Slot? {
        var nodePtr = rootPtr
        for _ in 0...BTree.maxHeight {
            let node = try sortedNode(at: nodePtr)
            switch node.kind {
            case .leaf:
                let search = try sortedLeafSearch(node, key: key)
                return search.found ? node.entry(search.index) : nil
            case .branch:
                nodePtr = try sortedChild(of: node, key: key).position
            }
        }
        throw .invalidBTreeNode
    }

    /// The number of keys below `key` in the tree at `rootPtr`, whether or
    /// not it is there: Zig's `sortedRank`.
    ///
    /// - Throws: `invalidBTreeNode` if the counts on the way, which came
    ///   from the file, add up past what a number holds, and the errors of
    ///   the descent.
    func sortedRank(rootPtr: UInt64, key: Span<UInt8>) throws(XitDBError) -> UInt64 {
        var nodePtr = rootPtr
        var rank: UInt64 = 0
        for _ in 0...BTree.maxHeight {
            let node = try sortedNode(at: nodePtr)
            switch node.kind {
            case .leaf:
                let search = try sortedLeafSearch(node, key: key)
                return try rank.addingCount(UInt64(search.index))
            case .branch:
                let (index, position) = try sortedChild(of: node, key: key)
                for below in 0..<index {
                    rank = try rank.addingCount(node.count(below))
                }
                nodePtr = position
            }
        }
        throw .invalidBTreeNode
    }

    /// The slot a path arrives at for an entry: the entry itself, its key,
    /// or its value. Only the value can be written through; a key stays
    /// where it is, since moving it would leave the entry out of order.
    /// Zig's `sortedTargetSlot`.
    func sortedTargetSlot(_ entry: Slot, _ kind: HashMapSlotKind) throws(XitDBError) -> SlotPointer {
        switch kind {
        case .kvPair:
            return SlotPointer(position: nil, slot: entry)
        case .key:
            return SlotPointer(position: nil, slot: try sortedEntryPair(entry).keySlot)
        case .value:
            return SlotPointer(
                position: KeyValuePair.valuePosition(of: entry, hashSize: hashSize),
                slot: try sortedEntryPair(entry).valueSlot
            )
        }
    }
}

extension UInt64 {
    /// This rank moved past `count` more entries.
    ///
    /// Ranks are summed from the counts of the branches on the way down,
    /// which came from the file, so that a damaged file is reported and
    /// cannot give a rank that wrapped.
    ///
    /// - Throws: `invalidBTreeNode` if the sum is past what a number holds.
    func addingCount(_ count: UInt64) throws(XitDBError) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(count)
        guard !overflow else { throw .invalidBTreeNode }
        return sum
    }
}

extension Database {
    // MARK: Writing records

    /// Writes a key: in a slot when it has at most eight bytes and no zero
    /// byte, as a byte record otherwise. Zig's `writeKey`.
    func writeKey(_ key: Span<UInt8>) throws(XitDBError) -> Slot {
        if ByteArrayFormat.isShort(key, hasFormatTag: false) {
            return ByteArrayFormat.shortSlot(key, formatTag: nil)
        }
        let position = try storage.length
        try write(UInt64(key.count), at: position)
        try storage.write(key, at: try position.offset(by: ByteArrayFormat.lengthByteCount))
        noteWrite()
        return Slot(value: position, tag: .bytes)
    }

    /// Appends a pair record of `tag` for `pair` and returns the slot that
    /// points at it: Zig's `writeKvPair`. A sorted pair has no hash; a
    /// hashed one, which only a crafted file puts in a sorted leaf, keeps
    /// the hash it was read with, as Zig's `decodeKvPair` and
    /// `encodeKvPair` keep it.
    func writeSortedPairRecord(_ tag: Slot.Tag, _ pair: HashedPair) throws(XitDBError) -> Slot {
        let position = try storage.length
        switch tag {
        case .sortedKvPair:
            let bytes = InlineArray<18, UInt8> { (output: inout OutputSpan<UInt8>) in
                pair.pair.encodeSorted(into: &output)
            }
            try storage.write(bytes.span, at: position)
            noteWrite()
        case .kvPair:
            try write(pair.pair, hash: pair.hash, at: position)
        default:
            throw .unexpectedTag
        }
        return Slot(value: position, tag: tag)
    }

    /// Wraps a key slot in a new pair with an empty value, for the caller to
    /// fill in: Zig's `writeSortedPair`.
    func writeSortedPair(keySlot: Slot) throws(XitDBError) -> Slot {
        try writeSortedPairRecord(
            .sortedKvPair, HashedPair(hash: KeyHash(zeros: 0), pair: KeyValuePair(keySlot: keySlot, valueSlot: Slot())))
    }

    // MARK: Put

    /// One node on the way down to a key, with the child the way goes
    /// through.
    private struct SortedFrame: FrameStackElement {
        var position: UInt64
        var node: SortedNode
        var index: Int

        static var placeholder: SortedFrame { SortedFrame(position: 0, node: .placeholder, index: 0) }
    }

    /// Descends from `rootPtr` to the leaf that `key` falls in, keeping the
    /// branches on the way.
    ///
    /// - Throws: `invalidBTreeNode` if a branch has no children, a child is
    ///   not a node, or the tree is deeper than a tree can be.
    private func sortedDescend(
        from rootPtr: UInt64,
        key: Span<UInt8>
    ) throws(XitDBError) -> (branches: FrameStack<SortedFrame>, leafPtr: UInt64, leaf: SortedNode) {
        var branches = FrameStack<SortedFrame>()
        var nodePtr = rootPtr
        while branches.count <= BTree.maxHeight {
            let node = try reader.sortedNode(at: nodePtr)
            if node.kind == .leaf {
                return (branches, nodePtr, node)
            }
            guard node.num > 0 else { throw .invalidBTreeNode }
            let index = try reader.sortedBranchSearch(node, key: key)
            guard node.child(index).tag == .index else { throw .invalidBTreeNode }
            branches.append(SortedFrame(position: nodePtr, node: node, index: index))
            nodePtr = node.child(index).value
        }
        throw .invalidBTreeNode
    }

    /// Puts `key` into the tree at `rootPtr`, or finds it: Zig's
    /// `sortedPut`. The caller writes the value of the entry in the result,
    /// unless `keyOnly`: then a new key is stored as a key-only entry and
    /// an existing one is left as it is.
    ///
    /// The nodes on the way are rewritten in place or copied, as the linked
    /// list's are; when the key is found and nothing below changed, nothing
    /// is written above the leaf.
    func sortedPut(
        rootPtr: UInt64,
        key: Span<UInt8>,
        keyOnly: Bool,
        frozenAt: UInt64
    ) throws(XitDBError) -> SortedInsertResult {
        let (branches, leafPtr, leaf) = try sortedDescend(from: rootPtr, key: key)
        let search = try reader.sortedLeafSearch(leaf, key: key)
        var result: SortedInsertResult
        if search.found {
            var entry = leaf.entry(search.index)
            if keyOnly {
                result = SortedInsertResult(
                    nodePtr: leafPtr, count: UInt64(leaf.num), entry: entry, added: false, split: nil)
            } else {
                // Replace: a key-only entry becomes a pair, and a pair from a
                // past moment is copied, so that its value can be written.
                if KeyValuePair.isKeyOnlyEntry(entry) {
                    entry = try writeSortedPair(keySlot: entry)
                } else if !bTreeReusable(entry.value, frozenAt: frozenAt) {
                    entry = try writeSortedPairRecord(entry.tag, try reader.keyValuePair(entry))
                }
                var written = leaf
                written.setEntry(entry, at: search.index)
                let ptr = try writeNodeVersion(written, oldPtr: leafPtr, frozenAt: frozenAt)
                result = SortedInsertResult(
                    nodePtr: ptr, count: UInt64(leaf.num), entry: entry, added: false, split: nil)
            }
        } else {
            // Insert a new entry where the search ended.
            let keySlot = try writeKey(key)
            let entry = keyOnly ? keySlot : try writeSortedPair(keySlot: keySlot)
            var entries = SortedEntries()
            entries.append(leaf, from: 0, to: search.index)
            entries.append(entry)
            entries.append(leaf, from: search.index, to: Int(leaf.num))
            if entries.count <= BTree.slotCount {
                let ptr = try writeNodeVersion(
                    entries.node(.leaf, from: 0, to: entries.count), oldPtr: leafPtr, frozenAt: frozenAt)
                result = SortedInsertResult(
                    nodePtr: ptr, count: UInt64(entries.count), entry: entry, added: true, split: nil)
            } else {
                // Overflow: two leaves; the new sibling's separator is the
                // key of its first entry.
                let leftCount = BTree.splitCount
                let separator = try reader.sortedEntryPair(entries.slots[leftCount]).keySlot
                let leftPtr = try writeNodeVersion(
                    entries.node(.leaf, from: 0, to: leftCount), oldPtr: leafPtr, frozenAt: frozenAt)
                let rightPtr = try appendNode(entries.node(.leaf, from: leftCount, to: entries.count))
                result = SortedInsertResult(
                    nodePtr: leftPtr,
                    count: UInt64(leftCount),
                    entry: entry,
                    added: true,
                    split: (rightPtr, UInt64(entries.count - leftCount), separator)
                )
            }
        }

        for index in stride(from: branches.count - 1, through: 0, by: -1) {

            let frame = branches[index]
            // Nothing below changed: this branch, and all above it, stay.
            // Zig gives the subtree's count in this result; here it is zero,
            // which is harmless today: a result's count is read only by the
            // branch above, which this skips, and by sortedGrowRoot for a
            // split, which this has none of. A caller that starts to read
            // it must compute it, as Zig does.
            if !result.added, result.nodePtr == frame.node.child(frame.index).value {
                return SortedInsertResult(nodePtr: rootPtr, count: 0, entry: result.entry, added: false, split: nil)
            }
            var entries = SortedEntries()
            entries.append(frame.node, from: 0, to: frame.index)
            entries.append(
                Slot(value: result.nodePtr, tag: .index), separator: frame.node.separator(frame.index),
                count: result.count)
            if let split = result.split {
                entries.append(Slot(value: split.nodePtr, tag: .index), separator: split.separator, count: split.count)
            }
            entries.append(frame.node, from: frame.index + 1, to: Int(frame.node.num))
            if entries.count <= BTree.slotCount {
                let branch = entries.node(.branch, from: 0, to: entries.count)
                let ptr = try writeNodeVersion(branch, oldPtr: frame.position, frozenAt: frozenAt)
                result = SortedInsertResult(
                    nodePtr: ptr, count: try branch.subtreeCount(), entry: result.entry, added: result.added, split: nil
                )
            } else {
                // Overflow: two branches; the new sibling's separator is the
                // one its first child had.
                let leftCount = BTree.splitCount
                let left = entries.node(.branch, from: 0, to: leftCount)
                let right = entries.node(.branch, from: leftCount, to: entries.count)
                let separator = entries.separators[leftCount]
                let leftPtr = try writeNodeVersion(left, oldPtr: frame.position, frozenAt: frozenAt)
                let rightPtr = try appendNode(right)
                result = SortedInsertResult(
                    nodePtr: leftPtr,
                    count: try left.subtreeCount(),
                    entry: result.entry,
                    added: result.added,
                    split: (rightPtr, try right.subtreeCount(), separator)
                )
            }
        }
        return result
    }

    /// The root for a put's result, a level taller if the old root split:
    /// Zig's `sortedGrowRoot`.
    func sortedGrowRoot(_ result: SortedInsertResult) throws(XitDBError) -> UInt64 {
        guard let split = result.split else { return result.nodePtr }
        var root = SortedNode(kind: .branch, num: 2)
        root.setChild(Slot(value: result.nodePtr, tag: .index), at: 0)
        root.setChild(Slot(value: split.nodePtr, tag: .index), at: 1)
        // separators[0] is an unused sentinel
        root.setSeparator(split.separator, at: 1)
        root.setCount(result.count, at: 0)
        root.setCount(split.count, at: 1)
        return try appendNode(root)
    }

    // MARK: Remove

    /// Removes `key` from the tree at `rootPtr`, rewriting the nodes on the
    /// way and counting down: Zig's `sortedRemove`. An emptied leaf stays
    /// where it is: separators are stable lower bounds, so nothing needs
    /// rebalancing, and every leaf keeps its depth.
    ///
    /// - Returns: The root as it is now, and whether the key was there.
    /// - Throws: `invalidBTreeNode` if a branch's count for the child was
    ///   already zero, and the errors of the descent.
    func sortedRemove(rootPtr: UInt64, key: Span<UInt8>, frozenAt: UInt64) throws(XitDBError) -> (
        rootPtr: UInt64, found: Bool
    ) {
        let (branches, leafPtr, leaf) = try sortedDescend(from: rootPtr, key: key)
        let search = try reader.sortedLeafSearch(leaf, key: key)
        guard search.found else { return (rootPtr, false) }

        var written = SortedNode(kind: .leaf, num: leaf.num - 1)
        for index in 0..<search.index {
            written.setEntry(leaf.entry(index), at: index)
        }
        for index in search.index..<(Int(leaf.num) - 1) {
            written.setEntry(leaf.entry(index + 1), at: index)
        }
        var childPtr = try writeNodeVersion(written, oldPtr: leafPtr, frozenAt: frozenAt)

        for index in stride(from: branches.count - 1, through: 0, by: -1) {

            let frame = branches[index]
            var branch = frame.node
            branch.setChild(Slot(value: childPtr, tag: .index), at: frame.index)
            // A count that is already zero disagrees with the entry just
            // found beneath it.
            guard branch.count(frame.index) > 0 else { throw .invalidBTreeNode }
            branch.setCount(branch.count(frame.index) - 1, at: frame.index)
            childPtr = try writeNodeVersion(branch, oldPtr: frame.position, frozenAt: frozenAt)
        }
        return (childPtr, true)
    }
}
