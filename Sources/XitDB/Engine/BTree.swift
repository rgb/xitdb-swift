// The count-augmented B-tree of a linked array list: Zig's `btree*`
// functions. Nodes hold up to sixteen entries, a branch keeps the number of
// elements beneath each child, and an element is found by its rank.
//
// Zig recurses through the tree. Here every descent is a loop with an
// explicit stack of the nodes on the way down, bounded by the greatest
// height a tree can have, so that a damaged file whose branches point back
// at their ancestors ends in an error and not in a stack overflow.
//
// Where a node is rewritten in place and where it is copied, and in what
// order new nodes are appended, decides the bytes of the file. All of it
// follows Zig exactly: a node made in this transaction after the writing
// cursor's freeze point is rewritten in place, any other node is copied, and
// the join and the split share untouched subtrees by pointer.

/// The tree's constants.
enum BTree {
    /// The most entries a node holds.
    static let slotCount = 16

    /// The entries kept on the left when a node overflows.
    static let splitCount = (slotCount + 1) / 2

    /// The greatest height a tree can have: a branch has at least two
    /// children, and there are at most 2⁶⁴ elements. A tree deeper than
    /// this is a damaged file.
    static let maxHeight = 64

    /// The size of the kind and count bytes a node starts with, which the
    /// slots follow.
    static let nodeHeaderByteCount: UInt64 = TreeNodeHeader.byteCount

    /// Where the entry at `index` of a node at `nodePtr` is stored.
    static func slotPosition(nodePtr: UInt64, index: Int) throws(XitDBError) -> UInt64 {
        try nodePtr.offset(by: nodeHeaderByteCount + Slot.byteCount * UInt64(index))
    }

    /// The child a rank falls under in a branch, and the rank within it.
    ///
    /// `inclusive` says what to do with a rank equal to the count of a
    /// child: an insert goes into that child, at its end; a read or a
    /// removal goes on to the next one.
    static func child(of node: BTreeNode, rank: UInt64, inclusive: Bool) -> (index: Int, rank: UInt64) {
        var index = 0
        var rem = rank
        while index + 1 < Int(node.num) {
            let count = node.counts[index]
            if inclusive ? rem <= count : rem < count { break }
            rem -= count
            index += 1
        }
        return (index, rem)
    }
}

/// Up to thirty-two entries of a node, or of two nodes end to end: what
/// the join and the split assemble new nodes from.
struct BTreeEntries {
    var slots: InlineArray<32, Slot> = InlineArray(repeating: Slot())
    var counts: InlineArray<32, UInt64> = InlineArray(repeating: 0)
    var count = 0

    /// Appends the first `num` entries of a node.
    mutating func append(_ node: BTreeNode) {
        for index in 0..<Int(node.num) {
            append(node.kind == .leaf ? node.values[index] : node.children[index], count: node.counts[index])
        }
    }

    /// Appends the entries of a node from `from` up to `to`.
    mutating func append(_ node: BTreeNode, from: Int, to: Int) {
        for index in from..<to {
            append(node.kind == .leaf ? node.values[index] : node.children[index], count: node.counts[index])
        }
    }

    mutating func append(_ slot: Slot, count: UInt64 = 0) {
        slots[self.count] = slot
        counts[self.count] = count
        self.count += 1
    }

    /// A node of the given kind holding the entries from `from` up to `to`.
    func node(_ kind: BTreeNodeKind, from: Int, to: Int) -> BTreeNode {
        var node = BTreeNode(kind: kind, num: UInt8(to - from))
        for index in from..<to {
            if kind == .leaf {
                node.values[index - from] = slots[index]
            } else {
                node.children[index - from] = slots[index]
                node.counts[index - from] = counts[index]
            }
        }
        return node
    }
}

/// What an insert into a subtree gives back: the node now at its root, the
/// elements beneath it, where the new element's slot is, and the right
/// sibling if the node overflowed and split.
struct BTreeInsertResult {
    var nodePtr: UInt64
    var count: UInt64
    var valuePosition: UInt64
    var split: (nodePtr: UInt64, count: UInt64)?
}

