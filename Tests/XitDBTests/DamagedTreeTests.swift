import Testing

@testable import XitDB

/// A linked array list whose tree does not hold what its header or its
/// branches say, through every operation and the iterator, on every
/// storage. Each must end in ``XitDBError/invalidBTreeNode`` where a count
/// or a rank is used against a node that cannot satisfy it, and never trap.
/// Zig's checks (its branch `fix-findings-2-8-9`, commit a395cf0) catch the
/// same cases; a damaged file produces each, and so can documented
/// operations (finding 23).
@Suite struct DamagedTreeTests {
    /// Forty elements: a root branch over four leaves of 8, 8, 8 and 16.
    private struct Subject {
        let subject: StorageUnderTest
        let database: Database
        let headerPtr: UInt64
        let rootPtr: UInt64

        init(_ kind: StorageKind) throws {
            subject = try StorageUnderTest(kind)
            database = try Database(
                storage: subject.storage, hashSize: 20, hashID: nil, fileID: 6,
                random: FixedRandom((1...50).map { UInt64($0) }))
            try database.runContext { cursor in
                let map = try HashMap(cursor)
                let list = try LinkedArrayList(try map.putCursor(sha1("list").bytes))
                for index in 0..<40 {
                    try list.append(.uint(UInt64(index)))
                }
                let short = try LinkedArrayList(try map.putCursor(sha1("short").bytes))
                try short.append(.uint(100))
            }
            let slot = try #require(try database.rootCursor().readPathSlot([.hashMapGet(.value, sha1("list"))]))
            headerPtr = slot.value
            rootPtr = try database.reader.bTreeHeader(at: headerPtr).rootPtr
            #expect(try database.reader.bTreeNode(at: rootPtr).num == 4)
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

    /// Runs every operation of the list, each in a transaction of its own
    /// that is rolled back afterwards, so that each meets the same damage,
    /// and returns which of them raised `invalidBTreeNode`. An index beyond
    /// the header's size is `keyNotFound`, which is not damage.
    private func failing(_ database: Database) throws -> Set<String> {
        var failed: Set<String> = []
        func attempt(
            _ name: String, _ body: (LinkedArrayList<ReadWrite>, LinkedArrayList<ReadWrite>) throws -> Void
        ) {
            do {
                try database.runContext { cursor in
                    let map = try HashMap(cursor)
                    let list = try LinkedArrayList(try map.putCursor(sha1("list").bytes))
                    let short = try LinkedArrayList(try map.putCursor(sha1("short").bytes))
                    try body(list, short)
                    throw Rollback()
                }
            } catch is Rollback {
                // the operation went through
            } catch let error as XitDBError where error == .invalidBTreeNode {
                failed.insert(name)
            } catch let error as XitDBError where error == .keyNotFound {
                // an index beyond what the header says: not damage
            } catch {
                Issue.record("\(name) raised \(error)")
            }
        }
        attempt("get 0") { list, _ in _ = try list.getCursor(0) }
        attempt("get -1") { list, _ in _ = try list.getCursor(-1) }
        attempt("get 50") { list, _ in _ = try list.getCursor(50) }
        attempt("put 0") { list, _ in try list.put(0, .uint(1)) }
        attempt("put 50") { list, _ in try list.put(50, .uint(1)) }
        attempt("insert 0") { list, _ in try list.insert(0, .uint(1)) }
        attempt("insert 50") { list, _ in try list.insert(50, .uint(1)) }
        attempt("append") { list, _ in try list.append(.uint(1)) }
        attempt("remove 0") { list, _ in try list.remove(0) }
        attempt("remove 50") { list, _ in try list.remove(50) }
        attempt("slice 0 5") { list, _ in try list.slice(offset: 0, size: 5) }
        attempt("slice 45 2") { list, _ in try list.slice(offset: 45, size: 2) }
        attempt("slice 20 5") { list, _ in try list.slice(offset: 20, size: 5) }
        attempt("concat onto") { list, short in try short.concat(try list.slot()) }
        attempt("concat") { list, short in try list.concat(try short.slot()) }
        attempt("iterate") { list, _ in
            var iterator = try list.iterator()
            while try iterator.next() != nil {}
        }
        attempt("iterate from 0") { list, _ in
            var iterator = try list.iteratorFrom(0)
            while try iterator.next() != nil {}
        }
        attempt("iterate from 50") { list, _ in
            var iterator = try list.iteratorFrom(50)
            while try iterator.next() != nil {}
        }
        return failed
    }

    /// A sound list raises nothing but `keyNotFound` for the indexes that
    /// do not exist, which `failing` does not count.
    @Test(arguments: StorageKind.allCases)
    func theSoundListRaisesNothing(kind: StorageKind) throws {
        let subject = try Subject(kind)
        var count = 0
        try subject.database.runContext { cursor in
            let list = try LinkedArrayList(try HashMap(cursor).putCursor(sha1("list").bytes))
            #expect(try list.count() == 40)
            #expect(throws: XitDBError.keyNotFound) { try list.put(50, .uint(1)) }
            #expect(throws: XitDBError.keyNotFound) { try list.slice(offset: 45, size: 2) }
            var iterator = try list.iterator()
            while let element = try iterator.next() {
                #expect(try element.readUint() == UInt64(count))
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
        let failed = try failing(database)
        // The walk of the iterator goes by the slots, not the count, as
        // Zig's does; the four leaves are still there.
        #expect(
            failed == [
                "get 0", "get -1", "put 0", "insert 0", "append", "remove 0", "slice 0 5", "slice 20 5", "concat onto",
                "concat", "iterate from 0",
            ])
    }

    /// The header says the list has a hundred elements; the tree has forty.
    @Test(arguments: StorageKind.allCases)
    func aHeaderLargerThanItsTree(kind: StorageKind) throws {
        let subject = try Subject(kind)
        let database = try subject.damaged(bigEndianBytes(100), at: subject.headerPtr)
        let failed = try failing(database)
        // Everything within the forty works; everything beyond them is
        // reported where the leaf runs out. A concat does not count.
        #expect(
            failed == [
                "get -1", "get 50", "put 50", "insert 50", "append", "remove 50", "slice 45 2", "iterate from 50",
            ])
    }

    /// The root's last child is not a node but a number, which happens to
    /// be where the first leaf is, so that taking it for a node would read a
    /// sound leaf and go on. Whatever goes through the last child is
    /// reported: the last element, an append, a slice whose right part is
    /// that child alone, and joining another list onto the right spine.
    @Test(arguments: StorageKind.allCases)
    func aChildThatIsNotANode(kind: StorageKind) throws {
        let subject = try Subject(kind)
        let firstLeaf = try subject.database.reader.bTreeNode(at: subject.rootPtr).children[0].value
        let database = try subject.damaged(
            slotBytes(Slot(value: firstLeaf, tag: .uint)), at: subject.rootPtr + 2 + 3 * 9)
        let failed = try failing(database)
        #expect(failed == ["get -1", "append", "slice 20 5", "concat"])
    }

    /// The root's first child points back at the root.
    @Test(arguments: StorageKind.allCases)
    func aBranchPointingAtItsAncestor(kind: StorageKind) throws {
        let subject = try Subject(kind)
        let database = try subject.damaged(
            slotBytes(Slot(value: subject.rootPtr, tag: .index)), at: subject.rootPtr + 2)
        let failed = try failing(database)
        // Whatever goes through the first child goes round until the
        // height a tree can have is passed. The other children are fine.
        #expect(
            failed == [
                "get 0", "put 0", "insert 0", "remove 0", "slice 0 5", "slice 20 5", "concat onto", "concat", "iterate",
                "iterate from 0",
            ])
    }

