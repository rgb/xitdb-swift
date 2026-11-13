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
/// end after giving out as many elements as the collection has: every
/// element is a slot that holds something, since an element of a linked
/// array list that was never written is a placeholder set to nothing and
/// marked full, and a sorted leaf's entries are packed at its start.
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
        /// list (finding 26). Here the walk visits the positions from its
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
        maxDepth: Int,
        depthError: XitDBError,
        nodeOffset: UInt64 = 0
    ) {
        self.reader = reader
        self.remaining = remaining
        self.maxDepth = maxDepth
        self.depthError = depthError
        self.nodeOffset = nodeOffset
    }

    /// A walk that gives out nothing.
    private init(reader: DatabaseReader) {
        self.init(reader: reader, remaining: .positions(0), maxDepth: 0, depthError: .invalidDatabase)
    }

    /// Starts a walk at the first slot of the collection that `slot` holds.
    /// An empty slot holds nothing to walk.
    ///
    /// - Throws: `unexpectedTag` if the slot holds something that is not a
    ///   collection, or `notImplemented` for the collections whose walks do
    ///   not exist yet.
    init(reader: DatabaseReader, collection slot: Slot) throws(XitDBError) {
        let rootPosition: UInt64
        switch slot.tag {
        case .none:
            self.init(reader: reader)
            return
        case .arrayList:
            let header = try reader.arrayListHeader(at: slot.value)
            self.init(
                reader: reader,
                remaining: .positions(header.size),
                maxDepth: Self.arrayListDepth(size: header.size),
                depthError: .maxShiftExceeded
            )
            rootPosition = header.ptr
        case .linkedArrayList:
            let header = try reader.bTreeHeader(at: slot.value)
            self.init(
                reader: reader,
                remaining: .elements(header.size),
                maxDepth: BTree.maxHeight + 1,
                depthError: .invalidBTreeNode,
                nodeOffset: BTree.nodeHeaderByteCount
            )
            rootPosition = try header.rootPtr.offset(by: BTree.nodeHeaderByteCount)
        case .hashMap, .hashSet:
            self.init(
                reader: reader, remaining: .none, maxDepth: Int(reader.hashSize) * 2, depthError: .keyOffsetExceeded)
            rootPosition = slot.value
        case .countedHashMap, .countedHashSet:
            self.init(
                reader: reader, remaining: .none, maxDepth: Int(reader.hashSize) * 2, depthError: .keyOffsetExceeded)
            rootPosition = try slot.value.offset(by: IndexBlock.countByteCount)
        case .sortedMap, .sortedSet:
            let header = try reader.bTreeHeader(at: slot.value)
            self.init(
                reader: reader,
                remaining: .elements(header.size),
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
    ///   array list, or if the list's blocks are not what its size says.
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
        let header = try reader.arrayListHeader(at: slot.value)
        guard let key = DatabaseReader.arrayListKey(index: startIndex, size: header.size) else {
            self.init(reader: reader)
            return
        }
        self.init(
            reader: reader,
            remaining: .positions(header.size - key),
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
        try self.init(reader: reader, tree: slot, from: startIndex) { (position) throws(XitDBError) in
            try reader.bTreeNode(at: position)
        }
    }

    /// Starts a walk of a sorted map or set at one of its entries, by
    /// descending the tree by rank: Zig's `sortedStackFromIndex`.
    ///
    /// - Throws: `unexpectedTag` if the slot holds something other than a
    ///   sorted map or set; `invalidBTreeNode` as for a linked array list.
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
        try self.init(reader: reader, tree: slot, from: startIndex) { (position) throws(XitDBError) in
            try reader.sortedNode(at: position)
        }
    }

    /// Starts a walk of a sorted map or set at the first entry whose key is
    /// not below `key`: Zig's `sortedStackFromKey`. A key beyond every
    /// entry gives a walk of nothing, and so does an empty slot.
    ///
    /// - Throws: `unexpectedTag` if the slot holds something other than a
    ///   sorted map or set; `invalidBTreeNode` if a branch has no children
    ///   or a child is not a node, the tree is deeper than a tree can be,
    ///   or the counts on the way add up past what a number holds; and
    ///   the errors of comparing keys.
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
        let header = try reader.bTreeHeader(at: slot.value)
        self.init(
            reader: reader,
            remaining: .elements(header.size),
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

    /// Starts a walk of a tree at the element at `startIndex`, read with
    /// `read`, with one level per node on the way and each level's index
    /// set to the child the way goes through.
    private init<Node: RankedNode>(
        reader: DatabaseReader,
        tree slot: Slot,
        from startIndex: Int64,
        read: (UInt64) throws(XitDBError) -> Node
    ) throws(XitDBError) {
        let header = try reader.bTreeHeader(at: slot.value)
        guard let rank = DatabaseReader.linkedArrayListRank(index: startIndex, size: header.size) else {
            self.init(reader: reader)
            return
        }
        self.init(
            reader: reader,
            remaining: .elements(header.size - rank),
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
    /// - Throws: `keyOffsetExceeded` for a hash trie, or `maxShiftExceeded`
    ///   for an array list, that is deeper than it can be; `invalidEnumTag`
    ///   or `endOfStream` for a block that cannot be read.
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
                let position = try slot.value.offset(by: nodeOffset)
                push(Level(position: position, block: try reader.indexBlock(at: position), index: 0))
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
