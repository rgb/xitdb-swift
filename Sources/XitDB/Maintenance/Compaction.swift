// Compaction: a new database holding only what the source's latest moment
// reaches, with every object copied once however many slots point at it,
// cycles included. Zig's `compact` and `Compactor`.
//
// Zig's compactor recurses through the slots; the depth is the nesting of
// the data, which the file decides and nothing bounds. Here the walk is a
// loop over an explicit stack of frames, one for each block being copied,
// in the same depth-first order: the target block is reserved and the
// mapping recorded when the block is first reached, before its children
// are visited, and the block is written when they are all done. The
// target's bytes depend on that order, so every rule of Zig's walk is
// kept.

extension Database {
    /// Compacts this database into `target`.
    ///
    /// The target gets what the latest moment reaches and nothing else, in
    /// one ordinary transaction, with its header, trailer and commit ID.
    /// A root that is an array list is a history, and only its last
    /// element survives, as the sole element of a new list. A list at the
    /// root whose last element is empty, because the list has no elements
    /// or its last element was appended and never written, is refused,
    /// whether or not the list is a history: compacting it would keep
    /// nothing of the list, which is what the original does. A last
    /// element set to nothing is a moment, and compacts. An empty root
    /// commits nothing. Any other root, one set to nothing included, is
    /// copied whole.
    ///
    /// The target must be a database whose root is empty, opened by the
    /// caller, with the same hash size as this one: a new one, or an
    /// existing one that was never written to, which keeps its own file ID
    /// and hash ID. To have the target opened for you, with this database's
    /// hash ID unless another is given, see
    /// ``compact(into:hashID:fileID:offsetMap:)``.
    ///
    /// - Parameters:
    ///   - target: The database to write into.
    ///   - offsetMap: Where the copy remembers what went where. It is reset
    ///     first, and holds every mapping when the call returns.
    /// - Throws: ``XitDBError/emptyLastMoment`` if the root is a list
    ///   whose last element is empty, which is checked before
    ///   anything else, so that the target and the offset map are as they
    ///   were; ``XitDBError/targetNotEmpty`` if the target's root holds
    ///   anything, this database itself included, in which case the target
    ///   is left as it was; ``XitDBError/invalidHashSize`` if the target's
    ///   hash size differs from this database's; and for a damaged source,
    ///   ``XitDBError/invalidEnumTag`` for a slot with an unknown tag,
    ///   ``XitDBError/endOfStream`` for a byte record or a block that
    ///   reaches past the end, ``XitDBError/invalidBTreeNode`` or
    ///   ``XitDBError/invalidBTreeNodeKind`` for a tree node that is not one,
    ///   and ``XitDBError/unexpectedTag`` for an array list whose index does
    ///   not hold what its size says. A compaction that fails leaves the
    ///   target as a transaction that did not commit: nothing of it is
    ///   reachable, and what it wrote is discarded at once, as after any
    ///   transaction that fails; should the storage refuse to cut it off
    ///   then, the next transaction discards it. Errors of the two
    ///   storages and of the offset map are passed on.
    public func compact<Map: OffsetMap>(into target: Database, offsetMap: inout Map) throws(XitDBError) {
        let source = try compactionSource()
        try compact(source, into: target, offsetMap: &offsetMap)
    }

