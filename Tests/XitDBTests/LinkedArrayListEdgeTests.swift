import Testing

@testable import XitDB

/// The linked array list where its own code decides more than the values
/// show: what a removal writes when it empties a leaf and when it leaves
/// the root with one child, a slice at the list's bounds, and what a write
/// into a list made in the same transaction rewrites.
@Suite struct LinkedArrayListEdgeTests {
    /// A removal that empties a leaf drops the leaf from its branch; a root
    /// left with one child is replaced by it; and removing a list's only
    /// element appends a new empty root instead of rewriting the old one.
    ///
    /// The lengths and the root positions are from a run of the same
    /// operations on the Zig original (a scratch test against its lib.zig,
    /// Zig 0.17.1), with the benchmark's file ID and hash ID, on a memory
    /// database. Two lists of sixteen are joined into one of thirty-two,
    /// whose two leaves are full, and the first sixteen elements are
    /// removed: the leaf being emptied cannot be merged with its full
    /// neighbour, so it shrinks to nothing and is dropped.
    @Test(arguments: StorageKind.allCases)
    func removalsThroughAnEmptiedLeafAndAOneChildRoot(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(
            storage: subject.storage,
            hashSize: 20,
            hashID: "sha1",
            fileID: 0x0011_2233_4455_6677,
            random: FixedRandom([1, 2, 3])
        )
        var end: UInt64 = 0
        _ = try database.rootCursor.writePath([.arrayListInit, .arrayListAppend, .hashMapInit(), .ctx]) { cursor in
            let moment = try HashMap(cursor)
            // thirty-two appends: a root over two leaves. (A concat used to
            // make the two leaves; it freezes the transaction now, finding
            // 22, which would copy them on the first removal.)
            let a = try LinkedArrayList(try moment.putCursor(forHash: sha1("a").bytes))
            for value in 0..<32 {
                try a.append(.uint(UInt64(value)))
            }
            let full = try subject.storage.length
            #expect(try a.count == 32)

            for removal in 0..<16 {
                try a.remove(at: 0)
                // the nodes are this transaction's, so every removal
                // rewrites them in place
                #expect(try subject.storage.length == full, "after removal \(removal)")
            }
            #expect(try a.count == 16)
            let values = try (0..<16).map { try a.cursor(at: $0)?.readUInt64() }
            #expect(values == (16..<32).map { UInt64($0) })
            // the root is now the surviving leaf itself, a node that was there
            // before the removals began
            let header = try database.reader.bTreeHeader(at: try a.slot.value)
            #expect(header.rootPtr < full)
            let root = try database.reader.bTreeNode(at: header.rootPtr)
            #expect(root.kind == .leaf && root.num == 16)

            // a list of one element, emptied: a new root is appended
            let c = try LinkedArrayList(try moment.putCursor(forHash: sha1("c").bytes))
            try c.append(.uint(7))
            let before = try subject.storage.length
            try c.remove(at: 0)
            // one empty leaf, 2 + 16 * 9 bytes, appended as the new root
            #expect(try subject.storage.length == before + 146)
            #expect(try database.reader.bTreeHeader(at: try c.slot.value).rootPtr == before)
            #expect(try c.count == 0)
            #expect(try c.cursor(at: 0) == nil)
            end = try subject.storage.length
        }
        // and the commit's trailer after it
        #expect(try subject.storage.length == end + 25)
    }

    /// A slice is checked against the size without overflowing, as in Zig:
    /// the offset may be at most the size, and the elements kept at most
    /// those from the offset on.
    @Test func aSliceAtTheBounds() throws {
        let database = try Database(
            storage: MemoryStorage(), hashSize: 20, hashID: nil, fileID: 6, random: FixedRandom([1, 2, 3]))
        try database.withTransaction { cursor in
            let list = try LinkedArrayList(cursor)
            for value in 0..<40 {
                try list.append(.uint(UInt64(value)))
            }
            #expect(throws: XitDBError.indexOutOfRange) { try list.formSlice(offset: 30, count: 15) }
            #expect(throws: XitDBError.indexOutOfRange) { try list.formSlice(offset: 41, count: 0) }
            #expect(throws: XitDBError.indexOutOfRange) { try list.formSlice(offset: 1, count: 40) }
            #expect(throws: XitDBError.indexOutOfRange) { try list.formSlice(offset: .max, count: 1) }
            #expect(throws: XitDBError.indexOutOfRange) { try list.formSlice(offset: 1, count: .max) }
            #expect(try list.count == 40)
            try list.formSlice(offset: 30, count: 10)
            #expect(try list.count == 10)
            #expect(try list.cursor(at: 0)?.readUInt64() == 30)
            try list.formSlice(offset: 10, count: 0)
            #expect(try list.count == 0)
        }
    }

    /// A write into a list made in the same transaction rewrites nothing on
    /// the way: not the nodes, which belong to the transaction, and not the
    /// header, which has not changed. Only the value's slot is written. A
    /// write into a list from an earlier transaction copies the leaf and
    /// the branch above it and writes the header, before the slot.
    @Test func aWriteIntoThisTransactionsListWritesOnlyTheSlot() throws {
        let storage = FaultInjectingStorage(MemoryStorage())
        let database = try Database(
            storage: storage, hashSize: 20, hashID: nil, fileID: 6, random: FixedRandom([1, 2, 3]))
        try database.withTransaction { cursor in
            let list = try LinkedArrayList(try HashMap(cursor).putCursor(forHash: sha1("list").bytes))
            for value in 0..<40 {
                try list.append(.uint(UInt64(value)))
            }
            let writes = storage.writeCount
            try list.put(.uint(99), at: 3)
            #expect(storage.writeCount == writes + 1)
            try list.put(.uint(98), at: 39)
            #expect(storage.writeCount == writes + 2)
        }
        try database.withTransaction { cursor in
            let list = try LinkedArrayList(try HashMap(cursor).putCursor(forHash: sha1("list").bytes))
            let writes = storage.writeCount
            try list.put(.uint(97), at: 3)
            // the leaf, the branch, the header, the slot
            #expect(storage.writeCount == writes + 4)
            // and the next write into the same leaf is in this transaction
            try list.put(.uint(96), at: 4)
            #expect(storage.writeCount == writes + 5)
            #expect(try list.cursor(at: 3)?.readUInt64() == 97)
            #expect(try list.cursor(at: 4)?.readUInt64() == 96)
        }
    }
}