    /// Fifteen hundred elements: a tree three branches high, so that a join
    /// descends a spine of the taller tree through a branch it reads on the
    /// way. A spine node that says it has no children, or whose child is
    /// not a node, is reported where the join meets it. The tree's height is
    /// found by following first children, so damage on the left spine stops
    /// a join from either side.
    @Test(arguments: StorageKind.allCases)
    func aDamagedSpineEndsAJoin(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(
            storage: subject.storage, hashSize: 20, hashID: nil, fileID: 6,
            random: FixedRandom((1...50).map { UInt64($0) }))
        try database.runContext { cursor in
            let map = try HashMap(cursor)
            let list = try LinkedArrayList(try map.putCursor(sha1("list").bytes))
            for index in 0..<1500 {
                try list.append(.uint(UInt64(index)))
            }
            let short = try LinkedArrayList(try map.putCursor(sha1("short").bytes))
            try short.append(.uint(100))
        }
        let slot = try #require(try database.rootCursor().readPathSlot([.hashMapGet(.value, sha1("list"))]))
        let rootPtr = try database.reader.bTreeHeader(at: slot.value).rootPtr
        #expect(try database.reader.bTreeHeight(rootPtr: rootPtr) == 3)
        let root = try database.reader.bTreeNode(at: rootPtr)
        let firstChild = root.children[0].value
        let lastChild = root.children[Int(root.num) - 1].value
        let lastBranch = try database.reader.bTreeNode(at: lastChild)
        let sound = try readBytes(subject.storage, at: 0, count: Int(try subject.storage.length()))

        /// Whether a concat in one direction, on the file damaged by
        /// `damage`, is reported as `invalidBTreeNode`.
        func concat(listOnto: Bool, _ damage: () throws -> Void) throws -> Bool {
            try writeBytes(subject.storage, sound, at: 0)
            try damage()
            let damaged = try Database(
                storage: subject.storage, hashSize: 20, hashID: nil, fileID: nil, random: FixedRandom([9]))
            var reported = false
            try damaged.runContext { cursor in
                let map = try HashMap(cursor)
                let list = try LinkedArrayList(try map.putCursor(sha1("list").bytes))
                let short = try LinkedArrayList(try map.putCursor(sha1("short").bytes))
                do {
                    if listOnto {
                        try short.concat(try list.slot())
                    } else {
                        try list.concat(try short.slot())
                    }
                } catch XitDBError.invalidBTreeNode {
                    reported = true
                }
            }
            return reported
        }

        // the root's last branch says it has no children: a join on the
        // right spine reads it on the way down; the left spine is fine
        let lastBranchEmpty = { try writeBytes(subject.storage, [0], at: lastChild + 1) }
        #expect(try concat(listOnto: false, lastBranchEmpty))
        #expect(try !concat(listOnto: true, lastBranchEmpty))
        // the last branch's last child is not a node
        let lastChildNotANode = {
            try writeBytes(
                subject.storage, slotBytes(Slot(value: 7, tag: .uint)),
                at: lastChild + 2 + 9 * UInt64(lastBranch.num - 1))
        }
        #expect(try concat(listOnto: false, lastChildNotANode))
        #expect(try !concat(listOnto: true, lastChildNotANode))
        // the root's first branch says it has no children: the height of the
        // tree cannot be found, so neither join starts
        let firstBranchEmpty = { try writeBytes(subject.storage, [0], at: firstChild + 1) }
        #expect(try concat(listOnto: false, firstBranchEmpty))
        #expect(try concat(listOnto: true, firstBranchEmpty))
        // the first branch's first child is not a node: the same
        let firstChildNotANode = {
            try writeBytes(subject.storage, slotBytes(Slot(value: 7, tag: .uint)), at: firstChild + 2)
        }
        #expect(try concat(listOnto: false, firstChildNotANode))
        #expect(try concat(listOnto: true, firstChildNotANode))
        // and with the file as it was, both joins work
        #expect(try !concat(listOnto: false) {})
        #expect(try !concat(listOnto: true) {})
    }
}
