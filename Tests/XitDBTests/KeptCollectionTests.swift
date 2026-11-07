import Testing

@testable import XitDB

// A port of the tests "collections kept across a freeze" and "invalid b-tree nodes" that the fix branch of the
// Zig original (`xitdb-fixes`) added in commit a395cf0; the line numbers are those of that branch's test.zig at
// that commit (lines 3912 to 4247). Both pin that a collection whose header disagrees with its tree gets
// `InvalidBTreeNode`, which the Swift port has from the start.
//
// Zig runs each test on one memory database, appending a moment to its history for every block and every
// `Freeze` value. Here each block is a test, and each of its moments a test case, with the storage kind and the
// `Freeze` value as the arguments: the blocks do not read what the ones before them wrote, each starting from
// `.{ .slot = null }`, so every test case makes a database of its own. The tests run on the memory, file and
// buffered-file storages, so that the errors come at the same calls on each.
//
// The comments inside the tests are Zig's. Zig's `Ctx` structs with a `run` method are the trailing closures
// of `append(_:_:)` here; `cursor.db.freeze()` is `cursor.database.freeze()`, `list.?` is `#require(list)`,
// and `expectError(error.X, call)` is `#expect(throws: XitDBError.x) { call }`. Zig's `error.InvalidCount`,
// for a counted hash map whose count disagrees with its entries, is `invalidDatabase` in the port, which has no
// `InvalidCount`. Where Zig damages bytes of the file through `db.core.writeBytes()`, the bytes are written to the
// storage directly. Zig's allocator and `buffer` lines have no counterpart.
//
// Left out, with what each part tests and the feature it waits for:
//
// - The `.concat` value of the first two blocks of "collections kept across a freeze" (3981-3983 and 4006-4008,
//   for that value of `Freeze`). Those two moments need the fix branch's concat, which freezes the transaction
//   after its join (commit b12b8bd, before a395cf0), so that the joined nodes are copied before they are changed.
//   The port keeps the original's concat, which freezes before the join, until parity (decision D18;
//   `LinkedArrayListParts.swift`). With the original's concat, a list initialized again after `list.concat`
//   shares the joined nodes with the kept list and changes them in place: in the first block the clone reads
//   [2, 3, 4] where Zig expects [1, 2, 4] (3977), and in the second `list.append(.{ .uint = 3 })` fails with
//   `invalidBTreeNode` where Zig expects it to succeed (4001). What the port does in those two moments is
//   pinned by two tests of its own, below the ports of the blocks. The other two `Freeze` values of those
//   blocks, and all four of the blocks after them, agree with Zig and are ported.
//
// Everything else in those lines is ported.

/// Zig's "collections kept across a freeze" (test.zig 3919-4179) and "invalid b-tree nodes" (4181-4247).
///
/// Zig's comment on the first: a freeze makes everything the transaction wrote so far immutable. that includes
/// the header of every collection and the entry that points at it, which is why collections must be initialized
/// again after `Database.freeze`, and after a concat, which freezes too. a collection that is kept instead
/// still writes through its old header and its old entry. this is what that does: its writes are lost or
/// shared, and when its header ends up disagreeing with its tree, it gets an error.
@Suite struct KeptCollectionTests {
    /// The storage kinds the tests run on.
    static let storageKinds: [StorageKind] = [.memory, .file, .bufferedFile]

    /// Zig's `xitdb.SLOT_COUNT`.
    private static let slotCount: UInt64 = Trie.slotsPerBlock

    /// Zig's `Freeze` (test.zig 3932-3946): `Database.freeze`, a concat of `list`, or a concat of another
    /// list.
    enum Freeze: CaseIterable, Sendable, CustomTestStringConvertible {
        case database
        case concat
        case concatElsewhere

        var testDescription: String {
            switch self {
            case .database: "database"
            case .concat: "concat"
            case .concatElsewhere: "concat_elsewhere"
            }
        }