    /// Compacts this database into a new one over `storage`, and returns
    /// it: ``compact(into:offsetMap:)`` with the target opened here.
    ///
    /// An empty storage gets a new database with this one's hash size, the
    /// hash ID given or else this one's, and the file ID given or else a
    /// random one. A storage that holds a database already keeps that
    /// database's file ID and hash ID, and must have an empty root.
    ///
    /// The target draws from this database's source of randomness, as the
    /// original's target draws from its source's: its file ID, when none
    /// is given, and then the commit ID of the compaction's transaction,
    /// in that order, so that this database's next commit draws after
    /// them.
    ///
    /// - Parameters:
    ///   - storage: Where the target lives.
    ///   - hashID: The target's hash ID, for a new database.
    ///   - fileID: The target's file ID, for a new database.
    ///   - offsetMap: Where the copy remembers what went where. It is reset
    ///     before the target is opened.
    /// - Returns: The target, open for reading and writing.
    /// - Throws: What ``compact(into:offsetMap:)`` throws, and what opening a
    ///   database over `storage` throws. ``XitDBError/emptyLastMoment`` is
    ///   raised before the target is opened, so an empty storage stays
    ///   empty.
    public func compact<Map: OffsetMap>(
        into storage: any WritableStorage,
        hashID: HashID? = nil,
        fileID: UInt64? = nil,
        offsetMap: inout Map
    ) throws(XitDBError) -> Database {
        // the source is checked before the target is opened, because opening
        // writes a header into an empty storage, and a guard writes nothing
        let source = try compactionSource()

        // cached offsets only apply to this compaction's target, and Zig
        // resets the map before it opens the target
        try offsetMap.clear()
        let target = try Database(
            storage: storage, hashSize: header.hashSize, hashID: hashID ?? header.hashID, fileID: fileID,
            random: random)
        try compact(source, into: target, offsetMap: &offsetMap)
        return target
    }

    /// What a compaction copies from its source.
    private enum CompactionSource {
        /// An empty root: nothing is committed in the target.
        case nothing
        /// The last moment of a history, which becomes the only moment of a
        /// new one.
        case lastMoment(Slot)
        /// Any other root, copied whole.
        case root(Slot)
    }

    /// Reads what a compaction copies, and refuses a list at the root whose
    /// last element is empty (finding 28): Zig compacts such a list to an
    /// empty database, losing the list and every element before the empty
    /// one. It runs before anything is done to the target or the offset
    /// map, so that the refusal writes nothing.
    private func compactionSource() throws(XitDBError) -> CompactionSource {
        // an empty root compacts to a new database. a root explicitly set
        // to nothing isn't empty, so it is remapped.
        let root = try rootCursor.slot
        if root.isEmpty { return .nothing }
        guard root.tag == .arrayList else { return .root(root) }

        // an array list root is a history. the path gives nil for a list
        // with no elements and for a last element appended and never
        // written; a last element set to nothing is full, so it comes back.
        let last: InlineArray<1, PathPart> = [.arrayListGet(-1)]
        guard let lastMoment = try rootCursor.readPathSlot(last.span) else { throw .emptyLastMoment }
        return .lastMoment(lastMoment)
    }

    private func compact<Map: OffsetMap>(
        _ source: CompactionSource, into target: Database, offsetMap: inout Map
    ) throws(XitDBError) {
        // cached offsets only apply to this compaction's target
        try offsetMap.clear()
        guard target.header.hashSize == header.hashSize else { throw .invalidHashSize }

        // the target must be a new or empty database, because compaction
        // writes to it with ordinary transactions. this also rejects
        // compacting a database into its own file.
        guard try target.rootCursor.slot.isEmpty else { throw .targetNotEmpty }

        // the target is written as one ordinary transaction, so it is
        // committed and synced like any other. the remap must run inside
        // the transaction, because starting one truncates the target.
        switch source {
        case .nothing:
            return
        case .lastMoment(let lastMoment):
            // the latest moment of a history becomes the only moment of a
            // new one
            var compactor = Compactor(source: self, target: target)
            let path: InlineArray<3, PathPart> = [.arrayListInit, .arrayListAppend, .ctx]
            _ = try target.rootCursor.writePath(path.span) { (cursor) throws(XitDBError) in
                try cursor.write(.slot(try compactor.remap(lastMoment, offsetMap: &offsetMap)))
            }
        case .root(let root):
            // any other root is remapped whole
            var compactor = Compactor(source: self, target: target)
            let path: InlineArray<1, PathPart> = [.ctx]
            _ = try target.rootCursor.writePath(path.span) { (cursor) throws(XitDBError) in
                try cursor.write(.slot(try compactor.remap(root, offsetMap: &offsetMap)))
            }
        }
    }
}

