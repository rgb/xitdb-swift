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
    /// Compacts this database into `target`: Zig's `compact`.
    ///
    /// The target gets what the latest moment reaches and nothing else, in
    /// one ordinary transaction, with its header, trailer and commit ID.
    /// A root that is an array list is a history, and only its last
    /// moment survives, as the sole element of a new list; a history with
    /// no last moment, or whose last moment was never written, commits
    /// nothing. An empty root commits nothing either. Any other root, one
    /// set to nothing included, is copied whole.
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
    /// - Throws: ``XitDBError/targetNotEmpty`` if the target's root holds
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
    ///   reachable, and the next transaction truncates it. Errors of the
    ///   two storages and of the offset map are passed on.
    public func compact<Map: OffsetMap>(into target: Database, offsetMap: inout Map) throws(XitDBError) {
        // cached offsets only apply to this compaction's target
        try offsetMap.reset()
        guard target.header.hashSize == header.hashSize else { throw .invalidHashSize }

        // the target must be a new or empty database, because compaction
        // writes to it with ordinary transactions. this also rejects
        // compacting a database into its own file.
        guard try target.rootCursor().slot().isEmpty else { throw .targetNotEmpty }

        // an empty root compacts to a new database. a root explicitly set
        // to nothing isn't empty, so it is remapped below.
        let sourceRoot = try rootCursor().slot()
        if sourceRoot.isEmpty { return }

        // the target is written as one ordinary transaction, so it is
        // committed and synced like any other. the remap must run inside
        // the transaction, because starting one truncates the target.
        var compactor = Compactor(source: self, target: target)
        switch sourceRoot.tag {
        case .arrayList:
            // an array list root is a history, and its latest moment
            // becomes the only moment of a new one
            let last: InlineArray<1, PathPart> = [.arrayListGet(-1)]
            if let lastMoment = try rootCursor().readPathSlot(last.span) {
                let path: InlineArray<3, PathPart> = [.arrayListInit, .arrayListAppend, .ctx]
                _ = try target.rootCursor().writePath(path.span) { (cursor) throws(XitDBError) in
                    try cursor.write(.slot(try compactor.remap(lastMoment, offsetMap: &offsetMap)))
                }
            }
        default:
            // any other root is remapped whole
            let path: InlineArray<1, PathPart> = [.ctx]
            _ = try target.rootCursor().writePath(path.span) { (cursor) throws(XitDBError) in
                try cursor.write(.slot(try compactor.remap(sourceRoot, offsetMap: &offsetMap)))
            }
        }
    }

    /// Compacts this database into a new one over `storage`, and returns
    /// it: ``compact(into:offsetMap:)`` with the target opened here.
    ///
    /// An empty storage gets a new database with this one's hash size, the
    /// hash ID given or else this one's, and the file ID given or else a
    /// random one. A storage that holds a database already keeps that
    /// database's file ID and hash ID, and must have an empty root.
    ///
    /// - Parameters:
    ///   - storage: Where the target lives.
    ///   - hashID: The target's hash ID, for a new database.
    ///   - fileID: The target's file ID, for a new database.
    ///   - offsetMap: Where the copy remembers what went where.
    /// - Returns: The target, open for reading and writing.
    /// - Throws: What ``compact(into:offsetMap:)`` throws, and what opening a
    ///   database over `storage` throws.
    public func compact<Map: OffsetMap>(
        into storage: any WritableStorage,
        hashID: HashID? = nil,
        fileID: UInt64? = nil,
        offsetMap: inout Map
    ) throws(XitDBError) -> Database {
        let target = try Database(
            storage: storage, hashSize: header.hashSize, hashID: hashID ?? header.hashID, fileID: fileID)
        try compact(into: target, offsetMap: &offsetMap)
        return target
    }
}

/// The walk that copies what a slot reaches from the source to the target:
/// Zig's `Compactor`, with its recursion as a stack of frames.
struct Compactor {
    private let source: DatabaseReader
    private let target: any WritableStorage

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