/// What a join of two subtrees gives back: the node now at its root, the
/// elements beneath it, and a right sibling if assembling it overflowed.
struct BTreeJoinResult {
    var nodePtr: UInt64
    var count: UInt64
    var split: (nodePtr: UInt64, count: UInt64)?
}

extension DatabaseReader {
    /// Reads the node at `position` in one call. It asks for a branch's
    /// worth of bytes and may get fewer when the node is a leaf near the end
    /// of the file.
    ///
    /// - Throws: `invalidBTreeNodeKind` or `invalidBTreeNode` for a bad
    ///   header, `invalidEnumTag` for an unknown slot tag, `endOfStream` if
    ///   the file ends inside the node.
    func bTreeNode(at position: UInt64) throws(XitDBError) -> BTreeNode {
        var buffer = InlineArray<274, UInt8>(repeating: 0)
        var span = buffer.mutableSpan
        let read = try storage.read(into: &span, at: position)
        return try BTreeNode(decoding: buffer.span.extracting(0..<read))
    }

    /// The slot of the element at `rank` in the tree at `rootPtr`: Zig's
    /// `descendByRank`.
    ///
    /// - Throws: `invalidBTreeNode` if the rank is beyond the leaf it leads
    ///   to, if a branch has no children or a child is not a node, or if the
    ///   tree is deeper than a tree can be; and the errors of reading a
    ///   node.
    func linkedArrayListSlot(rootPtr: UInt64, rank: UInt64) throws(XitDBError) -> SlotPointer {
        var nodePtr = rootPtr
        var rem = rank
        for _ in 0...BTree.maxHeight {
            let node = try bTreeNode(at: nodePtr)
            switch node.kind {
            case .leaf:
                guard rem < UInt64(node.num) else { throw .invalidBTreeNode }
                let index = Int(rem)
                return SlotPointer(
                    position: try BTree.slotPosition(nodePtr: nodePtr, index: index), slot: node.values[index])
            case .branch:
                guard node.num > 0 else { throw .invalidBTreeNode }
                let (index, next) = BTree.child(of: node, rank: rem, inclusive: false)
                guard node.children[index].tag == .index else { throw .invalidBTreeNode }
                nodePtr = node.children[index].value
                rem = next
            }
        }
        throw .invalidBTreeNode
    }

    /// The number of branch levels above the leaves of the tree at
    /// `rootPtr`: Zig's `btreeHeight`.
    ///
    /// - Throws: `invalidBTreeNode` if a branch has no children, a child is
    ///   not a node, or the tree is deeper than a tree can be.
    func bTreeHeight(rootPtr: UInt64) throws(XitDBError) -> Int {
        var nodePtr = rootPtr
        var height = 0
        while height <= BTree.maxHeight {
            let node = try bTreeNode(at: nodePtr)
            if node.kind == .leaf { return height }
            guard node.num > 0, node.children[0].tag == .index else { throw .invalidBTreeNode }
            nodePtr = node.children[0].value
            height += 1
        }
        throw .invalidBTreeNode
    }
}

extension Database {
    // MARK: Writing nodes

    /// Writes a node at `position`: 146 bytes for a leaf, 274 for a branch.
    func writeBTreeNode(_ node: BTreeNode, at position: UInt64) throws(XitDBError) {
        var block = InlineArray<274, UInt8>(repeating: 0)
        var bytes = block.mutableSpan
        node.encode(into: &bytes)
        try storage.write(block.span.extracting(0..<Int(node.byteCount)), at: position)
    }

    /// Appends a node and returns where it is: Zig's `writeBTreeNode`.
    func appendBTreeNode(_ node: BTreeNode) throws(XitDBError) -> UInt64 {
        let position = try storage.length()
        try writeBTreeNode(node, at: position)
        return position
    }

