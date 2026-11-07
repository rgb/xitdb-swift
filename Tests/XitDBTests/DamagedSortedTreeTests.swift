import Testing

@testable import XitDB

/// A sorted map whose tree does not hold what its header or its branches
/// say, through every operation and the three iterators, on every storage.
/// Each must end in ``XitDBError/invalidBTreeNode`` where a count, a rank or
/// an index is used against a node that cannot satisfy it, in
/// ``XitDBError/endOfStream`` where a key record reaches past the file, and
/// never trap. The companion of `DamagedTreeTests` for the sorted tree.
@Suite struct DamagedSortedTreeTests {
    /// Forty keys "k00" to "k39", put in order: a root branch over four
    /// leaves of 8, 8, 8 and 16, in key order.
    private struct Subject {
        let subject: StorageUnderTest
        let database: Database
        let headerPtr: UInt64
        let rootPtr: UInt64

        init(_ kind: StorageKind, keys: [[UInt8]] = (0..<40).map { Subject.key($0) }) throws {
            subject = try StorageUnderTest(kind)
            database = try Database(
                storage: subject.storage, hashSize: 20, hashID: nil, fileID: 6,
                random: FixedRandom((1...50).map { UInt64($0) }))
            try database.runContext { cursor in
                let map = try SortedMap(try HashMap(cursor).putCursor(sha1("map").bytes))
                for (index, key) in keys.enumerated() {
                    try map.put(key, .uint(UInt64(index)))
                }
            }
            let slot = try #require(try database.rootCursor().readPathSlot([.hashMapGet(.value, sha1("map"))]))
            headerPtr = slot.value
            rootPtr = try database.reader.bTreeHeader(at: headerPtr).rootPtr
        }

        static func key(_ index: Int) -> [UInt8] {
            Array("k\(index < 10 ? "0" : "")\(index)".utf8)
        }

        /// Damages the file and opens the database again on it.
        func damaged(_ bytes: [UInt8], at position: UInt64) throws -> Database {
            try writeBytes(subject.storage, bytes, at: position)
            return try Database(
                storage: subject.storage, hashSize: 20, hashID: nil, fileID: nil, random: FixedRandom([9]))
        }
    }

    /// A sentinel that rolls a transaction back after one operation.
    private struct Rollback: Error {}

    /// Runs every operation of the map, each in a transaction of its own
    /// that is rolled back afterwards, so that each meets the same damage,
    /// and returns which of them failed and how. A key or an index that is
    /// not there is `keyNotFound`, which is not damage.
    private func failing(_ database: Database) throws -> [String: XitDBError] {
        var failed: [String: XitDBError] = [:]
        func attempt(_ name: String, _ body: (SortedMap<ReadWrite>) throws -> Void) {
            do {
                try database.runContext { cursor in
                    let map = try SortedMap(try HashMap(cursor).putCursor(sha1("map").bytes))
                    try body(map)
                    throw Rollback()
                }
            } catch is Rollback {
                // the operation went through
            } catch let error as XitDBError where error == .keyNotFound {
                // a key or an index that is not there: not damage
            } catch let error as XitDBError {
                failed[name] = error
            } catch {
                Issue.record("\(name) raised \(error)")
            }
        }
        func walk(_ iterator: inout Cursor<ReadWrite>.Iter) throws {
            while let entry = try iterator.next() {
                _ = try entry.readKeyValuePair()
            }
        }
        let first = Subject.key(5)
        let last = Subject.key(35)
        let missing = Array("k99".utf8)
        attempt("get first") { _ = try $0.getCursor(first) }
        attempt("get last") { _ = try $0.getCursor(last) }
        attempt("get missing") { _ = try $0.getCursor(missing) }
        attempt("put first") { try $0.put(first, .uint(1)) }
        attempt("put last") { try $0.put(last, .uint(1)) }
        attempt("put new first") { try $0.put(Array("k005".utf8), .uint(1)) }
        attempt("put new last") { try $0.put(missing, .uint(1)) }
        attempt("get index 0") { _ = try $0.getIndexKeyValuePair(0) }
        attempt("get index -1") { _ = try $0.getIndexKeyValuePair(-1) }
        attempt("get index 50") { _ = try $0.getIndexKeyValuePair(50) }
        attempt("remove first") { try $0.remove(first) }
        attempt("remove last") { try $0.remove(last) }
        attempt("remove missing") { try $0.remove(missing) }
        attempt("rank first") { _ = try $0.rank(first) }
        attempt("rank last") { _ = try $0.rank(last) }
        attempt("rank missing") { _ = try $0.rank(missing) }
        attempt("iterate") {
            var iterator = try $0.iterator()
            try walk(&iterator)
        }
        attempt("iterate from index 0") {
            var iterator = try $0.iteratorFromIndex(0)
            try walk(&iterator)
        }
        attempt("iterate from index -1") {
            var iterator = try $0.iteratorFromIndex(-1)
            try walk(&iterator)
        }
        attempt("iterate from index 50") {
            var iterator = try $0.iteratorFromIndex(50)
            try walk(&iterator)
        }
        attempt("iterate from first") {
            var iterator = try $0.iteratorFrom(first)
            try walk(&iterator)
        }
        attempt("iterate from last") {
            var iterator = try $0.iteratorFrom(last)
            try walk(&iterator)
        }
        attempt("iterate from missing") {
            var iterator = try $0.iteratorFrom(missing)
            try walk(&iterator)
        }
        return failed
    }

