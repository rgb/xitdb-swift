import Testing

@testable import XitDB

@Suite struct NewDatabaseTests {
    /// The bytes of a new database with a fixed file ID, as pinned in the
    /// Zig test `testReplication` (test.zig lines 3999 to 4012): the header,
    /// which ends with the file ID, the root header, and the trailer for the
    /// empty root.
    @Test(arguments: StorageKind.allCases)
    func aNewDatabaseHasTheBytesZigPins(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(
            storage: subject.storage,
            hashSize: 20,
            hashID: nil,
            fileID: 0x0102_0304_0506_0708,
            random: FixedRandom()
        )
        try subject.storage.flush()
        let bytes = try subject.stored()

        #expect(bytes.count == 62)
        #expect(Array(bytes[12..<20]) == [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        #expect(
            Array(bytes[37...]) == [
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0xd6, 0x18, 0x4e, 0x46, 0xb4, 0x7d, 0x29,
                0x26,
            ]
        )
        // the rest: magic, padding, version 1, hash size 20, no hash ID, and
        // a root header with an empty root and the committed size 62
        #expect(Array(bytes[..<12]) == [0x78, 0x69, 0x74, 0x00, 0x00, 0x01, 0x00, 0x14, 0, 0, 0, 0])
        #expect(Array(bytes[20..<37]) == zeros(9) + [0, 0, 0, 0, 0, 0, 0, 62])

        #expect(database.header.version == 1)
        #expect(database.header.hashSize == 20)
        #expect(database.header.hashID == HashID(id: 0))
        #expect(database.header.fileID == 0x0102_0304_0506_0708)
        #expect(try database.committedSize() == 62)
        #expect(try database.rootCursor().slot().isEmpty)
        #expect(try database.rootCursor().count() == 0)
    }

    /// Creating a database asks the random source for nothing when the file
    /// ID is given, and for exactly the file ID when it is not.
    @Test func theFileIDComesFromTheRandomSourceOnlyWhenNotGiven() throws {
        let unused = FixedRandom([99])
        _ = try Database(storage: MemoryStorage(), hashSize: 20, hashID: nil, fileID: 5, random: unused)
        #expect(unused.remaining == 1)

        let used = FixedRandom([0xAABB_CCDD_0011_2233])
        let database = try Database(storage: MemoryStorage(), hashSize: 20, hashID: nil, fileID: nil, random: used)
        #expect(used.remaining == 0)
        #expect(database.header.fileID == 0xAABB_CCDD_0011_2233)

        // the public initialiser draws a file ID of its own
        let first = try Database(storage: MemoryStorage(), hashSize: 20)
        let second = try Database(storage: MemoryStorage(), hashSize: 20)
        #expect(first.header.fileID != second.header.fileID)
    }

    /// R15: a new database needs a hash size; an existing one is opened with
    /// the size in its header unless one is stated, and a disagreement is an
    /// error.
    @Test func theHashSizeIsRequiredToCreateAndCheckedToOpen() throws {
        #expect(throws: XitDBError.invalidHashSize) { try Database(storage: MemoryStorage()) }

        let storage = MemoryStorage()
        _ = try Database(storage: storage, hashSize: 32, hashID: HashID(bytes: [0x73, 0x68, 0x61, 0x32]))
        let reopened = try Database(storage: storage)
        #expect(reopened.header.hashSize == 32)
        #expect(reopened.header.hashID == HashID(bytes: [0x73, 0x68, 0x61, 0x32]))
        #expect(try Database(storage: storage, hashSize: 32).header.hashSize == 32)
        #expect(throws: XitDBError.invalidHashSize) { try Database(storage: storage, hashSize: 20) }
        // a hash ID or file ID given when opening is not written anywhere
        let ignored = try Database(storage: storage, hashSize: nil, hashID: HashID(id: 1), fileID: 2)
        #expect(ignored.header.hashID == reopened.header.hashID)
        #expect(ignored.header.fileID == reopened.header.fileID)
        #expect(storage.bytes.count == 62)
    }

    @Test func aStorageThatIsNotADatabaseIsRejected() throws {
        #expect(throws: XitDBError.endOfStream) { try Database(storage: MemoryStorage(bytes: [1, 2, 3])) }
        #expect(throws: XitDBError.invalidDatabase) {
            try Database(storage: MemoryStorage(bytes: [UInt8](repeating: 0, count: 62)))
        }

        let good = MemoryStorage()
        _ = try Database(storage: good, hashSize: 20)
        // a header and no root header
        #expect(throws: XitDBError.endOfStream) {
            try Database(storage: MemoryStorage(bytes: Array(good.bytes[..<30])))
        }
        // the last byte of the trailer is missing
        #expect(throws: XitDBError.truncatedDatabase) {
            try Database(storage: MemoryStorage(bytes: Array(good.bytes.dropLast())))
        }
        // a trailer that does not check out
        var corrupt = good.bytes
        corrupt[61] ^= 0x01
        #expect(throws: XitDBError.invalidDatabase) { try Database(storage: MemoryStorage(bytes: corrupt)) }
    }
}

