import Testing

@testable import XitDB

// A port of `testHighLevelApi` from the Zig original (`src/test.zig`, lines 216 to 957), of "hash map with u64
// hashes" (lines 2936 to 2954) and of `testIteratorFrom` (lines 3641 to 3755), through the public collections.
// Zig runs the first and the last once for each of the memory, file and buffered-file databases (test.zig 7-36
// and 3641-3670), so those tests take the storage kind as their argument; the u64 test runs on a memory
// database only, as in Zig.
//
// The comments inside the tests are Zig's. Zig's `history.appendContext(.{ .slot = ... }, Ctx{})` with a `Ctx`
// whose `run` method does the writing is `history.appendContext(.slot(...)) { cursor in ... }` here. Zig's
// allocator arguments and `defer allocator.free` lines have no counterpart, nor do the buffers it hands to
// `cursor.reader` and `cursor.writer`.
//
// Everything in those lines is ported. Nothing here compares bytes or lengths with a run of the Zig test, since
// the `random-number` bytes below are not Zig's, so the file differs from the first transaction on; what is here
// is every assertion Zig makes.
//
// Zig fills `random-number` with thirty-two bytes from its default PRNG seeded with 12345 (line 295) and never
// asserts on them, only on the format tag. Here they come from the SplitMix64 generator of the test support,
// seeded the same way; the bytes differ from Zig's.

/// Zig's "high level api" test: the collections, used as the readme shows.
@Suite struct HighLevelAPITests {
    /// The storage kinds of the three databases Zig runs the test for.
    static let storageKinds: [StorageKind] = [.memory, .file, .bufferedFile]

    /// Zig's `MAX_READ_BYTES`.
    private let maxReadBytes = 1024

    /// Zig's `error.UnexpectedTagType`.
    private struct UnexpectedTagType: Error {}