    /// The same names with every error `invalidBTreeNode`.
    private func invalid(_ names: Set<String>) -> [String: XitDBError] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, XitDBError.invalidBTreeNode) })
    }

    /// A sound map raises nothing but `keyNotFound` for what is not there,
    /// which `failing` does not count, and its leaves are as described.
    @Test(arguments: StorageKind.allCases)
    func theSoundMapRaisesNothing(kind: StorageKind) throws {
        let subject = try Subject(kind)
        let root = try subject.database.reader.sortedNode(at: subject.rootPtr)
        #expect(root.kind == .branch)
        #expect(root.num == 4)
        #expect((0..<4).map { root.counts[$0] } == [8, 8, 8, 16])
        #expect(try failing(subject.database).isEmpty)
        var count = 0
        try subject.database.runContext { cursor in
            let map = try SortedMap(try HashMap(cursor).putCursor(sha1("map").bytes))
            #expect(try map.count() == 40)
            #expect(try map.getIndexKeyValuePair(40) == nil)
            #expect(try map.getIndexKeyValuePair(-41) == nil)
            var iterator = try map.iterator()
            while let entry = try iterator.next() {
                #expect(try entry.readKeyValuePair().valueCursor.readUint() == UInt64(count))
                count += 1
            }
        }
        #expect(count == 40)
    }

    /// The root is a branch that says it has no children.
    @Test(arguments: StorageKind.allCases)
    func aBranchWithNoChildren(kind: StorageKind) throws {
        let subject = try Subject(kind)
        let database = try subject.damaged([0], at: subject.rootPtr + 1)
        // Every search and every descent by rank meets the root first. The
        // plain walk goes by the slots, not the count, as Zig's does; the
        // four leaves are still there.
        let failed = try failing(database)
        #expect(
            failed
                == invalid([
                    "get first", "get last", "get missing", "put first", "put last", "put new first", "put new last",
                    "get index 0", "get index -1", "remove first", "remove last", "remove missing", "rank first",
                    "rank last", "rank missing", "iterate from index 0", "iterate from index -1", "iterate from first",
                    "iterate from last", "iterate from missing",
                ]))
    }

    /// The header says the map has a hundred entries; the tree has forty.
    @Test(arguments: StorageKind.allCases)
    func aHeaderLargerThanItsTree(kind: StorageKind) throws {
        let subject = try Subject(kind)
        let database = try subject.damaged(bigEndianBytes(100), at: subject.headerPtr)
        // Everything by key works; everything by rank beyond the forty is
        // reported where the leaf runs out. The plain walk and the walk from
        // a key end when the blocks do.
        let failed = try failing(database)
        #expect(failed == invalid(["get index -1", "get index 50", "iterate from index -1", "iterate from index 50"]))
    }

    /// The header says the map is empty; the tree has forty entries.
    @Test(arguments: StorageKind.allCases)
    func aHeaderSmallerThanItsTree(kind: StorageKind) throws {
        let subject = try Subject(kind)
        let database = try subject.damaged(bigEndianBytes(0), at: subject.headerPtr)
        // A remove finds the key and cannot count it off the header. An
        // index names nothing, which is not damage, and the walks give
        // nothing.
        let failed = try failing(database)
        #expect(failed == invalid(["remove first", "remove last"]))
    }

    /// The root's count for its first child is zero.
    @Test(arguments: StorageKind.allCases)
    func aCountOfZeroForAChildWithEntries(kind: StorageKind) throws {
        let subject = try Subject(kind)
        let database = try subject.damaged(bigEndianBytes(0), at: subject.rootPtr + 290)
        // Removing from that child cannot count it down. The ranks of the
        // other children are off by eight, which the last leaf's own count
        // catches at the end: the counts now add up to thirty-two. An index
        // beyond the header's forty names nothing before any descent.
        let failed = try failing(database)
        #expect(failed == invalid(["remove first", "get index -1", "iterate from index -1"]))
        // a search by key does not use the counts
        try database.runContext { cursor in
            let map = try SortedMap(try HashMap(cursor).putCursor(sha1("map").bytes))
            #expect(try map.rank(Subject.key(10)) == 2)
            #expect(try #require(try map.getCursor(Subject.key(10))).readUint() == 10)
        }
    }

    /// The root's last child is not a node but a number, which happens to
    /// be where the first leaf is, so that taking it for a node would read a
    /// sound leaf and go on. Whatever a search or a descent by rank leads
    /// to the last child is reported. A walk that reaches it gives the
    /// number as an entry, as Zig's does, which reads as no pair.
    @Test(arguments: StorageKind.allCases)
    func aChildThatIsNotANode(kind: StorageKind) throws {
        let subject = try Subject(kind)
        let firstLeaf = try subject.database.reader.sortedNode(at: subject.rootPtr).children[0].value
        let database = try subject.damaged(
            slotBytes(Slot(value: firstLeaf, tag: .uint)), at: subject.rootPtr + 2 + 3 * 9)
        let failed = try failing(database)
        var expected = invalid([
            "get last", "get missing", "put last", "put new last", "get index -1", "remove last", "remove missing",
            "rank last", "rank missing", "iterate from index -1", "iterate from last", "iterate from missing",
        ])
        for walk in ["iterate", "iterate from index 0", "iterate from first"] {
            expected[walk] = .unexpectedTag
        }
        #expect(failed == expected)
    }

    /// The root's first child points back at the root.
    @Test(arguments: StorageKind.allCases)
    func aBranchPointingAtItsAncestor(kind: StorageKind) throws {
        let subject = try Subject(kind)
        let database = try subject.damaged(
            slotBytes(Slot(value: subject.rootPtr, tag: .index)), at: subject.rootPtr + 2)
        // Whatever goes through the first child goes round until the
        // height a tree can have is passed. The other children are fine.
        let failed = try failing(database)
        #expect(
            failed
                == invalid([
                    "get first", "put first", "put new first", "get index 0", "remove first", "rank first", "iterate",
                    "iterate from index 0", "iterate from first",
                ]))
    }

    /// A separator that is not a key: the root's third separator, which
    /// the binary search over four compares first for every key, is a
    /// number.
    @Test(arguments: StorageKind.allCases)
    func aSeparatorThatIsNotAKey(kind: StorageKind) throws {
        let subject = try Subject(kind)
        let database = try subject.damaged(
            slotBytes(Slot(value: 7, tag: .uint)), at: subject.rootPtr + 146 + 2 * 9)
        let failed = try failing(database)
        let expected = Dictionary(
            uniqueKeysWithValues: [
                "get first", "get last", "get missing", "put first", "put last", "put new first", "put new last",
                "remove first", "remove last", "remove missing", "rank first", "rank last", "rank missing",
                "iterate from first", "iterate from last", "iterate from missing",
            ].map { ($0, XitDBError.unexpectedTag) })
        #expect(failed == expected)
    }

    /// A key record whose length reaches past the end of the file is
    /// reported before any of it is compared. The map's keys are long
    /// enough to be records; the length of the one in the middle of the
    /// first leaf is damaged.
    @Test(arguments: StorageKind.allCases)
    func aKeyRecordPastTheFile(kind: StorageKind) throws {
        let keys = (0..<40).map { Array("a long key that is a record \($0 < 10 ? "0" : "")\($0)".utf8) }
        let subject = try Subject(kind, keys: keys)
        let firstLeaf = try subject.database.reader.sortedNode(at: subject.rootPtr).children[0].value
        let leaf = try subject.database.reader.sortedNode(at: firstLeaf)
        let entry = try subject.database.reader.sortedEntryPair(leaf.entries[4])
        #expect(entry.keySlot.tag == .bytes)
        let database = try subject.damaged(bigEndianBytes(UInt64.max - 8), at: entry.keySlot.value)

        // The leaf search of the first leaf meets the fourth entry for a key
        // below it or at it; a key beyond the first leaf never reads it.
        try database.runContext { cursor in
            let map = try SortedMap(try HashMap(cursor).putCursor(sha1("map").bytes))
            #expect(throws: XitDBError.endOfStream) { try map.getCursor(keys[4]) }
            #expect(throws: XitDBError.endOfStream) { try map.getCursor(keys[0]) }
            #expect(throws: XitDBError.endOfStream) { try map.rank(keys[4]) }
            #expect(throws: XitDBError.endOfStream) { try map.put(keys[4], .uint(1)) }
            #expect(throws: XitDBError.endOfStream) { try map.remove(keys[4]) }
            #expect(throws: XitDBError.endOfStream) { try map.iteratorFrom(keys[4]) }
            #expect(try #require(try map.getCursor(keys[20])).readUint() == 20)
            // the walks read the key itself only through its cursor, which
            // refuses the length before reading
            var iterator = try map.iterator()
            var count = 0
            while let entry = try iterator.next() {
                let pair = try entry.readKeyValuePair()
                if count == 4 {
                    #expect(throws: XitDBError.streamTooLong) { try pair.keyCursor.readBytesAlloc(maxSize: 100) }
                } else {
                    #expect(try pair.keyCursor.readBytesAlloc(maxSize: 100) == keys[count])
                }
                count += 1
            }
            #expect(count == 40)
        }
    }

    /// A key record whose length fits the file but reaches past its end by
    /// one byte, through the chunked comparison of a long key.
    @Test(arguments: StorageKind.allCases)
    func aLongKeyRecordCutShort(kind: StorageKind) throws {
        let long = [UInt8](repeating: 0x61, count: 300)
        let subject = try StorageUnderTest(kind)
        let database = try Database(
            storage: subject.storage, hashSize: 20, hashID: nil, fileID: 6,
            random: FixedRandom((1...50).map { UInt64($0) }))
        var keyPtr: UInt64 = 0
        try database.runContext { cursor in
            let map = try SortedMap(try HashMap(cursor).putCursor(sha1("map").bytes))
            try map.put(long, .uint(1))
            let pair = try #require(try map.getKeyValuePair(long))
            keyPtr = try pair.keyCursor.slot().value
        }
        // claim one byte more than the file has after the record's length,
        // and read without a transaction, which would append to the file
        let length = try subject.storage.length()
        try writeBytes(subject.storage, bigEndianBytes(length - keyPtr - 8 + 1), at: keyPtr)
        let damaged = try Database(
            storage: subject.storage, hashSize: 20, hashID: nil, fileID: nil, random: FixedRandom([9]))
        let root = try HashMap(damaged.rootCursor().readOnly())
        let map = try SortedMap(try #require(try root.getCursor(sha1("map").bytes)))
        #expect(throws: XitDBError.endOfStream) { try map.getCursor(long) }
        #expect(throws: XitDBError.endOfStream) { try map.rank(long + [0x61]) }
        // with the length it had, the key is read in two chunks and found
        try writeBytes(subject.storage, bigEndianBytes(300), at: keyPtr)
        #expect(try #require(try map.getCursor(long)).readUint() == 1)
        #expect(try map.rank(long + [0x61]) == 1)
        #expect(try map.rank(long.dropLast()) == 0)
    }
}
