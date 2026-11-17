import Testing

@testable import XitDB

/// A transaction of a test that rolls itself back.
private struct GivenUp: Error {}

/// The reader holds a count it finds in the file against how long the
/// storage is: more elements than the storage has room for is a count no
/// writer wrote. It asks the storage for its length only when a count does
/// not fit the length it knew last, and so it has to forget that length
/// when the storage becomes shorter under it: when a transaction that
/// failed is cut off, and when a copy from zero puts another database
/// there. Left as it was, the longer length would let a damaged count pass
/// that the storage as it is cannot hold.
///
/// This holds what this object itself does to its storage. A storage made
/// shorter by another object or another process is not seen: the length
/// then stays the longest one seen, and the check is the weaker for it,
/// nothing else.
@Suite struct LengthSetBackTests {
    /// A database whose root map has a list of one element under "list",
    /// and where that list's header is: its first eight bytes are its count.
    private static func withAList(_ storage: any WritableStorage) throws -> (database: Database, list: UInt64) {
        let database = try Database(
            storage: storage, hashSize: 20, hashID: nil, fileID: 5, random: FixedRandom((1...40).map { UInt64($0) }))
        var position: UInt64 = 0
        try database.withTransaction { cursor in
            let list = try cursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("list")), .arrayListInit])
            _ = try list.writePath([.arrayListAppend, .write(.uint(1))])
            position = try list.slot.value
        }
        return (database, position)
    }

    /// The count the database reads for its list.
    private static func count(_ database: Database) throws -> UInt64 {
        let list = try #require(try database.rootCursor.readOnly.readPath([.hashMapGet(.value, sha1("list"))]))
        return try ArrayList<ReadOnly>(list).count
    }

    /// Appends `count` elements to the list.
    private static func append(_ count: Int, _ cursor: inout Cursor<ReadWrite>) throws {
        let list = try cursor.writePath([.hashMapGet(.value, sha1("list")), .arrayListInit])
        for index in 0..<count {
            _ = try list.writePath([.arrayListAppend, .write(.uint(UInt64(index)))])
        }
    }

    /// A transaction makes the storage long, has counts held against it at
    /// that length, and fails; what it wrote is cut off. A count that the
    /// storage held before the cut and cannot hold after it is refused.
    @Test(arguments: StorageKind.allCases)
    func aCountIsHeldAgainstTheStorageAsARollbackLeftIt(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let (database, list) = try Self.withAList(subject.storage)
        let committed = try database.committedSize
        var long: UInt64 = 0
        #expect(throws: GivenUp.self) {
            try database.withTransaction { cursor in
                try Self.append(400, &cursor)
                // the list's count is read here, in the transaction, and
                // held against the storage as long as it is now: this is
                // where the reader comes to know the long length
                let list = try #require(try cursor.readPath([.hashMapGet(.value, sha1("list"))]))
                #expect(try ArrayList<ReadOnly>(list).count == 401)
                long = try subject.storage.length
                throw GivenUp()
            }
        }
        #expect(try subject.storage.length == committed)
        #expect(try Self.count(database) == 1)

        // a count of elements that the long storage had room for and the
        // storage as it is has not: nine bytes an element
        let damaged = committed / 9 + 1
        try #require(damaged * 9 > committed && damaged * 9 <= long)
        try writeBytes(subject.storage, bigEndianBytes(damaged), at: list)
        try subject.storage.flush()
        #expect(throws: XitDBError.invalidCount) { try Self.count(database) }
    }

    /// A copy from zero puts a shorter database where a long one was, in
    /// place or in a new file. A count that the old storage had room for
    /// and the new one has not is refused.
    @Test(arguments: StorageKind.allCases)
    func aCountIsHeldAgainstTheStorageAsACopyFromZeroLeftIt(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let (replica, _) = try Self.withAList(subject.storage)
        try replica.withTransaction { cursor in try Self.append(400, &cursor) }
        let long = try replica.committedSize
        #expect(try Self.count(replica) == 401)

        let (source, list) = try Self.withAList(MemoryStorage())
        let short = try source.committedSize
        try replica.applyReplicated(at: 0, bytes: try source.readCommitted(from: 0, to: short))
        #expect(try subject.storage.length == short)
        #expect(try Self.count(replica) == 1)

        let damaged = short / 9 + 1
        try #require(damaged * 9 > short && damaged * 9 <= long)
        try writeBytes(subject.storage, bigEndianBytes(damaged), at: list)
        try subject.storage.flush()
        #expect(throws: XitDBError.invalidCount) { try Self.count(replica) }
    }
}
