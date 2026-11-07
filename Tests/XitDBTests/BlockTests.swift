import Testing

@testable import XitDB

/// tag index (1), pointing at `offset`
private func indexSlot(_ offset: UInt8) -> [UInt8] {
    [0x01, 0, 0, 0, 0, 0, 0, 0, offset]
}

/// tag uint (8), holding `value`
private func uintSlot(_ value: UInt8) -> [UInt8] {
    [0x08, 0, 0, 0, 0, 0, 0, 0, value]
}

/// A subtree count.
private func count(_ value: UInt8) -> [UInt8] {
    [0, 0, 0, 0, 0, 0, 0, value]
}

@Suite struct IndexBlockTests {
    @Test func sizeOnDisk() {
        #expect(IndexBlock.byteCount == 144)
        #expect(IndexBlock.countByteCount == 8)
    }

    @Test func anEmptyBlockIsAllZeros() throws {
        #expect(encoded(capacity: 144) { IndexBlock().encode(into: &$0) } == zeros(144))
        let block = try IndexBlock(decoding: zeros(144).span)
        #expect(array(block.slots).allSatisfy { $0.isEmpty })
    }

    @Test func decodesAndEncodesHandWrittenBytes() throws {
        // slot 0: index at 0x25; slots 1 to 14 empty; slot 15: kv_pair at 0x1234
        let bytes = indexSlot(0x25) + zeros(9 * 14) + [0x05, 0, 0, 0, 0, 0, 0, 0x12, 0x34]
        #expect(bytes.count == 144)
        let block = try IndexBlock(decoding: bytes.span)
        #expect(block.slots[0] == Slot(value: 0x25, tag: .index))
        #expect(block.slots[15] == Slot(value: 0x1234, tag: .kvPair))
        #expect(array(block.slots)[1...14].allSatisfy { $0.isEmpty })
        #expect(encoded(capacity: 144) { block.encode(into: &$0) } == bytes)
    }

    @Test func roundTripsAtAnOffset() throws {
        var block = IndexBlock()
        for index in block.slots.indices {
            block.slots[index] = Slot(value: UInt64(index) * 1000 + 1, tag: .index, full: index % 2 == 1)
        }
        let bytes = [0xEE, 0xEE, 0xEE] + encoded(capacity: 144) { block.encode(into: &$0) }
        let decoded = try IndexBlock(decoding: bytes.span, at: 3)
        #expect(array(decoded.slots) == array(block.slots))
    }

    @Test func rejectsBadInput() {
        let short = zeros(143)
        #expect(throws: XitDBError.endOfStream) { try IndexBlock(decoding: short.span) }

        var badTag = zeros(144)
        badTag[9 * 3] = 0x7F
        #expect(throws: XitDBError.invalidEnumTag) { try IndexBlock(decoding: badTag.span) }
    }
}

@Suite struct BTreeNodeTests {
    @Test func sizesOnDisk() {
        #expect(TreeNodeHeader.byteCount == 2)
        #expect(BTreeNode.leafByteCount == 146)
        #expect(BTreeNode.branchByteCount == 274)
        #expect(BTreeNode(kind: .leaf, num: 0).byteCount == 146)
        #expect(BTreeNode(kind: .branch, num: 0).byteCount == 274)
    }

    @Test func leafDecodesAndEncodesHandWrittenBytes() throws {
        // kind leaf (0), two entries: uint 7 and uint 9
        let bytes: [UInt8] = [0x00, 0x02] + uintSlot(7) + uintSlot(9) + zeros(9 * 14)
        #expect(bytes.count == 146)
        let node = try BTreeNode(decoding: bytes.span)
        #expect(node.kind == .leaf)
        #expect(node.num == 2)
        #expect(node.values[0] == Slot(value: 7, tag: .uint))
        #expect(node.values[1] == Slot(value: 9, tag: .uint))
        #expect(array(node.values)[2...].allSatisfy { $0.isEmpty })
        // a leaf's values and a branch's children are the same sixteen
        // slots of the bytes, read as one or the other
        #expect(array(node.children) == array(node.values))
        #expect(array(node.counts).allSatisfy { $0 == 0 })
        #expect(node.subtreeCount == 2)
        #expect(encoded(capacity: 146) { node.encode(into: &$0) } == bytes)
    }