    /// Whether the node at `position` may be rewritten in place: it was
    /// made in this transaction, after the writing cursor's freeze point,
    /// so nothing committed and nothing shared by a concat refers to it.
    /// Outside a transaction nothing may be.
    func bTreeReusable(_ position: UInt64, frozenAt: UInt64) -> Bool {
        guard let old = try? isOld(position, frozenAt: frozenAt) else { return false }
        return !old
    }

    /// Writes a new version of a node: in place of `oldPtr` if that node
    /// belongs to this transaction, appended otherwise. Returns where the
    /// node is now.
    func bTreeWriteNode(_ node: BTreeNode, oldPtr: UInt64, frozenAt: UInt64) throws(XitDBError) -> UInt64 {
        if bTreeReusable(oldPtr, frozenAt: frozenAt) {
            try writeBTreeNode(node, at: oldPtr)
            return oldPtr
        }
        return try appendBTreeNode(node)
    }

    /// An empty tree: one leaf with nothing in it.
    func bTreeNewRoot() throws(XitDBError) -> UInt64 {
        try appendBTreeNode(BTreeNode(kind: .leaf, num: 0))
    }

    /// A root for a result: the node itself, or a new branch over it and
    /// its right sibling if it split.
    func bTreeMakeRoot(_ result: BTreeJoinResult) throws(XitDBError) -> UInt64 {
        guard let split = result.split else { return result.nodePtr }
        var root = BTreeNode(kind: .branch, num: 2)
        root.children[0] = Slot(value: result.nodePtr, tag: .index)
        root.children[1] = Slot(value: split.nodePtr, tag: .index)
        root.counts[0] = result.count
        root.counts[1] = split.count
        return try appendBTreeNode(root)
    }

    /// Reads the node at `position`, which a branch above it points at.
    ///
    /// - Throws: `invalidBTreeNode` if the slot is not a pointer to a node,
    ///   and the errors of reading one.
    private func bTreeChild(_ slot: Slot) throws(XitDBError) -> (position: UInt64, node: BTreeNode) {
        guard slot.tag == .index else { throw .invalidBTreeNode }
        return (slot.value, try reader.bTreeNode(at: slot.value))
    }

    // MARK: Insert

    /// One node on the way down to the element being inserted, read for
    /// writing, or removed, with the child the way goes through.
    private struct Frame {
        var position: UInt64
        var node: BTreeNode
        var index: Int
    }

    /// Descends from `rootPtr` to the leaf that `rank` falls in, keeping
    /// the branches on the way, and returns them with the leaf.
    ///
    /// - Parameter inclusive: Whether a rank equal to a child's count falls
    ///   in that child (an insert) or in the next one (a read, a removal).
    /// - Throws: `invalidBTreeNode` if a branch has no children, a child is
    ///   not a node, or the tree is deeper than a tree can be.
    private func bTreeDescend(
        from rootPtr: UInt64,
        rank: UInt64,
        inclusive: Bool
    ) throws(XitDBError) -> (branches: [Frame], leafPtr: UInt64, leaf: BTreeNode, rank: UInt64) {
        var branches: [Frame] = []
        var nodePtr = rootPtr
        var rem = rank
        while branches.count <= BTree.maxHeight {
            let node = try reader.bTreeNode(at: nodePtr)
            if node.kind == .leaf {
                return (branches, nodePtr, node, rem)
            }
            guard node.num > 0 else { throw .invalidBTreeNode }
            let (index, next) = BTree.child(of: node, rank: rem, inclusive: inclusive)
            guard node.children[index].tag == .index else { throw .invalidBTreeNode }
            branches.append(Frame(position: nodePtr, node: node, index: index))
            nodePtr = node.children[index].value
            rem = next
        }
        throw .invalidBTreeNode
    }