    /// The UTF-8 bytes of a string.
    private func utf8(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    /// Zig's `hashInt(text)`: the SHA-1 of the text, as the twenty bytes the collections take.
    private func hashInt(_ text: String) -> [UInt8] {
        sha1(text).bytes
    }

    /// Zig's `cursor.readBytes(&buffer)` with a buffer of `bufferSize` zero bytes: the part of the buffer that
    /// holds the value.
    private func readBytes<Access>(_ cursor: Cursor<Access>, bufferSize: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var span = buffer.mutableSpan
        let count = try cursor.readBytes(into: &span)
        return Array(buffer[..<count])
    }

    /// Zig's `cursor.readBytesObject(&buffer)` with a buffer of `bufferSize` zero bytes: the part of the buffer
    /// that holds the value, and the value's format tag.
    private func readBytesObject<Access>(_ cursor: Cursor<Access>, bufferSize: Int) throws -> Bytes {
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var span = buffer.mutableSpan
        let read = try cursor.readBytesObject(into: &span)
        return Bytes(Array(buffer[..<read.count]), formatTag: read.formatTag)
    }

    /// Zig's `reader.interface.readSliceShort(&buffer)` with a buffer of `size` zero bytes: the number of bytes
    /// read, and the buffer.
    private func readShort(_ reader: inout ByteReader, size: Int) throws -> (count: Int, buffer: [UInt8]) {
        var buffer = [UInt8](repeating: 0, count: size)
        var span = buffer.mutableSpan
        let count = try reader.read(into: &span)
        return (count, buffer)
    }

    /// test.zig 216-957: `testHighLevelApi`. The function is one database from start to finish, each block
    /// reading what the blocks before it wrote, so it is one test; its blocks are the methods below, in order.
    @Test(arguments: storageKinds)
    func highLevelApi(kind: StorageKind) throws {
        // init the db
        let subject = try StorageUnderTest(kind)
        var database = try Database(storage: subject.storage, hashSize: 20)

        try writesTheFirstTransaction(database)
        try changesTheDataInANewTransaction(database)
        try theOldDataHasNotChanged(database)
        try removesTheLastTransactionWithSlice(database)
        database = try opensTheDatabaseWithTrailingData(database, subject: subject, kind: kind)
        try clones(database)
        try mutatesAccidentallyWhenCloningInsideATransaction(database)
        try preventsAccidentalMutationWithFreezing(database)
        try buildsASecondaryIndexWithASortedMap(database)
    }

    /// test.zig 221-449: the first transaction, and reading the moment it makes.
    private func writesTheFirstTransaction(_ database: Database) throws {
        // to get the benefits of immutability, the top-level data structure
        // must be an ArrayList, so each transaction is stored as an item in it
        let history = try ArrayList<ReadWrite>(database.rootCursor)

        // this is how a transaction is executed. we call history.appendContext,
        // providing it with the most recent copy of the db and a context
        // object. the context object has a method that will run before the
        // transaction has completed. this method is where we can write
        // changes to the db. if any error happens in it, the transaction
        // will not complete and the db will be unaffected.
        try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)

            try moment.put(hashInt("foo"), .bytes(utf8("foo")))
            try moment.put(hashInt("bar"), .bytes(utf8("bar")))

            let fruitsCursor = try moment.putCursor(hashInt("fruits"))
            let fruits = try ArrayList<ReadWrite>(fruitsCursor)
            try fruits.append(.bytes(utf8("apple")))
            try fruits.append(.bytes(utf8("pear")))
            try fruits.append(.bytes(utf8("grape")))

            let peopleCursor = try moment.putCursor(hashInt("people"))
            let people = try ArrayList<ReadWrite>(peopleCursor)

            let aliceCursor = try people.appendCursor()
            let alice = try HashMap<ReadWrite>(aliceCursor)
            try alice.putKey(hashInt("name"), .bytes(utf8("name")))
            try alice.put(hashInt("name"), .bytes(utf8("Alice")))
            try alice.putKey(hashInt("age"), .bytes(utf8("age")))
            try alice.put(hashInt("age"), .uint(25))

            let bobCursor = try people.appendCursor()
            let bob = try HashMap<ReadWrite>(bobCursor)
            try bob.putKey(hashInt("name"), .bytes(utf8("name")))
            try bob.put(hashInt("name"), .bytes(utf8("Bob")))
            try bob.putKey(hashInt("age"), .bytes(utf8("age")))
            try bob.put(hashInt("age"), .uint(42))

            let todosCursor = try moment.putCursor(hashInt("todos"))
            let todos = try LinkedArrayList<ReadWrite>(todosCursor)
            try todos.append(.bytes(utf8("Pay the bills")))
            try todos.append(.bytes(utf8("Get an oil change")))
            try todos.insert(1, .bytes(utf8("Wash the car")))

            // make sure `insertCursor` works as well
            let todoCursor = try todos.insertCursor(1)
            _ = try HashMap<ReadWrite>(todoCursor)
            try todos.remove(1)

            let lettersCountedMapCursor = try moment.putCursor(hashInt("letters-counted-map"))
            let lettersCountedMap = try CountedHashMap<ReadWrite>(lettersCountedMapCursor)
            try lettersCountedMap.put(hashInt("a"), .uint(1))
            try lettersCountedMap.putKey(hashInt("a"), .bytes(utf8("a")))
            try lettersCountedMap.put(hashInt("a"), .uint(2))
            try lettersCountedMap.putKey(hashInt("a"), .bytes(utf8("b")))
            try lettersCountedMap.put(hashInt("c"), .uint(3))
            try lettersCountedMap.putKey(hashInt("c"), .bytes(utf8("c")))

            let lettersSetCursor = try moment.putCursor(hashInt("letters-set"))
            let lettersSet = try HashSet<ReadWrite>(lettersSetCursor)
            try lettersSet.put(hashInt("a"), .bytes(utf8("a")))
            try lettersSet.put(hashInt("a"), .bytes(utf8("a")))
            try lettersSet.put(hashInt("c"), .bytes(utf8("c")))

            let lettersCountedSetCursor = try moment.putCursor(hashInt("letters-counted-set"))
            let lettersCountedSet = try CountedHashSet<ReadWrite>(lettersCountedSetCursor)
            try lettersCountedSet.put(hashInt("a"), .bytes(utf8("a")))
            try lettersCountedSet.put(hashInt("a"), .bytes(utf8("a")))
            try lettersCountedSet.put(hashInt("c"), .bytes(utf8("c")))

            var prng = SeededGenerator(seed: 12345)
            var randomNumberBuffer: [UInt8] = []
            for _ in 0..<4 {
                randomNumberBuffer += bigEndianBytes(prng.next())
            }
            try moment.put(
                hashInt("random-number"),
                .bytes(randomNumberBuffer, formatTag: "bi")
            )

            var longTextCursor = try moment.putCursor(hashInt("long-text"))
            try longTextCursor.writer { writer in
                for _ in 0..<50 {
                    try writer.write(utf8("hello, world!\n"))
                }
            }
        }

        // get the most recent copy of the database, like a moment
        // in time. the -1 index will return the last index in the list.
        let momentCursor = try #require(try history.getCursor(-1))
        let moment = try HashMap<ReadOnly>(momentCursor)

        // we can read the value of "foo" from the map by getting
        // the cursor to "foo" and then calling readBytesAlloc on it
        let fooCursor = try #require(try moment.getCursor(hashInt("foo")))
        let fooValue = try fooCursor.readBytesAlloc(maxSize: maxReadBytes)
        #expect(fooValue == utf8("foo"))

        #expect(try #require(try moment.getSlot(hashInt("foo"))).tag == .shortBytes)
        #expect(try #require(try moment.getSlot(hashInt("bar"))).tag == .shortBytes)

        // to get the "fruits" list, we get the cursor to it and
        // then pass it to the ArrayList.init method
        let fruitsCursor = try #require(try moment.getCursor(hashInt("fruits")))
        let fruits = try ArrayList<ReadOnly>(fruitsCursor)
        #expect(try fruits.count() == 3)

        // now we can get the first item from the fruits list and read it
        let appleCursor = try #require(try fruits.getCursor(0))
        let appleValue = try appleCursor.readBytesAlloc(maxSize: maxReadBytes)
        #expect(appleValue == utf8("apple"))

        let peopleCursor = try #require(try moment.getCursor(hashInt("people")))
        let people = try ArrayList<ReadOnly>(peopleCursor)
        #expect(try people.count() == 2)

