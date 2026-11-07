import Testing

@testable import XitDB

/// The shared fixture `test.db`, read through the public collections: the
/// same values that `FixtureDatabaseTests` reads through the path API, with
/// the maps, lists and sets, their iterators, `readKeyValuePair` and the
/// byte reader.
@Suite struct FixtureCollectionTests {
    let database: Database

    init() throws {
        database = try Database(storage: MemoryStorage(bytes: try FixtureTests.load()), hashSize: 20)
    }

    /// The SHA-1 of a key, as the collections take it.
    private func hash(_ key: String) -> [UInt8] {
        sha1(key).bytes
    }

    private func history() throws -> ArrayList<ReadOnly> {
        try ArrayList<ReadOnly>(database.rootCursor.readOnly())
    }

    private func moment(_ index: Int64) throws -> HashMap<ReadOnly> {
        try HashMap<ReadOnly>(try #require(try history().getCursor(index)))
    }

    private func value(_ map: HashMap<ReadOnly>, _ key: String) throws -> Cursor<ReadOnly> {
        try #require(try map.getCursor(hash(key)))
    }

    private func text(_ cursor: Cursor<ReadOnly>) throws -> String {
        String(decoding: try cursor.readBytesAlloc(maxSize: 1024), as: UTF8.self)
    }

    /// The texts of the elements an iterator gives.
    private func texts(_ iter: inout Cursor<ReadOnly>.Iter) throws -> [String] {
        var names: [String] = []
        while let element = try iter.next() {
            names.append(try text(element))
        }
        return names
    }

    /// The texts of a list's elements, through its iterator.
    private func texts(_ list: ArrayList<ReadOnly>) throws -> [String] {
        var iter = try list.iterator()
        return try texts(&iter)
    }

    /// The texts of a linked list's elements, through its iterator.
    private func texts(_ list: LinkedArrayList<ReadOnly>) throws -> [String] {
        var iter = try list.iterator()
        return try texts(&iter)
    }

    /// The hashes of a map's or set's entries, through its iterator.
    private func hashes(_ iter: inout Cursor<ReadOnly>.Iter) throws -> Set<[UInt8]> {
        var found: Set<[UInt8]> = []
        while let entry = try iter.next() {
            found.insert(try entry.readKeyValuePair().hash)
        }
        return found
    }

    @Test func theDatabaseOpensAndHasTwoMoments() throws {
        #expect(database.header.hashSize == 20)
        #expect(database.header.fileID == 0x172A_756F_2208_A5EC)
        #expect(try database.committedSize == 8550)

        let history = try ArrayList<ReadOnly>(database.rootCursor.readOnly())
        #expect(try history.slot() == Slot(value: 4847, tag: .arrayList))
        #expect(try history.count() == 2)
        #expect(try history.getCursor(2) == nil)
        #expect(try history.getCursor(-3) == nil)
        #expect(try history.getSlot(2) == nil)
        // the last moment by a negative index
        #expect(try #require(try history.getCursor(-1)).slot() == (try #require(try history.getCursor(1)).slot()))
        #expect(try #require(try history.getCursor(-2)).slot() == (try #require(try history.getCursor(0)).slot()))
        #expect(try history.getSlot(-1) == (try history.getSlot(1)))

        // the iterator gives the two moments in order, and from the second on, only that one
        var iter = try history.iterator()
        #expect(try #require(try iter.next()).slot() == (try history.getSlot(0)))
        #expect(try #require(try iter.next()).slot() == (try history.getSlot(1)))
        #expect(try iter.next() == nil)
        var fromLast = try history.iteratorFrom(-1)
        #expect(try #require(try fromLast.next()).slot() == (try history.getSlot(1)))
        #expect(try fromLast.next() == nil)

        // the root holds a list, not a map
        #expect(throws: XitDBError.unexpectedTag) { try HashMap<ReadOnly>(database.rootCursor.readOnly()) }
    }

    @Test func theFirstMoment() throws {
        let momentCursor = try #require(try history().getCursor(0))
        #expect(try momentCursor.slot().tag == .hashMap)
        let moment = try HashMap<ReadOnly>(momentCursor)
        // a map that keeps no count is not a counted one, and a hash set
        // view of it reads its keys
        #expect(throws: XitDBError.unexpectedTag) { try CountedHashMap<ReadOnly>(momentCursor) }
        #expect(throws: XitDBError.unexpectedTag) { try ArrayList<ReadOnly>(momentCursor) }

        #expect(try text(try value(moment, "foo")) == "foo")
        #expect(try #require(try moment.getSlot(hash("foo"))).tag == .shortBytes)
        #expect(try text(try value(moment, "bar")) == "bar")
        #expect(try #require(try moment.getSlot(hash("bar"))).tag == .shortBytes)
        // no key was stored with either
        #expect(try moment.getKeyCursor(hash("foo")) == nil)
        #expect(try moment.getKeySlot(hash("foo")) == nil)
        #expect(try #require(try moment.getKeyValuePair(hash("foo"))).keyCursor.slot().isEmpty)

        // the ten entries, by their hashes
        let keys = [
            "foo", "bar", "fruits", "people", "todos", "letters-counted-map", "letters-set",
            "letters-counted-set", "random-number", "long-text",
        ]
        var iter = try moment.iterator()
        #expect(try hashes(&iter) == Set(keys.map { hash($0) }))

        let fruits = try ArrayList<ReadOnly>(try value(moment, "fruits"))
        #expect(try fruits.count() == 3)
        let names = try (0..<3).map { try text(try #require(try fruits.getCursor($0))) }
        #expect(names == ["apple", "pear", "grape"])
        #expect(try fruits.getCursor(3) == nil)
        #expect(try fruits.getSlot(3) == nil)
        #expect(try texts(fruits) == ["apple", "pear", "grape"])
        var fromPear = try fruits.iteratorFrom(1)
        #expect(try text(try #require(try fromPear.next())) == "pear")
        #expect(try text(try #require(try fromPear.next())) == "grape")
        #expect(try fromPear.next() == nil)
        var fromLast = try fruits.iteratorFrom(-1)
        #expect(try text(try #require(try fromLast.next())) == "grape")
        #expect(try fromLast.next() == nil)

        let people = try ArrayList<ReadOnly>(try value(moment, "people"))
        #expect(try people.count() == 2)
        let alice = try HashMap<ReadOnly>(try #require(try people.getCursor(0)))
        #expect(try text(try value(alice, "name")) == "Alice")
        #expect(try value(alice, "age").readUint() == 25)
        let bob = try HashMap<ReadOnly>(try #require(try people.getCursor(1)))
        #expect(try text(try value(bob, "name")) == "Bob")
        #expect(try value(bob, "age").readUint() == 42)
        // each person's keys were stored with their text
        for person in [alice, bob] {
            for key in ["name", "age"] {
                let keyCursor = try #require(try person.getKeyCursor(hash(key)))
                #expect(try text(keyCursor) == key)
                #expect(try #require(try person.getKeySlot(hash(key))).tag == .shortBytes)
                let pair = try #require(try person.getKeyValuePair(hash(key)))
                #expect(pair.hash == hash(key))
                #expect(pair.withHash { span in (0..<span.count).map { span[$0] } } == hash(key))
                #expect(try text(pair.keyCursor) == key)
            }
            // and the iterator gives both entries, each with its key and value
            var entries = try person.iterator()
            var found: [String: Cursor<ReadOnly>] = [:]
            while let entry = try entries.next() {
                let pair = try entry.readKeyValuePair()
                found[try text(pair.keyCursor)] = pair.valueCursor
            }
            #expect(found.count == 2)
            #expect(try text(try #require(found["name"])) == (try text(try value(person, "name"))))
            #expect(try #require(found["age"]).readUint() == (try value(person, "age").readUint()))
        }

        // todos was appended to twice, had "Wash the car" inserted at 1, and
        // then a map inserted at 1 and removed again
        let todosCursor = try value(moment, "todos")
        #expect(try todosCursor.slot().tag == .linkedArrayList)
        let todos = try LinkedArrayList<ReadOnly>(todosCursor)
        #expect(try todos.count() == 3)
        let todoTexts = try (0..<3).map { try text(try #require(try todos.getCursor($0))) }
        #expect(todoTexts == ["Pay the bills", "Wash the car", "Get an oil change"])
        #expect(try todos.getCursor(3) == nil)
        #expect(try todos.getSlot(3) == nil)
        #expect(try todos.getCursor(-4) == nil)
        #expect(try text(try #require(try todos.getCursor(-1))) == "Get an oil change")
        #expect(try todos.getSlot(-1) == (try todos.getSlot(2)))
        // each is longer than eight bytes, so none is in its slot
        for index in Int64(0)..<3 {
            #expect(try #require(try todos.getSlot(index)).tag == .bytes)
        }
        #expect(try texts(todos) == ["Pay the bills", "Wash the car", "Get an oil change"])
        var fromWash = try todos.iteratorFrom(1)
        #expect(try texts(&fromWash) == ["Wash the car", "Get an oil change"])
        var fromLastTodo = try todos.iteratorFrom(-1)
        #expect(try texts(&fromLastTodo) == ["Get an oil change"])
        var fromBeyond = try todos.iteratorFrom(3)
        #expect(try fromBeyond.next() == nil)
        // the other list kind refuses it, and it refuses the other kinds
        #expect(throws: XitDBError.unexpectedTag) { try ArrayList<ReadOnly>(todosCursor) }
        #expect(throws: XitDBError.unexpectedTag) { try LinkedArrayList<ReadOnly>(try value(moment, "fruits")) }
        #expect(throws: XitDBError.unexpectedTag) { try LinkedArrayList<ReadOnly>(momentCursor) }

        let countedMap = try CountedHashMap<ReadOnly>(try value(moment, "letters-counted-map"))
        #expect(try countedMap.slot().tag == .countedHashMap)
        #expect(try countedMap.count() == 2)
        #expect(try #require(try countedMap.getCursor(hash("a"))).readUint() == 2)
        #expect(try #require(try countedMap.getCursor(hash("c"))).readUint() == 3)
        #expect(try countedMap.getCursor(hash("b")) == nil)
        #expect(try countedMap.getSlot(hash("b")) == nil)
        #expect(try countedMap.getKeyValuePair(hash("b")) == nil)
        // a key is only written while it is empty, so "a" kept its first key
        #expect(try text(try #require(try countedMap.getKeyCursor(hash("a")))) == "a")
        var countedEntries = try countedMap.iterator()
        #expect(try hashes(&countedEntries) == [hash("a"), hash("c")])
        // it is not a map without a count
        #expect(throws: XitDBError.unexpectedTag) { try HashMap<ReadOnly>(try value(moment, "letters-counted-map")) }

        let set = try HashSet<ReadOnly>(try value(moment, "letters-set"))
        #expect(try set.slot().tag == .hashSet)
        let countedSet = try CountedHashSet<ReadOnly>(try value(moment, "letters-counted-set"))
        #expect(try countedSet.slot().tag == .countedHashSet)
        #expect(try countedSet.count() == 2)
        #expect(throws: XitDBError.unexpectedTag) { try CountedHashSet<ReadOnly>(try value(moment, "letters-set")) }
        #expect(throws: XitDBError.unexpectedTag) { try HashSet<ReadOnly>(try value(moment, "letters-counted-set")) }
        #expect(try text(try #require(try set.getCursor(hash("a")))) == "a")
        #expect(try text(try #require(try set.getCursor(hash("c")))) == "c")
        #expect(try set.getCursor(hash("b")) == nil)
        #expect(try #require(try set.getSlot(hash("a"))).tag == .shortBytes)
        #expect(try set.getSlot(hash("b")) == nil)
        #expect(try text(try #require(try countedSet.getCursor(hash("a")))) == "a")
        #expect(try text(try #require(try countedSet.getCursor(hash("c")))) == "c")
        #expect(try countedSet.getCursor(hash("b")) == nil)
        #expect(try #require(try countedSet.getSlot(hash("c"))).tag == .shortBytes)
        #expect(try countedSet.getSlot(hash("b")) == nil)
        // a set's entries have no value: seen as a map, a set has keys and nothing under them
        let setAsMap = try HashMap<ReadOnly>(try value(moment, "letters-set"))
        #expect(try setAsMap.getCursor(hash("a")) == nil)
        #expect(try setAsMap.getSlot(hash("a")) == nil)
        #expect(try text(try #require(try setAsMap.getKeyCursor(hash("a")))) == "a")
        #expect(try #require(try setAsMap.getKeyValuePair(hash("a"))).valueCursor.slot().isEmpty)
        let countedSetAsMap = try CountedHashMap<ReadOnly>(try value(moment, "letters-counted-set"))
        #expect(try countedSetAsMap.getCursor(hash("a")) == nil)
        #expect(try text(try #require(try countedSetAsMap.getKeyCursor(hash("a")))) == "a")
        #expect(try #require(try countedSetAsMap.getKeyValuePair(hash("a"))).valueCursor.slot().isEmpty)
        // and each set's iterator gives its two keys
        var setEntries = try set.iterator()
        var setKeys: Set<String> = []
        while let entry = try setEntries.next() {
            let pair = try entry.readKeyValuePair()
            #expect(try pair.valueCursor.slot().isEmpty)
            setKeys.insert(try text(pair.keyCursor))
        }
        #expect(setKeys == ["a", "c"])
        var countedSetEntries = try countedSet.iterator()
        #expect(try hashes(&countedSetEntries) == [hash("a"), hash("c")])

        let numberCursor = try value(moment, "random-number")
        let number = try numberCursor.readBytesObjectAlloc()
        #expect(number.value.count == 32)
        #expect(number.formatTag == "bi")
        #expect(try numberCursor.slot().tag == .bytes)
        // the reader gives the same bytes, without the tag
        var numberReader = try numberCursor.reader()
        #expect(numberReader.size == 32)
        #expect(try numberReader.readRemaining() == number.value)
        #expect(numberReader.position == 32)
        #expect(try numberReader.readRemaining() == [])

        let longText = try value(moment, "long-text")
        #expect(try longText.count() == 700)
        #expect(try text(longText) == String(repeating: "hello, world!\n", count: 50))
        #expect(throws: XitDBError.streamTooLong) { try longText.readBytesAlloc(maxSize: 699) }
        // through the reader, a line at a time, and the rest after a seek
        var reader = try longText.reader()
        #expect(reader.size == 700)
        var line = [UInt8](repeating: 0, count: 14)
        for index in 0..<50 {
            var span = line.mutableSpan
            try reader.readAll(into: &span)
            #expect(line == Array("hello, world!\n".utf8), "line \(index)")
        }
        #expect(reader.position == 700)
        var afterEnd = line.mutableSpan
        #expect(try reader.read(into: &afterEnd) == 0)
        reader.seek(to: 686)
        #expect(try reader.readRemaining(maxSize: 14) == Array("hello, world!\n".utf8))
        reader.seek(to: 0)
        #expect(throws: XitDBError.streamTooLong) { try reader.readRemaining(maxSize: 699) }
        #expect(try reader.readRemaining(maxSize: 700).count == 700)
    }

    @Test func theSecondMoment() throws {
        let moment = try moment(1)

        #expect(try text(try value(moment, "foo")) == "foo")
        // bar was removed
        #expect(try moment.getCursor(hash("bar")) == nil)
        #expect(try moment.getSlot(hash("bar")) == nil)
        #expect(try moment.getKeyValuePair(hash("bar")) == nil)
        var iter = try moment.iterator()
        let found = try hashes(&iter)
        #expect(found.count == 9)
        #expect(!found.contains(hash("bar")))
        #expect(found.contains(hash("foo")))

        // fruits got its key, its first element replaced and its last cut off
        let fruitsKey = try #require(try moment.getKeyCursor(hash("fruits")))
        #expect(try text(fruitsKey) == "fruits")
        #expect(try fruitsKey.slot().tag == .shortBytes)
        let fruits = try ArrayList<ReadOnly>(try value(moment, "fruits"))
        #expect(try fruits.count() == 2)
        let names = try (0..<2).map { try text(try #require(try fruits.getCursor($0))) }
        #expect(names == ["lemon", "pear"])
        #expect(try fruits.getCursor(2) == nil)
        #expect(try texts(fruits) == ["lemon", "pear"])
        let pair = try #require(try moment.getKeyValuePair(hash("fruits")))
        #expect(try pair.keyCursor.slot().tag == .shortBytes)
        #expect(try pair.valueCursor.slot().tag == .arrayList)
        #expect(try text(pair.keyCursor) == "fruits")
        #expect(try ArrayList<ReadOnly>(pair.valueCursor).count() == 2)

        let people = try ArrayList<ReadOnly>(try value(moment, "people"))
        #expect(try people.count() == 2)
        let alice = try HashMap<ReadOnly>(try #require(try people.getCursor(0)))
        #expect(try value(alice, "age").readUint() == 26)
        #expect(try text(try value(alice, "name")) == "Alice")
        let bob = try HashMap<ReadOnly>(try #require(try people.getCursor(1)))
        #expect(try value(bob, "age").readUint() == 42)

        // todos was concatenated with itself, cut down to its second and
        // third elements, and had the second of those removed
        let todos = try LinkedArrayList<ReadOnly>(try value(moment, "todos"))
        #expect(try todos.count() == 1)
        #expect(try text(try #require(try todos.getCursor(0))) == "Wash the car")
        #expect(try text(try #require(try todos.getCursor(-1))) == "Wash the car")
        #expect(try todos.getCursor(1) == nil)
        #expect(try todos.getCursor(-2) == nil)
        #expect(try texts(todos) == ["Wash the car"])
        var fromLastTodo = try todos.iteratorFrom(-1)
        #expect(try texts(&fromLastTodo) == ["Wash the car"])
        // the element's bytes are shared with the first moment
        let firstTodos = try LinkedArrayList<ReadOnly>(try value(try self.moment(0), "todos"))
        #expect(try todos.getSlot(0) == (try firstTodos.getSlot(1)))

        let countedMap = try CountedHashMap<ReadOnly>(try value(moment, "letters-counted-map"))
        #expect(try countedMap.count() == 1)
        #expect(try #require(try countedMap.getCursor(hash("a"))).readUint() == 2)
        #expect(try countedMap.getCursor(hash("c")) == nil)
        var countedEntries = try countedMap.iterator()
        #expect(try hashes(&countedEntries) == [hash("a")])
        let set = try HashSet<ReadOnly>(try value(moment, "letters-set"))
        #expect(try set.getCursor(hash("a")) != nil)
        #expect(try set.getCursor(hash("c")) == nil)
        var setEntries = try set.iterator()
        #expect(try hashes(&setEntries) == [hash("a")])
        let countedSet = try CountedHashSet<ReadOnly>(try value(moment, "letters-counted-set"))
        #expect(try countedSet.count() == 1)
        #expect(try countedSet.getCursor(hash("c")) == nil)
        var countedSetEntries = try countedSet.iterator()
        #expect(try hashes(&countedSetEntries) == [hash("a")])

        // what the second transaction did not touch is shared with the first
        let first = try self.moment(0)
        #expect(try moment.getSlot(hash("random-number")) == (try first.getSlot(hash("random-number"))))
        #expect(try moment.getSlot(hash("long-text")) == (try first.getSlot(hash("long-text"))))
    }

    /// The first moment still reads as it did before the second transaction.
    @Test func thePastIsUnchanged() throws {
        let first = try moment(0)
        #expect(try text(try value(first, "bar")) == "bar")
        #expect(try ArrayList<ReadOnly>(try value(first, "fruits")).count() == 3)
        let alice = try HashMap<ReadOnly>(
            try #require(try ArrayList<ReadOnly>(try value(first, "people")).getCursor(0)))
        #expect(try value(alice, "age").readUint() == 25)
        #expect(try first.getKeyCursor(hash("fruits")) == nil)
        #expect(try first.getKeySlot(hash("fruits")) == nil)
    }

    /// The fixture is also a valid database to go on writing to: a third
    /// transaction leaves the first two moments as they were.
    @Test func aThirdMomentCanBeAppended() throws {
        let storage = MemoryStorage(bytes: try FixtureTests.load())
        let database = try Database(storage: storage, hashSize: 20)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            try moment.put(hash("foo"), .bytes(Array("changed".utf8)))
        }
        #expect(try history.count() == 3)
        #expect(Array(storage.bytes[37..<8550]) == Array(try FixtureTests.load()[37...]))

        let reopened = try Database(storage: storage, hashSize: 20)
        let reopenedHistory = try ArrayList<ReadOnly>(reopened.rootCursor.readOnly())
        let third = try HashMap<ReadOnly>(try #require(try reopenedHistory.getCursor(2)))
        #expect(try text(try value(third, "foo")) == "changed")
        let second = try HashMap<ReadOnly>(try #require(try reopenedHistory.getCursor(1)))
        #expect(try text(try value(second, "foo")) == "foo")
        #expect(try ArrayList<ReadOnly>(try value(third, "fruits")).count() == 2)
    }
}
