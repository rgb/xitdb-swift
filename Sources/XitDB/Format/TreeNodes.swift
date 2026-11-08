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
}

/// What a tree node is: its bytes on disk, in an inline array of the size
/// of a branch, with the fields read and written in place.
///
/// Zig reads and writes a node whole and touches only the fields it needs;
/// decoding every field into arrays of slots cost the port a third of a
/// write. The checks of a node stay where they were, in the decode that
/// validates every slot's tag and the counts' presence before the bytes are
/// kept, so that a damaged file is reported there and the accessors read
/// bytes that were checked.
///
/// The fields are read one at a time with `child(_:)`, `count(_:)` and the
/// like, and written with `setChild(_:at:)` and the like. The arrays of
/// sixteen, `children`, `counts` and so on, decode or encode all sixteen at
/// once, for the walk of an iterator and for tests.
protocol TreeNodeBytes {
    /// The size of a leaf on disk.
    static var leafByteCount: UInt64 { get }
    /// The size of a branch on disk.
    static var branchByteCount: UInt64 { get }
}

extension Slot {
    /// The slot at `offset` of a node's bytes, which were validated when the
    /// node was decoded or written by this engine, so that its tag is one.
    static func inNode(_ bytes: Span<UInt8>, at offset: Int) -> Slot {
        let first = bytes[offset]
        guard let tag = Slot.Tag(rawValue: first & 0x7F) else {
            preconditionFailure("a node's bytes were not validated")
        }
        return Slot(value: bytes.bigEndian(UInt64.self, at: offset + 1), tag: tag, full: first & 0x80 != 0)
    }
}

/// A node of a linked array list's tree.
///
/// As in Zig, one value serves for both kinds: a leaf's values and a
/// branch's children are the same sixteen slots after the header, and a
/// branch's counts follow them. Only the first `num` entries are in use,
/// but all sixteen are stored.
struct BTreeNode: Sendable, TreeNodeBytes {
    /// The node as it is on disk, a branch's worth; a leaf uses the first
    /// 146 bytes and the rest are zero.
    private(set) var bytes: InlineArray<274, UInt8>

    /// The size of a leaf on disk.
    static let leafByteCount: UInt64 = TreeNodeHeader.byteCount + Slot.byteCount * Trie.slotsPerBlock

    /// The size of a branch on disk.
    static let branchByteCount: UInt64 = TreeNodeHeader.byteCount + (Slot.byteCount + 8) * Trie.slotsPerBlock

    /// Where the counts of a branch start.
    static let countsOffset = 146

    /// Creates a node with every entry empty.
    init(kind: BTreeNodeKind, num: UInt8) {
        bytes = InlineArray(repeating: 0)
        bytes[0] = kind.rawValue
        bytes[1] = num
    }

    var kind: BTreeNodeKind {
        get {
            guard let kind = BTreeNodeKind(rawValue: bytes[0]) else {
                preconditionFailure("a node's bytes were not validated")
            }
            return kind
        }
        set { bytes[0] = newValue.rawValue }
    }

    /// The number of entries in use.
    var num: UInt8 {
        get { bytes[1] }
        set { bytes[1] = newValue }
    }

    /// Leaf: the element slot at `index`.
    func value(_ index: Int) -> Slot {
        Slot.inNode(bytes.span, at: 2 + 9 * index)
    }

    /// Branch: the `index` slot pointing at the child at `index`.
    func child(_ index: Int) -> Slot {
        Slot.inNode(bytes.span, at: 2 + 9 * index)
    }

    /// Branch: the number of elements beneath the child at `index`.
    func count(_ index: Int) -> UInt64 {
        bytes.span.bigEndian(at: Self.countsOffset + 8 * index)
    }

    mutating func setValue(_ slot: Slot, at index: Int) {
        var span = bytes.mutableSpan
        slot.encode(into: &span, at: 2 + 9 * index)
    }

    mutating func setChild(_ slot: Slot, at index: Int) {
        var span = bytes.mutableSpan
        slot.encode(into: &span, at: 2 + 9 * index)
    }

    mutating func setCount(_ count: UInt64, at index: Int) {
        var span = bytes.mutableSpan
        span.storeBigEndian(count, at: Self.countsOffset + 8 * index)
    }

    /// Leaf: the element slots, all sixteen.
    var values: InlineArray<16, Slot> {
        get { InlineArray { value($0) } }
        set {
            for index in 0..<16 {
                setValue(newValue[index], at: index)
            }
        }
    }

    /// Branch: `index` slots pointing at the child nodes, all sixteen.
    var children: InlineArray<16, Slot> {
        get { InlineArray { child($0) } }
        set {
            for index in 0..<16 {
                setChild(newValue[index], at: index)
            }
        }
    }