        let aliceCursor = try #require(try people.getCursor(0))
        let alice = try HashMap<ReadOnly>(aliceCursor)
        let aliceAgeCursor = try #require(try alice.getCursor(hashInt("age")))
        #expect(try aliceAgeCursor.readUint() == 25)

        let todosCursor = try #require(try moment.getCursor(hashInt("todos")))
        let todos = try LinkedArrayList<ReadOnly>(todosCursor)
        #expect(try todos.count() == 3)

        let todoCursor = try #require(try todos.getCursor(0))
        let todoValue = try todoCursor.readBytesAlloc(maxSize: maxReadBytes)
        #expect(todoValue == utf8("Pay the bills"))

        var fruitsIter = try fruits.iterator()
        while let fruitCursor = try fruitsIter.next() {
            _ = try readBytes(fruitCursor, bufferSize: 100)
        }

        var peopleIter = try people.iterator()
        while let personCursor = try peopleIter.next() {
            let person = try HashMap<ReadOnly>(personCursor)
            var personIter = try person.iterator()
            while let kvPairCursor = try personIter.next() {
                let kvPair = try kvPairCursor.readKeyValuePair()
                _ = try readBytes(kvPair.keyCursor, bufferSize: 100)

                switch try kvPair.valueCursor.slot().tag {
                case .shortBytes, .bytes:
                    _ = try readBytes(kvPair.valueCursor, bufferSize: 100)
                case .uint: _ = try kvPair.valueCursor.readUint()
                case .int: _ = try kvPair.valueCursor.readInt()
                case .float: _ = try kvPair.valueCursor.readFloat()
                default: throw UnexpectedTagType()
                }
            }
        }

        do {
            let lettersCountedMapCursor = try #require(try moment.getCursor(hashInt("letters-counted-map")))
            let lettersCountedMap = try CountedHashMap<ReadOnly>(lettersCountedMapCursor)
            #expect(try lettersCountedMap.count() == 2)

            var iter = try lettersCountedMap.iterator()
            var count = 0
            while let kvPairCursor = try iter.next() {
                let kvPair = try kvPairCursor.readKeyValuePair()
                _ = try readBytes(kvPair.keyCursor, bufferSize: 8)
                count += 1
            }
            #expect(count == 2)
        }

        do {
            let lettersSetCursor = try #require(try moment.getCursor(hashInt("letters-set")))
            let lettersSet = try HashSet<ReadOnly>(lettersSetCursor)
            #expect(try lettersSet.getCursor(hashInt("a")) != nil)
            #expect(try lettersSet.getCursor(hashInt("c")) != nil)

            var iter = try lettersSet.iterator()
            var count = 0
            while let kvPairCursor = try iter.next() {
                let kvPair = try kvPairCursor.readKeyValuePair()
                _ = try readBytes(kvPair.keyCursor, bufferSize: 8)
                count += 1
            }
            #expect(count == 2)
        }

        do {
            let lettersCountedSetCursor = try #require(try moment.getCursor(hashInt("letters-counted-set")))
            let lettersCountedSet = try CountedHashSet<ReadOnly>(lettersCountedSetCursor)
            #expect(try lettersCountedSet.count() == 2)

            var iter = try lettersCountedSet.iterator()
            var count = 0
            while let kvPairCursor = try iter.next() {
                let kvPair = try kvPairCursor.readKeyValuePair()
                _ = try readBytes(kvPair.keyCursor, bufferSize: 8)
                count += 1
            }
            #expect(count == 2)
        }

        do {
            let randomNumberCursor = try #require(try moment.getCursor(hashInt("random-number")))
            let randomNumber = try readBytesObject(randomNumberCursor, bufferSize: 32)
            let formatTag = try #require(randomNumber.formatTag)
            #expect(formatTag == "bi")
        }