    /// Inserts a placeholder at `rank` in the tree at `rootPtr`, rewriting
    /// the nodes on the way: Zig's `btreeInsert`. The caller writes the
    /// element's value at the position in the result.
    ///
    /// The placeholder is a slot set to nothing, marked full, so that an
    /// element that is never written still counts as one when iterating.
    ///
    /// - Throws: `invalidBTreeNode` if the rank is beyond the leaf it leads
    ///   to, and the errors of the descent.
    func bTreeInsert(rootPtr: UInt64, rank: UInt64, frozenAt: UInt64) throws(XitDBError) -> BTreeInsertResult {
        let (branches, leafPtr, leaf, leafRank) = try bTreeDescend(from: rootPtr, rank: rank, inclusive: true)

        // The leaf, with the placeholder spliced in.
        guard leafRank <= UInt64(leaf.num) else { throw .invalidBTreeNode }
        let r = Int(leafRank)
        var entries = BTreeEntries()
        entries.append(leaf, from: 0, to: r)
        entries.append(Slot(tag: .none, full: true))
        entries.append(leaf, from: r, to: Int(leaf.num))
        var result: BTreeInsertResult
        if entries.count <= BTree.slotCount {
            let ptr = try bTreeWriteNode(
                entries.node(.leaf, from: 0, to: entries.count), oldPtr: leafPtr, frozenAt: frozenAt)
            result = BTreeInsertResult(
                nodePtr: ptr,
                count: UInt64(entries.count),
                valuePosition: try BTree.slotPosition(nodePtr: ptr, index: r),
                split: nil
            )
        } else {
            // Overflow: two leaves, the left one in this node's place.
            let leftCount = BTree.splitCount
            let leftPtr = try bTreeWriteNode(
                entries.node(.leaf, from: 0, to: leftCount), oldPtr: leafPtr, frozenAt: frozenAt)
            let rightPtr = try appendBTreeNode(entries.node(.leaf, from: leftCount, to: entries.count))
            result = BTreeInsertResult(
                nodePtr: leftPtr,
                count: UInt64(leftCount),
                valuePosition: r < leftCount
                    ? try BTree.slotPosition(nodePtr: leftPtr, index: r)
                    : try BTree.slotPosition(nodePtr: rightPtr, index: r - leftCount),
                split: (rightPtr, UInt64(entries.count - leftCount))
            )
        }

        // Each branch on the way up, rebuilt with its child as it is now.
        for frame in branches.reversed() {
            var entries = BTreeEntries()
            entries.append(frame.node, from: 0, to: frame.index)
            entries.append(Slot(value: result.nodePtr, tag: .index), count: result.count)
            if let split = result.split {
                entries.append(Slot(value: split.nodePtr, tag: .index), count: split.count)
            }
            entries.append(frame.node, from: frame.index + 1, to: Int(frame.node.num))
            if entries.count <= BTree.slotCount {
                let branch = entries.node(.branch, from: 0, to: entries.count)
                let ptr = try bTreeWriteNode(branch, oldPtr: frame.position, frozenAt: frozenAt)
                result = BTreeInsertResult(
                    nodePtr: ptr, count: branch.subtreeCount, valuePosition: result.valuePosition, split: nil)
            } else {
                let leftCount = BTree.splitCount
                let left = entries.node(.branch, from: 0, to: leftCount)
                let right = entries.node(.branch, from: leftCount, to: entries.count)
                let leftPtr = try bTreeWriteNode(left, oldPtr: frame.position, frozenAt: frozenAt)
                let rightPtr = try appendBTreeNode(right)
                result = BTreeInsertResult(
                    nodePtr: leftPtr,
                    count: left.subtreeCount,
                    valuePosition: result.valuePosition,
                    split: (rightPtr, right.subtreeCount)
                )
            }
        }
        return result
    }

    /// The root for an insert's result, a level taller if the old root
    /// split: Zig's `btreeGrowRoot`.
    func bTreeGrowRoot(_ result: BTreeInsertResult) throws(XitDBError) -> UInt64 {
        try bTreeMakeRoot(BTreeJoinResult(nodePtr: result.nodePtr, count: result.count, split: result.split))
    }

    // MARK: Get for writing