/// The walk that copies what a slot reaches from the source to the target:
/// Zig's `Compactor`, with its recursion as a stack of frames.
struct Compactor {
    private let source: DatabaseReader
    private let target: any WritableStorage
    /// A branch's worth of zeros, what a reserve writes.
    private let zeros = InlineArray<418, UInt8>(repeating: 0)

    init(source: Database, target: Database) {
        self.source = source.reader
        self.target = target.storage
    }

    /// What a frame waits for from the child it is at: a slot copied through
    /// Zig's `remapSlot`, a tree node, or a block of an array list's index.
    /// Each ends in a target offset.
    private enum Task {
        case slot(Slot)
        case bTreeNode(UInt64)
        case sortedNode(UInt64)
        case arrayListIndex(UInt64, size: UInt64, shift: UInt8)
    }

    /// A block being copied: its bytes as they were read from the source,
    /// with each slot replaced in place by its copy as the task for it ends,
    /// so that the block is written from them as it is, prefix, header and
    /// counts included; where it goes; and which slot is next.
    private struct Frame {
        enum Kind {
            /// Sixteen slots after `prefix` bytes kept as they are: an index
            /// block, a hash map or set, with its count before the block if
            /// it keeps one, or a tree leaf after its header.
            case slots(prefix: Int)
            /// A linked array list's branch: its header, sixteen children, of
            /// which only nodes are remapped, and the counts as they are.
            case bTreeBranch
            /// A sorted map's branch: the children as for a linked array
            /// list, then sixteen separators, each remapped, then the counts.
            case sortedBranch
            /// A key-value pair: its hash as it is, then the key slot and the
            /// value slot.
            case kvPair(hashSize: Int)
            /// An array list's header: its index, then the header with the
            /// new pointer in place of the old.
            case arrayListHeader
            /// A linked array list's or sorted map's header: its root node,
            /// then the header with the new pointer.
            case treeHeader
            /// A partial block of an array list's index, copied without the
            /// memo: its first `count` children, each a block of `childSize`
            /// elements but the last, which holds the rest; the slots after
            /// them are left empty.
            case arrayListPartial(size: UInt64, childSize: UInt64, shift: UInt8)
        }

        let kind: Kind
        let targetOffset: UInt64
        /// The block's bytes, a branch's worth at most.
        var bytes = InlineArray<418, UInt8>(repeating: 0)
        /// How many slots the block has to deal with.
        let count: Int
        /// The next slot to deal with.
        var next = 0
        /// A task found and not yet begun: a header's one task, or the
        /// first slot of a block that needs a visit.
        var task: Task?

        init(kind: Kind, targetOffset: UInt64, count: Int, task: Task? = nil) {
            self.kind = kind
            self.targetOffset = targetOffset
            self.count = count
            self.task = task
        }

        /// How many bytes the block takes.
        var byteCount: Int {
            switch kind {
            case .slots(let prefix): prefix + 144
            case .bTreeBranch: 274
            case .sortedBranch: 418
            case .kvPair(let hashSize): hashSize + 18
            case .arrayListHeader, .treeHeader: 16
            case .arrayListPartial: 144
            }
        }

        /// Where the slot at `index` is in the bytes.
        func slotOffset(_ index: Int) -> Int {
            switch kind {
            case .slots(let prefix): prefix + 9 * index
            case .bTreeBranch: 2 + 9 * index
            case .sortedBranch: index < 16 ? 2 + 9 * index : 146 + 9 * (index - 16)
            case .kvPair(let hashSize): hashSize + 9 * index
            case .arrayListHeader, .treeHeader: 8
            case .arrayListPartial: 9 * index
            }
        }

