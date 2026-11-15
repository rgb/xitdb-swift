// Going through the slots of a collection in order: the core of Zig's
// `Cursor.Iter`, on the read side of the engine.

/// Walks the elements of an array list or a linked array list, or the
/// entries of a hash map or set, one slot at a time.
///
/// It keeps the index blocks on the way from the collection's root to where
/// it stands, as Zig's iterator does, so that going on to the next slot
/// reads a block only when it enters one.
///
/// **The depth is bounded by what the collection allows.** A hash trie can
/// be as deep as its hashes have groups of four bits, and an array list as
/// deep as its size needs. A file that goes deeper, which includes one whose
/// blocks point back at themselves, is damaged, and the walk ends with an
/// error instead of growing without end. (Zig's iterator has a stack of a
/// fixed size and fails when it is full.)
///
/// A linked array list's or a sorted map's blocks are tree nodes, which
/// start with two bytes of kind and count that the walk skips. Their walks
/// count the elements they give and end at the size the header has, or
/// before it where the tree holds fewer (the last paragraph): every
/// element is a slot that holds something, since an element of a linked
/// array list that was never written is a placeholder set to nothing and
/// marked full, and a sorted leaf's entries are packed at its start.
///
/// **The work is bounded by the file, or by what the walk has given.** The
/// depth alone bounds no walk: blocks that lead to each other, within the
/// depth allowed, make a walk of sixteen to the power of that depth, on a
/// file no writer makes. So a walk counts the blocks it enters, and ends
/// with the error of its depth when they are more than its collection can
/// have (``Bound``). A hash trie's blocks and a sorted map's or set's nodes
/// are each a piece of the file of their own, since no block is twice in
/// one trie and no node twice in one sorted tree: such a walk enters no
/// more of them than the file has room for. A linked array list's nodes
/// can be in the list many times over, where a list was joined to itself,
/// so its walk is held to what it gives instead: no more nodes than the
/// depth a tree can have, sixty-five, for each element given so far and
/// for the next one. An array list's walk visits as many positions as the
/// list's size, which the file has room for
/// (``DatabaseReader/checkedArrayListHeader(at:)``).
///
/// **No count is held against another.** A copy of a collection made by
/// its slot and frozen by its cursor, then written beside its original in
/// one transaction, is left with a header, or with a branch's counts, that
/// disagree with what is under them, with no byte damaged; the original
/// reads such a tree, and so does this walk, as it did before it counted
/// blocks: it gives what the leaves hold, up to the header's size, and
/// ends.
struct SlotIterator {
    /// One block on the way down, and the slot in it that the walk is at.
    struct Level {
        var position: UInt64
        var block: IndexBlock
        var index: UInt8
    }

    private let reader: DatabaseReader

    /// The block the walk is in, or a used-up one when the walk is over.
    /// Kept apart from the stack so that the step from one slot to the next
    /// touches no array: an array's element is copied out to be read and
    /// checked for sharing to be changed, which was a third of the time of
    /// iterating.
    private var current = Level(position: 0, block: IndexBlock(), index: UInt8(Trie.slotsPerBlock))

    /// The blocks above `current`, nearest last.
    private var stack: [Level] = []

    /// The number of blocks on the way, `current` included. Zero when the
    /// walk is over.
    private var depth = 0

    /// Enters a block below the current one.
    private mutating func push(_ level: Level) {
        if depth > 0 {
            stack.append(current)
        }
        current = level
        depth += 1
    }

    /// Leaves the current block for the one above it.
    private mutating func pop() {
        depth -= 1
        if depth > 0 {
            current = stack.removeLast()
        }
    }

