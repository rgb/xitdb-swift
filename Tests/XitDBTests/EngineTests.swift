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

        // todos was appended to twice, had "Wash the car" inserted at 1, and
        // then a map inserted at 1 and removed again
        let todos = try value(moment, "todos")
        #expect(try todos.slot().tag == .linkedArrayList)
        #expect(try todos.count() == 3)
        let todoTexts = try (0..<3).map { try text(try #require(try todos.readPath([.linkedArrayListGet($0)]))) }
        #expect(todoTexts == ["Pay the bills", "Wash the car", "Get an oil change"])
        #expect(try todos.readPath([.linkedArrayListGet(3)]) == nil)
        #expect(try todos.readPath([.linkedArrayListGet(-4)]) == nil)
        #expect(try text(try #require(try todos.readPath([.linkedArrayListGet(-1)]))) == "Get an oil change")
        // each is longer than eight bytes, so none is in its slot
        for index in Int64(0)..<3 {
            #expect(try #require(try todos.readPathSlot([.linkedArrayListGet(index)])).tag == .bytes)
        }

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

        // todos was concatenated with itself, cut down to its second and
        // third elements, and had the second of those removed
        let todos = try value(moment, "todos")
        #expect(try todos.slot().tag == .linkedArrayList)
        #expect(try todos.count() == 1)
        #expect(try text(try #require(try todos.readPath([.linkedArrayListGet(0)]))) == "Wash the car")
        #expect(try text(try #require(try todos.readPath([.linkedArrayListGet(-1)]))) == "Wash the car")
        #expect(try todos.readPath([.linkedArrayListGet(1)]) == nil)
        #expect(try todos.readPath([.linkedArrayListGet(-2)]) == nil)
        // the element's bytes are shared with the first moment
        let firstTodos = try value(try self.moment(0), "todos")
        #expect(
            try todos.readPathSlot([.linkedArrayListGet(0)]) == (try firstTodos.readPathSlot([.linkedArrayListGet(1)])))

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
/// lines 69 to 109). In the hash map half Zig uses the `HashMap` wrapper,
/// each of whose methods is one path call; the path calls are written out
/// here. The linked array list half uses the collection, as Zig does.
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

    /// test.zig 98-108: the linked array list half.
    @Test func aLinkedArrayListAtTheRoot() throws {
        let storage = MemoryStorage(maxSize: 50000)
        let database = try Database(storage: storage, hashSize: 20)

        let list = try LinkedArrayList<ReadWrite>(database.rootCursor())
        try list.append(.uint(1))
        #expect(try list.count() == 1)
    }
}

/// Edges of the engine that neither the Zig tests nor the conformance
/// scripts reach.
@Suite struct EngineEdgeTests {
    private func makeDatabase(_ storage: MemoryStorage = MemoryStorage()) throws -> Database {
        try Database(
            storage: storage, hashSize: 20, hashID: nil, fileID: 3, random: FixedRandom((1...50).map { UInt64($0) }))
    }

