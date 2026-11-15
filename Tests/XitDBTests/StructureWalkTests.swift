import Testing

@testable import XitDB

/// What the structural walk says of a linked array list whose header counts
/// positions its tree does not have, which is what the freeze hazard
/// leaves: the snapshot proof walks the hazard's fixtures, and holds the
/// words pinned here to those fixtures alone.
@Suite struct StructureWalkTests {
    /// A linked array list of the numbers 0 to 39 under "original", and
    /// under "copy" a copy of it made by its slot and a frozen cursor;
    /// then, in the same transaction, ten removed from the original's
    /// front and 999 appended to the copy. The copy's append runs into the
    /// difference and throws; what it leaves is committed.
    private func hazard() throws -> Database {
        let database = try Database(creating: MemoryStorage(), hashSize: 20)
        try database.withTransaction { cursor in
            let root = try HashMap(cursor)
            let original = try LinkedArrayList(try root.putCursor(forHash: sha1("original").bytes))
            for number in 0..<40 {
                try original.append(.uint(UInt64(number)))
            }
            var copyCursor = try root.putCursor(forHash: sha1("copy").bytes)
            try copyCursor.write(.slot(try original.slot))
            try copyCursor.freeze()
            let copy = try LinkedArrayList(copyCursor)
            for _ in 0..<10 {
                try original.remove(at: 0)
            }
            #expect(throws: XitDBError.invalidBTreeNode) { try copy.append(.uint(999)) }
        }
        return database
    }

    private func copy(in database: Database) throws -> Cursor<ReadOnly> {
        try #require(try database.rootCursor.readPath([.hashMapGet(.value, sha1("copy"))]))
    }

    /// The copy's positions that its tree has are described by their
    /// elements and the others as "no position", each in its place: the
    /// copy's header still counts forty, and the tree it shares with its
    /// original has the thirty that were not removed. A snapshot walks to
    /// the same words, and the original, which is sound, to none of them.
    @Test func aPositionTheTreeDoesNotHaveIsDescribedAsThat() throws {
        let database = try hazard()
        let walk = try StructureWalk.describe(try copy(in: database))
        let elements = (10..<40).map { "uint(\($0))" } + Array(repeating: "no position", count: 10)
        #expect(walk == "linked[" + elements.joined(separator: ", ") + "](40)")
        #expect(walk.ranges(of: StructureWalk.noPosition).count == 10)

        let snapshot = try database.snapshot()
        let inSnapshot = try #require(try snapshot.rootCursor.readPath([.hashMapGet(.value, sha1("copy"))]))
        #expect(try StructureWalk.describe(inSnapshot) == walk)

        let original = try #require(try database.rootCursor.readPath([.hashMapGet(.value, sha1("original"))]))
        let sound = try StructureWalk.describe(original)
        #expect(sound == "linked[" + (10..<40).map { "uint(\($0))" }.joined(separator: ", ") + "](30)")
        #expect(sound.ranges(of: StructureWalk.noPosition).isEmpty)
    }

    /// A list is described while it lacks no more positions than the walk
    /// allows, 1,024, and one more ends the walk in the error the read
    /// gives: a size gone wild is damage and is reported, not described.
    /// The list is a sound one of forty whose size, the first eight bytes
    /// of its header, is written over.
    @Test func aListThatLacksMoreThanTheWalkAllowsEndsIt() throws {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashSize: 20)
        try database.withTransaction { cursor in
            let list = try LinkedArrayList(try HashMap(cursor).putCursor(forHash: sha1("copy").bytes))
            for number in 0..<40 {
                try list.append(.uint(UInt64(number)))
            }
        }
        let sizePtr = try copy(in: database).slot.value
        let most = UInt64(StructureWalk.mostPositionsLacking)

        try writeBytes(storage, bigEndianBytes(40 + most), at: sizePtr)
        let allowed = try StructureWalk.describe(try copy(in: try Database(opening: storage, hashSize: 20)))
        #expect(allowed.ranges(of: StructureWalk.noPosition).count == 1024)
        #expect(allowed.hasSuffix("no position](1064)"))

        try writeBytes(storage, bigEndianBytes(40 + most + 1), at: sizePtr)
        let wild = try copy(in: try Database(opening: storage, hashSize: 20))
        #expect(throws: XitDBError.invalidBTreeNode) { try StructureWalk.describe(wild) }
    }
}
