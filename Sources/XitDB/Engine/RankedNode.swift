/// What the two trees' nodes have in common, which lets one descent by rank
/// serve both: Zig's `descendByRank`, whose branches start with the
/// children and end with the counts in both trees.
protocol RankedNode {
    var kind: BTreeNodeKind { get }
    var num: UInt8 { get }
    var children: InlineArray<16, Slot> { get }
    var counts: InlineArray<16, UInt64> { get }

    /// The element or entry at `index` of a leaf.
    func leafSlot(at index: Int) -> Slot
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