    /// The slot of the element at `rank`, with every node on the way
    /// copied into this transaction unless it is there already: Zig's
    /// `btreeGetForWrite`. When nothing needed copying, nothing is written.
    ///
    /// - Returns: The root as it is now, the slot's position and the slot.
    /// - Throws: `invalidBTreeNode` if the rank is beyond the leaf it leads
    ///   to, and the errors of the descent.
    func bTreeGetForWrite(
        rootPtr: UInt64,
        rank: UInt64,
        frozenAt: UInt64
    ) throws(XitDBError) -> (rootPtr: UInt64, valuePosition: UInt64, slot: Slot) {
        let (branches, leafPtr, leaf, leafRank) = try bTreeDescend(from: rootPtr, rank: rank, inclusive: false)
        guard leafRank < UInt64(leaf.num) else { throw .invalidBTreeNode }
        let newLeafPtr = bTreeReusable(leafPtr, frozenAt: frozenAt) ? leafPtr : try appendBTreeNode(leaf)
        let valuePosition = try BTree.slotPosition(nodePtr: newLeafPtr, index: Int(leafRank))
        let slot = leaf.values[Int(leafRank)]

        var childPtr = newLeafPtr
        var oldChildPtr = leafPtr
        for frame in branches.reversed() {
            // A child that stayed put leaves this branch, and all above it,
            // as they are.
            if childPtr == oldChildPtr {
                return (rootPtr, valuePosition, slot)
            }
            var node = frame.node
            node.children[frame.index] = Slot(value: childPtr, tag: .index)
            oldChildPtr = frame.position
            childPtr = try bTreeWriteNode(node, oldPtr: frame.position, frozenAt: frozenAt)
        }
        return (childPtr, valuePosition, slot)
    }

    // MARK: Remove

    /// Removes the element at `rank` from the tree at `rootPtr`: Zig's
    /// `btreeRemove`. The nodes below the root are written; the root is
    /// returned for the caller to write, or to replace if it is left with a
    /// single child.
    ///
    /// An emptied child is dropped, and a child left under half full is
    /// merged with a neighbour it fits with, so every leaf stays at the
    /// same depth.
    ///
    /// - Throws: `invalidBTreeNode` if the rank is beyond the leaf it leads
    ///   to, and the errors of the descent.
    func bTreeRemove(rootPtr: UInt64, rank: UInt64, frozenAt: UInt64) throws(XitDBError) -> BTreeNode {
        var (branches, leafPtr, child, leafRank) = try bTreeDescend(from: rootPtr, rank: rank, inclusive: false)
        guard leafRank < UInt64(child.num) else { throw .invalidBTreeNode }
        for index in Int(leafRank)..<(Int(child.num) - 1) {
            child.values[index] = child.values[index + 1]
        }
        child.num -= 1
        child.values[Int(child.num)] = Slot()

        var childPtr = leafPtr
        while let frame = branches.popLast() {
            var node = frame.node
            var index = frame.index
            if child.num == 0 {
                Self.bTreeDropChild(&node, at: index)
                child = node
                childPtr = frame.position
                continue
            }
            if Int(child.num) < BTree.splitCount, node.num > 1 {
                // The pair is this child and its right neighbour, or its
                // left one if it is the last.
                let first = index + 1 < Int(node.num) ? index : index - 1
                let neighbourSlot = node.children[first == index ? index + 1 : first]
                let neighbour = try bTreeChild(neighbourSlot).node
                if Int(child.num) + Int(neighbour.num) <= BTree.slotCount {
                    child =
                        first == index
                        ? Self.bTreeConcatNodes(child, neighbour) : Self.bTreeConcatNodes(neighbour, child)
                    Self.bTreeDropChild(&node, at: first + 1)
                    index = first
                }
            }
            node.children[index] = Slot(
                value: try bTreeWriteNode(child, oldPtr: childPtr, frozenAt: frozenAt), tag: .index)
            node.counts[index] = child.subtreeCount
            child = node
            childPtr = frame.position
        }
        return child
    }