    /// What stops the walk at the collection's size.
    enum Counting {
        /// A hash map or set: the walk ends when its blocks do.
        case none
        /// An array list: the number of positions still to visit, which is
        /// what stops the walk at the list's size: the blocks may go on
        /// beyond it, with elements of a longer list that was cut down.
        ///
        /// Zig counts the elements it gives out instead, so after passing
        /// over an empty slot it gives out one past the end of a cut-down
        /// list. Here the walk visits the positions from its
        /// start to the list's size and no further, as reading by index
        /// does. Since the original's `89da8e7` an append leaves a slot set
        /// to nothing, which both walks give out, so the two agree on files
        /// written since; an empty slot inside a list's size is what an
        /// element appended and never written was before, and what a file
        /// from then still holds.
        case positions(UInt64)
        /// A linked array list: the number of elements still to give out,
        /// as Zig counts. The slots of a node beyond its count are empty
        /// and passed over without counting.
        case elements(UInt64)
    }

    private var remaining: Counting

    /// What bounds the number of blocks a walk enters, beside the depth.
    enum Bound {
        /// An array list: nothing more. Its walk visits as many positions
        /// as the list's size, and a block below the depth its size allows
        /// ends it.
        case positions
        /// A hash trie, or a sorted map's or set's tree: no more blocks
        /// than the file has room for, at `byteCount` bytes each, which is
        /// the least a block of the collection takes. Each block is a
        /// piece of the file of its own: which block of a trie an entry is
        /// in follows from its hash, and no writer puts a node in a sorted
        /// tree twice. (A sorted tree keeps its emptied leaves, so it may
        /// have many more nodes than entries; it has no more than the file
        /// holds.)
        case fileHolds(byteCount: UInt64)
        /// A linked array list's tree: no more nodes than the depth a tree
        /// can have for each element given so far, and for the next one.
        /// The file bounds nothing here, since a list joined to itself
        /// holds its nodes many times over. But every leaf of a list holds
        /// an element: a leaf that is emptied is dropped from the tree,
        /// and an element that was never written is a placeholder marked
        /// full, as it has been since the original's lists had trees (its
        /// commit 66a3a28). So the walk comes to an element within the
        /// depth of the tree from wherever it stands, and a walk that
        /// enters more nodes than that between two elements is among nodes
        /// that lead to each other.
        case elementsGiven

        /// A hash trie's bound: its blocks, of sixteen slots each.
        static var blocksOfATrie: Bound { .fileHolds(byteCount: IndexBlock.byteCount) }

        /// A sorted tree's bound: its nodes, the least of which is a leaf.
        static var nodesOfASortedTree: Bound { .fileHolds(byteCount: SortedNode.leafByteCount) }
    }

    private let bound: Bound

    /// The blocks the walk may still enter before its bound is looked at
    /// again. The step that enters a block counts this down and does
    /// nothing else for the bound: the bound itself, which asks the file
    /// for its length or works out what the elements given allow, is
    /// looked at only when this is used up (``allowMoreBlocks()``). A
    /// bound only ever grows, with the file or with the elements given, so
    /// looking at it late refuses the same block as looking at it for
    /// every one.
    private var blocksLeft: UInt64

    /// The blocks the walk has been allowed in all, below the ones it
    /// started with: when `blocksLeft` is used up, the number it has
    /// entered.
    private var blocksAllowed: UInt64 = 0

    /// For a walk bounded by what it gives: the elements it had to give
    /// when it started.
    private var elementsAtStart: UInt64 = 0

    /// The bytes to skip at the start of a block the walk enters: a tree
    /// node's kind and count, or nothing for an index block.
    private let nodeOffset: UInt64

    /// The most blocks that can lie on the way from the root to a slot.
    private let maxDepth: Int

    /// What going deeper than `maxDepth` is reported as.
    private let depthError: XitDBError

