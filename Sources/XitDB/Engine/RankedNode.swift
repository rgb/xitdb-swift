/// What the two trees' nodes have in common, which lets one descent by rank
/// and one way of writing nodes serve both: Zig's `descendByRank`, whose
/// branches start with the children and end with the counts in both trees,
/// and its `btreeWriteNode` and `sortedWriteNode`, which rewrite a node in
/// place or append it by the same rule.
protocol RankedNode {
    var kind: BTreeNodeKind { get }
    var num: UInt8 { get }
    var children: InlineArray<16, Slot> { get }
    var counts: InlineArray<16, UInt64> { get }

    /// The number of bytes the node takes in the file, by its kind.
    var byteCount: UInt64 { get }

    /// The element or entry at `index` of a leaf.
    func leafSlot(at index: Int) -> Slot

    /// Writes the node's bytes at the start of `bytes`, which must hold
    /// `byteCount` of them.
    func encode(into bytes: inout MutableSpan<UInt8>)
}

extension BTreeNode: RankedNode {
    func leafSlot(at index: Int) -> Slot {
        values[index]
    }
}

extension SortedNode: RankedNode {
    func leafSlot(at index: Int) -> Slot {
        entries[index]
    }
}

extension DatabaseReader {
    /// The slot of the element at `rank` in the tree at `rootPtr`, read
    /// with `read`: Zig's `descendByRank`, for both trees.
    ///
    /// - Throws: `invalidBTreeNode` if the rank is beyond the leaf it leads
    ///   to, if a branch has no children or a child is not a node, or if the
    ///   tree is deeper than a tree can be; and the errors of reading a
    ///   node.
    func slotByRank<Node: RankedNode>(
        rootPtr: UInt64,
        rank: UInt64,
        read: (UInt64) throws(XitDBError) -> Node
    ) throws(XitDBError) -> SlotPointer {
        var nodePtr = rootPtr
        var rem = rank
        for _ in 0...BTree.maxHeight {
            let node = try read(nodePtr)
            switch node.kind {
            case .leaf:
                guard rem < UInt64(node.num) else { throw .invalidBTreeNode }
                let index = Int(rem)
                return SlotPointer(
                    position: try BTree.slotPosition(nodePtr: nodePtr, index: index), slot: node.leafSlot(at: index))
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
}

extension Database {
    /// Writes a node at `position`: as many bytes as its kind takes, 146
    /// for a leaf, 274 for a linked array list's branch and 418 for a
    /// sorted map's.
    func writeNode(_ node: some RankedNode, at position: UInt64) throws(XitDBError) {
        var block = InlineArray<418, UInt8>(repeating: 0)
        var bytes = block.mutableSpan
        node.encode(into: &bytes)
        try storage.write(block.span.extracting(0..<Int(node.byteCount)), at: position)
    }

    /// Appends a node and returns where it is: Zig's `writeBTreeNode` and
    /// `writeSortedNode`.
    func appendNode(_ node: some RankedNode) throws(XitDBError) -> UInt64 {
        let position = try storage.length()
        try writeNode(node, at: position)
        return position
    }

    /// Writes a new version of a node: in place of `oldPtr` if that node
    /// belongs to this transaction, appended otherwise. Returns where the
    /// node is now. Zig's `btreeWriteNode` and `sortedWriteNode`.
    func writeNodeVersion(_ node: some RankedNode, oldPtr: UInt64, frozenAt: UInt64) throws(XitDBError) -> UInt64 {
        if bTreeReusable(oldPtr, frozenAt: frozenAt) {
            try writeNode(node, at: oldPtr)
            return oldPtr
        }
        return try appendNode(node)
    }
}