/// The shared fixture `test.db`, written by another implementation with
/// SHA-1 keys, read through the engine: every moment of it. It holds the two
/// transactions of the Zig test "high level api" (test.zig lines 221 to 500).
///
/// The elements of the `todos` linked array list are not read here: that
/// needs the linked array list's parts, which arrive with milestone M5. Its
/// count, which is in its header, is read.
@Suite struct FixtureDatabaseTests {
    let database: Database

    init() throws {
        database = try Database(storage: MemoryStorage(bytes: try FixtureTests.load()), hashSize: 20)
    }

    private func moment(_ index: Int64) throws -> Cursor<ReadOnly> {
        try #require(try database.rootCursor().readPath([.arrayListGet(index)]))
    }

    private func value(_ cursor: Cursor<ReadOnly>, _ key: String) throws -> Cursor<ReadOnly> {
        try #require(try cursor.readPath([.hashMapGet(.value, sha1(key))]))
    }

    private func text(_ cursor: Cursor<ReadOnly>) throws -> String {
        String(decoding: try cursor.readBytesAlloc(maxSize: 1024), as: UTF8.self)
    }

    @Test func theDatabaseOpensAndHasTwoMoments() throws {
        #expect(database.header.hashSize == 20)
        #expect(database.header.fileID == 0x172A_756F_2208_A5EC)
        #expect(try database.committedSize() == 8550)
        #expect(try database.rootCursor().slot() == Slot(value: 4847, tag: .arrayList))
        #expect(try database.rootCursor().count() == 2)
        #expect(try database.rootCursor().readPath([.arrayListGet(2)]) == nil)
        #expect(try database.rootCursor().readPath([.arrayListGet(-3)]) == nil)
        // the last moment by a negative index
        #expect(try #require(try database.rootCursor().readPath([.arrayListGet(-1)])).slot() == (try moment(1).slot()))
        #expect(try #require(try database.rootCursor().readPath([.arrayListGet(-2)])).slot() == (try moment(0).slot()))
    }

