/// Whether a tree node is a leaf or a branch. The raw value is the node's
/// first byte on disk.
///
/// Zig declares this twice, as `BTreeNodeKind` and `SortedNodeKind`, with the
/// same values. Both trees use this one.
enum BTreeNodeKind: UInt8, Sendable {
    case leaf = 0
    case branch = 1
}

/// The two bytes every tree node starts with.
enum TreeNodeHeader {
    /// The size of the kind and entry-count bytes.
    static let byteCount: UInt64 = 2

    /// Decodes and validates a node's kind and number of entries.
    ///
    /// - Throws: in the order Zig checks: `endOfStream` if there is no kind
    ///   byte, `invalidBTreeNodeKind` if it is neither leaf nor branch,
    ///   `endOfStream` if there is no count byte, `invalidBTreeNode` if the
    ///   count is more than sixteen.
    static func decode(_ bytes: Span<UInt8>) throws(XitDBError) -> (kind: BTreeNodeKind, num: UInt8) {
        try bytes.requireBytes(1, at: 0)
        guard let kind = BTreeNodeKind(rawValue: bytes[0]) else { throw .invalidBTreeNodeKind }
        try bytes.requireBytes(1, at: 1)
        let num = bytes[1]
        guard UInt64(num) <= Trie.slotsPerBlock else { throw .invalidBTreeNode }
        return (kind, num)
    }

    /// The sum of the first `num` subtree counts.
    static func total(of counts: InlineArray<16, UInt64>, num: UInt8) -> UInt64 {
        var total: UInt64 = 0
        for index in 0..<Int(num) {
            total += counts[index]
        }
        return total
    }
}

/// A node of a linked array list's tree.
///
/// As in Zig, one value serves for both kinds: a leaf uses `values`, a branch
/// uses `children` and `counts`, and the fields of the other kind stay empty.
/// Only the first `num` entries are in use, but all sixteen are stored.
struct BTreeNode: Sendable {
    var kind: BTreeNodeKind

    /// The number of entries in use.
    var num: UInt8

    /// Leaf: the element slots.
    var values: InlineArray<16, Slot>

    /// Branch: `index` slots pointing at the child nodes.
    var children: InlineArray<16, Slot>

    /// Branch: the number of elements beneath each child.
    var counts: InlineArray<16, UInt64>

    /// The size of a leaf on disk.
    static let leafByteCount: UInt64 = TreeNodeHeader.byteCount + Slot.byteCount * Trie.slotsPerBlock

    /// The size of a branch on disk.
    static let branchByteCount: UInt64 = TreeNodeHeader.byteCount + (Slot.byteCount + 8) * Trie.slotsPerBlock

    /// Creates a node with every entry empty.
    init(kind: BTreeNodeKind, num: UInt8) {
        self.kind = kind
        self.num = num
        self.values = InlineArray(repeating: Slot())
        self.children = InlineArray(repeating: Slot())
        self.counts = InlineArray(repeating: 0)
    }

    /// The size of this node on disk.
    var byteCount: UInt64 {
        kind == .leaf ? Self.leafByteCount : Self.branchByteCount
    }

    /// The number of elements in and beneath this node.
    var subtreeCount: UInt64 {
        kind == .leaf ? UInt64(num) : TreeNodeHeader.total(of: counts, num: num)
    }

    /// Decodes a node from the start of `bytes`.
    ///
    /// A node is read with one call that asks for a branch's worth of bytes
    /// and may get fewer when the node is a leaf near the end of the file, so
    /// `bytes` may be longer or shorter than the node.
    ///
    /// - Throws: `invalidBTreeNodeKind` or `invalidBTreeNode` for a bad
    ///   header, `invalidEnumTag` at the first slot whose tag is unknown, or
    ///   `endOfStream` where the bytes run out before the node is complete.
    init(decoding bytes: Span<UInt8>) throws(XitDBError) {
        let header = try TreeNodeHeader.decode(bytes)
        self.init(kind: header.kind, num: header.num)
        switch kind {
        case .leaf:
            values = try SlotGroup.decode(bytes, at: 2)
        case .branch:
            children = try SlotGroup.decode(bytes, at: 2)
            counts = try SlotGroup.decodeCounts(bytes, at: 146)
        }
    }