        /// The slot at `index`, whose tag `checkedSlot` found to be one
        /// when the walk reached it.
        func slot(_ index: Int) -> Slot {
            Slot.inNode(bytes.span, at: slotOffset(index))
        }

        /// The slot at `index` with its tag checked: Zig's `validate`, made
        /// as the walk reaches the slot, so that a child visited earlier
        /// reports its own damage first.
        ///
        /// - Throws: `invalidEnumTag` if the tag is not one.
        func checkedSlot(_ index: Int) throws(XitDBError) -> Slot {
            try Slot(decoding: bytes.span, at: slotOffset(index))
        }

        /// Records the target offset a task ended in: for a header, as its
        /// pointer; otherwise as the copy of the slot the task was for,
        /// with its tag and full flag. Moves on.
        mutating func deliver(_ offset: UInt64) {
            switch kind {
            case .arrayListHeader, .treeHeader:
                var span = bytes.mutableSpan
                span.storeBigEndian(offset, at: 8)
            default:
                let slot = slot(next)
                let position = slotOffset(next)
                var span = bytes.mutableSpan
                Slot(value: offset, tag: slot.tag, full: slot.full).encode(into: &span, at: position)
            }
            next += 1
        }
    }

    // MARK: Reading the source

    /// A frame over the block at `position`: its `byteCount` bytes, all of
    /// them (Zig's `readSliceAll`). A key-value pair's two slots are
    /// checked here, as Zig's `decodeKvPair` checks both before either is
    /// remapped; any other block's slots are checked one at a time as the
    /// walk reaches them, as Zig's populate functions check each before
    /// they remap it.
    ///
    /// - Throws: `endOfStream` if the source ends first, `invalidEnumTag`
    ///   for a pair whose key or value has a tag that is not one.
    private func readFrame(
        _ kind: Frame.Kind, at position: UInt64, targetOffset: UInt64, count: Int, task: Task? = nil
    ) throws(XitDBError) -> Frame {
        var frame = Frame(kind: kind, targetOffset: targetOffset, count: count, task: task)
        let storage = source.storage
        let wanted = frame.byteCount
        var span = frame.bytes.mutableSpan
        let read = try storage.read(into: &span, range: 0..<wanted, at: position)
        guard read == wanted else { throw .endOfStream }
        if case .kvPair = kind {
            for index in 0..<count {
                _ = try frame.checkedSlot(index)
            }
        }
        return frame
    }

    /// The two header bytes of a tree node, checked in Zig's order: its
    /// `remapBTreeNode` reads the kind, checks it, then reads the count,
    /// so a node whose kind is the last byte of the source reports the
    /// kind before the end.
    private func nodeKind(at position: UInt64) throws(XitDBError) -> BTreeNodeKind {
        var buffer = InlineArray<2, UInt8>(repeating: 0)
        var span = buffer.mutableSpan
        let read = try source.storage.read(into: &span, at: position)
        return try TreeNodeHeader.decode(buffer.span.extracting(0..<read)).kind
    }

    // MARK: Writing the target

    /// Appends `count` zero bytes to the target and returns where they
    /// start: Zig's `reserveBlock`.
    private func reserve(_ count: Int) throws(XitDBError) -> UInt64 {
        let offset = try target.length
        try target.write(zeros.span.extracting(0..<count), at: offset)
        return offset
    }

    /// Writes a frame's block, its slots all copied, at its target offset.
    private func finish(_ frame: Frame) throws(XitDBError) {
        try target.write(frame.bytes.span.extracting(0..<frame.byteCount), at: frame.targetOffset)
    }

    // MARK: The walk