    @Test func theFirstMoment() throws {
        let moment = try moment(0)
        #expect(try moment.slot().tag == .hashMap)

        #expect(try text(try value(moment, "foo")) == "foo")
        #expect(try value(moment, "foo").slot().tag == .shortBytes)
        #expect(try text(try value(moment, "bar")) == "bar")
        #expect(try value(moment, "bar").slot().tag == .shortBytes)

        let fruits = try value(moment, "fruits")
        #expect(try fruits.count() == 3)
        let names = try (0..<3).map { try text(try #require(try fruits.readPath([.arrayListGet($0)]))) }
        #expect(names == ["apple", "pear", "grape"])
        #expect(try fruits.readPath([.arrayListGet(3)]) == nil)

        let people = try value(moment, "people")
        #expect(try people.count() == 2)
        let alice = try #require(try people.readPath([.arrayListGet(0)]))
        #expect(try text(try value(alice, "name")) == "Alice")
        #expect(try value(alice, "age").readUint() == 25)
        let bob = try #require(try people.readPath([.arrayListGet(1)]))
        #expect(try text(try value(bob, "name")) == "Bob")
        #expect(try value(bob, "age").readUint() == 42)
        // each person's keys were stored with their text
        for person in [alice, bob] {
            for key in ["name", "age"] {
                let keyCursor = try #require(try person.readPath([.hashMapGet(.key, sha1(key))]))
                #expect(try text(keyCursor) == key)
                let pair = try #require(try person.readPath([.hashMapGet(.kvPair, sha1(key))])).readKeyValuePair()
                #expect(pair.hash == sha1(key).bytes)
                #expect(try text(pair.keyCursor) == key)
            }
        }

        let todos = try value(moment, "todos")
        #expect(try todos.slot().tag == .linkedArrayList)
        #expect(try todos.count() == 3)

        let countedMap = try value(moment, "letters-counted-map")
        #expect(try countedMap.slot().tag == .countedHashMap)
        #expect(try countedMap.count() == 2)
        #expect(try value(countedMap, "a").readUint() == 2)
        #expect(try value(countedMap, "c").readUint() == 3)
        #expect(try countedMap.readPath([.hashMapGet(.value, sha1("b"))]) == nil)
        // a key is only written while it is empty, so "a" kept its first key
        #expect(try text(try #require(try countedMap.readPath([.hashMapGet(.key, sha1("a"))]))) == "a")

        let set = try value(moment, "letters-set")
        #expect(try set.slot().tag == .hashSet)
        let countedSet = try value(moment, "letters-counted-set")
        #expect(try countedSet.slot().tag == .countedHashSet)
        #expect(try countedSet.count() == 2)
        for letters in [set, countedSet] {
            #expect(try text(try #require(try letters.readPath([.hashMapGet(.key, sha1("a"))]))) == "a")
            #expect(try text(try #require(try letters.readPath([.hashMapGet(.key, sha1("c"))]))) == "c")
            #expect(try letters.readPath([.hashMapGet(.key, sha1("b"))]) == nil)
            // a set's entries have no value
            #expect(try letters.readPath([.hashMapGet(.value, sha1("a"))]) == nil)
            let pair = try #require(try letters.readPath([.hashMapGet(.kvPair, sha1("a"))])).readKeyValuePair()
            #expect(try pair.valueCursor.slot().isEmpty)
        }

        let number = try value(moment, "random-number").readBytesObjectAlloc()
        #expect(number.value.count == 32)
        #expect(number.formatTag.map { array($0) } == Array("bi".utf8))
        #expect(try value(moment, "random-number").slot().tag == .bytes)

        let longText = try value(moment, "long-text")
        #expect(try longText.count() == 700)
        #expect(try text(longText) == String(repeating: "hello, world!\n", count: 50))
        #expect(throws: XitDBError.streamTooLong) { try longText.readBytesAlloc(maxSize: 699) }
    }

    @Test func theSecondMoment() throws {
        let moment = try moment(1)

        #expect(try text(try value(moment, "foo")) == "foo")
        // bar was removed
        #expect(try moment.readPath([.hashMapGet(.value, sha1("bar"))]) == nil)
        #expect(try moment.readPathSlot([.hashMapGet(.value, sha1("bar"))]) == nil)

        // fruits got its key, its first element replaced and its last cut off
        let fruitsKey = try #require(try moment.readPath([.hashMapGet(.key, sha1("fruits"))]))
        #expect(try text(fruitsKey) == "fruits")
        #expect(try fruitsKey.slot().tag == .shortBytes)
        let fruits = try value(moment, "fruits")
        #expect(try fruits.count() == 2)
        let names = try (0..<2).map { try text(try #require(try fruits.readPath([.arrayListGet($0)]))) }
        #expect(names == ["lemon", "pear"])
        #expect(try fruits.readPath([.arrayListGet(2)]) == nil)
        let pair = try #require(try moment.readPath([.hashMapGet(.kvPair, sha1("fruits"))])).readKeyValuePair()
        #expect(try pair.keyCursor.slot().tag == .shortBytes)
        #expect(try pair.valueCursor.slot().tag == .arrayList)

        let people = try value(moment, "people")
        #expect(try people.count() == 2)
        let alice = try #require(try people.readPath([.arrayListGet(0)]))
        #expect(try value(alice, "age").readUint() == 26)
        #expect(try text(try value(alice, "name")) == "Alice")
        let bob = try #require(try people.readPath([.arrayListGet(1)]))
        #expect(try value(bob, "age").readUint() == 42)

        #expect(try value(moment, "todos").count() == 1)

        let countedMap = try value(moment, "letters-counted-map")
        #expect(try countedMap.count() == 1)
        #expect(try value(countedMap, "a").readUint() == 2)
        #expect(try countedMap.readPath([.hashMapGet(.value, sha1("c"))]) == nil)
        let set = try value(moment, "letters-set")
        #expect(try set.readPath([.hashMapGet(.key, sha1("a"))]) != nil)
        #expect(try set.readPath([.hashMapGet(.key, sha1("c"))]) == nil)
        let countedSet = try value(moment, "letters-counted-set")
        #expect(try countedSet.count() == 1)
        #expect(try countedSet.readPath([.hashMapGet(.key, sha1("c"))]) == nil)

        // what the second transaction did not touch is shared with the first
        let first = try self.moment(0)
        #expect(try value(moment, "random-number").slot() == (try value(first, "random-number").slot()))
        #expect(try value(moment, "long-text").slot() == (try value(first, "long-text").slot()))
    }

    /// The first moment still reads as it did before the second transaction.
    @Test func thePastIsUnchanged() throws {
        let first = try moment(0)
        #expect(try text(try value(first, "bar")) == "bar")
        #expect(try value(first, "fruits").count() == 3)
        let alice = try #require(try value(first, "people").readPath([.arrayListGet(0)]))
        #expect(try value(alice, "age").readUint() == 25)
        #expect(try first.readPath([.hashMapGet(.key, sha1("fruits"))]) == nil)
    }

    /// The fixture is also a valid database to go on writing to: a third
    /// transaction leaves the first two moments as they were.
    @Test func aThirdMomentCanBeAppended() throws {
        let storage = MemoryStorage(bytes: try FixtureTests.load())
        let database = try Database(storage: storage, hashSize: 20, hashID: nil, fileID: nil, random: FixedRandom([7]))
        let root = database.rootCursor()
        let last = try root.readPathSlot([.arrayListGet(-1)])
        _ = try root.writePath([.arrayListInit, .arrayListAppend, .write(.slot(last)), .hashMapInit(), .ctx]) {
            cursor in
            _ = try cursor.writePath([.hashMapGet(.value, sha1("foo")), .write(.bytes(Array("changed".utf8)))])
        }
        #expect(try root.count() == 3)
        #expect(Array(storage.bytes[37..<8550]) == Array(try FixtureTests.load()[37...]))

        let reopened = try Database(storage: storage, hashSize: 20)
        let third = try #require(try reopened.rootCursor().readPath([.arrayListGet(2)]))
        #expect(
            try #require(try third.readPath([.hashMapGet(.value, sha1("foo"))])).readBytesAlloc()
                == Array("changed".utf8))
        let second = try #require(try reopened.rootCursor().readPath([.arrayListGet(1)]))
        #expect(
            try #require(try second.readPath([.hashMapGet(.value, sha1("foo"))])).readBytesAlloc() == Array("foo".utf8))
        #expect(try #require(try third.readPath([.hashMapGet(.value, sha1("fruits"))])).count() == 2)
    }
}

/// Port of the Zig test "not using arraylist at the top level" (test.zig
/// lines 69 to 109), the hash map half. Zig uses the `HashMap` wrapper, each
/// of whose methods is one path call; the path calls are written out here.
///
/// The linked array list half (lines 98 to 108) waits for milestone M5.
@Suite struct NotUsingAnArrayListAtTheTopLevelTests {
    @Test func aHashMapAtTheRoot() throws {
        let storage = MemoryStorage(maxSize: 50000)
        let database = try Database(storage: storage, hashSize: 20)

        // HashMap.init on a root cursor
        let map = try database.rootCursor().writePath([.hashMapInit(counted: false, set: false)])
        // map.put
        _ = try map.writePath([.hashMapGet(.value, sha1("foo")), .write(.bytes(Array("foo".utf8)))])
        _ = try map.writePath([.hashMapGet(.value, sha1("bar")), .write(.bytes(Array("bar".utf8)))])

        // Every write to the root is a transaction, so a nested cursor
        // cannot be written to after it was returned.
        let innerMapCursor = try map.writePath([.hashMapGet(.value, sha1("inner-map"))])
        #expect(throws: XitDBError.expectedTxStart) {
            try innerMapCursor.writePath([.hashMapInit(counted: false, set: false)])
        }

        // not in the Zig test: what was written reads back
        let root = database.rootCursor()
        #expect(
            try #require(try root.readPath([.hashMapGet(.value, sha1("foo"))])).readBytesAlloc() == Array("foo".utf8))
        #expect(
            try #require(try root.readPath([.hashMapGet(.value, sha1("bar"))])).readBytesAlloc() == Array("bar".utf8))
    }
}
