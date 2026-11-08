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
// and `expectError(error.X, call)` is `#expect(throws: XitDBError.x) { call }`. Zig's `error.InvalidCount`, for a
// counted hash map whose count disagrees with its entries, is `invalidCount` in the port. Where Zig damages bytes of
// the file through `db.core.writeBytes()`, the bytes are written to the storage directly. Zig's allocator and
// `buffer` lines have no counterpart.
//
// Adjusted for the port's guard (decision D18, brief package-12): a collection kept across a freeze cannot write
// any more. Where Zig's branch shows what a kept collection's writes do (lost, shared, or a header that
// disagrees with its tree), the port refuses them with `staleCursor`, and what the kept collection reads is
// its snapshot; the moments below say so at each write Zig's test makes through a kept collection, and the
// outcomes Zig's test reads after those writes are the port's instead. The `.concat` moments of the first two
// blocks, left out until the concat froze after its join (finding 22), are ported now. After a freeze a
// transaction goes on by running a collection's init on a cursor it holds, so `moment` is made again from the
// callback's cursor where Zig goes on through the kept `moment`.

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
            let other = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha1("other").bytes))
            switch self {
            case .database: try cursor.database.freeze()
            case .concat:
                let list = try #require(list)
                try list.append(contentsOf: try other.slot)
            case .concatElsewhere: try other.append(contentsOf: try other.slot)
            }
        }
    }

    /// `std.enums.values(Freeze)`: the `Freeze` values the blocks with a list run for.
    static let allFreezes: [Freeze] = Freeze.allCases

    /// `[_]Freeze{ .database, .concat_elsewhere }`: the values the blocks without a list run for.
    static let freezesWithoutAList: [Freeze] = [.database, .concatElsewhere]

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
        #expect(UInt64(expected.count) == (try list.count))
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
    @Test(arguments: storageKinds, allFreezes)
    func aListInitializedAgainIsACopyOfTheOneBeforeTheFreeze(kind: StorageKind, freeze: Freeze) throws {
        let history = try makeHistory(kind).history

        try history.append(.slot(nil)) { cursor in
            var moment = try HashMap<ReadWrite>(cursor)
            var list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            try list.append(.uint(1))
            try list.append(.uint(2))
            let slotBefore = try list.slot

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

    /// test.zig 3986-4009: in Zig's branch a kept list writes through the entry it was made with, and the map's
    /// new entry for the list doesn't see what it writes. Here the kept list cannot write: its write is
    /// `staleCursor`, and it reads its snapshot.
    @Test(arguments: storageKinds, allFreezes)
    func aKeptListCannotWriteAfterAFreeze(kind: StorageKind, freeze: Freeze) throws {
        let history = try makeHistory(kind).history

        try history.append(.slot(nil)) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            try list.append(.uint(1))
            try list.append(.uint(2))

            try freeze.run(cursor, moment, list)
            let momentAgain = try HashMap<ReadWrite>(cursor)
            let listAgain = try LinkedArrayList<ReadWrite>(try momentAgain.putCursor(forHash: hashInt("list")))
            try listAgain.remove(at: 0)
            #expect(throws: XitDBError.staleCursor) { try list.append(.uint(3)) }
            try expectUints(list, [1, 2])
            try expectUints(listAgain, [2])
            // and so is the kept moment: a get through it is a write it cannot make
            #expect(throws: XitDBError.staleCursor) { try moment.putCursor(forHash: hashInt("list")) }
        }
    }

    /// test.zig 4011-4048: in Zig's branch a kept list that writes before the list is initialized again shares a
    /// node with the second header, which both change in place, until the kept header counts entries its tree
    /// doesn't have. Here every write through the kept list is `staleCursor`, before and after the second init,
    /// and its reads stay its snapshot.
    @Test(arguments: storageKinds, allFreezes)
    func aKeptListIsRefusedBeforeAndAfterTheSecondInit(kind: StorageKind, freeze: Freeze) throws {
        let history = try makeHistory(kind).history

        try history.append(.slot(nil)) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            try list.append(.uint(1))
            try list.append(.uint(2))
            try list.append(.uint(3))

            try freeze.run(cursor, moment, list)
            #expect(throws: XitDBError.staleCursor) { try list.append(.uint(4)) }
            try expectUints(list, [1, 2, 3])
            let momentAgain = try HashMap<ReadWrite>(cursor)
            let listAgain = try LinkedArrayList<ReadWrite>(try momentAgain.putCursor(forHash: hashInt("list")))
            try listAgain.remove(at: 0)
            try listAgain.remove(at: 0)
            try expectUints(listAgain, [3])

            #expect(try list.count == 3)
            #expect(try #require(try list.cursor(at: 0)).readUInt64() == 1)
            #expect(try #require(try list.cursor(at: 2)).readUInt64() == 3)
            #expect(throws: XitDBError.staleCursor) { try list.append(.uint(5)) }
            #expect(throws: XitDBError.staleCursor) { try list.insert(.uint(5), at: 2) }
            #expect(throws: XitDBError.staleCursor) { try list.put(.uint(5), at: 2) }
            #expect(throws: XitDBError.staleCursor) { try list.remove(at: 2) }
            #expect(throws: XitDBError.staleCursor) { try list.formSlice(offset: 0, count: 3) }
            var iterator = try list.iterator(fromIndex: 2)
            #expect(try iterator.next()?.readUInt64() == 3)
            try expectUints(listAgain, [3])
        }
    }

    /// test.zig 4050-4080: in Zig's branch a clone from before the freeze shares the kept list's header and
    /// changes with it, and a clone from after the kept list's write shares a node it can change in place. Here
    /// the kept list cannot write, so a clone from before the freeze stays what it was, and one made after it
    /// is a copy of its own.
    @Test(arguments: storageKinds, allFreezes)
    func aCloneFromBeforeTheFreezeStaysWhatItWas(kind: StorageKind, freeze: Freeze) throws {
        let history = try makeHistory(kind).history

        try history.append(.slot(nil)) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            try list.append(.uint(1))
            var earlyCursor = try moment.putCursor(forHash: hashInt("early"))
            try earlyCursor.write(.slot(try list.slot))

            try freeze.run(cursor, moment, list)
            #expect(throws: XitDBError.staleCursor) { try list.append(.uint(2)) }
            let momentAgain = try HashMap<ReadWrite>(cursor)
            let early = try LinkedArrayList<ReadOnly>(try #require(try momentAgain.cursor(forHash: hashInt("early"))))
            try expectUints(early, [1])

            var lateCursor = try momentAgain.putCursor(forHash: hashInt("late"))
            try lateCursor.write(.slot(try list.slot))
            let late = try LinkedArrayList<ReadWrite>(lateCursor)
            try late.remove(at: 0)
            try expectUints(late, [])
            try expectUints(early, [1])
            try expectUints(list, [1])
            #expect(throws: XitDBError.staleCursor) { try list.append(.uint(3)) }
        }
    }

    /// test.zig 4082-4121: in Zig's branch a kept sorted map's header ends up over a tree with other keys. Here
    /// the kept map cannot write, and reads the forty keys it had.
    @Test(arguments: storageKinds, freezesWithoutAList)
    func aKeptSortedMapCannotWriteAfterAFreeze(kind: StorageKind, freeze: Freeze) throws {
        let history = try makeHistory(kind).history

        try history.append(.slot(nil)) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let map = try SortedMap<ReadWrite>(try moment.putCursor(forHash: hashInt("map")))
            for i in 0..<UInt64(40) {
                try map.put(.uint(i), forKey: paddedKey(i, width: 3))
            }

            try freeze.run(cursor, moment, nil)
            #expect(throws: XitDBError.staleCursor) { try map.put(.uint(999), forKey: utf8("k999")) }
            let momentAgain = try HashMap<ReadWrite>(cursor)
            let mapAgain = try SortedMap<ReadWrite>(try momentAgain.putCursor(forHash: hashInt("map")))
            for i in 0..<UInt64(36) {
                #expect(try mapAgain.remove(forKey: paddedKey(i, width: 3)))
            }
            #expect(try mapAgain.count == 4)

            // the kept map still reads its forty keys
            #expect(try map.count == 40)
            #expect(try map.entry(at: 39)?.value.readUInt64() == 39)
            #expect(try map.entry(at: 40) == nil)
            var iterator = try map.iterator(fromIndex: 30)
            #expect(try iterator.next()?.readEntry().value.readUInt64() == 30)

            #expect(throws: XitDBError.staleCursor) { try map.put(.uint(998), forKey: utf8("k998")) }
            for key in ["k036", "k037", "k038", "k039"] {
                #expect(try mapAgain.remove(forKey: utf8(key)))
            }
            #expect(try mapAgain.count == 0)
            #expect(try !mapAgain.remove(forKey: utf8("k999")))
        }
    }

    /// test.zig 4123-4153: in Zig's branch a counted hash map's count is copied with its root block when it is
    /// initialized again, over blocks the kept map goes on changing. Here the kept map cannot write, so the
    /// copy counts what it has.
    @Test(arguments: storageKinds, freezesWithoutAList)
    func aKeptCountedMapCannotWriteAfterAFreeze(kind: StorageKind, freeze: Freeze) throws {
        let history = try makeHistory(kind).history

        try history.append(.slot(nil)) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let counted = try CountedHashMap<ReadWrite>(try moment.putCursor(forHash: hashInt("counted")))
            // these hashes end with the same four bits, so they are in a block below the root
            try counted.put(.uint(1), forHash: hashNumber(0x01))
            try counted.put(.uint(2), forHash: hashNumber(0x11))

            try freeze.run(cursor, moment, nil)
            #expect(throws: XitDBError.staleCursor) { try counted.put(.uint(3), forHash: hashNumber(0x21)) }
            let momentAgain = try HashMap<ReadWrite>(cursor)
            let countedAgain = try CountedHashMap<ReadWrite>(try momentAgain.putCursor(forHash: hashInt("counted")))
            #expect(throws: XitDBError.staleCursor) { try counted.put(.uint(4), forHash: hashNumber(0x31)) }

            #expect(try countedAgain.count == 2)
            for hash in [UInt8(0x01), 0x11] {
                #expect(try countedAgain.remove(forHash: hashNumber(hash)))
            }
            #expect(try countedAgain.count == 0)
            #expect(try !countedAgain.remove(forHash: hashNumber(0x21)))
            #expect(try counted.count == 2)
        }
    }

    /// test.zig 4155-4178: in Zig's branch an array list has no tree its header could disagree with, and a kept
    /// one shares what it wrote after the freeze with the one initialized again. Here a kept array list cannot
    /// write either, and sees nothing of what the new one writes.
    @Test(arguments: storageKinds, freezesWithoutAList)
    func aKeptArrayListCannotWriteAfterAFreezeEither(kind: StorageKind, freeze: Freeze) throws {
        let history = try makeHistory(kind).history

        try history.append(.slot(nil)) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let array = try ArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("array")))
            for i in 0..<20 {
                try array.append(.uint(UInt64(i)))
            }

            try freeze.run(cursor, moment, nil)
            #expect(throws: XitDBError.staleCursor) { try array.append(.uint(20)) }
            let momentAgain = try HashMap<ReadWrite>(cursor)
            let arrayAgain = try ArrayList<ReadWrite>(try momentAgain.putCursor(forHash: hashInt("array")))
            try arrayAgain.append(.uint(99))
            #expect(try #require(try arrayAgain.cursor(at: 20)).readUInt64() == 99)
            #expect(try array.count == 20)
            #expect(try array.cursor(at: 20) == nil)
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

        // Zig makes these five calls in one transaction. Here an operation that fails after writing poisons
        // its transaction (finding 16), so each runs in one of its own, which is then rolled back: the ones
        // that write before they meet the damaged node end in `poisonedTransaction`, the others roll back as
        // Zig's does.
        func attempt(_ what: Comment, poisoning: Bool, _ body: @escaping (HashMap<ReadWrite>) throws -> Void) throws {
            let outcome = Result { () throws -> Void in
                try history.append(.slot(try history.slot(at: -1))) { cursor in
                    try body(try HashMap<ReadWrite>(cursor))
                }
            }
            if poisoning {
                #expect(throws: XitDBError.poisonedTransaction, what) { try outcome.get() }
            } else {
                #expect(throws: Never.self, what) { try outcome.get() }
            }
        }
        try attempt("remove", poisoning: false) { moment in
            let list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            #expect(throws: XitDBError.invalidBTreeNode) { try list.remove(at: 0) }
        }
        try attempt("slice", poisoning: false) { moment in
            let list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            #expect(throws: XitDBError.invalidBTreeNode) { try list.formSlice(offset: 1, count: 2) }
        }
        try attempt("concat of the damaged list", poisoning: false) { moment in
            let list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            let shortList = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("short-list")))
            #expect(throws: XitDBError.invalidBTreeNode) { try list.append(contentsOf: try shortList.slot) }
        }
        try attempt("concat onto the damaged list", poisoning: false) { moment in
            let list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("list")))
            let shortList = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("short-list")))
            #expect(throws: XitDBError.invalidBTreeNode) { try shortList.append(contentsOf: try list.slot) }
        }
        try attempt("sorted remove", poisoning: true) { moment in
            let map = try SortedMap<ReadWrite>(try moment.putCursor(forHash: hashInt("map")))
            #expect(throws: XitDBError.invalidBTreeNode) { try map.remove(forKey: utf8("k00")) }
        }
    }

    /// Zig's `takeInt(u64, .big)`: the number that eight big-endian bytes hold.
    private func bigEndian(_ bytes: [UInt8]) -> UInt64 {
        precondition(bytes.count == 8)
        return bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }
}