    @Test func branchDecodesAndEncodesHandWrittenBytes() throws {
        // kind branch (1), two children at 100 and 200 holding 16 and 3 elements
        let children = indexSlot(100) + indexSlot(200) + zeros(9 * 14)
        let counts = count(16) + count(3) + zeros(8 * 14)
        let bytes: [UInt8] = [0x01, 0x02] + children + counts
        #expect(bytes.count == 274)
        let node = try BTreeNode(decoding: bytes.span)
        #expect(node.kind == .branch)
        #expect(node.num == 2)
        #expect(node.children[0] == Slot(value: 100, tag: .index))
        #expect(node.children[1] == Slot(value: 200, tag: .index))
        #expect(node.counts[0] == 16)
        #expect(node.counts[1] == 3)
        #expect(array(node.values) == array(node.children))
        #expect(node.subtreeCount == 19)
        #expect(encoded(capacity: 274) { node.encode(into: &$0) } == bytes)
    }

    @Test func subtreeCountUsesOnlyTheEntriesInUse() {
        var branch = BTreeNode(kind: .branch, num: 2)
        branch.counts[0] = 5
        branch.counts[1] = 6
        branch.counts[2] = 100
        #expect(branch.subtreeCount == 11)

        var leaf = BTreeNode(kind: .leaf, num: 16)
        leaf.counts[0] = 100
        #expect(leaf.subtreeCount == 16)
    }

    @Test func aFullNodeRoundTrips() throws {
        var leaf = BTreeNode(kind: .leaf, num: 16)
        var branch = BTreeNode(kind: .branch, num: 16)
        for index in 0..<16 {
            leaf.values[index] = Slot(value: UInt64(index), tag: .int, full: false)
            branch.children[index] = Slot(value: UInt64(index) * 300 + 37, tag: .index)
            branch.counts[index] = UInt64(index) << 40 | 1
        }

        let leafBytes = encoded(capacity: 146) { leaf.encode(into: &$0) }
        let decodedLeaf = try BTreeNode(decoding: leafBytes.span)
        #expect(decodedLeaf.kind == .leaf)
        #expect(decodedLeaf.num == 16)
        #expect(array(decodedLeaf.values) == array(leaf.values))

        let branchBytes = encoded(capacity: 274) { branch.encode(into: &$0) }
        let decodedBranch = try BTreeNode(decoding: branchBytes.span)
        #expect(decodedBranch.kind == .branch)
        #expect(decodedBranch.num == 16)
        #expect(array(decodedBranch.children) == array(branch.children))
        #expect(array(decodedBranch.counts) == array(branch.counts))
    }

    @Test func aLeafDecodesFromABranchSizedRead() throws {
        // a node is read with one call that asks for a branch's worth of bytes
        let bytes: [UInt8] = [0x00, 0x01] + uintSlot(7) + zeros(9 * 15) + [UInt8](repeating: 0xFF, count: 128)
        #expect(bytes.count == 274)
        let node = try BTreeNode(decoding: bytes.span)
        #expect(node.kind == .leaf)
        #expect(node.values[0] == Slot(value: 7, tag: .uint))
    }

    @Test func headerIsValidatedInZigsOrder() {
        let none: [UInt8] = []
        #expect(throws: XitDBError.endOfStream) { try BTreeNode(decoding: none.span) }

        let badKindOnly: [UInt8] = [0x02]
        #expect(throws: XitDBError.invalidBTreeNodeKind) { try BTreeNode(decoding: badKindOnly.span) }

        let kindOnly: [UInt8] = [0x00]
        #expect(throws: XitDBError.endOfStream) { try BTreeNode(decoding: kindOnly.span) }

        let badKindAndNum: [UInt8] = [0x02, 0x11] + zeros(272)
        #expect(throws: XitDBError.invalidBTreeNodeKind) { try BTreeNode(decoding: badKindAndNum.span) }

        let tooMany: [UInt8] = [0x00, 0x11] + zeros(144)
        #expect(throws: XitDBError.invalidBTreeNode) { try BTreeNode(decoding: tooMany.span) }

        let tooManyAndShort: [UInt8] = [0x01, 0xFF]
        #expect(throws: XitDBError.invalidBTreeNode) { try BTreeNode(decoding: tooManyAndShort.span) }
    }