    /// The slot that points at the copy of what `slot` points at: Zig's
    /// `remapSlot`, for the root of a walk.
    mutating func remap<Map: OffsetMap>(_ slot: Slot, offsetMap: inout Map) throws(XitDBError) -> Slot {
        var stack: [Frame] = []
        // The target offset the task just finished ended in, for the frame
        // on top of the stack, or for the caller when there is none.
        var result = try begin(.slot(slot), stack: &stack, offsetMap: &offsetMap)
        while true {
            if let offset = result {
                guard let top = stack.indices.last else {
                    return Slot(value: offset, tag: slot.tag, full: slot.full)
                }
                stack[top].deliver(offset)
                result = nil
            }
            // The frame on top: its next task, or its end.
            let top = stack.count - 1
            if let task = try advance(&stack[top], offsetMap: &offsetMap) {
                result = try begin(task, stack: &stack, offsetMap: &offsetMap)
            } else {
                let frame = stack.removeLast()
                try finish(frame)
                result = frame.targetOffset
            }
        }
    }

    /// Whether a slot's copy is the slot itself or a byte record copied at
    /// once, with no block to visit.
    private static func isImmediate(_ tag: Slot.Tag) -> Bool {
        switch tag {
        case .none, .uint, .int, .float, .shortBytes, .bytes: true
        default: false
        }
    }

    /// Deals with the frame's slots in order until one needs a visit, and
    /// returns the task for it, or `nil` when the block is done. A scalar
    /// slot stays as it is, a byte record is copied at once (Zig's
    /// `remapSlot` for the tags that need no `visitObject`), a child of a
    /// branch that is not a node stays as it is.
    private mutating func advance<Map: OffsetMap>(_ frame: inout Frame, offsetMap: inout Map) throws(XitDBError)
        -> Task?
    {
        if let task = frame.task {
            frame.task = nil
            return task
        }
        while frame.next < frame.count {
            let slot = try frame.checkedSlot(frame.next)
            switch frame.kind {
            case .slots, .kvPair:
                if !Self.isImmediate(slot.tag) { return .slot(slot) }
            case .bTreeBranch:
                if slot.tag == .index { return .bTreeNode(slot.value) }
            case .sortedBranch:
                if frame.next < 16 {
                    if slot.tag == .index { return .sortedNode(slot.value) }
                } else if !Self.isImmediate(slot.tag) {
                    return .slot(slot)
                }
            case .arrayListPartial(let size, let childSize, let shift):
                if shift > 0 {
                    guard slot.tag == .index else { throw .unexpectedTag }
                    let count = min(size - UInt64(frame.next) * childSize, childSize)
                    return .arrayListIndex(slot.value, size: count, shift: shift - 1)
                }
                if !Self.isImmediate(slot.tag) { return .slot(slot) }
            case .arrayListHeader, .treeHeader:
                return nil
            }
            // the slot's copy is itself, or its record copied now
            if slot.tag == .bytes {
                frame.deliver(try remapBytes(slot, offsetMap: &offsetMap))
            } else {
                frame.next += 1
            }
        }
        return nil
    }

    /// Takes a frame that was just read: begins its slots, and if none
    /// needs a visit, writes the block and gives its offset; otherwise
    /// keeps the first task found and pushes the frame.
    private mutating func settle<Map: OffsetMap>(
        _ frame: Frame, stack: inout [Frame], offsetMap: inout Map
    ) throws(XitDBError) -> UInt64? {
        var frame = frame
        if let task = try advance(&frame, offsetMap: &offsetMap) {
            frame.task = task
            stack.append(frame)
            return nil
        }
        try finish(frame)
        return frame.targetOffset
    }

