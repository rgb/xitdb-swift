import Testing

@testable import XitDB

/// A database's hash size is whatever its creator chose, up to 65,535
/// bytes, and a file's header may claim any. A key-value pair is the hash
/// and eighteen bytes more, so with hashes of more than 400 bytes it is
/// the largest block a database has, larger than a sorted map's branch of
/// 418 bytes.
///
/// Compaction once kept its blocks in room sized for that branch, and
/// trapped on the first pair of a longer hash: the fuzzer found it on a
/// version 1 file whose header a seed had damaged to claim a hash size of
/// 4,116, and a database created with a hash size of 401 could not be
/// compacted at all. Every release before 0.3.0 has the trap, 0.1.0 to
/// 0.2.1.
@Suite struct LargeHashTests {
    /// A hash of `size` bytes for a name: the SHA-1 of the name, repeated.
    static func hash(_ name: String, _ size: Int) -> [UInt8] {
        let digest = sha1(name).bytes
        return (0..<size).map { digest[$0 % digest.count] }
    }

    /// A history of two moments in a database with hashes of `hashSize`
    /// bytes. Each moment is a map with a value of every kind and every
    /// kind of collection in it, a map inside a map inside a map, so that
    /// pairs are copied while the pairs around them wait, and two keys
    /// whose hashes share their last five bytes, the ten digits a trie
    /// takes first, which puts ten index blocks between the map's and
    /// their pairs.
    static func fill(_ database: Database, hashSize: Int) throws {
        func key(_ name: String) -> [UInt8] { hash(name, hashSize) }
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        for round: UInt64 in 1...2 {
            try history.append(.slot(try history.slot(at: -1))) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                try moment.put(.uint(round), forHash: key("n"))
                try moment.put(
                    .bytes(utf8("a value longer than a slot holds, in round \(round)")), forHash: key("long"))
                try moment.putKey(.bytes(utf8("the key of long")), forHash: key("long"))

                let list = try ArrayList<ReadWrite>(try moment.putCursor(forHash: key("list")))
                for index in 0..<20 {
                    try list.append(.uint(UInt64(index) * round))
                }
                let linked = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: key("linked")))
                for index in 0..<20 {
                    try linked.append(.int(Int64(index) - 10))
                }
                let set = try HashSet<ReadWrite>(try moment.putCursor(forHash: key("set")))
                for name in ["one", "two", "three"] {
                    try set.insert(.bytes(utf8(name)), forHash: key(name))
                }
                let counted = try CountedHashMap<ReadWrite>(try moment.putCursor(forHash: key("counted")))
                for name in ["one", "two", "three"] {
                    try counted.put(.uint(round), forHash: key(name))
                }
                let sorted = try SortedMap<ReadWrite>(try moment.putCursor(forHash: key("sorted")))
                for index in 0..<40 {
                    try sorted.put(.uint(UInt64(index)), forKey: utf8("key \(index) of the sorted map"))
                }

                let outer = try HashMap<ReadWrite>(try moment.putCursor(forHash: key("outer")))
                let middle = try HashMap<ReadWrite>(try outer.putCursor(forHash: key("middle")))
                let inner = try HashMap<ReadWrite>(try middle.putCursor(forHash: key("inner")))
                try inner.put(.bytes(utf8("at the bottom, in round \(round)")), forHash: key("bottom"))
                let innerList = try ArrayList<ReadWrite>(try inner.putCursor(forHash: key("list")))
                try innerList.append(.uint(round))

                var near = key("near")
                try moment.put(.uint(1), forHash: near)
                near[hashSize - 6] ^= 0x01
                try moment.put(.uint(2), forHash: near)
            }
        }
    }

    /// A database with hashes at, just above and far above the size at
    /// which a pair outgrows a tree's blocks, up to the largest a header
    /// can name, is created, filled and compacted, on memory and on files;
    /// the target holds the source's last moment, read back whole, and
    /// reads the same when it is opened again.
    @Test(arguments: [400, 401, 512, 4116, 65535], [StorageKind.memory, .file, .bufferedFile])
    func aDatabaseOfAnyHashSizeCompacts(hashSize: Int, kind: StorageKind) throws {
        let sourceSubject = try StorageUnderTest(kind)
        let source = try Database(creating: sourceSubject.storage, hashSize: hashSize)
        try Self.fill(source, hashSize: hashSize)
        let sourceMoment = try #require(try ArrayList<ReadOnly>(source.rootCursor.readOnly).cursor(at: -1))
        let expected = try StructureWalk.describe(sourceMoment)
        #expect(try HashMap<ReadOnly>(sourceMoment).cursor(forHash: Self.hash("n", hashSize))?.readUInt64() == 2)

        let targetSubject = try StorageUnderTest(kind)
        var offsets = MemoryOffsetMap()
        let target = try source.compact(into: targetSubject.storage, fileID: 0x20, offsetMap: &offsets)
        #expect(Int(target.header.hashSize) == hashSize)
        #expect(try target.committedSize < source.committedSize)

        func lastMoment(_ database: Database) throws -> Cursor<ReadOnly> {
            let moments = try ArrayList<ReadOnly>(database.rootCursor.readOnly)
            #expect(try moments.count == 1)
            return try #require(try moments.cursor(at: 0))
        }
        #expect(try StructureWalk.describe(try lastMoment(target)) == expected)
        try targetSubject.storage.flush()
        let reopened = try Database(opening: targetSubject.storage, hashSize: hashSize)
        #expect(try StructureWalk.describe(try lastMoment(reopened)) == expected)

        // the pairs came across with their hashes: a lookup finds them
        let moment = try HashMap<ReadOnly>(try lastMoment(reopened))
        #expect(try moment.cursor(forHash: Self.hash("n", hashSize))?.readUInt64() == 2)
        var near = Self.hash("near", hashSize)
        #expect(try moment.cursor(forHash: near)?.readUInt64() == 1)
        near[hashSize - 6] ^= 0x01
        #expect(try moment.cursor(forHash: near)?.readUInt64() == 2)
        #expect(try moment.keyCursor(forHash: Self.hash("long", hashSize))?.readBytes() == utf8("the key of long"))

        // and the target is written to like any database
        try Self.fill(reopened, hashSize: hashSize)
        #expect(try ArrayList<ReadOnly>(reopened.rootCursor.readOnly).count == 3)
    }

    /// A header damaged to claim another hash size than its pairs have:
    /// opening without a stated size takes the header's word, and what
    /// reads a pair then reads the wrong bytes or past the end. Whatever
    /// the claim, compaction gives an error or a target, and never a trap.
    @Test(arguments: [1, 19, 21, 64, 65, 400, 401, 418, 419, 4116, 65535])
    func aHeaderThatClaimsAnotherHashSizeNeverTraps(claimed: Int) throws {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashSize: 20)
        try Self.fill(database, hashSize: 20)
        var bytes = storage.bytes
        bytes[6] = UInt8(claimed >> 8)
        bytes[7] = UInt8(claimed & 0xFF)

        let damaged = try Database(opening: MemoryStorage(bytes: bytes))
        #expect(Int(damaged.header.hashSize) == claimed)
        #expect(throws: XitDBError.invalidHashSize) { try Database(opening: MemoryStorage(bytes: bytes), hashSize: 20) }
        var offsets = MemoryOffsetMap()
        let target = MemoryStorage(maxSize: 1 << 24)
        let outcome = Result { try damaged.compact(into: target, offsetMap: &offsets) }
        if case .failure(let error) = outcome {
            #expect(error is XitDBError, "\(error)")
            // a compaction that fails commits nothing to its target
            #expect(target.bytes.count == 57)
        }
    }
}