    /// Any byte array can be read as a key on its own, which is what an
    /// entry of a sorted set is: the key is the slot itself, there is no
    /// value, no position to write through, and no hash.
    @Test func bytesReadAsAKeyOnlyEntry() throws {
        let database = try makeDatabase()
        try database.runContext { cursor in
            _ = try cursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("short")), .write(.bytes([1, 2, 3]))])
            _ = try cursor.writePath([
                .hashMapGet(.value, sha1("long")), .write(.bytes([UInt8](repeating: 9, count: 30))),
            ])
            for key in ["short", "long"] {
                let entry = try cursor.writePath([.hashMapGet(.value, sha1(key))])
                let pair = try entry.readKeyValuePair()
                #expect(pair.hash == [UInt8](repeating: 0, count: 20))
                #expect(try pair.keyCursor.slot() == (try entry.slot()))
                #expect(try pair.keyCursor.readBytesAlloc() == (try entry.readBytesAlloc()))
                #expect(try pair.valueCursor.slot().isEmpty)
                // neither can be written through
                var key = pair.keyCursor
                var value = pair.valueCursor
                #expect(throws: XitDBError.cursorNotWriteable) { try key.write(.uint(1)) }
                #expect(throws: XitDBError.cursorNotWriteable) { try value.write(.uint(1)) }
            }
        }
    }

    /// An entry of a sorted map points at a pair with no hash: a key slot
    /// and a value slot. Sorted maps arrive with a later milestone, so the
    /// record is made by hand here.
    @Test func aSortedPairReadsWithoutAHash() throws {
        let database = try makeDatabase()
        try database.runContext { cursor in
            _ = try cursor.writePath([.hashMapInit()])
            // eighteen bytes: a key slot (short bytes "k") and a value slot (uint 7)
            let record =
                slotBytes(Slot(value: 0x6B00_0000_0000_0000, tag: .shortBytes)) + slotBytes(Slot(value: 7, tag: .uint))
            var holder = try cursor.writePath([.hashMapGet(.value, sha1("record"))])
            try holder.writer { writer in try writer.write(record) }
            // the record's bytes start after the byte array's length
            let pairPosition = try holder.slot().value + 8

            let entry = try cursor.writePath([
                .hashMapGet(.value, sha1("entry")), .write(.slot(Slot(value: pairPosition, tag: .sortedKvPair))),
            ])
            let pair = try entry.readKeyValuePair()
            #expect(pair.hash == [UInt8](repeating: 0, count: 20))
            #expect(try pair.keyCursor.readBytesAlloc() == Array("k".utf8))
            #expect(try pair.valueCursor.readUint() == 7)

            // the value's position is right after the key's, with no hash before them
            var value = pair.valueCursor
            try value.write(.uint(8))
            #expect(try entry.readKeyValuePair().valueCursor.readUint() == 8)
            #expect(try holder.readBytesAlloc() == Array(record[..<9]) + slotBytes(Slot(value: 8, tag: .uint)))
        }
    }

    @Test func removingAMissingKeyLeavesACountedMapsCount() throws {
        let database = try makeDatabase()
        try database.runContext { cursor in
            let map = try cursor.writePath([.hashMapInit(counted: true)])
            _ = try map.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(1))])
            _ = try map.writePath([.hashMapGet(.value, sha1("b")), .write(.uint(2))])
            #expect(try map.count() == 2)

            #expect(throws: XitDBError.keyNotFound) { try map.writePath([.hashMapRemove(sha1("missing"))]) }
            #expect(try map.count() == 2)
            // getting an entry that exists does not count it again
            _ = try map.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(3))])
            _ = try map.writePath([.hashMapGet(.key, sha1("a"))])
            #expect(try map.count() == 2)

            _ = try map.writePath([.hashMapRemove(sha1("a"))])
            #expect(try map.count() == 1)
            #expect(throws: XitDBError.keyNotFound) { try map.writePath([.hashMapRemove(sha1("a"))]) }
            #expect(try map.count() == 1)
        }
        #expect(try database.rootCursor().count() == 1)
        // an init of the other kind is refused
        #expect(throws: XitDBError.unexpectedTag) {
            try database.rootCursor().writePath([.hashMapInit(), .write(.uint(1))])
        }
        #expect(throws: XitDBError.unexpectedTag) {
            try database.rootCursor().writePath([.arrayListInit, .arrayListAppend])
        }
        #expect(try database.rootCursor().count() == 1)
    }

    /// A transaction on a root that is a sorted map or set would have to
    /// run that collection's init part first, to copy it into the
    /// transaction. That part arrives with milestone M6. Until then such a
    /// transaction is refused; going on without the init part would write
    /// into committed data.
    @Test(arguments: [XitDB.Tag.sortedMap, .sortedSet])
    func aTransactionOnARootOfACollectionNotBuiltYetIsRefused(tag: XitDB.Tag) throws {
        let storage = MemoryStorage()
        let database = try makeDatabase(storage)
        // a root that claims to be such a collection
        var root = database.rootCursor()
        try root.write(.slot(Slot(value: 37, tag: tag)))
        let committed = storage.bytes
        #expect(try database.rootCursor().slot().tag == tag)

        #expect(throws: XitDBError.notImplemented) { try database.rootCursor().writePath([.write(.uint(1))]) }
        #expect(throws: XitDBError.notImplemented) { try database.runContext { _ in } }
        #expect(storage.bytes == committed)
        // reading its count, which is in its header, works
        _ = try database.rootCursor().count()
    }

    /// A slot's position is computed from offsets in the file. In a sound
    /// file no slot is at the root header's position, which is how a cursor
    /// at the root is told from any other. A file that leads a write path
    /// there is corrupt, and the write is refused.
    @Test func aPathThatArrivesAtTheRootHeaderIsRefused() throws {
        let storage = MemoryStorage()
        let database = try makeDatabase(storage)
        var listPosition: UInt64 = 0
        try database.runContext { cursor in
            let list = try cursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("list")), .arrayListInit])
            _ = try list.writePath([.arrayListAppend, .write(.uint(1))])
            listPosition = try list.slot().value
        }

        // the list's header now says its index block is at the root header
        var bytes = storage.bytes
        bytes.replaceSubrange(Int(listPosition + 8)..<Int(listPosition + 16), with: bigEndianBytes(RootHeader.position))
        let damaged = MemoryStorage(bytes: bytes)
        let reopened = try makeDatabase(damaged)

        try reopened.runContext { cursor in
            // without the init part, the element's slot is where the header says: at the root header
            #expect(throws: XitDBError.invalidDatabase) {
                try cursor.writePath([.hashMapGet(.value, sha1("list")), .arrayListGet(0), .write(.uint(9))])
            }
        }
        // the root header was not written to
        #expect(Array(damaged.bytes[20..<29]) != slotBytes(Slot(value: 9, tag: .uint)))
        // and a read there just reads the root again
        let list = try #require(try reopened.rootCursor().readPath([.hashMapGet(.value, sha1("list"))]))
        #expect(try list.readPath([.arrayListGet(0)]) != nil)
    }

    /// A hash trie works to the full depth its hash allows: 128 levels for
    /// a hash of sixty-four bytes. Zig counts the depth in a byte that it
    /// multiplies by four, which overflows at level 64 (finding 7 of the
    /// director's list of Zig behaviours to correct), so two keys that share
    /// their low 256 bits crash it. Here they are stored, read and removed.
    @Test(arguments: StorageKind.allCases)
    func aTrieOfSixtyFourByteHashesGoesToItsFullDepth(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(
            storage: subject.storage, hashSize: 64, hashID: nil, fileID: 3,
            random: FixedRandom((1...9).map { UInt64($0) }))

        // Every level of the trie takes four bits, from the low end of the
        // hash. `differing(at:)` is the base hash with the four bits of one
        // level changed, so it shares exactly that many levels with the base.
        let base = [UInt8](repeating: 0x55, count: 64)
        func differing(at level: Int) -> KeyHash {
            var bytes = base
            let index = 63 - level / 2
            bytes[index] = level % 2 == 0 ? (bytes[index] & 0xF0) | 0x0A : (bytes[index] & 0x0F) | 0xA0
            return KeyHash(bytes)
        }
        let keys: [(hash: KeyHash, value: UInt64)] = [
            (KeyHash(base), 1), (differing(at: 0), 2), (differing(at: 63), 3), (differing(at: 64), 4),
            (differing(at: 127), 5),
        ]

        func values(_ map: Cursor<ReadWrite>) throws -> [UInt64?] {
            try keys.map { try map.readPath([.hashMapGet(.value, $0.hash)])?.readUint() }
        }
        /// How many index blocks lie between the map's root block and the
        /// base hash's pair.
        func depthOfBase(_ map: Cursor<ReadWrite>) throws -> Int {
            var position = try map.slot().value
            var depth = 0
            while true {
                let slot = try database.reader.slot(at: position + 9 * 5)
                if slot.tag != .index { return depth }
                position = slot.value
                depth += 1
            }
        }

        try database.runContext { cursor in
            let map = try cursor.writePath([.hashMapInit()])
            for key in keys {
                _ = try map.writePath([.hashMapGet(.value, key.hash), .write(.uint(key.value))])
            }
            #expect(try values(map) == [1, 2, 3, 4, 5])
            // the base hash and the one that differs in the last four bits
            // share 127 levels, and sit side by side in the block below them
            #expect(try depthOfBase(map) == 127)

            _ = try map.writePath([.hashMapRemove(keys[4].hash)])
            #expect(try values(map) == [1, 2, 3, 4, nil])
            #expect(try depthOfBase(map) == 64)
            _ = try map.writePath([.hashMapRemove(keys[3].hash)])
            #expect(try values(map) == [1, 2, 3, nil, nil])
            #expect(try depthOfBase(map) == 63)
            _ = try map.writePath([.hashMapRemove(keys[2].hash)])
            #expect(try depthOfBase(map) == 0)
            #expect(try values(map) == [1, 2, nil, nil, nil])

            // and back to the full depth, in the other order
            _ = try map.writePath([.hashMapGet(.value, keys[4].hash), .write(.uint(50))])
            _ = try map.writePath([.hashMapGet(.value, keys[3].hash), .write(.uint(40))])
            #expect(try values(map) == [1, 2, nil, 40, 50])
            #expect(try depthOfBase(map) == 127)
        }
        // committed, and read back through a new database on the same bytes
        let moment = database.rootCursor()
        #expect(try moment.readPath([.hashMapGet(.value, keys[4].hash)])?.readUint() == 50)
        #expect(try moment.readPath([.hashMapGet(.value, keys[2].hash)]) == nil)
    }

    /// A pair's record has the same bytes for every hash size: the hash, the
    /// key slot, the value slot. Up to sixty-four bytes of hash it is built
    /// in place, beyond that in an array.
    @Test(arguments: [1, 8, 20, 32, 63, 64, 65, 100])
    func aPairRecordIsTheHashAndItsTwoSlots(hashSize: Int) throws {
        let storage = MemoryStorage()
        let database = try Database(
            storage: storage, hashSize: UInt16(hashSize), hashID: nil, fileID: 3, random: FixedRandom([1, 2]))
        let hashBytes = (0..<hashSize).map { UInt8(truncatingIfNeeded: 0xA0 &+ $0) }
        let pair = KeyValuePair(
            keySlot: Slot(value: 0x0102_0304_0506_0708, tag: .bytes, full: true),
            valueSlot: Slot(value: .max - 1, tag: .uint)
        )
        let position = try storage.length()
        try database.write(pair, hash: KeyHash(hashBytes), at: position)

        let expected = encoded(capacity: hashSize + 18) { pair.encodeHashed(hash: hashBytes.span, into: &$0) }
        #expect(Array(storage.bytes[Int(position)...]) == expected)
        #expect(expected.count == hashSize + 18)
        let read = try database.reader.hashedPair(at: position)
        #expect(read.pair == pair)
        #expect(read.hash == KeyHash(hashBytes))
    }

    /// The committed size in the root header must leave room for a trailer
    /// after the two headers. A smaller one is refused even when the bytes
    /// that end there pass for a trailer.
    @Test func aCommittedSizeThatReachesIntoTheHeadersIsRefused() throws {
        let storage = MemoryStorage()
        _ = try makeDatabase(storage)
        var bytes = storage.bytes
        try #require(bytes.count == 62)

        // A size of 60 puts the trailer at 35, over the last two bytes of
        // the size itself. Those read as the tag of an empty slot and the
        // first byte of its value, so a checksum can be made to fit.
        bytes.replaceSubrange(29..<37, with: bigEndianBytes(60))
        var crc = CRC64XZ()
        crc.updateBigEndian(3 as UInt64)
        crc.updateBigEndian(35 as UInt64)
        crc.update(bytes.span, at: 35, count: 17)
        bytes.replaceSubrange(52..<60, with: bigEndianBytes(crc.checksum))
        let trailer = try RootTrailer(decoding: bytes.span, at: 35, fileID: 3, position: 35)
        #expect(trailer.root.tag == .none)

        #expect(throws: XitDBError.invalidDatabase) {
            let database = try Database(
                storage: MemoryStorage(bytes: bytes), hashSize: 20, hashID: nil, fileID: nil, random: FixedRandom([1]))
            _ = try database.committedSize()
        }
    }

    /// The engine's writer of a byte array is refused once its transaction
    /// has ended, as Zig's is. A cursor's `writer` cannot get there, because
    /// its writer does not outlive the call, but the engine does not rely
    /// on that.
    @Test func aRecordWriterKeptPastItsTransactionIsRefused() throws {
        final class Kept {
            var writer: ByteRecordWriter?
            var slotPosition: UInt64?
        }
        let storage = MemoryStorage()
        let database = try makeDatabase(storage)
        let kept = Kept()
        let first: [UInt8] = [1, 2, 3]
        try database.runContext { cursor in
            let slot = try cursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("bytes"))])
            var writer = try ByteRecordWriter(database: database, at: slot.slotPointer)
            try writer.write(first.span)
            kept.slotPosition = slot.slotPointer.position
            kept.writer = consume writer
        }
        let committed = storage.bytes

        guard var writer = kept.writer.take() else {
            Issue.record("the writer was not kept")
            return
        }
        do throws(XitDBError) {
            try writer.write(first.span)
            Issue.record("a write after the transaction was accepted")
        } catch {
            #expect(error == .expectedTxStart)
        }
        do throws(XitDBError) {
            _ = try writer.finish(slotPosition: kept.slotPosition)
            Issue.record("the array was finished after the transaction")
        } catch {
            #expect(error == .expectedTxStart)
        }
        #expect(storage.bytes == committed)
    }

    /// Removing the only entry of an inner block of a map's trie leaves the
    /// block nothing to hold, and the slot above it is emptied, as in Zig.
    /// The engine never leaves a block with one entry itself; here one is
    /// made by writing to a slot of the trie.
    @Test func removingTheOnlyEntryOfAnInnerBlockEmptiesTheSlotAboveIt() throws {
        let database = try makeDatabase()
        // two hashes that share the four bits the trie looks at first, and
        // differ in the next four
        let first = KeyHash([UInt8](repeating: 0xAA, count: 19) + [0x00])
        let second = KeyHash([UInt8](repeating: 0xBB, count: 19) + [0x10])
        try database.runContext { cursor in
            let map = try cursor.writePath([.hashMapInit()])
            _ = try map.writePath([.hashMapGet(.value, first), .write(.uint(1))])
            _ = try map.writePath([.hashMapGet(.value, second), .write(.uint(2))])
            let rootBlock = try map.slot().value
            let inner = try database.reader.slot(at: rootBlock)
            #expect(inner.tag == .index)

            _ = try map.writePath([.hashMapGet(.kvPair, second), .write(.slot(nil))])
            let gone = try map.readPath([.hashMapGet(.value, second)])
            #expect(gone == nil)
            let kept = try map.readPath([.hashMapGet(.value, first)])
            #expect(try kept?.readUint() == 1)

            let size = try database.storage.length()
            _ = try map.writePath([.hashMapRemove(first)])
            let emptied = try database.reader.slot(at: rootBlock)
            #expect(emptied == Slot())
            #expect(try database.storage.length() == size)
        }
    }
}