    /// Branch: the number of elements beneath each child, all sixteen.
    var counts: InlineArray<16, UInt64> {
        get { InlineArray { count($0) } }
        set {
            for index in 0..<16 {
                setCount(newValue[index], at: index)
            }
        }
    }

    /// The size of this node on disk.
    var byteCount: UInt64 {
        kind == .leaf ? Self.leafByteCount : Self.branchByteCount
    }

    /// The number of elements in and beneath this node.
    ///
    /// - Throws: `invalidBTreeNode` if a branch's counts, which came from
    ///   the file, add up past what a number holds.
    func subtreeCount() throws(XitDBError) -> UInt64 {
        if kind == .leaf { return UInt64(num) }
        var total: UInt64 = 0
        for index in 0..<Int(num) {
            let (sum, overflow) = total.addingReportingOverflow(count(index))
            guard !overflow else { throw .invalidBTreeNode }
            total = sum
        }
        return total
    }

    /// Decodes a node from the start of `bytes`.
    ///
    /// A node is read with one call that asks for a branch's worth of bytes
    /// and may get fewer when the node is a leaf near the end of the file, so
    /// `bytes` may be longer or shorter than the node. Every slot's tag is
    /// checked, and the counts' presence, before the bytes are kept.
    ///
    /// - Throws: `invalidBTreeNodeKind` or `invalidBTreeNode` for a bad
    ///   header, `invalidEnumTag` at the first slot whose tag is unknown, or
    ///   `endOfStream` where the bytes run out before the node is complete.
    init(decoding bytes: Span<UInt8>) throws(XitDBError) {
        let header = try TreeNodeHeader.decode(bytes)
        try SlotGroup.validate(bytes, at: 2)
        if header.kind == .branch {
            try bytes.requireBytes(128, at: Self.countsOffset)
        }
        self.bytes = InlineArray(repeating: 0)
        let count = Int(header.kind == .leaf ? Self.leafByteCount : Self.branchByteCount)
        var span = self.bytes.mutableSpan
        span.copyBytes(from: bytes, count: count)
    }

    /// Appends the node: 146 bytes for a leaf, 274 for a branch.
    func encode(into output: inout OutputSpan<UInt8>) {
        for index in 0..<Int(byteCount) {
            output.append(bytes[index])
        }
    }

    /// Stores the node at the start of `bytes`, in place: 146 bytes for a
    /// leaf, 274 for a branch.
    ///
    /// - Precondition: `bytes` holds at least as many bytes as the node
    ///   takes.
    func encode(into bytes: inout MutableSpan<UInt8>) {
        bytes.copyBytes(from: self.bytes.span, count: Int(byteCount))
    }
}

/// A node of a sorted map's tree: a linked array list's node with a
/// separator key for each child of a branch.
///
/// As in Zig, one value serves for both kinds: a leaf's entries and a
/// branch's children are the same sixteen slots after the header, and a
/// branch's separators and counts follow them.
struct SortedNode: Sendable, TreeNodeBytes {
    /// The node as it is on disk, a branch's worth; a leaf uses the first
    /// 146 bytes and the rest are zero.
    private(set) var bytes: InlineArray<418, UInt8>

    /// The size of a leaf on disk.
    static let leafByteCount: UInt64 = TreeNodeHeader.byteCount + Slot.byteCount * Trie.slotsPerBlock

    /// The size of a branch on disk.
    static let branchByteCount: UInt64 = TreeNodeHeader.byteCount + (Slot.byteCount * 2 + 8) * Trie.slotsPerBlock

    /// Where the separators of a branch start.
    static let separatorsOffset = 146

    /// Where the counts of a branch start.
    static let countsOffset = 290

    /// Creates a node with every entry empty.
    init(kind: BTreeNodeKind, num: UInt8) {
        bytes = InlineArray(repeating: 0)
        bytes[0] = kind.rawValue
        bytes[1] = num
    }

    var kind: BTreeNodeKind {
        get {
            guard let kind = BTreeNodeKind(rawValue: bytes[0]) else {
                preconditionFailure("a node's bytes were not validated")
            }
            return kind
        }
        set { bytes[0] = newValue.rawValue }
    }

    /// The number of entries in use.
    var num: UInt8 {
        get { bytes[1] }
        set { bytes[1] = newValue }
    }

    /// Leaf: the entry at `index`, in ascending key order: a pointer to a
    /// key-value pair or a key on its own.
    func entry(_ index: Int) -> Slot {
        Slot.inNode(bytes.span, at: 2 + 9 * index)
    }

    /// Branch: the `index` slot pointing at the child at `index`.
    func child(_ index: Int) -> Slot {
        Slot.inNode(bytes.span, at: 2 + 9 * index)
    }

    /// Branch: a byte-array slot holding a lower bound for the keys beneath
    /// the child at `index`. The first is an unused sentinel.
    func separator(_ index: Int) -> Slot {
        Slot.inNode(bytes.span, at: Self.separatorsOffset + 9 * index)
    }

