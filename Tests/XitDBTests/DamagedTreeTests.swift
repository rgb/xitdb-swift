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
                "get 0", "get -1", "put 0", "insert 0", "append", "remove 0", "slice 0 5", "concat onto", "concat",
                "iterate from 0",
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
                "get 0", "put 0", "insert 0", "remove 0", "slice 0 5", "concat onto", "concat", "iterate",
                "iterate from 0",
            ])
    }
}
