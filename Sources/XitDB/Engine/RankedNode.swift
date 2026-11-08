/// What the two trees' nodes have in common, which lets one descent by rank
/// and one way of writing nodes serve both: Zig's `descendByRank`, whose
/// branches start with the children and end with the counts in both trees,
/// and its `btreeWriteNode` and `sortedWriteNode`, which rewrite a node in
/// place or append it by the same rule.
protocol RankedNode {
    var kind: BTreeNodeKind { get }
    var num: UInt8 { get }
    /// All sixteen children of a branch, for a walk that keeps the block.
    var children: InlineArray<16, Slot> { get }

    /// The child at `index` of a branch.
    func child(_ index: Int) -> Slot

    /// The number of elements beneath the child at `index` of a branch.
    func count(_ index: Int) -> UInt64

    /// The number of bytes the node takes in the file, by its kind.
    var byteCount: UInt64 { get }

    /// Where a branch's sixteen counts start; its children start right
    /// after the header in both trees.
    static var countsOffset: Int { get }

    /// Checks the bytes of a node of this kind as decoding the whole node
    /// would, so that a reader taking one slot and the counts from the
    /// bytes reports the same errors: a cut node and an unknown tag
    /// anywhere in it.
    static func validate(_ bytes: Span<UInt8>, kind: BTreeNodeKind) throws(XitDBError)

    /// The element or entry at `index` of a leaf.
    func leafSlot(at index: Int) -> Slot

    /// Writes the node's bytes at the start of `bytes`, which must hold
    /// `byteCount` of them.
    func encode(into bytes: inout MutableSpan<UInt8>)
}

extension BTreeNode: RankedNode {
    func leafSlot(at index: Int) -> Slot {
        value(index)
    }

    static func validate(_ bytes: Span<UInt8>, kind: BTreeNodeKind) throws(XitDBError) {
        try SlotGroup.validate(bytes, at: 2)
        if kind == .branch {
            try bytes.requireBytes(128, at: countsOffset)
        }
    }
}

extension SortedNode: RankedNode {
    func leafSlot(at index: Int) -> Slot {
        entry(index)
    }

    static func validate(_ bytes: Span<UInt8>, kind: BTreeNodeKind) throws(XitDBError) {
        try SlotGroup.validate(bytes, at: 2)
        if kind == .branch {
            try SlotGroup.validate(bytes, at: 146)
            try bytes.requireBytes(128, at: countsOffset)
        }
    }
}

extension DatabaseReader {
    /// The slot of the element at `rank` in the tree at `rootPtr`, whose
    /// nodes are of `Node`'s kind: Zig's `descendByRank`, for both trees.
    ///
    /// Each node is read once and checked whole, but only what the descent
    /// needs is decoded: the counts up to the child the rank falls in, and
    /// that child, or the one slot of the leaf.
    ///
    /// - Throws: `invalidBTreeNode` if the rank is beyond the leaf it leads
    ///   to, if a branch has no children or a child is not a node, or if the
    ///   tree is deeper than a tree can be; and the errors of reading a
    ///   node.
    func slotByRank<Node: RankedNode>(
        rootPtr: UInt64,
        rank: UInt64,
        in node: Node.Type
    ) throws(XitDBError) -> SlotPointer {
        var buffer = InlineArray<418, UInt8>(repeating: 0)
        var nodePtr = rootPtr
        var rem = rank
        for _ in 0...BTree.maxHeight {
            var span = buffer.mutableSpan
            let read = try storage.read(into: &span, at: nodePtr)
            let bytes = buffer.span.extracting(0..<read)
            let header = try TreeNodeHeader.decode(bytes)
            try Node.validate(bytes, kind: header.kind)
            switch header.kind {
            case .leaf:
                guard rem < UInt64(header.num) else { throw .invalidBTreeNode }
                let index = Int(rem)
                return SlotPointer(
                    position: try BTree.slotPosition(nodePtr: nodePtr, index: index),
                    slot: try Slot(decoding: bytes, at: 2 + index * 9)
                )
            case .branch:
                guard header.num > 0 else { throw .invalidBTreeNode }
                // the child rule, over the counts as they are read
                var index = 0
                while index + 1 < Int(header.num) {
                    let count: UInt64 = bytes.bigEndian(at: Node.countsOffset + index * 8)
                    if rem < count { break }
                    rem -= count
                    index += 1
                }
                let child = try Slot(decoding: bytes, at: 2 + index * 9)
                guard child.tag == .index else { throw .invalidBTreeNode }
                nodePtr = child.value
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
        noteWrite()
    }

    /// Appends a node and returns where it is: Zig's `writeBTreeNode` and
    /// `writeSortedNode`.
    func appendNode(_ node: some RankedNode) throws(XitDBError) -> UInt64 {
        let position = try storage.length
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