    /// Takes the child at `index` out of a branch, closing the gap.
    private static func bTreeDropChild(_ branch: inout BTreeNode, at index: Int) {
        for i in index..<(Int(branch.num) - 1) {
            branch.children[i] = branch.children[i + 1]
            branch.counts[i] = branch.counts[i + 1]
        }
        branch.num -= 1
        branch.children[Int(branch.num)] = Slot()
        branch.counts[Int(branch.num)] = 0
    }

    /// Two nodes of one kind whose entries fit in one node, `a` before `b`.
    private static func bTreeConcatNodes(_ a: BTreeNode, _ b: BTreeNode) -> BTreeNode {
        var node = a
        for index in 0..<Int(b.num) {
            if a.kind == .leaf {
                node.values[Int(a.num) + index] = b.values[index]
            } else {
                node.children[Int(a.num) + index] = b.children[index]
                node.counts[Int(a.num) + index] = b.counts[index]
            }
        }
        node.num = a.num + b.num
        return node
    }

    // MARK: Join

    /// Writes entries as one node, or as two balanced nodes if there are
    /// more than a node holds: Zig's `btreeAssembleLeaf` and
    /// `btreeAssembleBranch`.
    private func bTreeAssemble(_ kind: BTreeNodeKind, _ entries: BTreeEntries) throws(XitDBError) -> BTreeJoinResult {
        if entries.count <= BTree.slotCount {
            let node = entries.node(kind, from: 0, to: entries.count)
            return BTreeJoinResult(nodePtr: try appendBTreeNode(node), count: node.subtreeCount, split: nil)
        }
        let leftCount = entries.count / 2
        let left = entries.node(kind, from: 0, to: leftCount)
        let right = entries.node(kind, from: leftCount, to: entries.count)
        let leftPtr = try appendBTreeNode(left)
        let rightPtr = try appendBTreeNode(right)
        return BTreeJoinResult(nodePtr: leftPtr, count: left.subtreeCount, split: (rightPtr, right.subtreeCount))
    }

    /// Merges two nodes of one height, `a` before `b`, into one or two
    /// nodes: Zig's `btreeMergeNodes`.
    private func bTreeMergeNodes(_ a: BTreeNode, _ b: BTreeNode) throws(XitDBError) -> BTreeJoinResult {
        var entries = BTreeEntries()
        entries.append(a)
        entries.append(b)
        return try bTreeAssemble(a.kind, entries)
    }

    /// Joins a shorter tree `b` into the rightmost spine of a taller tree
    /// `a` (Zig's `btreeJoinRight`), or a shorter tree `a` into the leftmost
    /// spine of a taller tree `b` (`btreeJoinLeft`). The spine is descended
    /// until the trees are of one height, where they are merged, and the
    /// nodes of the spine are then assembled anew, from the bottom up.
    private func bTreeJoinSpine(
        taller tallerPtr: UInt64,
        tallerHeight: Int,
        shorter shorterPtr: UInt64,
        shorterHeight: Int,
        right: Bool
    ) throws(XitDBError) -> BTreeJoinResult {
        // Down the spine, keeping each node.
        var spine: [BTreeNode] = []
        var nodePtr = tallerPtr
        var height = tallerHeight
        while height - 1 > shorterHeight {
            let node = try reader.bTreeNode(at: nodePtr)
            guard node.num > 0 else { throw .invalidBTreeNode }
            spine.append(node)
            let next = node.children[right ? Int(node.num) - 1 : 0]
            guard next.tag == .index else { throw .invalidBTreeNode }
            nodePtr = next.value
            height -= 1
            if spine.count > BTree.maxHeight { throw .invalidBTreeNode }
        }
        let node = try reader.bTreeNode(at: nodePtr)
        guard node.num > 0 else { throw .invalidBTreeNode }
        spine.append(node)

        // The merge at the bottom.
        let end = try bTreeChild(node.children[right ? Int(node.num) - 1 : 0]).node
        let other = try reader.bTreeNode(at: shorterPtr)
        var sub = right ? try bTreeMergeNodes(end, other) : try bTreeMergeNodes(other, end)

        // Back up the spine.
        for branch in spine.reversed() {
            var entries = BTreeEntries()
            if right {
                entries.append(branch, from: 0, to: Int(branch.num) - 1)
                entries.append(Slot(value: sub.nodePtr, tag: .index), count: sub.count)
                if let split = sub.split {
                    entries.append(Slot(value: split.nodePtr, tag: .index), count: split.count)
                }
            } else {
                entries.append(Slot(value: sub.nodePtr, tag: .index), count: sub.count)
                if let split = sub.split {
                    entries.append(Slot(value: split.nodePtr, tag: .index), count: split.count)
                }
                entries.append(branch, from: 1, to: Int(branch.num))
            }
            sub = try bTreeAssemble(.branch, entries)
        }
        return sub
    }