        /// test.zig 3938-3945: `Freeze.run`.
        func run(_ cursor: Cursor<ReadWrite>, _ moment: HashMap<ReadWrite>, _ list: LinkedArrayList<ReadWrite>?) throws
        {
            var other = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha1("other").bytes))
            switch self {
            case .database: try cursor.database.freeze()
            case .concat:
                var list = try #require(list)
                try list.append(contentsOf: try other.slot())
            case .concatElsewhere: try other.append(contentsOf: try other.slot())
            }
        }
    }

    /// `std.enums.values(Freeze)`: the `Freeze` values the blocks with a list run for.
    static let allFreezes: [Freeze] = Freeze.allCases

    /// `[_]Freeze{ .database, .concat_elsewhere }`: the values the blocks without a list run for.
    static let freezesWithoutAList: [Freeze] = [.database, .concatElsewhere]

    /// The values the first two blocks run for here: `std.enums.values(Freeze)` without `.concat`, whose
    /// moments need the fix branch's concat (see the file's header).
    static let freezesWithTheOriginalsConcat: [Freeze] = [.database, .concatElsewhere]

    /// The UTF-8 bytes of a string.
    private func utf8(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    /// Zig's `hashInt(text)`: the SHA-1 of the text, as the twenty bytes the collections take.
    private func hashInt(_ text: String) -> [UInt8] {
        sha1(text).bytes
    }

    /// Zig's `std.mem.print(&kbuf, "k{d:0>3}", .{i})`: the key for a number, its digits padded with zeros on
    /// the left to `width`.
    private func paddedKey(_ number: UInt64, width: Int) -> [UInt8] {
        let digits = String(number)
        return utf8("k" + String(repeating: "0", count: max(0, width - digits.count)) + digits)
    }

    /// A `HashInt` (a `u160`) given as a number, as Zig's `0x01`: its twenty big-endian bytes.
    private func hashNumber(_ value: UInt8) -> [UInt8] {
        zeros(19) + [value]
    }

    /// test.zig 3912-3917: `expectUints`.
    private func expectUints<Access>(_ list: LinkedArrayList<Access>, _ expected: [UInt64]) throws {
        #expect(UInt64(expected.count) == (try list.count()))
        for (i, value) in expected.enumerated() {
            #expect(value == (try #require(try list.cursor(at: Int64(i))).readUInt64()))
        }
    }

    /// A database on a new storage, and its history.
    private func makeHistory(_ kind: StorageKind) throws -> (subject: StorageUnderTest, history: ArrayList<ReadWrite>) {
        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)
        return (subject, try ArrayList<ReadWrite>(database.rootCursor))
    }

    /// test.zig 3953-3984: a list that is initialized again is a copy of the one before the freeze, and a slot
    /// read before the freeze keeps what it had.
    ///
    /// Left out: the `.concat` moment (see the file's header).
    @Test(arguments: storageKinds, freezesWithTheOriginalsConcat)
    func aListInitializedAgainIsACopyOfTheOneBeforeTheFreeze(kind: StorageKind, freeze: Freeze) throws {
        let history = try makeHistory(kind).history

        try history.append(.slot(nil)) { cursor in
            var moment = try HashMap<ReadWrite>(cursor)
            var list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            try list.append(.uint(1))
            try list.append(.uint(2))
            let slotBefore = try list.slot()

            try freeze.run(cursor, moment, list)
            moment = try HashMap<ReadWrite>(cursor)
            list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            try list.append(.uint(3))
            try list.remove(at: 0)
            try expectUints(list, [2, 3])

            var cloneCursor = try moment.putCursor(forHash: hashInt("clone"))
            try cloneCursor.write(.slot(slotBefore))
            let clone = try LinkedArrayList<ReadWrite>(cloneCursor)
            try clone.append(.uint(4))
            try expectUints(clone, [1, 2, 4])
            try expectUints(list, [2, 3])
        }
    }

    /// The `.concat` moment of the test above, as the port does it with the original's concat, which freezes
    /// before its join: the joined nodes are not frozen, so the list initialized again after the concat shares
    /// them with the kept list, and the clone, whose header the concat updated in place, sees the kept list's
    /// changes. Pinned so that decision D18, which moves the freeze, shows up here when it is made.
    @Test(arguments: storageKinds)
    func aListInitializedAgainAfterTheOriginalsConcatSharesTheJoinedNodes(kind: StorageKind) throws {
        let history = try makeHistory(kind).history

        try history.append(.slot(nil)) { cursor in
            var moment = try HashMap<ReadWrite>(cursor)
            var list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            try list.append(.uint(1))
            try list.append(.uint(2))
            let slotBefore = try list.slot()

            try Freeze.concat.run(cursor, moment, list)
            moment = try HashMap<ReadWrite>(cursor)
            list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            try list.append(.uint(3))
            try list.remove(at: 0)
            try expectUints(list, [2, 3])

            var cloneCursor = try moment.putCursor(forHash: hashInt("clone"))
            try cloneCursor.write(.slot(slotBefore))
            let clone = try LinkedArrayList<ReadWrite>(cloneCursor)
            try clone.append(.uint(4))
            // Zig's fix branch, whose concat freezes after the join, gives [1, 2, 4] here
            try expectUints(clone, [2, 3, 4])
            try expectUints(list, [2, 3])
        }
    }

    /// test.zig 3986-4009: a kept list writes through the entry it was made with. once the map has a new entry
    /// for the list, it doesn't see what the kept list writes.
    ///
    /// Left out: the `.concat` moment (see the file's header).
    @Test(arguments: storageKinds, freezesWithTheOriginalsConcat)
    func aKeptListWritesThroughTheEntryItWasMadeWith(kind: StorageKind, freeze: Freeze) throws {
        let history = try makeHistory(kind).history

        try history.append(.slot(nil)) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            try list.append(.uint(1))
            try list.append(.uint(2))

            try freeze.run(cursor, moment, list)
            let listAgain = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            try listAgain.remove(at: 0)
            try list.append(.uint(3))
            try expectUints(list, [1, 2, 3])
            try expectUints(listAgain, [2])
        }
    }

    /// The `.concat` moment of the test above, as the port does it with the original's concat: the list
    /// initialized again after the concat shares the joined nodes with the kept list, so its removal leaves the
    /// kept list's header counting an element its tree no longer has, which the kept list's next write reports.
    /// This is the shortest form of finding 22; Zig's fix branch gives [1, 2, 3] and [2] here.
    @Test(arguments: storageKinds)
    func aKeptListAfterTheOriginalsConcatDisagreesWithItsTree(kind: StorageKind) throws {
        let history = try makeHistory(kind).history

        try history.append(.slot(nil)) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            try list.append(.uint(1))
            try list.append(.uint(2))

            try Freeze.concat.run(cursor, moment, list)
            let listAgain = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            try listAgain.remove(at: 0)
            #expect(throws: XitDBError.invalidBTreeNode) { try list.append(.uint(3)) }
            try expectUints(listAgain, [2])
        }
    }

    /// test.zig 4011-4048: if the kept list writes before the list is initialized again, the second header is
    /// a copy of the first, over a node that both can change in place. the kept list's header then counts
    /// entries that the node doesn't have.
    @Test(arguments: storageKinds, allFreezes)
    func aKeptListThatWroteBeforeTheSecondInitDisagreesWithItsTree(kind: StorageKind, freeze: Freeze) throws {
        let history = try makeHistory(kind).history

        try history.append(.slot(nil)) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            try list.append(.uint(1))
            try list.append(.uint(2))
            try list.append(.uint(3))

            try freeze.run(cursor, moment, list)
            try list.append(.uint(4))
            try expectUints(list, [1, 2, 3, 4])
            let listAgain = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            try listAgain.remove(at: 0)
            try listAgain.remove(at: 0)
            try expectUints(listAgain, [3, 4])

            #expect(try list.count() == 4)
            #expect(try #require(try list.cursor(at: 0)).readUInt64() == 3)
            #expect(throws: XitDBError.invalidBTreeNode) { try list.cursor(at: 2) }
            #expect(throws: XitDBError.invalidBTreeNode) { try list.append(.uint(5)) }
            #expect(throws: XitDBError.invalidBTreeNode) { try list.insert(.uint(5), at: 3) }
            #expect(throws: XitDBError.invalidBTreeNode) { try list.put(.uint(5), at: 3) }
            #expect(throws: XitDBError.invalidBTreeNode) { try list.remove(at: 3) }
            #expect(throws: XitDBError.invalidBTreeNode) { try list.formSlice(offset: 0, count: 4) }
            #expect(throws: XitDBError.invalidBTreeNode) { try list.iterator(fromIndex: 3) }
            try expectUints(listAgain, [3, 4])
        }
    }

    /// test.zig 4050-4080: a clone from before the freeze shares the kept list's header, so it changes with the
    /// kept list. a clone from after the kept list's write gets a copy of the header, over the node that the
    /// kept list can change in place.
    @Test(arguments: storageKinds, allFreezes)
    func aCloneFromBeforeTheFreezeSharesTheKeptListsHeader(kind: StorageKind, freeze: Freeze) throws {
        let history = try makeHistory(kind).history

        try history.append(.slot(nil)) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            try list.append(.uint(1))
            var earlyCursor = try moment.putCursor(forHash: hashInt("early"))
            try earlyCursor.write(.slot(try list.slot()))

            try freeze.run(cursor, moment, list)
            try list.append(.uint(2))
            let early = try LinkedArrayList<ReadOnly>(try #require(try moment.cursor(forHash: hashInt("early"))))
            try expectUints(early, [1, 2])

            var lateCursor = try moment.putCursor(forHash: hashInt("late"))
            try lateCursor.write(.slot(try list.slot()))
            let late = try LinkedArrayList<ReadWrite>(lateCursor)
            try late.remove(at: 0)
            try expectUints(late, [2])
            #expect(throws: XitDBError.invalidBTreeNode) { try list.append(.uint(3)) }
        }
    }

    /// test.zig 4082-4121: a sorted map has a header over a tree too.
    @Test(arguments: storageKinds, freezesWithoutAList)
    func aSortedMapHasAHeaderOverATreeToo(kind: StorageKind, freeze: Freeze) throws {
        let history = try makeHistory(kind).history

        try history.append(.slot(nil)) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let map = try SortedMap<ReadWrite>(try moment.putCursor(forHash: hashInt("map")))
            for i in 0..<UInt64(40) {
                try map.put(.uint(i), forKey: paddedKey(i, width: 3))
            }

            try freeze.run(cursor, moment, nil)
            try map.put(.uint(999), forKey: utf8("k999"))
            let mapAgain = try SortedMap<ReadWrite>(try moment.putCursor(forHash: hashInt("map")))
            for i in 0..<UInt64(36) {
                #expect(try mapAgain.remove(forKey: paddedKey(i, width: 3)))
            }
            #expect(try mapAgain.count() == 5)

            // the kept map's header counts 41 keys, in a tree that has 5
            #expect(try map.count() == 41)
            #expect(throws: XitDBError.invalidBTreeNode) { try map.entry(at: 40) }
            #expect(throws: XitDBError.invalidBTreeNode) { try map.iterator(fromIndex: 30) }

            // after one more key from the kept map, the second header
            // counts one key less than the tree has
            try map.put(.uint(998), forKey: utf8("k998"))
            for key in ["k036", "k037", "k038", "k039", "k998"] {
                #expect(try mapAgain.remove(forKey: utf8(key)))
            }
            #expect(try mapAgain.count() == 0)
            #expect(throws: XitDBError.invalidBTreeNode) { try mapAgain.remove(forKey: utf8("k999")) }
        }
    }

    /// test.zig 4123-4153: a counted hash map's count is copied with its root block when it is initialized
    /// again, and they share the blocks below.
    @Test(arguments: storageKinds, freezesWithoutAList)
    func aCountedHashMapsCountIsCopiedWithItsRootBlock(kind: StorageKind, freeze: Freeze) throws {
        let history = try makeHistory(kind).history

        try history.append(.slot(nil)) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let counted = try CountedHashMap<ReadWrite>(try moment.putCursor(forHash: hashInt("counted")))
            // these hashes end with the same four bits, so they are in a block below the root
            try counted.put(.uint(1), forHash: hashNumber(0x01))
            try counted.put(.uint(2), forHash: hashNumber(0x11))

            try freeze.run(cursor, moment, nil)
            try counted.put(.uint(3), forHash: hashNumber(0x21))
            let countedAgain = try CountedHashMap<ReadWrite>(try moment.putCursor(forHash: hashInt("counted")))
            try counted.put(.uint(4), forHash: hashNumber(0x31))

            // the second count is 3, in a map that has 4 keys
            #expect(try countedAgain.count() == 3)
            for hash in [UInt8(0x01), 0x11, 0x21] {
                #expect(try countedAgain.remove(forHash: hashNumber(hash)))
            }
            #expect(try countedAgain.count() == 0)
            #expect(throws: XitDBError.invalidDatabase) { try countedAgain.remove(forHash: hashNumber(0x31)) }
        }
    }

    /// test.zig 4155-4178: an array list has no tree that its header could disagree with. a kept one shares
    /// what it wrote after the freeze with the one that is initialized again.
    @Test(arguments: storageKinds, freezesWithoutAList)
    func anArrayListHasNoTreeItsHeaderCouldDisagreeWith(kind: StorageKind, freeze: Freeze) throws {
        let history = try makeHistory(kind).history

        try history.append(.slot(nil)) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let array = try ArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("array")))
            for i in 0..<20 {
                try array.append(.uint(UInt64(i)))
            }

            try freeze.run(cursor, moment, nil)
            try array.append(.uint(20))
            let arrayAgain = try ArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("array")))
            try arrayAgain.put(.uint(99), at: 20)
            #expect(try #require(try array.cursor(at: 20)).readUInt64() == 99)
        }
    }

    /// test.zig 4181-4247: "invalid b-tree nodes". Zig's comment: a node that doesn't have what its parent
    /// expects of it is an error as well. Zig's `writeInt(u64, 0, .big)` is eight zero bytes.
    @Test(arguments: storageKinds)
    func invalidBTreeNodes(kind: StorageKind) throws {
        let (subject, history) = try makeHistory(kind)

        // a list and a sorted map with enough entries for their root to be a branch
        try history.append(.slot(nil)) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            let map = try SortedMap<ReadWrite>(try moment.putCursor(forHash: hashInt("map")))
            for i in 0..<(Self.slotCount + 1) {
                try list.append(.uint(i))
                try map.put(.uint(i), forKey: paddedKey(i, width: 2))
            }
            let shortList = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("short-list")))
            try shortList.append(.uint(0))
        }

        // a header is the size followed by the position of the root node
        let committed = try HashMap<ReadOnly>(try #require(try history.cursor(at: -1)))
        let listHeader = try #require(try committed.slot(forHash: hashInt("list"))).value
        let listRoot = bigEndian(try readBytes(subject.storage, at: listHeader + 8, count: 8))
        let mapHeader = try #require(try committed.slot(forHash: hashInt("map"))).value
        let mapRoot = bigEndian(try readBytes(subject.storage, at: mapHeader + 8, count: 8))

        // a node is its kind, its number of entries, and then its slots. change the
        // list's root to have no children, and the sorted map's root to count no
        // keys below its first child (the counts follow the children and separators).
        try writeBytes(subject.storage, [0], at: listRoot + 1)
        try writeBytes(subject.storage, zeros(8), at: mapRoot + 2 + 2 * Self.slotCount * 9)
        try subject.storage.flush()

        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            var list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            var shortList = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("short-list")))
            let map = try SortedMap<ReadWrite>(try moment.putCursor(forHash: hashInt("map")))

            #expect(throws: XitDBError.invalidBTreeNode) { try list.remove(at: 0) }
            #expect(throws: XitDBError.invalidBTreeNode) { try list.formSlice(offset: 1, count: 2) }
            #expect(throws: XitDBError.invalidBTreeNode) { try list.append(contentsOf: try shortList.slot()) }
            #expect(throws: XitDBError.invalidBTreeNode) { try shortList.append(contentsOf: try list.slot()) }
            #expect(throws: XitDBError.invalidBTreeNode) { try map.remove(forKey: utf8("k00")) }
        }
    }

    /// Zig's `takeInt(u64, .big)`: the number that eight big-endian bytes hold.
    private func bigEndian(_ bytes: [UInt8]) -> UInt64 {
        precondition(bytes.count == 8)
        return bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }
}