    /// Branch: the number of entries beneath the child at `index`.
    func count(_ index: Int) -> UInt64 {
        bytes.span.bigEndian(at: Self.countsOffset + 8 * index)
    }

    mutating func setEntry(_ slot: Slot, at index: Int) {
        var span = bytes.mutableSpan
        slot.encode(into: &span, at: 2 + 9 * index)
    }

    mutating func setChild(_ slot: Slot, at index: Int) {
        var span = bytes.mutableSpan
        slot.encode(into: &span, at: 2 + 9 * index)
    }

    mutating func setSeparator(_ slot: Slot, at index: Int) {
        var span = bytes.mutableSpan
        slot.encode(into: &span, at: Self.separatorsOffset + 9 * index)
    }

    mutating func setCount(_ count: UInt64, at index: Int) {
        var span = bytes.mutableSpan
        span.storeBigEndian(count, at: Self.countsOffset + 8 * index)
    }

    /// Leaf: the entries, all sixteen.
    var entries: InlineArray<16, Slot> {
        get { InlineArray { entry($0) } }
        set {
            for index in 0..<16 {
                setEntry(newValue[index], at: index)
            }
        }
    }

    /// Branch: `index` slots pointing at the child nodes, all sixteen.
    var children: InlineArray<16, Slot> {
        get { InlineArray { child($0) } }
        set {
            for index in 0..<16 {
                setChild(newValue[index], at: index)
            }
        }
    }

    /// Branch: the separators, all sixteen.
    var separators: InlineArray<16, Slot> {
        get { InlineArray { separator($0) } }
        set {
            for index in 0..<16 {
                setSeparator(newValue[index], at: index)
            }
        }
    }

    /// Branch: the number of entries beneath each child, all sixteen.
    var counts: InlineArray<16, UInt64> {
        get { InlineArray { count($0) } }
        set {
            for index in 0..<16 {
                setCount(newValue[index], at: index)
            }
        }
    }

    /// The size of this node on disk.
    var byteCount: UInt64 {
        kind == .leaf ? Self.leafByteCount : Self.branchByteCount
    }

    /// The number of entries in and beneath this node.
    ///
    /// - Throws: `invalidBTreeNode` if a branch's counts, which came from
    ///   the file, add up past what a number holds.
    func subtreeCount() throws(XitDBError) -> UInt64 {
        if kind == .leaf { return UInt64(num) }
        var total: UInt64 = 0
        for index in 0..<Int(num) {
            let (sum, overflow) = total.addingReportingOverflow(count(index))
            guard !overflow else { throw .invalidBTreeNode }
            total = sum
        }
        return total
    }

    /// Decodes a node from the start of `bytes`.
    ///
    /// As with ``BTreeNode``, `bytes` may be longer or shorter than the node,
    /// and every slot's tag is checked, and the counts' presence, before the
    /// bytes are kept.
    ///
    /// - Throws: `invalidBTreeNodeKind` or `invalidBTreeNode` for a bad
    ///   header, `invalidEnumTag` at the first slot whose tag is unknown, or
    ///   `endOfStream` where the bytes run out before the node is complete.
    init(decoding bytes: Span<UInt8>) throws(XitDBError) {
        let header = try TreeNodeHeader.decode(bytes)
        try SlotGroup.validate(bytes, at: 2)
        if header.kind == .branch {
            try SlotGroup.validate(bytes, at: Self.separatorsOffset)
            try bytes.requireBytes(128, at: Self.countsOffset)
        }
        self.bytes = InlineArray(repeating: 0)
        let count = Int(header.kind == .leaf ? Self.leafByteCount : Self.branchByteCount)
        var span = self.bytes.mutableSpan
        span.copyBytes(from: bytes, count: count)
    }

    /// Appends the node: 146 bytes for a leaf, 418 for a branch.
    func encode(into output: inout OutputSpan<UInt8>) {
        for index in 0..<Int(byteCount) {
            output.append(bytes[index])
        }
    }

    /// Stores the node at the start of `bytes`, in place: 146 bytes for a
    /// leaf, 418 for a branch.
    ///
    /// - Precondition: `bytes` holds at least as many bytes as the node
    ///   takes.
    func encode(into bytes: inout MutableSpan<UInt8>) {
        bytes.copyBytes(from: self.bytes.span, count: Int(byteCount))
    }
}

extension BTreeNode: FrameStackElement {
    /// An empty leaf, to fill a frame stack's inline storage with.
    static var placeholder: BTreeNode { BTreeNode(kind: .leaf, num: 0) }
}

extension SortedNode: FrameStackElement {
    /// An empty leaf, to fill a frame stack's inline storage with.
    static var placeholder: SortedNode { SortedNode(kind: .leaf, num: 0) }
}