    /// Begins a task. A scalar slot and an object copied already end at
    /// once, and so does a byte record, which is copied here; anything else
    /// reserves its block, records the mapping, reads the block, and either
    /// finishes it at once or pushes a frame for the children it has to
    /// visit: Zig's `visitObject`.
    ///
    /// - Returns: The target offset, or `nil` if a frame was pushed.
    private mutating func begin<Map: OffsetMap>(
        _ task: Task, stack: inout [Frame], offsetMap: inout Map
    ) throws(XitDBError) -> UInt64? {
        switch task {
        case .slot(let slot):
            switch slot.tag {
            case .none, .uint, .int, .float, .shortBytes:
                return slot.value
            case .bytes:
                return try remapBytes(slot, offsetMap: &offsetMap)
            case .index, .hashMap, .hashSet:
                if let offset = try offsetMap.lookup(slot.value) { return offset }
                let offset = try reserve(144)
                try offsetMap.record(slot.value, offset)
                let frame = try readFrame(.slots(prefix: 0), at: slot.value, targetOffset: offset, count: 16)
                return try settle(frame, stack: &stack, offsetMap: &offsetMap)
            case .countedHashMap, .countedHashSet:
                if let offset = try offsetMap.lookup(slot.value) { return offset }
                let offset = try reserve(152)
                try offsetMap.record(slot.value, offset)
                let frame = try readFrame(.slots(prefix: 8), at: slot.value, targetOffset: offset, count: 16)
                return try settle(frame, stack: &stack, offsetMap: &offsetMap)
            case .arrayList:
                if let offset = try offsetMap.lookup(slot.value) { return offset }
                let offset = try reserve(16)
                try offsetMap.record(slot.value, offset)
                let header = try source.arrayListHeader(at: slot.value)
                let shift = header.size <= Trie.slotsPerBlock ? 0 : Trie.arrayListShift(lastIndex: header.size - 1)
                let frame = try readFrame(
                    .arrayListHeader, at: slot.value, targetOffset: offset, count: 0,
                    task: .arrayListIndex(header.ptr, size: header.size, shift: shift))
                stack.append(frame)
                return nil
            case .linkedArrayList:
                if let offset = try offsetMap.lookup(slot.value) { return offset }
                let offset = try reserve(16)
                try offsetMap.record(slot.value, offset)
                let header = try source.bTreeHeader(at: slot.value)
                let frame = try readFrame(
                    .treeHeader, at: slot.value, targetOffset: offset, count: 0, task: .bTreeNode(header.rootPtr))
                stack.append(frame)
                return nil
            case .sortedMap, .sortedSet:
                if let offset = try offsetMap.lookup(slot.value) { return offset }
                let offset = try reserve(16)
                try offsetMap.record(slot.value, offset)
                let header = try source.bTreeHeader(at: slot.value)
                let frame = try readFrame(
                    .treeHeader, at: slot.value, targetOffset: offset, count: 0, task: .sortedNode(header.rootPtr))
                stack.append(frame)
                return nil
            case .kvPair:
                if let offset = try offsetMap.lookup(slot.value) { return offset }
                let hashSize = Int(source.hashSize)
                let offset = try reserve(hashSize + 18)
                try offsetMap.record(slot.value, offset)
                let frame = try readFrame(.kvPair(hashSize: hashSize), at: slot.value, targetOffset: offset, count: 2)
                return try settle(frame, stack: &stack, offsetMap: &offsetMap)
            case .sortedKvPair:
                if let offset = try offsetMap.lookup(slot.value) { return offset }
                let offset = try reserve(18)
                try offsetMap.record(slot.value, offset)
                let frame = try readFrame(.kvPair(hashSize: 0), at: slot.value, targetOffset: offset, count: 2)
                return try settle(frame, stack: &stack, offsetMap: &offsetMap)
            }

        case .bTreeNode(let nodePtr):
            if let offset = try offsetMap.lookup(nodePtr) { return offset }
            // read the header first because the node kind determines its size
            switch try nodeKind(at: nodePtr) {
            case .leaf:
                let offset = try reserve(146)
                try offsetMap.record(nodePtr, offset)
                let frame = try readFrame(.slots(prefix: 2), at: nodePtr, targetOffset: offset, count: 16)
                return try settle(frame, stack: &stack, offsetMap: &offsetMap)
            case .branch:
                let offset = try reserve(274)
                try offsetMap.record(nodePtr, offset)
                let frame = try readFrame(.bTreeBranch, at: nodePtr, targetOffset: offset, count: 16)
                return try settle(frame, stack: &stack, offsetMap: &offsetMap)
            }

        case .sortedNode(let nodePtr):
            if let offset = try offsetMap.lookup(nodePtr) { return offset }
            switch try nodeKind(at: nodePtr) {
            case .leaf:
                let offset = try reserve(146)
                try offsetMap.record(nodePtr, offset)
                let frame = try readFrame(.slots(prefix: 2), at: nodePtr, targetOffset: offset, count: 16)
                return try settle(frame, stack: &stack, offsetMap: &offsetMap)
            case .branch:
                let offset = try reserve(418)
                try offsetMap.record(nodePtr, offset)
                let frame = try readFrame(.sortedBranch, at: nodePtr, targetOffset: offset, count: 32)
                return try settle(frame, stack: &stack, offsetMap: &offsetMap)
            }

        case .arrayListIndex(let blockPtr, let size, let shift):
            // full blocks can use the normal cache. partial blocks may be
            // shared by lists with different sizes, so copy them separately
            // and leave the slots beyond the size empty.
            let childSize: UInt64 = 1 << (UInt64(shift) * 4)
            let (full, overflow) = childSize.multipliedReportingOverflow(by: Trie.slotsPerBlock)
            if !overflow && size == full {
                return try begin(.slot(Slot(value: blockPtr, tag: .index)), stack: &stack, offsetMap: &offsetMap)
            }
            let offset = try reserve(144)
            // The children Zig reads: one while any of the size is left, so
            // a last child that is not full counts. Rounding up through a
            // sum overflowed for a size near the largest.
            let used = Int(min(size / childSize + (size % childSize == 0 ? 0 : 1), Trie.slotsPerBlock))
            // Zig reads the used children one by one and stops, so only
            // those are read, and each is checked as the walk reaches it;
            // the rest of the block stays empty.
            var frame = Frame(
                kind: .arrayListPartial(size: size, childSize: childSize, shift: shift), targetOffset: offset,
                count: used)
            if used > 0 {
                let storage = source.storage
                var span = frame.bytes.mutableSpan
                let read = try storage.read(into: &span, range: 0..<(used * 9), at: blockPtr)
                guard read == used * 9 else { throw .endOfStream }
            }
            return try settle(frame, stack: &stack, offsetMap: &offsetMap)
        }
    }