    @Test func aTruncatedNodeIsEndOfStream() {
        let shortLeaf: [UInt8] = [0x00, 0x01] + zeros(143)
        #expect(throws: XitDBError.endOfStream) { try BTreeNode(decoding: shortLeaf.span) }

        // a branch of which only a leaf's worth of bytes could be read
        let leafSizedBranch: [UInt8] = [0x01, 0x01] + zeros(144)
        #expect(throws: XitDBError.endOfStream) { try BTreeNode(decoding: leafSizedBranch.span) }

        let shortBranch: [UInt8] = [0x01, 0x01] + zeros(271)
        #expect(throws: XitDBError.endOfStream) { try BTreeNode(decoding: shortBranch.span) }
    }

    @Test func slotsAreCheckedInOrder() {
        var badValue: [UInt8] = [0x00, 0x01] + zeros(144)
        badValue[2 + 9 * 2] = 0x7F
        #expect(throws: XitDBError.invalidEnumTag) { try BTreeNode(decoding: badValue.span) }

        // the unknown tag in slot 2 is met before the bytes run out in slot 5
        let badThenShort = Array(badValue.prefix(2 + 9 * 5))
        #expect(throws: XitDBError.invalidEnumTag) { try BTreeNode(decoding: badThenShort.span) }

        // the bytes run out in slot 1, before the unknown tag in slot 2
        let shortThenBad = Array(badValue.prefix(2 + 9 + 4))
        #expect(throws: XitDBError.endOfStream) { try BTreeNode(decoding: shortThenBad.span) }

        var badChild: [UInt8] = [0x01, 0x01] + zeros(272)
        badChild[2 + 9 * 15] = 0x11
        #expect(throws: XitDBError.invalidEnumTag) { try BTreeNode(decoding: badChild.span) }
    }
}

@Suite struct SortedNodeTests {
    @Test func sizesOnDisk() {
        #expect(SortedNode.leafByteCount == 146)
        #expect(SortedNode.branchByteCount == 418)
        #expect(SortedNode(kind: .leaf, num: 0).byteCount == 146)
        #expect(SortedNode(kind: .branch, num: 0).byteCount == 418)
    }

    @Test func leafDecodesAndEncodesHandWrittenBytes() throws {
        // kind leaf (0), two entries: a key on its own (short_bytes "a") and a
        // pointer to a sorted key-value pair at 0x40
        let key: [UInt8] = [0x07, 0x61, 0, 0, 0, 0, 0, 0, 0]
        let pair: [UInt8] = [0x10, 0, 0, 0, 0, 0, 0, 0, 0x40]
        let bytes: [UInt8] = [0x00, 0x02] + key + pair + zeros(9 * 14)
        #expect(bytes.count == 146)
        let node = try SortedNode(decoding: bytes.span)
        #expect(node.kind == .leaf)
        #expect(node.num == 2)
        #expect(node.entries[0] == Slot(value: 0x6100_0000_0000_0000, tag: .shortBytes))
        #expect(node.entries[1] == Slot(value: 0x40, tag: .sortedKvPair))
        #expect(array(node.entries)[2...].allSatisfy { $0.isEmpty })
        #expect(node.subtreeCount == 2)
        #expect(encoded(capacity: 146) { node.encode(into: &$0) } == bytes)
    }