    /// A block being copied: what it is, where it goes, the slots it holds
    /// in the source, the slots copied so far, and which is next.
    private struct Frame {
        enum Kind {
            /// Sixteen slots, each remapped, after a prefix written as it
            /// is: an index block, a hash map or set, with its count before
            /// the block if it keeps one, or a tree leaf after its header.
            case slots(prefix: [UInt8])
            /// A linked array list's branch: sixteen children, of which only
            /// nodes are remapped, then the counts as they are.
            case bTreeBranch(header: [UInt8], counts: [UInt8])
            /// A sorted map's branch: the children as for a linked array
            /// list, then sixteen separators, each remapped, then the counts.
            case sortedBranch(header: [UInt8], counts: [UInt8])
            /// A key-value pair: the key slot, then the value slot, written
            /// in the same form, with the hash it had.
            case kvPair(tag: Tag, hash: KeyHash)
            /// An array list's header: its index, then the header with the
            /// new pointer.
            case arrayListHeader(size: UInt64)
            /// A linked array list's or sorted map's header: its root node,
            /// then the header with the new pointer.
            case treeHeader(size: UInt64)
            /// A partial block of an array list's index, copied without the
            /// memo: its first `used` children, each a block of `childSize`
            /// elements but the last, which holds the rest; the slots after
            /// them are left empty.
            case arrayListPartial(size: UInt64, childSize: UInt64, shift: UInt8, used: Int)
        }

        var kind: Kind
        let targetOffset: UInt64
        /// The slots of the source block, up to thirty-two: a sorted
        /// branch's children and separators.
        var slots: InlineArray<32, Slot> = InlineArray(repeating: Slot())
        /// The copied slots, filled in as the tasks end.
        var remapped: InlineArray<32, Slot> = InlineArray(repeating: Slot())
        /// How many of `slots` are used.
        let count: Int
        /// The next slot to deal with.
        var next = 0
        /// The one task of a header frame, which has no slots; taken once.
        var task: Task?

        init(kind: Kind, targetOffset: UInt64, count: Int, task: Task? = nil) {
            self.kind = kind
            self.targetOffset = targetOffset
            self.count = count
            self.task = task
        }

        /// Records the target offset a task ended in, as the copy of the
        /// slot it was for, and moves on. A header frame's one task has no
        /// slot; its offset lands in the first place.
        mutating func deliver(_ offset: UInt64) {
            let slot = slots[next]
            remapped[next] = Slot(value: offset, tag: slot.tag, full: slot.full)
            next += 1
        }
    }

    // MARK: Reading the source

    /// Reads `count` bytes at `position` into the start of a buffer, all of
    /// them: Zig's `readSliceAll`.
    ///
    /// - Throws: `endOfStream` if the source ends first.
    private func read(
        _ buffer: inout InlineArray<418, UInt8>, count: Int, at position: UInt64
    ) throws(XitDBError) {
        var span = buffer.mutableSpan
        let read = try source.storage.read(into: &span, range: 0..<count, at: position)
        guard read == count else { throw .endOfStream }
    }

    /// `count` slots at `position`, each checked as Zig checks it on
    /// reading, into a frame's slots from `index` on.
    private func readSlots(
        _ count: Int, at position: UInt64, into frame: inout Frame, from index: Int
    ) throws(XitDBError) {
        var buffer = InlineArray<418, UInt8>(repeating: 0)
        try read(&buffer, count: count * 9, at: position)
        for slot in 0..<count {
            frame.slots[index + slot] = try Slot(decoding: buffer.span, at: slot * 9)
        }
    }

    /// The raw counts of a branch, copied as they are.
    private func readCounts(at position: UInt64) throws(XitDBError) -> [UInt8] {
        var buffer = InlineArray<418, UInt8>(repeating: 0)
        try read(&buffer, count: 128, at: position)
        return (0..<128).map { buffer[$0] }
    }

    /// The two header bytes of a tree node, checked: Zig's `remapBTreeNode`
    /// reads them before it visits the node.
    private func nodeHeader(at position: UInt64) throws(XitDBError) -> (kind: BTreeNodeKind, bytes: [UInt8]) {
        var buffer = InlineArray<418, UInt8>(repeating: 0)
        try read(&buffer, count: 2, at: position)
        let header = try TreeNodeHeader.decode(buffer.span.extracting(0..<2))
        return (header.kind, [buffer[0], buffer[1]])
    }

    // MARK: Writing the target

    /// Appends `count` zero bytes to the target and returns where they
    /// start: Zig's `reserveBlock`.
    private func reserve(_ count: Int) throws(XitDBError) -> UInt64 {
        let offset = try target.length()
        let zeros = [UInt8](repeating: 0, count: count)
        try target.write(zeros.span, at: offset)
        return offset
    }