    private init(
        reader: DatabaseReader,
        remaining: Counting,
        bound: Bound,
        maxDepth: Int,
        depthError: XitDBError,
        nodeOffset: UInt64 = 0
    ) {
        self.reader = reader
        self.remaining = remaining
        self.bound = bound
        self.maxDepth = maxDepth
        self.depthError = depthError
        self.nodeOffset = nodeOffset
        // An array list's walk is never asked: its allowance is every
        // block there could be. The others start with none, so that their
        // bound is looked at for the first block.
        if case .positions = bound {
            blocksLeft = .max
        } else {
            blocksLeft = 0
        }
        if case .elements(let elements) = remaining {
            elementsAtStart = elements
        }
    }

    /// A walk that gives out nothing.
    private init(reader: DatabaseReader) {
        self.init(
            reader: reader, remaining: .positions(0), bound: .positions, maxDepth: 0, depthError: .invalidDatabase)
    }

    /// The block the step enters: ``DatabaseReader/indexBlock(at:)``,
    /// written out so that it is compiled into the step with the read of
    /// its bytes, as the step had it before the reader looked at where
    /// data starts. Left to the optimiser, the read became a call of its
    /// own, which cost a walk of a list one part in forty.
    @inline(__always)
    private func enteredBlock(at position: UInt64) throws(XitDBError) -> IndexBlock {
        let bytes: InlineArray<144, UInt8> = try reader.bytes(at: position)
        return try IndexBlock(decoding: bytes.span)
    }

    /// Looks at the walk's bound again, when the blocks it was allowed are
    /// used up, and allows it as many more as the bound now has room for,
    /// or refuses the block it is about to enter. Kept out of the step:
    /// it runs once for a walk bounded by the file, unless the file is too
    /// small for the walk, and once in many blocks for a list.
    ///
    /// - Throws: The error of the walk's depth, `keyOffsetExceeded` for a
    ///   hash trie and `invalidBTreeNode` for a tree, if the walk has
    ///   entered as many blocks as its collection can have; and the
    ///   storage's errors where its length is asked for.
    @inline(never)
    private mutating func allowMoreBlocks() throws(XitDBError) {
        let allowed: UInt64
        switch bound {
        case .positions:
            allowed = .max
        case .fileHolds(let byteCount):
            // as it is now: the file may have grown since it was asked
            allowed = try reader.piecesTheFileHolds(of: byteCount)
        case .elementsGiven:
            guard case .elements(let left) = remaining else {
                blocksLeft = .max
                return
            }
            // The elements given so far and the next one, each allowed
            // the depth of a tree. A product past what a number holds
            // bounds nothing a walk can reach.
            let (elements, tooMany) = (elementsAtStart - left).addingReportingOverflow(1)
            let (product, overflow) = elements.multipliedReportingOverflow(by: UInt64(maxDepth))
            allowed = tooMany || overflow ? .max : product
        }
        guard allowed > blocksAllowed else { throw depthError }
        blocksLeft = allowed - blocksAllowed
        blocksAllowed = allowed
    }