    /// Joins two trees, every element of `a` before every element of `b`,
    /// sharing their untouched subtrees: Zig's `btreeJoin`. Returns the
    /// root of the result.
    func bTreeJoin(_ rootA: UInt64, _ rootB: UInt64) throws(XitDBError) -> UInt64 {
        let heightA = try reader.bTreeHeight(rootPtr: rootA)
        let heightB = try reader.bTreeHeight(rootPtr: rootB)
        let result: BTreeJoinResult
        if heightA == heightB {
            result = try bTreeMergeNodes(try reader.bTreeNode(at: rootA), try reader.bTreeNode(at: rootB))
        } else if heightA > heightB {
            result = try bTreeJoinSpine(
                taller: rootA, tallerHeight: heightA, shorter: rootB, shorterHeight: heightB, right: true)
        } else {
            result = try bTreeJoinSpine(
                taller: rootB, tallerHeight: heightB, shorter: rootA, shorterHeight: heightA, right: false)
        }
        return try bTreeMakeRoot(result)
    }

    // MARK: Split

    /// A tree made of a run of sibling subtrees: an empty tree for none,
    /// the subtree itself for one, a branch over them otherwise. Zig's
    /// `btreeSubtree`.
    private func bTreeSubtree(_ node: BTreeNode, from: Int, to: Int) throws(XitDBError) -> UInt64 {
        if to == from { return try bTreeNewRoot() }
        if to - from == 1 {
            guard node.children[from].tag == .index else { throw .invalidBTreeNode }
            return node.children[from].value
        }
        var entries = BTreeEntries()
        entries.append(node, from: from, to: to)
        // No more than a node holds, so this never splits.
        return try bTreeAssemble(.branch, entries).nodePtr
    }

    /// Splits the tree at `rootPtr` into the elements before `rank` and the
    /// elements from `rank` on, sharing untouched subtrees: Zig's
    /// `btreeSplit`. The partial nodes on the way are put back together with
    /// joins, so both trees stay balanced.
    ///
    /// - Throws: `invalidBTreeNode` if the rank is beyond the leaf it leads
    ///   to, and the errors of the descent.
    func bTreeSplit(rootPtr: UInt64, rank: UInt64) throws(XitDBError) -> (left: UInt64, right: UInt64) {
        let (branches, _, leaf, leafRank) = try bTreeDescend(from: rootPtr, rank: rank, inclusive: true)
        guard leafRank <= UInt64(leaf.num) else { throw .invalidBTreeNode }
        let r = Int(leafRank)
        var entries = BTreeEntries()
        entries.append(leaf)
        var left = try appendBTreeNode(entries.node(.leaf, from: 0, to: r))
        var right = try appendBTreeNode(entries.node(.leaf, from: r, to: entries.count))

        for frame in branches.reversed() {
            let leftSub = try bTreeSubtree(frame.node, from: 0, to: frame.index)
            let rightSub = try bTreeSubtree(frame.node, from: frame.index + 1, to: Int(frame.node.num))
            left = try bTreeJoin(leftSub, left)
            right = try bTreeJoin(right, rightSub)
        }
        return (left, right)
    }
}
