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
            hashID: HashID(bytes: [0x73, 0x68, 0x61, 0x31]),
            fileID: 0x0011_2233_4455_6677,
            random: FixedRandom([1, 2, 3])
        )
        _ = try database.rootCursor().writePath([.arrayListInit, .arrayListAppend, .hashMapInit(), .ctx]) { cursor in
            let moment = try HashMap(cursor)
            let a = try LinkedArrayList(try moment.putCursor(sha1("a").bytes))
            for value in 0..<16 {
                try a.append(.uint(UInt64(value)))
            }
            let b = try LinkedArrayList(try moment.putCursor(sha1("b").bytes))
            for value in 16..<32 {
                try b.append(.uint(UInt64(value)))
            }
            try a.concat(try b.slot())
            #expect(try subject.storage.length == 1485)
            #expect(try a.count() == 32)

            for removal in 0..<16 {
                try a.remove(0)
                // the joined nodes are this transaction's, so every removal
                // rewrites them in place
                #expect(try subject.storage.length == 1485, "after removal \(removal)")
            }
            #expect(try a.count() == 16)
            let values = try (0..<16).map { try a.getCursor($0)?.readUint() }
            #expect(values == (16..<32).map { UInt64($0) })
            // the root is now the surviving leaf itself
            let header = try database.reader.bTreeHeader(at: try a.slot().value)
            #expect(header.rootPtr == 1065)
            let root = try database.reader.bTreeNode(at: header.rootPtr)
            #expect(root.kind == .leaf && root.num == 16)

            // a list of one element, emptied: a new root is appended
            let c = try LinkedArrayList(try moment.putCursor(sha1("c").bytes))
            try c.append(.uint(7))
            let before = try subject.storage.length
            #expect(before == 1685)
            try c.remove(0)
            #expect(try subject.storage.length == 1831)
            #expect(try database.reader.bTreeHeader(at: try c.slot().value).rootPtr == 1685)
            #expect(try c.count() == 0)
            #expect(try c.getCursor(0) == nil)
        }
        #expect(try subject.storage.length == 1856)
    }

    /// A slice is checked against the size without overflowing, as in Zig:
    /// the offset may be at most the size, and the elements kept at most
    /// those from the offset on.
    @Test func aSliceAtTheBounds() throws {
        let database = try Database(
            storage: MemoryStorage(), hashSize: 20, hashID: nil, fileID: 6, random: FixedRandom([1, 2, 3]))
        try database.runContext { cursor in
            let list = try LinkedArrayList(cursor)
            for value in 0..<40 {
                try list.append(.uint(UInt64(value)))
            }
            #expect(throws: XitDBError.keyNotFound) { try list.slice(offset: 30, size: 15) }
            #expect(throws: XitDBError.keyNotFound) { try list.slice(offset: 41, size: 0) }
            #expect(throws: XitDBError.keyNotFound) { try list.slice(offset: 1, size: 40) }
            #expect(throws: XitDBError.keyNotFound) { try list.slice(offset: .max, size: 1) }
            #expect(throws: XitDBError.keyNotFound) { try list.slice(offset: 1, size: .max) }
            #expect(try list.count() == 40)
            try list.slice(offset: 30, size: 10)
            #expect(try list.count() == 10)
            #expect(try list.getCursor(0)?.readUint() == 30)
            try list.slice(offset: 10, size: 0)
            #expect(try list.count() == 0)
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
        try database.runContext { cursor in
            let list = try LinkedArrayList(try HashMap(cursor).putCursor(sha1("list").bytes))
            for value in 0..<40 {
                try list.append(.uint(UInt64(value)))
            }
            let writes = storage.writeCount
            try list.put(3, .uint(99))
            #expect(storage.writeCount == writes + 1)
            try list.put(39, .uint(98))
            #expect(storage.writeCount == writes + 2)
        }
        try database.runContext { cursor in
            let list = try LinkedArrayList(try HashMap(cursor).putCursor(sha1("list").bytes))
            let writes = storage.writeCount
            try list.put(3, .uint(97))
            // the leaf, the branch, the header, the slot
            #expect(storage.writeCount == writes + 4)
            // and the next write into the same leaf is in this transaction
            try list.put(4, .uint(96))
            #expect(storage.writeCount == writes + 5)
            #expect(try list.getCursor(3)?.readUint() == 97)
            #expect(try list.getCursor(4)?.readUint() == 96)
        }
    }
}