    /// Starts a walk at the first slot of the collection that `slot` holds.
    /// An empty slot holds nothing to walk.
    ///
    /// - Throws: `unexpectedTag` if the slot holds something that is not a
    ///   collection; `invalidCount` for an array list or a sorted map or
    ///   set whose size the file has no room for; and the errors of reading
    ///   the header and the first block.
    init(reader: DatabaseReader, collection slot: Slot) throws(XitDBError) {
        let rootPosition: UInt64
        switch slot.tag {
        case .none:
            self.init(reader: reader)
            return
        case .arrayList:
            let header = try reader.checkedArrayListHeader(at: slot.value)
            self.init(
                reader: reader,
                remaining: .positions(header.size),
                bound: .positions,
                maxDepth: Self.arrayListDepth(size: header.size),
                depthError: .maxShiftExceeded
            )
            rootPosition = header.ptr
        case .linkedArrayList:
            let header = try reader.bTreeHeader(at: slot.value)
            self.init(
                reader: reader,
                remaining: .elements(header.size),
                bound: .elementsGiven,
                maxDepth: BTree.maxHeight + 1,
                depthError: .invalidBTreeNode,
                nodeOffset: BTree.nodeHeaderByteCount
            )
            rootPosition = try header.rootPtr.offset(by: BTree.nodeHeaderByteCount)
        case .hashMap, .hashSet:
            self.init(
                reader: reader, remaining: .none, bound: .blocksOfATrie,
                maxDepth: Int(reader.hashSize) * 2, depthError: .keyOffsetExceeded)
            rootPosition = slot.value
        case .countedHashMap, .countedHashSet:
            self.init(
                reader: reader, remaining: .none, bound: .blocksOfATrie,
                maxDepth: Int(reader.hashSize) * 2, depthError: .keyOffsetExceeded)
            rootPosition = try slot.value.offset(by: IndexBlock.countByteCount)
        case .sortedMap, .sortedSet:
            let header = try reader.checkedSortedHeader(at: slot.value)
            self.init(
                reader: reader,
                remaining: .elements(header.size),
                bound: .nodesOfASortedTree,
                maxDepth: BTree.maxHeight + 1,
                depthError: .invalidBTreeNode,
                nodeOffset: BTree.nodeHeaderByteCount
            )
            rootPosition = try header.rootPtr.offset(by: BTree.nodeHeaderByteCount)
        default:
            throw .unexpectedTag
        }
        stack.reserveCapacity(min(maxDepth, 8))
        push(Level(position: rootPosition, block: try reader.indexBlock(at: rootPosition), index: 0))
    }

    /// Starts a walk of an array list at one of its elements. A negative
    /// index counts from the end. An index that names no element gives a
    /// walk of nothing, and so does an empty slot.
    ///
    /// - Throws: `unexpectedTag` if the slot holds something other than an
    ///   array list, or if the list's blocks are not what its size says;
    ///   `invalidCount` for a size the file has no room for.
    init(reader: DatabaseReader, arrayList slot: Slot, from startIndex: Int64) throws(XitDBError) {
        switch slot.tag {
        case .none:
            self.init(reader: reader)
            return
        case .arrayList:
            break
        default:
            throw .unexpectedTag
        }
        let header = try reader.checkedArrayListHeader(at: slot.value)
        guard let key = DatabaseReader.arrayListKey(index: startIndex, size: header.size) else {
            self.init(reader: reader)
            return
        }
        self.init(
            reader: reader,
            remaining: .positions(header.size - key),
            bound: .positions,
            maxDepth: Self.arrayListDepth(size: header.size),
            depthError: .maxShiftExceeded
        )
        stack.reserveCapacity(maxDepth)

        // Descend to the element, keeping each block with its index set to
        // the slot the way goes through. The walk goes forward from there.
        var position = header.ptr
        var shift = maxDepth - 1
        while true {
            let block = try reader.indexBlock(at: position)
            let index = Int(DatabaseReader.arrayListSlotIndex(key: key, shift: UInt8(shift)))
            push(Level(position: position, block: block, index: UInt8(index)))
            if shift == 0 { break }
            // Every block above the last holds a pointer to the next one for
            // any element the list has.
            let child = block.slots[index]
            guard child.tag == .index else { throw .unexpectedTag }
            position = child.value
            shift -= 1
        }
    }

    /// Starts a walk of a linked array list at one of its elements, by
    /// descending the tree by rank: Zig's `btreeStackFromIndex`. A negative
    /// index counts from the end. An index that names no element gives a
    /// walk of nothing, and so does an empty slot.
    ///
    /// - Throws: `unexpectedTag` if the slot holds something other than a
    ///   linked array list; `invalidBTreeNode` if the rank is beyond the
    ///   leaf it leads to, a branch has no children or a child is not a
    ///   node, or the tree is deeper than a tree can be.
    init(reader: DatabaseReader, linkedArrayList slot: Slot, from startIndex: Int64) throws(XitDBError) {
        switch slot.tag {
        case .none:
            self.init(reader: reader)
            return
        case .linkedArrayList:
            break
        default:
            throw .unexpectedTag
        }
        let header = try reader.bTreeHeader(at: slot.value)
        try self.init(reader: reader, tree: header, bound: .elementsGiven, from: startIndex) {
            (position) throws(XitDBError) in
            try reader.bTreeNode(at: position)
        }
    }