    /// Writes a block at its target offset: `prefix`, then the slots from
    /// `from` up to `to` of `slots`, then `suffix`.
    private func writeBlock(
        prefix: [UInt8], _ slots: InlineArray<32, Slot>, from: Int, to: Int, suffix: [UInt8], at position: UInt64
    ) throws(XitDBError) {
        var block = [UInt8](repeating: 0, count: prefix.count + (to - from) * 9 + suffix.count)
        var bytes = block.mutableSpan
        for index in prefix.indices {
            bytes[index] = prefix[index]
        }
        for index in from..<to {
            slots[index].encode(into: &bytes, at: prefix.count + (index - from) * 9)
        }
        for index in suffix.indices {
            bytes[prefix.count + (to - from) * 9 + index] = suffix[index]
        }
        try target.write(block.span, at: position)
    }

    // MARK: The walk

    /// The slot that points at the copy of what `slot` points at: Zig's
    /// `remapSlot`, for the root of a walk.
    mutating func remap<Map: OffsetMap>(_ slot: Slot, offsetMap: inout Map) throws(XitDBError) -> Slot {
        var stack: [Frame] = []
        // The target offset the task just finished ended in, for the frame
        // on top of the stack, or for the caller when there is none.
        var result = try start(.slot(slot), stack: &stack, offsetMap: &offsetMap)
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
            if let task = try nextTask(of: &stack[top]) {
                result = try start(task, stack: &stack, offsetMap: &offsetMap)
            } else {
                let frame = stack.removeLast()
                try finish(frame)
                result = frame.targetOffset
            }
        }
    }

    /// Begins a task. A scalar slot and an object copied already end at
    /// once, and so does a byte record, which is copied here; anything else
    /// reserves its block, records the mapping, and pushes a frame for its
    /// children: Zig's `visitObject`.
    ///
    /// - Returns: The target offset, or `nil` if a frame was pushed.
    private mutating func start<Map: OffsetMap>(
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
                if let offset = try offsetMap.get(slot.value) { return offset }
                let offset = try reserve(144)
                try offsetMap.put(slot.value, offset)
                var frame = Frame(kind: .slots(prefix: []), targetOffset: offset, count: 16)
                try readSlots(16, at: slot.value, into: &frame, from: 0)
                stack.append(frame)
            case .countedHashMap, .countedHashSet:
                if let offset = try offsetMap.get(slot.value) { return offset }
                let offset = try reserve(152)
                try offsetMap.put(slot.value, offset)
                var buffer = InlineArray<418, UInt8>(repeating: 0)
                try read(&buffer, count: 8, at: slot.value)
                var frame = Frame(kind: .slots(prefix: (0..<8).map { buffer[$0] }), targetOffset: offset, count: 16)
                try readSlots(16, at: try slot.value.offset(by: 8), into: &frame, from: 0)
                stack.append(frame)
            case .arrayList:
                if let offset = try offsetMap.get(slot.value) { return offset }
                let offset = try reserve(16)
                try offsetMap.put(slot.value, offset)
                let header = try source.arrayListHeader(at: slot.value)
                let shift = header.size <= Trie.slotsPerBlock ? 0 : Trie.arrayListShift(lastIndex: header.size - 1)
                stack.append(
                    Frame(
                        kind: .arrayListHeader(size: header.size), targetOffset: offset, count: 0,
                        task: .arrayListIndex(header.ptr, size: header.size, shift: shift)))
            case .linkedArrayList:
                if let offset = try offsetMap.get(slot.value) { return offset }
                let offset = try reserve(16)
                try offsetMap.put(slot.value, offset)
                let header = try source.bTreeHeader(at: slot.value)
                stack.append(
                    Frame(
                        kind: .treeHeader(size: header.size), targetOffset: offset, count: 0,
                        task: .bTreeNode(header.rootPtr)))
            case .sortedMap, .sortedSet:
                if let offset = try offsetMap.get(slot.value) { return offset }
                let offset = try reserve(16)
                try offsetMap.put(slot.value, offset)
                let header = try source.bTreeHeader(at: slot.value)
                stack.append(
                    Frame(
                        kind: .treeHeader(size: header.size), targetOffset: offset, count: 0,
                        task: .sortedNode(header.rootPtr)))
            case .kvPair:
                if let offset = try offsetMap.get(slot.value) { return offset }
                let offset = try reserve(Int(source.hashSize) + 18)
                try offsetMap.put(slot.value, offset)
                let hashed = try source.hashedPair(at: slot.value)
                var frame = Frame(kind: .kvPair(tag: .kvPair, hash: hashed.hash), targetOffset: offset, count: 2)
                frame.slots[0] = hashed.pair.keySlot
                frame.slots[1] = hashed.pair.valueSlot
                stack.append(frame)
            case .sortedKvPair:
                if let offset = try offsetMap.get(slot.value) { return offset }
                let offset = try reserve(18)
                try offsetMap.put(slot.value, offset)
                let pair = try source.sortedPair(at: slot.value)
                var frame = Frame(
                    kind: .kvPair(tag: .sortedKvPair, hash: KeyHash(zeros: 0)), targetOffset: offset, count: 2)
                frame.slots[0] = pair.keySlot
                frame.slots[1] = pair.valueSlot
                stack.append(frame)
            }
            return nil

        case .bTreeNode(let nodePtr):
            if let offset = try offsetMap.get(nodePtr) { return offset }
            // read the header first because the node kind determines its size
            let header = try nodeHeader(at: nodePtr)
            let body = try nodePtr.offset(by: 2)
            switch header.kind {
            case .leaf:
                let offset = try reserve(146)
                try offsetMap.put(nodePtr, offset)
                var frame = Frame(kind: .slots(prefix: header.bytes), targetOffset: offset, count: 16)
                try readSlots(16, at: body, into: &frame, from: 0)
                stack.append(frame)
            case .branch:
                let offset = try reserve(274)
                try offsetMap.put(nodePtr, offset)
                var frame = Frame(kind: .bTreeBranch(header: header.bytes, counts: []), targetOffset: offset, count: 16)
                try readSlots(16, at: body, into: &frame, from: 0)
                frame.kind = .bTreeBranch(header: header.bytes, counts: try readCounts(at: try nodePtr.offset(by: 146)))
                stack.append(frame)
            }
            return nil

        case .sortedNode(let nodePtr):
            if let offset = try offsetMap.get(nodePtr) { return offset }
            let header = try nodeHeader(at: nodePtr)
            let body = try nodePtr.offset(by: 2)
            switch header.kind {
            case .leaf:
                let offset = try reserve(146)
                try offsetMap.put(nodePtr, offset)
                var frame = Frame(kind: .slots(prefix: header.bytes), targetOffset: offset, count: 16)
                try readSlots(16, at: body, into: &frame, from: 0)
                stack.append(frame)
            case .branch:
                let offset = try reserve(418)
                try offsetMap.put(nodePtr, offset)
                var frame = Frame(
                    kind: .sortedBranch(header: header.bytes, counts: []), targetOffset: offset, count: 32)
                try readSlots(16, at: body, into: &frame, from: 0)
                try readSlots(16, at: try nodePtr.offset(by: 146), into: &frame, from: 16)
                frame.kind = .sortedBranch(
                    header: header.bytes, counts: try readCounts(at: try nodePtr.offset(by: 290)))
                stack.append(frame)
            }
            return nil

        case .arrayListIndex(let blockPtr, let size, let shift):
            // full blocks can use the normal cache. partial blocks may be
            // shared by lists with different sizes, so copy them separately
            // and leave the slots beyond the size empty.
            let childSize: UInt64 = 1 << (UInt64(shift) * 4)
            let (full, overflow) = childSize.multipliedReportingOverflow(by: Trie.slotsPerBlock)
            if !overflow && size == full {
                return try start(.slot(Slot(value: blockPtr, tag: .index)), stack: &stack, offsetMap: &offsetMap)
            }
            let offset = try reserve(144)
            let used = Int(min((size + childSize - 1) / childSize, Trie.slotsPerBlock))
            var frame = Frame(
                kind: .arrayListPartial(size: size, childSize: childSize, shift: shift, used: used),
                targetOffset: offset, count: used)
            if used > 0 {
                try readSlots(used, at: blockPtr, into: &frame, from: 0)
            }
            stack.append(frame)
            return nil
        }
    }

    /// Copies a byte record, length, bytes and format tag, in chunks, and
    /// memoises it afterwards: bytes contain no references, so there is no
    /// cycle to end first. Zig's `remapBytes`.
    ///
    /// - Throws: `endOfStream` if the record reaches past the end of the
    ///   source, before any of it is copied.
    private func remapBytes<Map: OffsetMap>(_ slot: Slot, offsetMap: inout Map) throws(XitDBError) -> UInt64 {
        if let offset = try offsetMap.get(slot.value) { return offset }
        let length = try source.uint64(at: slot.value)
        // total size: u64 length + bytes + optional 2-byte format_tag
        let payload = try length.offset(by: slot.full ? ByteArrayFormat.formatTagByteCount : 0)
        var remaining = try payload.offset(by: ByteArrayFormat.lengthByteCount)
        guard remaining <= (try source.storage.length()) - slot.value else { throw .endOfStream }

        let newOffset = try target.length()
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
        try offsetMap.put(slot.value, newOffset)
        return newOffset
    }

    /// The next task of a frame, or `nil` when its slots are all dealt
    /// with. A slot that needs no copy is passed through here.
    private func nextTask(of frame: inout Frame) throws(XitDBError) -> Task? {
        if let task = frame.task {
            frame.task = nil
            return task
        }
        while frame.next < frame.count {
            let slot = frame.slots[frame.next]
            switch frame.kind {
            case .slots, .kvPair:
                return .slot(slot)
            case .bTreeBranch:
                guard slot.tag == .index else { break }
                return .bTreeNode(slot.value)
            case .sortedBranch:
                if frame.next >= 16 { return .slot(slot) }
                guard slot.tag == .index else { break }
                return .sortedNode(slot.value)
            case .arrayListPartial(let size, let childSize, let shift, _):
                if shift == 0 { return .slot(slot) }
                guard slot.tag == .index else { throw .unexpectedTag }
                let count = min(size - UInt64(frame.next) * childSize, childSize)
                return .arrayListIndex(slot.value, size: count, shift: shift - 1)
            case .arrayListHeader, .treeHeader:
                return nil
            }
            // a child that is not a node stays as it is
            frame.remapped[frame.next] = slot
            frame.next += 1
        }
        return nil
    }

    /// Writes a frame's block, all its children copied.
    private func finish(_ frame: Frame) throws(XitDBError) {
        switch frame.kind {
        case .slots(let prefix):
            try writeBlock(prefix: prefix, frame.remapped, from: 0, to: 16, suffix: [], at: frame.targetOffset)
        case .bTreeBranch(let header, let counts):
            try writeBlock(prefix: header, frame.remapped, from: 0, to: 16, suffix: counts, at: frame.targetOffset)
        case .sortedBranch(let header, let counts):
            try writeBlock(prefix: header, frame.remapped, from: 0, to: 32, suffix: counts, at: frame.targetOffset)
        case .kvPair(let tag, let hash):
            let pair = KeyValuePair(keySlot: frame.remapped[0], valueSlot: frame.remapped[1])
            var bytes: [UInt8] = []
            if tag == .kvPair {
                bytes = [UInt8](repeating: 0, count: Int(source.hashSize) + 18)
                var span = bytes.mutableSpan
                hash.copyBytes(into: &span)
                pair.keySlot.encode(into: &span, at: Int(source.hashSize))
                pair.valueSlot.encode(into: &span, at: Int(source.hashSize) + 9)
            } else {
                bytes = [UInt8](repeating: 0, count: 18)
                var span = bytes.mutableSpan
                pair.keySlot.encode(into: &span, at: 0)
                pair.valueSlot.encode(into: &span, at: 9)
            }
            try target.write(bytes.span, at: frame.targetOffset)
        case .arrayListHeader(let size):
            let header = ArrayListHeader(size: size, ptr: frame.remapped[0].value)
            let bytes = InlineArray<16, UInt8> { (output: inout OutputSpan<UInt8>) in header.encode(into: &output) }
            try target.write(bytes.span, at: frame.targetOffset)
        case .treeHeader(let size):
            let header = BTreeHeader(size: size, rootPtr: frame.remapped[0].value)
            let bytes = InlineArray<16, UInt8> { (output: inout OutputSpan<UInt8>) in header.encode(into: &output) }
            try target.write(bytes.span, at: frame.targetOffset)
        case .arrayListPartial:
            try writeBlock(prefix: [], frame.remapped, from: 0, to: 16, suffix: [], at: frame.targetOffset)
        }
    }
}
