// Going through the slots of a collection in order: the core of Zig's
// `Cursor.Iter`, on the read side of the engine.

/// Walks the elements of an array list, or the entries of a hash map or set,
/// one slot at a time.
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
/// The walks of linked array lists and sorted maps arrive with those
/// collections: they add a way to start, and a node header to skip when
/// entering a block.
struct SlotIterator {
    /// One block on the way down, and the slot in it that the walk is at.
    struct Level {
        var position: UInt64
        var block: IndexBlock
        var index: UInt8
    }

    private let reader: DatabaseReader
    private var stack: [Level] = []

    /// For an array list, the number of positions still to visit, which is
    /// what stops the walk at the list's size: the blocks may go on beyond
    /// it, with elements of a longer list that was cut down. `nil` for a
    /// hash map or set, whose walk ends when its blocks do.
    ///
    /// Zig counts the elements it gives out instead, so after passing over
    /// an element that was never written it gives out one past the end of
    /// a cut-down list (finding 26). Here the walk visits the positions from
    /// its start to the list's size and no further, as reading by index
    /// does.
    private var remaining: UInt64?

    /// The most blocks that can lie on the way from the root to a slot.
    private let maxDepth: Int

    /// What going deeper than `maxDepth` is reported as.
    private let depthError: XitDBError

    private init(reader: DatabaseReader, remaining: UInt64?, maxDepth: Int, depthError: XitDBError) {
        self.reader = reader
        self.remaining = remaining
        self.maxDepth = maxDepth
        self.depthError = depthError
    }

    /// A walk that gives out nothing.
    private init(reader: DatabaseReader) {
        self.init(reader: reader, remaining: 0, maxDepth: 0, depthError: .invalidDatabase)
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
                remaining: header.size,
                maxDepth: Self.arrayListDepth(size: header.size),
                depthError: .maxShiftExceeded
            )
            rootPosition = header.ptr
        case .hashMap, .hashSet:
            self.init(
                reader: reader, remaining: nil, maxDepth: Int(reader.hashSize) * 2, depthError: .keyOffsetExceeded)
            rootPosition = slot.value
        case .countedHashMap, .countedHashSet:
            self.init(
                reader: reader, remaining: nil, maxDepth: Int(reader.hashSize) * 2, depthError: .keyOffsetExceeded)
            rootPosition = try slot.value.offset(by: IndexBlock.countByteCount)
        case .linkedArrayList, .sortedMap, .sortedSet:
            throw .notImplemented
        default:
            throw .unexpectedTag
        }
        stack.reserveCapacity(min(maxDepth, 8))
        stack.append(Level(position: rootPosition, block: try reader.indexBlock(at: rootPosition), index: 0))
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
            remaining: header.size - key,
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
            stack.append(Level(position: position, block: block, index: UInt8(index)))
            if shift == 0 { break }
            // Every block above the last holds a pointer to the next one for
            // any element the list has.
            let child = block.slots[index]
            guard child.tag == .index else { throw .unexpectedTag }
            position = child.value
            shift -= 1
        }
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
    /// A slot that was never written is passed over. One that was set to
    /// nothing is given out: it is an element whose value is nothing.
    ///
    /// - Throws: `keyOffsetExceeded` for a hash trie, or `maxShiftExceeded`
    ///   for an array list, that is deeper than it can be; `invalidEnumTag`
    ///   or `endOfStream` for a block that cannot be read.
    mutating func next() throws(XitDBError) -> SlotPointer? {
        while !stack.isEmpty {
            let top = stack.count - 1
            let index = Int(stack[top].index)
            if index == Int(Trie.slotsPerBlock) {
                // This block is done: go on in the one above it.
                stack.removeLast()
                if top > 0 {
                    stack[top - 1].index += 1
                }
                continue
            }
            let slot = stack[top].block.slots[index]
            if slot.tag == .index {
                if stack.count >= maxDepth { throw depthError }
                stack.append(Level(position: slot.value, block: try reader.indexBlock(at: slot.value), index: 0))
                continue
            }
            // A slot that is not a block is an element, or an entry.
            if let left = remaining {
                if left == 0 { return nil }
                remaining = left - 1
            }
            stack[top].index += 1
            if !slot.isEmpty {
                let position = try stack[top].position.offset(by: Slot.byteCount * UInt64(index))
                return SlotPointer(position: position, slot: slot)
            }
        }
        return nil
    }
}