    @Test func branchDecodesAndEncodesHandWrittenBytes() throws {
        // kind branch (1), two children at 100 and 200; the first separator is
        // the unused sentinel, the second is short_bytes "m"; counts 4 and 9
        let children = indexSlot(100) + indexSlot(200) + zeros(9 * 14)
        let separators = zeros(9) + [0x07, 0x6D, 0, 0, 0, 0, 0, 0, 0] + zeros(9 * 14)
        let counts = count(4) + count(9) + zeros(8 * 14)
        let bytes: [UInt8] = [0x01, 0x02] + children + separators + counts
        #expect(bytes.count == 418)
        let node = try SortedNode(decoding: bytes.span)
        #expect(node.kind == .branch)
        #expect(node.num == 2)
        #expect(node.children[0] == Slot(value: 100, tag: .index))
        #expect(node.children[1] == Slot(value: 200, tag: .index))
        #expect(node.separators[0].isEmpty)
        #expect(node.separators[1] == Slot(value: 0x6D00_0000_0000_0000, tag: .shortBytes))
        #expect(node.counts[0] == 4)
        #expect(node.counts[1] == 9)
        #expect(array(node.entries) == array(node.children))
        #expect(node.subtreeCount == 13)
        #expect(encoded(capacity: 418) { node.encode(into: &$0) } == bytes)
    }

    @Test func aFullNodeRoundTrips() throws {
        var leaf = SortedNode(kind: .leaf, num: 16)
        var branch = SortedNode(kind: .branch, num: 16)
        for index in 0..<16 {
            leaf.entries[index] = Slot(value: UInt64(index) + 500, tag: .kvPair)
            branch.children[index] = Slot(value: UInt64(index) * 500 + 37, tag: .index)
            branch.separators[index] = Slot(value: UInt64(index) + 900, tag: .bytes, full: index % 2 == 0)
            branch.counts[index] = UInt64(index) << 33 | 7
        }

        let leafBytes = encoded(capacity: 146) { leaf.encode(into: &$0) }
        let decodedLeaf = try SortedNode(decoding: leafBytes.span)
        #expect(decodedLeaf.kind == .leaf)
        #expect(decodedLeaf.num == 16)
        #expect(array(decodedLeaf.entries) == array(leaf.entries))

        let branchBytes = encoded(capacity: 418) { branch.encode(into: &$0) }
        let decodedBranch = try SortedNode(decoding: branchBytes.span)
        #expect(decodedBranch.kind == .branch)
        #expect(decodedBranch.num == 16)
        #expect(array(decodedBranch.children) == array(branch.children))
        #expect(array(decodedBranch.separators) == array(branch.separators))
        #expect(array(decodedBranch.counts) == array(branch.counts))
        #expect(decodedBranch.subtreeCount == branch.subtreeCount)
    }

    @Test func headerIsValidatedInZigsOrder() {
        let none: [UInt8] = []
        #expect(throws: XitDBError.endOfStream) { try SortedNode(decoding: none.span) }

        let badKind: [UInt8] = [0x02, 0x11] + zeros(416)
        #expect(throws: XitDBError.invalidBTreeNodeKind) { try SortedNode(decoding: badKind.span) }

        let kindOnly: [UInt8] = [0x01]
        #expect(throws: XitDBError.endOfStream) { try SortedNode(decoding: kindOnly.span) }

        let tooMany: [UInt8] = [0x01, 0x11] + zeros(416)
        #expect(throws: XitDBError.invalidBTreeNode) { try SortedNode(decoding: tooMany.span) }
    }

    @Test func rejectsTruncatedAndCorruptNodes() {
        let shortLeaf: [UInt8] = [0x00, 0x01] + zeros(143)
        #expect(throws: XitDBError.endOfStream) { try SortedNode(decoding: shortLeaf.span) }

        let shortBranch: [UInt8] = [0x01, 0x01] + zeros(415)
        #expect(throws: XitDBError.endOfStream) { try SortedNode(decoding: shortBranch.span) }

        // a linked-array-list branch's worth of bytes is not enough
        let bTreeSizedBranch: [UInt8] = [0x01, 0x01] + zeros(272)
        #expect(throws: XitDBError.endOfStream) { try SortedNode(decoding: bTreeSizedBranch.span) }

        var badEntry: [UInt8] = [0x00, 0x01] + zeros(144)
        badEntry[2] = 0x7F
        #expect(throws: XitDBError.invalidEnumTag) { try SortedNode(decoding: badEntry.span) }

        var badSeparator: [UInt8] = [0x01, 0x01] + zeros(416)
        badSeparator[146 + 9] = 0x7F
        #expect(throws: XitDBError.invalidEnumTag) { try SortedNode(decoding: badSeparator.span) }
    }
}