        do {
            let longTextCursor = try #require(try moment.getCursor(hashInt("long-text")))
            var reader = try longTextCursor.reader()
            // Zig: `while (try reader.interface.takeDelimiter('\n')) |_| count += 1`, which gives each line
            // up to its newline, and what follows the last newline if anything does
            var count = 0
            var lineStarted = false
            while true {
                let read = try readShort(&reader, size: 1024)
                if read.count == 0 { break }
                for byte in read.buffer[..<read.count] {
                    if byte == UInt8(ascii: "\n") {
                        count += 1
                        lineStarted = false
                    } else {
                        lineStarted = true
                    }
                }
            }
            if lineStarted { count += 1 }
            #expect(count == 50)
        }
    }

    /// test.zig 451-558: "make a new transaction and change the data".
    private func changesTheDataInANewTransaction(_ database: Database) throws {
        let history = try ArrayList<ReadWrite>(database.rootCursor)

        try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)

            #expect(try moment.remove(hashInt("bar")))
            #expect(try !moment.remove(hashInt("doesn't exist")))

            // this associates the hash of "fruits" with the actual string.
            // hash maps use hashes directly as keys so they are not able
            // to get the original bytes of the key unless we store it
            // explicitly this way.
            try moment.putKey(hashInt("fruits"), .bytes(utf8("fruits")))

            let fruitsCursor = try moment.putCursor(hashInt("fruits"))
            let fruits = try ArrayList<ReadWrite>(fruitsCursor)
            try fruits.put(0, .bytes(utf8("lemon")))
            try fruits.slice(2)

            let peopleCursor = try moment.putCursor(hashInt("people"))
            let people = try ArrayList<ReadWrite>(peopleCursor)

            let aliceCursor = try people.putCursor(0)
            let alice = try HashMap<ReadWrite>(aliceCursor)
            try alice.put(hashInt("age"), .uint(26))

            let todosCursor = try moment.putCursor(hashInt("todos"))
            let todos = try LinkedArrayList<ReadWrite>(todosCursor)
            try todos.concat(try todosCursor.slot())
            try todos.slice(offset: 1, size: 2)
            try todos.remove(1)

            let lettersCountedMapCursor = try moment.putCursor(hashInt("letters-counted-map"))
            let lettersCountedMap = try CountedHashMap<ReadWrite>(lettersCountedMapCursor)
            _ = try lettersCountedMap.remove(hashInt("b"))
            _ = try lettersCountedMap.remove(hashInt("c"))

            let lettersSetCursor = try moment.putCursor(hashInt("letters-set"))
            let lettersSet = try HashSet<ReadWrite>(lettersSetCursor)
            _ = try lettersSet.remove(hashInt("b"))
            _ = try lettersSet.remove(hashInt("c"))

            let lettersCountedSetCursor = try moment.putCursor(hashInt("letters-counted-set"))
            let lettersCountedSet = try CountedHashSet<ReadWrite>(lettersCountedSetCursor)
            _ = try lettersCountedSet.remove(hashInt("b"))
            _ = try lettersCountedSet.remove(hashInt("c"))
        }

        let momentCursor = try #require(try history.getCursor(-1))
        let moment = try HashMap<ReadOnly>(momentCursor)

        #expect(try moment.getCursor(hashInt("bar")) == nil)

        let fruitsKeyCursor = try #require(try moment.getKeyCursor(hashInt("fruits")))
        let fruitsKeyValue = try fruitsKeyCursor.readBytesAlloc(maxSize: maxReadBytes)
        #expect(fruitsKeyValue == utf8("fruits"))

        let fruitsCursor = try #require(try moment.getCursor(hashInt("fruits")))
        let fruits = try ArrayList<ReadOnly>(fruitsCursor)
        #expect(try fruits.count() == 2)

        // you can get both the key and value cursor this way
        let fruitsKvCursor = try #require(try moment.getKeyValuePair(hashInt("fruits")))
        #expect(try fruitsKvCursor.keyCursor.slot().tag == .shortBytes)
        #expect(try fruitsKvCursor.valueCursor.slot().tag == .arrayList)

        let lemonCursor = try #require(try fruits.getCursor(0))
        let lemonValue = try lemonCursor.readBytesAlloc(maxSize: maxReadBytes)
        #expect(lemonValue == utf8("lemon"))

        let peopleCursor = try #require(try moment.getCursor(hashInt("people")))
        let people = try ArrayList<ReadOnly>(peopleCursor)
        #expect(try people.count() == 2)

        let aliceCursor = try #require(try people.getCursor(0))
        let alice = try HashMap<ReadOnly>(aliceCursor)
        let aliceAgeCursor = try #require(try alice.getCursor(hashInt("age")))
        #expect(try aliceAgeCursor.readUint() == 26)

        let todosCursor = try #require(try moment.getCursor(hashInt("todos")))
        let todos = try LinkedArrayList<ReadOnly>(todosCursor)
        #expect(try todos.count() == 1)

        let todoCursor = try #require(try todos.getCursor(0))
        let todoValue = try todoCursor.readBytesAlloc(maxSize: maxReadBytes)
        #expect(todoValue == utf8("Wash the car"))

        let lettersCountedMapCursor = try #require(try moment.getCursor(hashInt("letters-counted-map")))
        let lettersCountedMap = try CountedHashMap<ReadOnly>(lettersCountedMapCursor)
        #expect(try lettersCountedMap.count() == 1)

        let lettersSetCursor = try #require(try moment.getCursor(hashInt("letters-set")))
        let lettersSet = try HashSet<ReadOnly>(lettersSetCursor)
        #expect(try lettersSet.getCursor(hashInt("a")) != nil)
        #expect(try lettersSet.getCursor(hashInt("b")) == nil)

        let lettersCountedSetCursor = try #require(try moment.getCursor(hashInt("letters-counted-set")))
        let lettersCountedSet = try CountedHashSet<ReadOnly>(lettersCountedSetCursor)
        #expect(try lettersCountedSet.count() == 1)
    }

    /// test.zig 560-601: "the old data hasn't changed".
    private func theOldDataHasNotChanged(_ database: Database) throws {
        let history = try ArrayList<ReadWrite>(database.rootCursor)

        let momentCursor = try #require(try history.getCursor(0))
        let moment = try HashMap<ReadOnly>(momentCursor)

        let fooCursor = try #require(try moment.getCursor(hashInt("foo")))
        let fooValue = try fooCursor.readBytesAlloc(maxSize: maxReadBytes)
        #expect(fooValue == utf8("foo"))

        #expect(try #require(try moment.getSlot(hashInt("foo"))).tag == .shortBytes)
        #expect(try #require(try moment.getSlot(hashInt("bar"))).tag == .shortBytes)

        let fruitsCursor = try #require(try moment.getCursor(hashInt("fruits")))
        let fruits = try ArrayList<ReadOnly>(fruitsCursor)
        #expect(try fruits.count() == 3)

        let appleCursor = try #require(try fruits.getCursor(0))
        let appleValue = try appleCursor.readBytesAlloc(maxSize: maxReadBytes)
        #expect(appleValue == utf8("apple"))

        let peopleCursor = try #require(try moment.getCursor(hashInt("people")))
        let people = try ArrayList<ReadOnly>(peopleCursor)
        #expect(try people.count() == 2)

        let aliceCursor = try #require(try people.getCursor(0))
        let alice = try HashMap<ReadOnly>(aliceCursor)
        let aliceAgeCursor = try #require(try alice.getCursor(hashInt("age")))
        #expect(try aliceAgeCursor.readUint() == 25)

        let todosCursor = try #require(try moment.getCursor(hashInt("todos")))
        let todos = try LinkedArrayList<ReadOnly>(todosCursor)
        #expect(try todos.count() == 3)

        let todoCursor = try #require(try todos.getCursor(0))
        let todoValue = try todoCursor.readBytesAlloc(maxSize: maxReadBytes)
        #expect(todoValue == utf8("Pay the bills"))
    }

    /// test.zig 603-646: "remove the last transaction with `slice`".
    private func removesTheLastTransactionWithSlice(_ database: Database) throws {
        let history = try ArrayList<ReadWrite>(database.rootCursor)

        try history.slice(1)

        let momentCursor = try #require(try history.getCursor(-1))
        let moment = try HashMap<ReadOnly>(momentCursor)

        let fooCursor = try #require(try moment.getCursor(hashInt("foo")))
        let fooValue = try fooCursor.readBytesAlloc(maxSize: maxReadBytes)
        #expect(fooValue == utf8("foo"))

        #expect(try #require(try moment.getSlot(hashInt("foo"))).tag == .shortBytes)
        #expect(try #require(try moment.getSlot(hashInt("bar"))).tag == .shortBytes)

        let fruitsCursor = try #require(try moment.getCursor(hashInt("fruits")))
        let fruits = try ArrayList<ReadOnly>(fruitsCursor)
        #expect(try fruits.count() == 3)

        let appleCursor = try #require(try fruits.getCursor(0))
        let appleValue = try appleCursor.readBytesAlloc(maxSize: maxReadBytes)
        #expect(appleValue == utf8("apple"))

        let peopleCursor = try #require(try moment.getCursor(hashInt("people")))
        let people = try ArrayList<ReadOnly>(peopleCursor)
        #expect(try people.count() == 2)

        let aliceCursor = try #require(try people.getCursor(0))
        let alice = try HashMap<ReadOnly>(aliceCursor)
        let aliceAgeCursor = try #require(try alice.getCursor(hashInt("age")))
        #expect(try aliceAgeCursor.readUint() == 25)

        let todosCursor = try #require(try moment.getCursor(hashInt("todos")))
        let todos = try LinkedArrayList<ReadOnly>(todosCursor)
        #expect(try todos.count() == 3)

        let todoCursor = try #require(try todos.getCursor(0))
        let todoValue = try todoCursor.readBytesAlloc(maxSize: maxReadBytes)
        #expect(todoValue == utf8("Pay the bills"))
    }

    /// test.zig 648-688: "opening the db leaves trailing data alone". Zig writes the trailing data through the
    /// database's core and opens the database again on the same storage; here the data is written to the
    /// storage and a second database opened on it, which the rest of the test goes on with.
    private func opensTheDatabaseWithTrailingData(
        _ database: Database,
        subject: StorageUnderTest,
        kind: StorageKind
    ) throws -> Database {
        // opening the db leaves trailing data alone, because it may
        // belong to another writer's unfinished transaction. the next
        // write transaction truncates it before allocating new data.
        let sizeBefore = try subject.storage.length

        try writeBytes(subject.storage, utf8("this is trailing data from an unfinished transaction"), at: sizeBefore)
        try subject.storage.flush()
        let sizeWithTail = try subject.storage.length

        // no error is thrown if db file is opened in read-only mode
        switch kind {
        case .memory:
            break
        case .file:
            let file = try FileStorage(path: try #require(subject.path), access: .readOnly)
            _ = try Database(storage: file, hashSize: 20)
        case .bufferedFile, .bufferedFileSmallWindow:
            let file = try BufferedFileStorage(path: try #require(subject.path), access: .readOnly)
            _ = try Database(storage: file, hashSize: 20)
        }

        let reopened = try Database(storage: subject.storage, hashSize: 20)

        let sizeAfter = try subject.storage.length

        #expect(sizeWithTail == sizeAfter)

        _ = try ArrayList<ReadWrite>(reopened.rootCursor)
        #expect(try subject.storage.length == sizeBefore)

        return reopened
    }

    /// test.zig 690-726: "cloning".
    private func clones(_ database: Database) throws {
        let history = try ArrayList<ReadWrite>(database.rootCursor)

        try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)

            let fruitsCursor = try #require(try moment.getCursor(hashInt("fruits")))
            let fruits = try ArrayList<ReadOnly>(fruitsCursor)

            // create a new key called "food" whose initial value is
            // based on the "fruits" list
            var foodCursor = try moment.putCursor(hashInt("food"))
            try foodCursor.write(.slot(try fruits.slot()))

            let food = try ArrayList<ReadWrite>(foodCursor)
            try food.append(.bytes(utf8("eggs")))
            try food.append(.bytes(utf8("rice")))
            try food.append(.bytes(utf8("fish")))
        }

        let momentCursor = try #require(try history.getCursor(-1))
        let moment = try HashMap<ReadOnly>(momentCursor)

        // the food list includes the fruits
        let foodCursor = try #require(try moment.getCursor(hashInt("food")))
        let food = try ArrayList<ReadOnly>(foodCursor)
        #expect(try food.count() == 6)

        // ...but the fruits list hasn't been changed
        let fruitsCursor = try #require(try moment.getCursor(hashInt("fruits")))
        let fruits = try ArrayList<ReadOnly>(fruitsCursor)
        #expect(try fruits.count() == 3)
    }

    /// test.zig 728-770: "accidental mutation when cloning inside a transaction".
    private func mutatesAccidentallyWhenCloningInsideATransaction(_ database: Database) throws {
        let history = try ArrayList<ReadWrite>(database.rootCursor)

        let historyIndex = try history.count() - 1

        try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)

            let bigCitiesCursor = try moment.putCursor(hashInt("big-cities"))
            let bigCities = try ArrayList<ReadWrite>(bigCitiesCursor)
            try bigCities.append(.bytes(utf8("New York, NY")))
            try bigCities.append(.bytes(utf8("Los Angeles, CA")))

            // create a new key called "cities" whose initial value is
            // based on the "big-cities" list
            var citiesCursor = try moment.putCursor(hashInt("cities"))
            try citiesCursor.write(.slot(try bigCities.slot()))

            let cities = try ArrayList<ReadWrite>(citiesCursor)
            try cities.append(.bytes(utf8("Charleston, SC")))
            try cities.append(.bytes(utf8("Louisville, KY")))
        }

        let momentCursor = try #require(try history.getCursor(-1))
        let moment = try HashMap<ReadOnly>(momentCursor)

        // the cities list contains all four
        let citiesCursor = try #require(try moment.getCursor(hashInt("cities")))
        let cities = try ArrayList<ReadOnly>(citiesCursor)
        #expect(try cities.count() == 4)

        // ..but so does big-cities! we did not intend to mutate this
        let bigCitiesCursor = try #require(try moment.getCursor(hashInt("big-cities")))
        let bigCities = try ArrayList<ReadOnly>(bigCitiesCursor)
        #expect(try bigCities.count() == 4)

        // revert that change
        try history.append(.slot(try history.getSlot(Int64(historyIndex))))
    }

    /// The operations of the freeze-callback loop (test.zig 816).
    private enum FreezeOp {
        case append
        case slice
        case linkedGet
    }

    /// Zig's `List` in the freeze-callback loop (test.zig 832): `DB.LinkedArrayList(.read_write)` for
    /// `.linked_get`, `DB.ArrayList(.read_write)` for the other operations.
    private enum FreezeList {
        case array(ArrayList<ReadWrite>)
        case linked(LinkedArrayList<ReadWrite>)

        /// Zig's `List.init(cursor)`.
        init(_ op: FreezeOp, _ cursor: Cursor<ReadWrite>) throws {
            self =
                op == .linkedGet
                ? .linked(try LinkedArrayList<ReadWrite>(cursor)) : .array(try ArrayList<ReadWrite>(cursor))
        }

        var cursor: Cursor<ReadWrite> {
            switch self {
            case .array(let list): list.cursor
            case .linked(let list): list.cursor
            }
        }

        func append(_ data: WritableData) throws {
            switch self {
            case .array(let list): try list.append(data)
            case .linked(let list): try list.append(data)
            }
        }
    }

    /// test.zig 772-851: "preventing accidental mutation with freezing", with the freeze-callback loop.
    private func preventsAccidentalMutationWithFreezing(_ database: Database) throws {
        let history = try ArrayList<ReadWrite>(database.rootCursor)

        try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)

            let bigCitiesCursor = try moment.putCursor(hashInt("big-cities"))
            let bigCities = try ArrayList<ReadWrite>(bigCitiesCursor)
            try bigCities.append(.bytes(utf8("New York, NY")))
            try bigCities.append(.bytes(utf8("Los Angeles, CA")))

            // create a new key called "cities" whose initial value is
            // based on the "big-cities" list
            var citiesCursor = try moment.putCursor(hashInt("cities"))
            try citiesCursor.write(.slot(try bigCities.slot()))

            // freeze here, so writes to cities won't mutate big-cities
            // note: you can also freeze globally with `cursor.db.freeze()`,
            // but call it before `putCursor` creates the cities cursor
            try citiesCursor.freeze()

            let cities = try ArrayList<ReadWrite>(citiesCursor)
            try cities.append(.bytes(utf8("Charleston, SC")))
            try cities.append(.bytes(utf8("Louisville, KY")))
        }

        let momentCursor = try #require(try history.getCursor(-1))
        let moment = try HashMap<ReadOnly>(momentCursor)

        // the cities list contains all four
        let citiesCursor = try #require(try moment.getCursor(hashInt("cities")))
        let cities = try ArrayList<ReadOnly>(citiesCursor)
        #expect(try cities.count() == 4)

        // and big-cities only contains the original two
        let bigCitiesCursor = try #require(try moment.getCursor(hashInt("big-cities")))
        let bigCities = try ArrayList<ReadOnly>(bigCitiesCursor)
        #expect(try bigCities.count() == 2)

        // callbacks must see complete headers before freezing their collections
        for op in [FreezeOp.append, .slice, .linkedGet] {
            try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
                var map = try HashMap<ReadWrite>(cursor)
                try map.put(hashInt("freeze-callback"), .slot(nil))
                var list = try FreezeList(op, try map.putCursor(hashInt("freeze-callback")))
                try list.append(.uint(1))
                if op == .slice { try list.append(.uint(2)) }
                try database.freeze()
                map = try HashMap<ReadWrite>(map.cursor)
                list = try FreezeList(op, try map.putCursor(hashInt("freeze-callback")))
                // Zig's `FreezeCtx`, with the list's read-only cursor as its field
                let frozenList = list.cursor.readOnly()
                let path: [PathPart] =
                    switch op {
                    case .append: [.arrayListAppend, .write(.uint(2)), .ctx]
                    case .slice: [.arrayListSlice(size: 1), .ctx]
                    case .linkedGet: [.linkedArrayListGet(0), .write(.uint(2)), .ctx]
                    }
                _ = try list.cursor.writePath(path) { _ in
                    try database.freeze()
                    #expect(try frozenList.count() == (op == .append ? 2 : 1))
                    let get: PathPart = op == .linkedGet ? .linkedArrayListGet(0) : .arrayListGet(-1)
                    let value = try #require(try frozenList.readPath([get]))
                    #expect(try value.readUint() == (op == .slice ? 1 : 2))
                }
            }
        }
    }

    /// Zig's `User` (test.zig 859).
    private struct User {
        let id: String
        let username: String
        let name: String
    }

    /// test.zig 853-955: the secondary index, the "Sorting and Paginating" example of the readme. Zig's
    /// `hashInt(&user_id)` hashes the sixteen bytes read from the index's value; here they are decoded as the
    /// string they are, which hashes the same.
    private func buildsASecondaryIndexWithASortedMap(_ database: Database) throws {
        // build a secondary index with a SortedMap to sort and paginate,
        // like the "Sorting and Paginating" section of the readme
        let history = try ArrayList<ReadWrite>(database.rootCursor)

        let userIDSize = 16

        // inserted in arbitrary order; the index sorts them alphabetically
        let newUsers = [
            User(id: "user000000000001", username: "dave", name: "Dave Smith"),
            User(id: "user000000000002", username: "alice", name: "Alice Jones"),
            User(id: "user000000000003", username: "carol", name: "Carol White"),
            User(id: "user000000000004", username: "dan", name: "Dan Brown"),
            User(id: "user000000000005", username: "bob", name: "Bob Lee"),
            User(id: "user000000000006", username: "eve", name: "Eve Adams"),
        ]

        try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)

            // the primary store: a HashMap from user id to the user's fields
            let idToUserCursor = try moment.putCursor(hashInt("id->user"))
            let idToUser = try HashMap<ReadWrite>(idToUserCursor)

            // the secondary index: a SortedMap ordered alphabetically by username
            let usernameToIDCursor = try moment.putCursor(hashInt("username->id"))
            let usernameToID = try SortedMap<ReadWrite>(usernameToIDCursor)

            for user in newUsers {
                let userCursor = try idToUser.putCursor(hashInt(user.id))
                let userMap = try HashMap<ReadWrite>(userCursor)
                try userMap.put(hashInt("username"), .bytes(utf8(user.username)))
                try userMap.put(hashInt("name"), .bytes(utf8(user.name)))

                // the key is the username (the sort key); the value is the id
                try usernameToID.put(utf8(user.username), .bytes(utf8(user.id)))
            }
        }

        let momentCursor = try #require(try history.getCursor(-1))
        let moment = try HashMap<ReadOnly>(momentCursor)

        let idToUserCursor = try #require(try moment.getCursor(hashInt("id->user")))
        let idToUser = try HashMap<ReadOnly>(idToUserCursor)

        let usernameToIDCursor = try #require(try moment.getCursor(hashInt("username->id")))
        let usernameToID = try SortedMap<ReadOnly>(usernameToIDCursor)

        #expect(try usernameToID.count() == UInt64(newUsers.count))

        // page through the index two at a time and check we get every user back
        // in alphabetical order by username (not the order they were inserted)
        let pageSize: UInt64 = 2
        let expectedNames = ["Alice Jones", "Bob Lee", "Carol White", "Dan Brown", "Dave Smith", "Eve Adams"]

        let count = try usernameToID.count()
        var seen = 0
        var after: UInt64 = 0
        while after < count {
            let end = min(after + pageSize, count)
            var iter = try usernameToID.iteratorFromIndex(Int64(after))
            var i = after
            while i < end {
                let idCursor = try #require(try iter.next())
                let idKV = try idCursor.readKeyValuePair()
                let userID = try readBytes(idKV.valueCursor, bufferSize: userIDSize)

                let userCursor = try #require(try idToUser.getCursor(hashInt(String(decoding: userID, as: UTF8.self))))
                let userMap = try HashMap<ReadOnly>(userCursor)
                let nameCursor = try #require(try userMap.getCursor(hashInt("name")))
                let name = try readBytes(nameCursor, bufferSize: 64)
                #expect(name == utf8(expectedNames[seen]))
                seen += 1
                i += 1
            }
            after += pageSize
        }
        #expect(seen == newUsers.count)

        // autocomplete: seek straight to the first username >= "da", then walk
        // forward only while the prefix matches. this lower-bound seek by key is
        // the thing an ArrayList can't do.
        let prefix = "da"
        let expectedMatches = ["dan", "dave"]
        var matches = 0
        var acIter = try usernameToID.iteratorFrom(utf8(prefix))
        while let nextCursor = try acIter.next() {
            let idKV = try nextCursor.readKeyValuePair()
            let username = try readBytes(idKV.keyCursor, bufferSize: 64)
            if !username.starts(with: utf8(prefix)) { break }
            #expect(username == utf8(expectedMatches[matches]))
            matches += 1
        }
        #expect(matches == expectedMatches.count)
    }

    /// test.zig 2936-2954: "hash map with u64 hashes". Zig's `Database(.memory, u64)` is a database with a hash
    /// size of eight; a `u64` hash is its eight big-endian bytes.
    @Test func hashMapWithU64Hashes() throws {
        let database = try Database(storage: MemoryStorage(), hashSize: 8)
        let map = try HashMap<ReadWrite>(database.rootCursor)

        // the first two keys share all but their highest nibble, exercising
        // the full trie depth with the narrower shift type required by u64.
        let hashes: [UInt64] = [0, 1 << 60, .max]
        for (i, hash) in hashes.enumerated() {
            try map.put(bigEndianBytes(hash), .uint(UInt64(i)))
        }
        for (i, hash) in hashes.enumerated() {
            #expect(try #require(try map.getCursor(bigEndianBytes(hash))).readUint() == UInt64(i))
        }
        for hash in hashes {
            #expect(try map.remove(bigEndianBytes(hash)))
            #expect(try map.getCursor(bigEndianBytes(hash)) == nil)
        }
    }

    /// test.zig 3672-3755: `testIteratorFrom`.
    @Test(arguments: storageKinds)
    func iteratorFromIndex(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)
        let rootCursor = database.rootCursor

        // enough items to force several tiers in both the array-list radix trie
        // (16^2 = 256 > 200) and the linked-array-list b-tree
        let count: Int64 = 200

        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .hashMapInit(),
            .ctx,
        ]) { (cursor: inout Cursor<ReadWrite>) in
            let moment = try HashMap<ReadWrite>(cursor)

            let list = try ArrayList<ReadWrite>(try moment.putCursor(hashInt("list")))
            for i in 0..<count {
                try list.append(.uint(UInt64(i)))
            }

            let linked = try LinkedArrayList<ReadWrite>(try moment.putCursor(hashInt("linked")))
            for i in 0..<count {
                try linked.append(.uint(UInt64(i)))
            }
        }

        let history = try ArrayList<ReadOnly>(database.rootCursor.readOnly())
        let moment = try HashMap<ReadOnly>(try #require(try history.getCursor(-1)))
        let list = try ArrayList<ReadOnly>(try #require(try moment.getCursor(hashInt("list"))))
        let linked = try LinkedArrayList<ReadOnly>(try #require(try moment.getCursor(hashInt("linked"))))

        // iteratorFrom(k) yields exactly k, k+1, .., COUNT-1 in order, for both types.
        // negative indexes count from the end: -1 starts at the last element, -COUNT
        // at the first.
        let starts: [Int64] = [0, 1, 15, 16, 17, 100, count - 2, count - 1, -1, -2, -16, -100, -count]
        for start in starts {
            let resolved: UInt64 = start < 0 ? UInt64(count + start) : UInt64(start)
            do {
                var iter = try list.iteratorFrom(start)
                var expected = resolved
                while let c = try iter.next() {
                    #expect(try c.readUint() == expected)
                    expected += 1
                }
                #expect(expected == UInt64(count))
            }
            do {
                var iter = try linked.iteratorFrom(start)
                var expected = resolved
                while let c = try iter.next() {
                    #expect(try c.readUint() == expected)
                    expected += 1
                }
                #expect(expected == UInt64(count))
            }
        }

        // iteratorFrom(0) matches a plain iterator()
        do {
            var a = try list.iterator()
            var b = try list.iteratorFrom(0)
            while let ca = try a.next() {
                let cb = try #require(try b.next())
                #expect(try ca.readUint() == (try cb.readUint()))
            }
            let afterLast = try b.next()
            #expect(afterLast == nil)
        }

        // a start out of range (past the end, or more negative than -COUNT) yields nothing
        for start in [count, count + 1, count + 1000, -count - 1, -count - 1000] {
            var li = try list.iteratorFrom(start)
            let first = try li.next()
            #expect(first == nil)
            var ki = try linked.iteratorFrom(start)
            let firstLinked = try ki.next()
            #expect(firstLinked == nil)
        }
    }
}