    /// Copies a byte record, length, bytes and format tag, in chunks, and
    /// memoises it afterwards: bytes contain no references, so there is no
    /// cycle to end first. Zig's `remapBytes`.
    ///
    /// - Throws: `endOfStream` if the record reaches past the end of the
    ///   source, before any of it is copied.
    private func remapBytes<Map: OffsetMap>(_ slot: Slot, offsetMap: inout Map) throws(XitDBError) -> UInt64 {
        if let offset = try offsetMap.lookup(slot.value) { return offset }
        let length = try source.uint64(at: slot.value)
        // total size: u64 length + bytes + optional 2-byte format_tag
        let payload = try length.offset(by: slot.full ? ByteArrayFormat.formatTagByteCount : 0)
        var remaining = try payload.offset(by: ByteArrayFormat.lengthByteCount)
        guard remaining <= (try source.storage.length) - slot.value else { throw .endOfStream }

        let newOffset = try target.length
        var position = slot.value
        var targetPosition = newOffset
        var buffer = InlineArray<4096, UInt8>(repeating: 0)
        while remaining > 0 {
            let chunk = Int(min(remaining, 4096))
            var span = buffer.mutableSpan
            let read = try source.storage.read(into: &span, range: 0..<chunk, at: position)
            guard read == chunk else { throw .endOfStream }
            try target.write(buffer.span.extracting(0..<chunk), at: targetPosition)
            position += UInt64(chunk)
            targetPosition += UInt64(chunk)
            remaining -= UInt64(chunk)
        }
        try offsetMap.record(slot.value, newOffset)
        return newOffset
    }
}