    /// Starts a walk of a sorted map or set at one of its entries, by
    /// descending the tree by rank: Zig's `sortedStackFromIndex`.
    ///
    /// - Throws: `unexpectedTag` if the slot holds something other than a
    ///   sorted map or set; `invalidCount` for a size the file has no room
    ///   for; `invalidBTreeNode` as for a linked array list.
    init(reader: DatabaseReader, sortedMap slot: Slot, from startIndex: Int64) throws(XitDBError) {
        switch slot.tag {
        case .none:
            self.init(reader: reader)
            return
        case .sortedMap, .sortedSet:
            break
        default:
            throw .unexpectedTag
        }
        let header = try reader.checkedSortedHeader(at: slot.value)
        try self.init(
            reader: reader, tree: header, bound: .nodesOfASortedTree, from: startIndex
        ) { (position) throws(XitDBError) in
            try reader.sortedNode(at: position)
        }
    }

    /// Starts a walk of a sorted map or set at the first entry whose key is
    /// not below `key`: Zig's `sortedStackFromKey`. A key beyond every
    /// entry gives a walk of nothing, and so does an empty slot.
    ///
    /// - Throws: `unexpectedTag` if the slot holds something other than a
    ///   sorted map or set; `invalidCount` for a size the file has no room
    ///   for; `invalidBTreeNode` if a branch has no children or a child is
    ///   not a node, the tree is deeper than a tree can be, or the counts
    ///   on the way add up past what a number holds; and the errors of
    ///   comparing keys.
    init(reader: DatabaseReader, sortedMap slot: Slot, fromKey key: SortedKey) throws(XitDBError) {
        switch slot.tag {
        case .none:
            self.init(reader: reader)
            return
        case .sortedMap, .sortedSet:
            break
        default:
            throw .unexpectedTag
        }
        let header = try reader.checkedSortedHeader(at: slot.value)
        self.init(
            reader: reader,
            remaining: .elements(header.size),
            bound: .nodesOfASortedTree,
            maxDepth: BTree.maxHeight + 1,
            depthError: .invalidBTreeNode,
            nodeOffset: BTree.nodeHeaderByteCount
        )

        // The keys below the start are the entries the walk does not give.
        var before: UInt64 = 0
        var nodePtr = header.rootPtr
        try key.withBytes { (bytes: Span<UInt8>) throws(XitDBError) in
            while depth <= BTree.maxHeight {
                let node = try reader.sortedNode(at: nodePtr)
                let position = try nodePtr.offset(by: BTree.nodeHeaderByteCount)
                switch node.kind {
                case .leaf:
                    let search = try reader.sortedLeafSearch(node, key: bytes)
                    before = try before.addingCount(UInt64(search.index))
                    push(Level(position: position, block: IndexBlock(slots: node.entries), index: UInt8(search.index)))
                    return
                case .branch:
                    guard node.num > 0 else { throw .invalidBTreeNode }
                    let index = try reader.sortedBranchSearch(node, key: bytes)
                    guard node.child(index).tag == .index else { throw .invalidBTreeNode }
                    for below in 0..<index {
                        before = try before.addingCount(node.count(below))
                    }
                    push(Level(position: position, block: IndexBlock(slots: node.children), index: UInt8(index)))
                    nodePtr = node.child(index).value
                }
            }
            throw .invalidBTreeNode
        }
        remaining = .elements(before < header.size ? header.size - before : 0)
    }

