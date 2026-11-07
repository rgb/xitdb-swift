import Testing

@testable import XitDB

/// What the sorted map and set do at the edges of their persistence
/// model, beyond what the Zig tests and the conformance scripts pin.
@Suite struct SortedMapEdgeTests {
    /// Putting a key that is already in a committed set changes nothing in
    /// its tree: the leaf is found, nothing below changed, and the branches
    /// above it are not copied. Only the header is copied into the
    /// transaction, as it is for any kept collection.
    @Test(arguments: StorageKind.allCases)
    func puttingAKeyThatIsThereLeavesTheTreeUntouched(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)
        try database.runContext { cursor in
            let set = try SortedSet(try HashMap(cursor).putCursor(sha1("set").bytes))
            for index in 0..<40 {
                try set.put(Array("k\(index)".utf8))
            }
        }
        let before = try #require(try database.rootCursor().readPathSlot([.hashMapGet(.value, sha1("set"))]))
        let treeBefore = try database.reader.bTreeHeader(at: before.value)
        let lengthBefore = try subject.storage.length

        try database.runContext { cursor in
            let set = try SortedSet(try HashMap(cursor).putCursor(sha1("set").bytes))
            try set.put(Array("k7".utf8))
            try set.put(Array("k39".utf8))
            #expect(try set.count() == 40)
        }
        let after = try #require(try database.rootCursor().readPathSlot([.hashMapGet(.value, sha1("set"))]))
        let treeAfter = try database.reader.bTreeHeader(at: after.value)
        #expect(after.value != before.value)
        #expect(treeAfter.rootPtr == treeBefore.rootPtr)
        #expect(treeAfter.size == 40)
        let appended = try subject.storage.length - lengthBefore

        // a transaction that only touches the set appends the same: the
        // hash map's blocks and the set's header, and no node
        let lengthBetween = try subject.storage.length
        try database.runContext { cursor in
            _ = try SortedSet(try HashMap(cursor).putCursor(sha1("set").bytes))
        }
        #expect(try subject.storage.length - lengthBetween == appended)
    }
}