/// What is copied and what is changed in place, and what a transaction
/// commits: the parts of the engine where a mistake leaves every value
/// reading back right and only the file different. Each of these was a gap
/// found by changing the engine's source and seeing no test fail.
@Suite struct CopyOnWriteTests {
    let storage = MemoryStorage()
    let random = FixedRandom((1...50).map { UInt64($0) })

    private func makeDatabase() throws -> Database {
        try Database(storage: storage, hashSize: 20, hashID: nil, fileID: 4, random: random)
    }

    /// Data the transaction makes right at a cursor's freeze point is newer
    /// than the freeze, and is changed in place.
    @Test func dataMadeRightAtACursorsFreezePointIsNotCopied() throws {
        let database = try makeDatabase()
        try database.runContext { cursor in
            var slot = try cursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("list"))])
            try slot.freeze()
            let frozenAt = UInt64(storage.bytes.count)

            let list = try slot.writePath([.arrayListInit])
            #expect(try list.slot().value == frozenAt)
            let again = try slot.writePath([.arrayListInit])
            #expect(try again.slot().value == frozenAt)
            #expect(UInt64(storage.bytes.count) == frozenAt + 16 + 144)
        }
    }

    /// The same for the database's freeze: what is made right after it
    /// belongs to the transaction.
    @Test func dataMadeRightAfterTheDatabaseIsFrozenIsNotCopied() throws {
        let database = try makeDatabase()
        try database.runContext { cursor in
            let slot = try cursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("list"))])
            let before = try slot.writePath([.arrayListInit])
            try database.freeze()
            let frozenAt = UInt64(storage.bytes.count)

            // the list made before the freeze is copied now, to the freeze point
            let copied = try slot.writePath([.arrayListInit])
            #expect(try copied.slot().value == frozenAt)
            #expect(try copied.slot().value != (try before.slot().value))
            // and the copy is the transaction's own
            let again = try slot.writePath([.arrayListInit])
            #expect(try again.slot().value == frozenAt)
            #expect(UInt64(storage.bytes.count) == frozenAt + 16 + 144)
        }
    }

    /// The cursor a callback is given has the freeze point of the cursor the
    /// path was called on: what that cursor froze is copied by writes in the
    /// callback too.
    @Test func aCallbacksCursorInheritsTheFreezePoint() throws {
        let database = try makeDatabase()
        try database.runContext { cursor in
            var slot = try cursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("list"))])
            let original = try slot.writePath([.arrayListInit])
            try slot.freeze()

            _ = try slot.writePath([.ctx]) { inner in
                let copy = try inner.writePath([.arrayListInit])
                #expect(try copy.slot().value != (try original.slot().value))
            }

            // a cursor that did not freeze still changes the list in place
            let unfrozen = try cursor.writePath([.hashMapGet(.value, sha1("list"))])
            let current = try unfrozen.slot().value
            _ = try unfrozen.writePath([.ctx]) { inner in
                let inPlace = try inner.writePath([.arrayListInit])
                #expect(try inPlace.slot().value == current)
            }
        }
    }

    /// Cutting a list down across a change of depth makes one of its lower
    /// blocks the new root. That block may belong to an earlier moment, and
    /// roots are written to directly, so it is copied first.
    @Test func aSliceThatMakesTheListShallowerLeavesThePastAlone() throws {
        let database = try makeDatabase()
        let root = database.rootCursor()
        _ = try root.writePath([.arrayListInit, .arrayListAppend, .arrayListInit, .ctx]) { list in
            for index in 0..<20 {
                _ = try list.writePath([.arrayListAppend, .write(.uint(UInt64(index)))])
            }
        }
        let first = try root.readPathSlot([.arrayListGet(-1)])
        _ = try root.writePath([.arrayListInit, .arrayListAppend, .write(.slot(first)), .arrayListInit, .ctx]) { list in
            _ = try list.writePath([.arrayListSlice(size: 5)])
            _ = try list.writePath([.arrayListGet(0), .write(.uint(99))])
            _ = try list.writePath([.arrayListAppend, .write(.uint(100))])
        }

        let past = try #require(try root.readPath([.arrayListGet(0)]))
        #expect(try past.count() == 20)
        for index in 0..<20 {
            #expect(try #require(try past.readPath([.arrayListGet(Int64(index))])).readUint() == UInt64(index))
        }
        let present = try #require(try root.readPath([.arrayListGet(1)]))
        #expect(try present.count() == 6)
        let values = try (0..<6).map { try #require(try present.readPath([.arrayListGet($0)])).readUint() }
        #expect(values == [99, 1, 2, 3, 4, 100])
    }

    @Test func aSliceToTheCurrentSizeChangesNothingAndALargerOneFails() throws {
        let database = try makeDatabase()
        try database.runContext { cursor in
            let list = try cursor.writePath([.arrayListInit])
            for index in 0..<3 {
                _ = try list.writePath([.arrayListAppend, .write(.uint(UInt64(index)))])
            }
            _ = try list.writePath([.arrayListSlice(size: 3)])
            #expect(try list.count() == 3)
            #expect(throws: XitDBError.keyNotFound) { try list.writePath([.arrayListSlice(size: 4)]) }
            #expect(try list.count() == 3)
            _ = try list.writePath([.arrayListSlice(size: 0)])
            #expect(try list.count() == 0)
            #expect(try list.readPath([.arrayListGet(0)]) == nil)
        }
    }

    // MARK: What a transaction commits

    /// A transaction that writes nothing still commits, and the root it
    /// commits is the one it started from.
    @Test func aTransactionThatWritesNothingKeepsTheRoot() throws {
        let database = try makeDatabase()
        // on an empty root
        try database.runContext { _ in }
        #expect(try database.rootCursor().slot().isEmpty)
        #expect(try database.committedSize() == 62 + 9 + 25)

        // on a root that is a plain value
        var root = database.rootCursor()
        try root.write(.uint(5))
        let size = try database.committedSize()
        try database.runContext { _ in }
        #expect(try database.rootCursor().readUint() == 5)
        #expect(try database.committedSize() == size + 9 + 25)
    }

    static let initParts: [PathPart] = [
        .arrayListInit,
        .hashMapInit(counted: false, set: false),
        .hashMapInit(counted: false, set: true),
        .hashMapInit(counted: true, set: false),
        .hashMapInit(counted: true, set: true),
    ]

    /// For every kind of collection: initialising a root that already is
    /// that collection commits nothing and draws no commit ID, and a
    /// transaction on such a root leaves it the kind it was.
    @Test(arguments: 0..<5)
    func initialisingAnInitialisedRootIsFreeForEveryCollection(partIndex: Int) throws {
        let part = Self.initParts[partIndex]
        let database = try makeDatabase()
        let created = try database.rootCursor().writePath([part])
        let tag = try created.slot().tag
        #expect(tag == part.initTag)
        let size = try database.committedSize()
        let drawn = random.remaining

        let again = try database.rootCursor().writePath([part])
        #expect(try again.slot() == (try created.slot()))
        #expect(try database.committedSize() == size)
        #expect(random.remaining == drawn)

        // a transaction on it: the root is copied by its own init part, and
        // stays the kind of collection it was
        try database.runContext { cursor in
            if tag == .arrayList {
                _ = try cursor.writePath([.arrayListAppend, .write(.uint(1))])
            } else {
                _ = try cursor.writePath([.hashMapGet(.key, sha1("k")), .write(.uint(1))])
            }
        }
        #expect(try database.rootCursor().slot().tag == tag)
        #expect(random.remaining == drawn - 1)
        if tag != .hashMap && tag != .hashSet {
            #expect(try database.rootCursor().count() == 1)
        }

        // any other init is a transaction, and is refused or changes the root
        let other = Self.initParts[(partIndex + 1) % 5]
        let before = try database.committedSize()
        _ = try? database.rootCursor().writePath([other])
        if try database.committedSize() != before {
            #expect(try database.rootCursor().slot().tag == other.initTag)
        }
    }

    /// Initialising an initialised root also discards what an unfinished
    /// transaction left after the committed size, without committing.
    @Test func aFreeInitDiscardsLeftoverBytes() throws {
        let database = try makeDatabase()
        _ = try database.rootCursor().writePath([.arrayListInit, .arrayListAppend, .write(.uint(1))])
        let committed = storage.bytes

        let leftover = MemoryStorage(bytes: committed + [UInt8](repeating: 0xAB, count: 40))
        let reopened = try Database(storage: leftover, hashSize: 20, hashID: nil, fileID: nil, random: random)
        let drawn = random.remaining
        #expect(leftover.bytes.count == committed.count + 40)

        _ = try reopened.rootCursor().writePath([.arrayListInit])
        #expect(leftover.bytes == committed)
        #expect(random.remaining == drawn)
    }

    // MARK: Cursors

    /// Reading from the root gives a cursor pinned to the root slot in the
    /// trailer of the commit it was read from.
    @Test func aCursorReadFromTheRootIsAtTheTrailersSlot() throws {
        let database = try makeDatabase()
        _ = try database.rootCursor().writePath([.hashMapInit(), .hashMapGet(.value, sha1("a")), .write(.uint(1))])
        let pinned = try #require(try database.rootCursor().readPath([]))
        let position = try #require(pinned.slotPointer.position)
        #expect(position == (try database.committedSize()) - 25)
        #expect(try database.reader.slot(at: position) == (try pinned.slot()))

        // a later commit does not move it
        _ = try database.rootCursor().writePath([.hashMapInit(), .hashMapGet(.value, sha1("b")), .write(.uint(2))])
        #expect(try pinned.readPath([.hashMapGet(.value, sha1("b"))]) == nil)
        #expect(try database.rootCursor().readPath([.hashMapGet(.value, sha1("b"))]) != nil)
    }

    /// A cursor at an entry of a map is at the slot of the map's trie that
    /// points at the entry, in a read path and in a write path.
    @Test func aCursorAtAnEntryIsAtTheTriesSlot() throws {
        let database = try makeDatabase()
        try database.runContext { cursor in
            _ = try cursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("a")), .write(.uint(1))])
            let written = try cursor.writePath([.hashMapGet(.kvPair, sha1("a"))])
            let writtenPosition = try #require(written.slotPointer.position)
            #expect(try database.reader.slot(at: writtenPosition) == (try written.slot()))
            #expect(try written.slot().tag == .kvPair)
        }
        let read = try #require(try database.rootCursor().readPath([.hashMapGet(.kvPair, sha1("a"))]))
        let readPosition = try #require(read.slotPointer.position)
        #expect(try database.reader.slot(at: readPosition) == (try read.slot()))
    }

    /// `writeIfEmpty` on a root cursor looks at the root as it is now, not
    /// at what the cursor saw when it was made.
    @Test func writeIfEmptyOnARootCursorSeesTheCurrentRoot() throws {
        let database = try makeDatabase()
        var kept = database.rootCursor()
        var other = database.rootCursor()
        try other.write(.uint(1))

        try kept.writeIfEmpty(.uint(2))
        #expect(try database.rootCursor().readUint() == 1)
    }

    @Test func aHashOfTheWrongSizeIsRefused() throws {
        let database = try makeDatabase()
        let short = KeyHash([1, 2, 3])
        let long = KeyHash([UInt8](repeating: 1, count: 21))
        _ = try database.rootCursor().writePath([.hashMapInit(counted: true)])
        for hash in [short, long] {
            #expect(throws: XitDBError.invalidHashSize) {
                try database.rootCursor().readPath([.hashMapGet(.value, hash)])
            }
            #expect(throws: XitDBError.invalidHashSize) {
                try database.rootCursor().writePath([.hashMapGet(.value, hash), .write(.uint(1))])
            }
            #expect(throws: XitDBError.invalidHashSize) { try database.rootCursor().writePath([.hashMapRemove(hash)]) }
        }
        #expect(try database.rootCursor().count() == 0)
    }

    // MARK: Counts that cannot be right

    /// A count that would overflow or go below zero comes from a damaged
    /// file. It is reported, and nothing is changed.
    @Test func aCountThatCannotChangeIsReported() throws {
        let database = try makeDatabase()
        var mapPosition = 0
        var listPosition = 0
        try database.runContext { cursor in
            let map = try cursor.writePath([
                .hashMapInit(), .hashMapGet(.value, sha1("map")), .hashMapInit(counted: true),
            ])
            _ = try map.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(1))])
            mapPosition = Int(try map.slot().value)
            let list = try cursor.writePath([.hashMapGet(.value, sha1("list")), .arrayListInit])
            _ = try list.writePath([.arrayListAppend, .write(.uint(1))])
            listPosition = Int(try list.slot().value)
        }

        func damaged(at position: Int, _ value: UInt64) throws -> Database {
            var bytes = storage.bytes
            bytes.replaceSubrange(position..<(position + 8), with: bigEndianBytes(value))
            return try Database(
                storage: MemoryStorage(bytes: bytes), hashSize: 20, hashID: nil, fileID: nil, random: random)
        }
        let countedMap: [PathPart] = [.hashMapGet(.value, sha1("map")), .hashMapInit(counted: true)]

        // a counted map that says it is full to the last number
        let full = try damaged(at: mapPosition, .max)
        try full.runContext { cursor in
            #expect(throws: XitDBError.invalidDatabase) {
                try cursor.writePath(countedMap + [.hashMapGet(.value, sha1("new")), .write(.uint(2))])
            }
        }
        // and one that says it is empty, with an entry in it
        let empty = try damaged(at: mapPosition, 0)
        try empty.runContext { cursor in
            #expect(throws: XitDBError.invalidDatabase) {
                try cursor.writePath(countedMap + [.hashMapRemove(sha1("a"))])
            }
        }
        // a list that says it has as many elements as there are numbers
        let endless = try damaged(at: listPosition, .max)
        try endless.runContext { cursor in
            #expect(throws: XitDBError.self) {
                try cursor.writePath([.hashMapGet(.value, sha1("list")), .arrayListInit, .arrayListAppend])
            }
        }
    }
}