    /// Appends the node: 146 bytes for a leaf, 274 for a branch.
    func encode(into output: inout OutputSpan<UInt8>) {
        output.append(kind.rawValue)
        output.append(num)
        switch kind {
        case .leaf:
            SlotGroup.encode(values, into: &output)
        case .branch:
            SlotGroup.encode(children, into: &output)
            SlotGroup.encodeCounts(counts, into: &output)
        }
    }
}

/// A node of a sorted map's or sorted set's tree.
///
/// As in Zig, one value serves for both kinds: a leaf uses `entries`, a
/// branch uses `children`, `separators` and `counts`, and the fields of the
/// other kind stay empty. Only the first `num` entries are in use, but all
/// sixteen are stored.
struct SortedNode: Sendable {
    var kind: BTreeNodeKind

    /// The number of entries in use.
    var num: UInt8

    /// Leaf: the entries in ascending key order. Each is either a pointer to
    /// a key-value pair or a key on its own.
    var entries: InlineArray<16, Slot>

    /// Branch: `index` slots pointing at the child nodes.
    var children: InlineArray<16, Slot>

    /// Branch: for each child, a byte-array slot holding a lower bound for
    /// the keys beneath it. The first is an unused sentinel.
    var separators: InlineArray<16, Slot>

    /// Branch: the number of entries beneath each child.
    var counts: InlineArray<16, UInt64>

    /// The size of a leaf on disk.
    static let leafByteCount: UInt64 = TreeNodeHeader.byteCount + Slot.byteCount * Trie.slotsPerBlock

    /// The size of a branch on disk.
    static let branchByteCount: UInt64 = TreeNodeHeader.byteCount + (Slot.byteCount * 2 + 8) * Trie.slotsPerBlock

    /// Creates a node with every entry empty.
    init(kind: BTreeNodeKind, num: UInt8) {
        self.kind = kind
        self.num = num
        self.entries = InlineArray(repeating: Slot())
        self.children = InlineArray(repeating: Slot())
        self.separators = InlineArray(repeating: Slot())
        self.counts = InlineArray(repeating: 0)
    }

    /// The size of this node on disk.
    var byteCount: UInt64 {
        kind == .leaf ? Self.leafByteCount : Self.branchByteCount
    }

    /// The number of entries in and beneath this node.
    var subtreeCount: UInt64 {
        kind == .leaf ? UInt64(num) : TreeNodeHeader.total(of: counts, num: num)
    }

    /// Decodes a node from the start of `bytes`.
    ///
    /// As with ``BTreeNode``, `bytes` may be longer or shorter than the node.
    ///
    /// - Throws: `invalidBTreeNodeKind` or `invalidBTreeNode` for a bad
    ///   header, `invalidEnumTag` at the first slot whose tag is unknown, or
    ///   `endOfStream` where the bytes run out before the node is complete.
    init(decoding bytes: Span<UInt8>) throws(XitDBError) {
        let header = try TreeNodeHeader.decode(bytes)
        self.init(kind: header.kind, num: header.num)
        switch kind {
        case .leaf:
            entries = try SlotGroup.decode(bytes, at: 2)
        case .branch:
            children = try SlotGroup.decode(bytes, at: 2)
            separators = try SlotGroup.decode(bytes, at: 146)
            counts = try SlotGroup.decodeCounts(bytes, at: 290)
        }
    }

    /// Appends the node: 146 bytes for a leaf, 418 for a branch.
    func encode(into output: inout OutputSpan<UInt8>) {
        output.append(kind.rawValue)
        output.append(num)
        switch kind {
        case .leaf:
            SlotGroup.encode(entries, into: &output)
        case .branch:
            SlotGroup.encode(children, into: &output)
            SlotGroup.encode(separators, into: &output)
            SlotGroup.encodeCounts(counts, into: &output)
        }
    }
}
