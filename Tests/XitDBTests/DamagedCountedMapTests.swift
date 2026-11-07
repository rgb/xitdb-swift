import Testing

@testable import XitDB

/// A counted hash map whose count disagrees with its trie, through the
/// writes that use the count, on every storage. The count is the one count
/// in the format that is not a tree node's; the companion of
/// `DamagedTreeTests` for it.
@Suite struct DamagedCountedMapTests {
    /// Three entries in a counted map under the root map, committed.
    private struct Subject {
        let subject: StorageUnderTest
        let database: Database
        /// Where the map's count is: the first eight bytes of what its
        /// slot points at.
        let countPtr: UInt64

        init(_ kind: StorageKind) throws {
            subject = try StorageUnderTest(kind)
            database = try Database(
                storage: subject.storage, hashSize: 20, hashID: nil, fileID: 6,
                random: FixedRandom((1...50).map { UInt64($0) }))
            try database.withTransaction { cursor in
                let map = try CountedHashMap(try HashMap(cursor).putCursor(forHash: sha1("counted").bytes))
                for index in 0..<3 {
                    try map.put(.uint(UInt64(index)), forHash: Subject.hash(index))
                }
            }
            let slot = try #require(try database.rootCursor.readPathSlot([.hashMapGet(.value, sha1("counted"))]))
            countPtr = slot.value
        }

        static func hash(_ index: Int) -> [UInt8] {
            sha1("k\(index)").bytes
        }

        /// Damages the file and opens the database again on it.
        func damaged(_ bytes: [UInt8], at position: UInt64) throws -> Database {
            try writeBytes(subject.storage, bytes, at: position)
            return try Database(
                storage: subject.storage, hashSize: 20, hashID: nil, fileID: nil, random: FixedRandom([9]))
        }
    }

    /// A sentinel that rolls a transaction back after `body`.
    private struct Rollback: Error {}

    /// Opens the map for writing in a transaction, runs `body` on it, and
    /// rolls the transaction back, so that the committed data is as it was.
    private func inTransaction(_ database: Database, _ body: (CountedHashMap<ReadWrite>) throws -> Void) throws {
        do {
            try database.withTransaction { cursor in
                let map = try CountedHashMap(try HashMap(cursor).putCursor(forHash: sha1("counted").bytes))
                try body(map)
                throw Rollback()
            }
        } catch is Rollback {
            // the body went through
        }
    }

    /// The map as the last commit has it.
    private func committed(_ database: Database) throws -> CountedHashMap<ReadOnly> {
        let root = try HashMap(database.rootCursor.readOnly)
        return try CountedHashMap(try #require(try root.cursor(forHash: sha1("counted").bytes)))
    }

    /// A sound map counts up and down, and removing a key that is not
    /// there from a map whose count is nothing is not damage: the count is
    /// right for an empty map.
    @Test(arguments: StorageKind.allCases)
    func theSoundMapCountsItsEntries(kind: StorageKind) throws {
        let subject = try Subject(kind)
        #expect(try committed(subject.database).count == 3)
        try inTransaction(subject.database) { map in
            #expect(try map.count == 3)
            try map.put(.uint(9), forHash: Subject.hash(9))
            #expect(try map.count == 4)
            try map.put(.uint(10), forHash: Subject.hash(9))
            #expect(try map.count == 4, "a key that is there is not counted again")
            for index in 0..<3 {
                #expect(try map.remove(forHash: Subject.hash(index)))
            }
            #expect(try map.remove(forHash: Subject.hash(9)))
            #expect(try map.count == 0)
            #expect(try !map.remove(forHash: Subject.hash(0)))
            #expect(try !map.remove(forHash: Subject.hash(9)))
            #expect(try map.count == 0)
        }
        #expect(try committed(subject.database).count == 3)
    }

    /// The count says the map holds as many entries as a number can.
    @Test(arguments: StorageKind.allCases)
    func aCountAtTheLargestNumber(kind: StorageKind) throws {
        let subject = try Subject(kind)
        let database = try subject.damaged(bigEndianBytes(UInt64.max), at: subject.countPtr)
        try inTransaction(database) { map in
            // the count was copied into the transaction with the root block
            #expect(try map.count == .max)
            let length = try subject.subject.storage.length
            // A count that cannot grow is damage whatever the key: a put is
            // reported before the trie is written to, for a new key and for
            // one that is there (C4).
            #expect(throws: XitDBError.invalidCount) { try map.put(.uint(9), forHash: Subject.hash(9)) }
            #expect(throws: XitDBError.invalidCount) { try map.put(.uint(9), forHash: Subject.hash(0)) }
            #expect(throws: XitDBError.invalidCount) { try map.putCursor(forHash: Subject.hash(0)) }
            #expect(throws: XitDBError.invalidCount) { try map.putKey(.bytes([1]), forHash: Subject.hash(9)) }
            #expect(try subject.subject.storage.length == length)
            // the entries are still read, and a remove counts down from the
            // number
            #expect(try map.cursor(forHash: Subject.hash(0))?.readUInt64() == 0)
            #expect(try map.remove(forHash: Subject.hash(0)))
            #expect(try map.count == .max - 1)
        }
        let reader = try committed(database)
        #expect(try reader.count == .max)
        #expect(try reader.cursor(forHash: Subject.hash(0))?.readUInt64() == 0)
    }

    /// The count says the map is empty; the trie holds three entries.
    @Test(arguments: StorageKind.allCases)
    func aCountOfZeroWithEntries(kind: StorageKind) throws {
        let subject = try Subject(kind)
        let database = try subject.damaged(bigEndianBytes(0), at: subject.countPtr)
        try inTransaction(database) { map in
            #expect(try map.count == 0)
            // A count of nothing is right for an empty map, so only finding
            // the key proves it wrong: a remove of a key that is there is
            // reported, one of a key that is not is not damage.
            #expect(throws: XitDBError.invalidCount) { try map.remove(forHash: Subject.hash(0)) }
            #expect(try !map.remove(forHash: Subject.hash(9)))
            // a put counts up from the number it finds
            try map.put(.uint(9), forHash: Subject.hash(9))
            #expect(try map.count == 1)
        }
        let reader = try committed(database)
        #expect(try reader.count == 0)
        #expect(try reader.cursor(forHash: Subject.hash(1))?.readUInt64() == 1)
    }
}