    /// Starts a walk of the tree of `header` at the element at
    /// `startIndex`, read with `read`, with one level per node on the way
    /// and each level's index set to the child the way goes through.
    private init<Node: RankedNode>(
        reader: DatabaseReader,
        tree header: BTreeHeader,
        bound: Bound,
        from startIndex: Int64,
        read: (UInt64) throws(XitDBError) -> Node
    ) throws(XitDBError) {
        guard let rank = DatabaseReader.linkedArrayListRank(index: startIndex, size: header.size) else {
            self.init(reader: reader)
            return
        }
        self.init(
            reader: reader,
            remaining: .elements(header.size - rank),
            bound: bound,
            maxDepth: BTree.maxHeight + 1,
            depthError: .invalidBTreeNode,
            nodeOffset: BTree.nodeHeaderByteCount
        )

        var nodePtr = header.rootPtr
        var rem = rank
        while depth <= BTree.maxHeight {
            let node = try read(nodePtr)
            let position = try nodePtr.offset(by: BTree.nodeHeaderByteCount)
            switch node.kind {
            case .leaf:
                guard rem < UInt64(node.num) else { throw .invalidBTreeNode }
                var block = IndexBlock()
                for index in 0..<16 {
                    block.slots[index] = node.leafSlot(at: index)
                }
                push(Level(position: position, block: block, index: UInt8(rem)))
                return
            case .branch:
                guard node.num > 0 else { throw .invalidBTreeNode }
                let (index, next) = BTree.child(of: node, rank: rem, inclusive: false)
                guard node.child(index).tag == .index else { throw .invalidBTreeNode }
                push(Level(position: position, block: IndexBlock(slots: node.children), index: UInt8(index)))
                nodePtr = node.child(index).value
                rem = next
            }
        }
        throw .invalidBTreeNode
    }

    /// The number of blocks from the root of an array list of `size`
    /// elements to an element.
    static func arrayListDepth(size: UInt64) -> Int {
        guard size > Trie.slotsPerBlock else { return 1 }
        return Int(Trie.arrayListShift(lastIndex: size - 1)) + 1
    }

    /// The next slot that holds something, with its position, or `nil` when
    /// the walk is over.
    ///
    /// An empty slot is passed over. One that was set to nothing is given
    /// out: it is an element whose value is nothing, which is also what an
    /// append leaves for an element that is never written.
    ///
    /// - Throws: `keyOffsetExceeded` for a hash trie that is deeper than it
    ///   can be, or that has more blocks than the file has room for;
    ///   `maxShiftExceeded` for an array list that is deeper than it can
    ///   be; `invalidBTreeNode` for a tree that is deeper than it can be,
    ///   or that has more nodes than its collection can have (``Bound``);
    ///   `invalidEnumTag` or `endOfStream` for a block that cannot be read,
    ///   the latter also for one before where data starts.
    mutating func next() throws(XitDBError) -> SlotPointer? {
        while depth > 0 {
            let index = Int(current.index)
            if index == Int(Trie.slotsPerBlock) {
                // This block is done: go on in the one above it.
                pop()
                current.index += 1
                continue
            }
            let slot = current.block.slots[index]
            if slot.tag == .index {
                if depth >= maxDepth { throw depthError }
                if blocksLeft == 0 { try allowMoreBlocks() }
                blocksLeft &-= 1
                let position = try slot.value.offset(by: nodeOffset)
                push(Level(position: position, block: try enteredBlock(at: position), index: 0))
                continue
            }
            // A slot that is not a block is an element, or an entry.
            switch remaining {
            case .none:
                break
            case .positions(let left):
                if left == 0 { return nil }
                remaining = .positions(left - 1)
            case .elements(let left):
                if left == 0 { return nil }
                if !slot.isEmpty { remaining = .elements(left - 1) }
            }
            current.index += 1
            if !slot.isEmpty {
                let position = try current.position.offset(by: Slot.byteCount * UInt64(index))
                return SlotPointer(position: position, slot: slot)
            }
        }
        return nil
    }
}
