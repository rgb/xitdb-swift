import Testing

@testable import XitDB

/// What the collection types add to the path API: the check of the slot
/// when a read-only view is made, the init part when a writing one is, and
/// the shape of each method's result. The Zig tests and the conformance
/// scripts go through the path API, so these are the port's own.
@Suite struct CollectionViewTests {
    private func makeDatabase(_ storage: MemoryStorage = MemoryStorage()) throws -> Database {
        try Database(
            storage: storage, hashSize: 20, hashID: nil, fileID: 5, random: FixedRandom((1...50).map { UInt64($0) }))
    }

    private func key(_ text: String) -> [UInt8] {
        sha1(text).bytes
    }

    /// A read-only view checks what the slot holds. A slot with nothing is
    /// every collection; anything else is only its own kind.
    @Test func aReadOnlyViewChecksTheSlot() throws {
        let database = try makeDatabase()
        try database.runContext { cursor in
            _ = try cursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("list")), .arrayListInit])
            _ = try cursor.writePath([.hashMapGet(.value, sha1("map")), .hashMapInit()])
            _ = try cursor.writePath([.hashMapGet(.value, sha1("set")), .hashMapInit(set: true)])
            _ = try cursor.writePath([.hashMapGet(.value, sha1("counted-map")), .hashMapInit(counted: true)])
            _ = try cursor.writePath([.hashMapGet(.value, sha1("counted-set")), .hashMapInit(counted: true, set: true)])
            _ = try cursor.writePath([.hashMapGet(.value, sha1("number")), .write(.uint(1))])
            _ = try cursor.writePath([.hashMapGet(.value, sha1("none")), .write(.slot(nil))])
        }
        let moment = database.rootCursor().readOnly()
        func at(_ name: String) throws -> Cursor<ReadOnly> {
            try #require(try moment.readPath([.hashMapGet(.value, sha1(name))]))
        }
        let list = try at("list")
        let map = try at("map")
        let set = try at("set")
        let countedMap = try at("counted-map")
        let countedSet = try at("counted-set")
        let number = try at("number")
        let none = try at("none")

        #expect(try ArrayList(list).count() == 0)
        #expect(try ArrayList(none).count() == 0)
        for other in [map, set, countedMap, countedSet, number] {
            #expect(throws: XitDBError.unexpectedTag) { try ArrayList(other) }
        }

        // a map and a set are each other's kind to the views, as in Zig
        for fine in [map, set, none] {
            #expect(try HashMap(fine).getCursor(key("x")) == nil)
            #expect(try HashSet(fine).getCursor(key("x")) == nil)
        }
        for other in [list, countedMap, countedSet, number] {
            #expect(throws: XitDBError.unexpectedTag) { try HashMap(other) }
            #expect(throws: XitDBError.unexpectedTag) { try HashSet(other) }
        }
        for fine in [countedMap, countedSet, none] {
            #expect(try CountedHashMap(fine).count() == 0)
            #expect(try CountedHashSet(fine).count() == 0)
        }
        for other in [list, map, set, number] {
            #expect(throws: XitDBError.unexpectedTag) { try CountedHashMap(other) }
            #expect(throws: XitDBError.unexpectedTag) { try CountedHashSet(other) }
        }

        // a view of nothing gives nothing
        var elements = try ArrayList(none).iterator()
        #expect(try elements.next() == nil)
        var fromIndex = try ArrayList(none).iteratorFrom(0)
        #expect(try fromIndex.next() == nil)
        var entries = try HashMap(none).iterator()
        #expect(try entries.next() == nil)
        #expect(try ArrayList(none).getSlot(0) == nil)
        #expect(try HashMap(none).getKeyValuePair(key("x")) == nil)
        #expect(try HashMap(none).getKeySlot(key("x")) == nil)
        #expect(try CountedHashSet(none).getSlot(key("x")) == nil)
    }

    /// A writing view makes the slot its kind of collection, and the other
    /// kinds refuse the slot afterwards.
    @Test func aWritingViewMakesTheCollection() throws {
        let database = try makeDatabase()
        try database.runContext { cursor in
            let map = try HashMap(cursor)
            #expect(try map.slot().tag == .hashMap)
            #expect(try cursor.slot().tag == .none, "the view's cursor is a new one; the caller's is unchanged")
            #expect(try map.cursor.slot().tag == .hashMap)

            let list = try ArrayList(try map.putCursor(key("list")))
            #expect(try list.slot().tag == .arrayList)
            #expect(try map.getSlot(key("list"))?.tag == .arrayList)
            let countedMap = try CountedHashMap(try map.putCursor(key("counted-map")))
            #expect(try countedMap.slot().tag == .countedHashMap)
            let set = try HashSet(try map.putCursor(key("set")))
            #expect(try set.slot().tag == .hashSet)
            let countedSet = try CountedHashSet(try map.putCursor(key("counted-set")))
            #expect(try countedSet.slot().tag == .countedHashSet)

            // the wrong kind of view on each, writing: a list is not a map,
            // and a counted map is not an uncounted one. A map and a set
            // are one kind to the init part, as in Zig, which gives the
            // slot the tag asked for: a map becomes a set, and back.
            #expect(throws: XitDBError.unexpectedTag) { try HashMap(try map.putCursor(key("list"))) }
            #expect(throws: XitDBError.unexpectedTag) { try ArrayList(try map.putCursor(key("set"))) }
            #expect(throws: XitDBError.unexpectedTag) { try HashSet(try map.putCursor(key("counted-set"))) }
            #expect(throws: XitDBError.unexpectedTag) { try CountedHashMap(try map.putCursor(key("set"))) }
            #expect(try CountedHashSet(try map.putCursor(key("counted-map"))).slot().tag == .countedHashSet)
            #expect(try HashMap(try map.putCursor(key("set"))).slot().tag == .hashMap)

            // and the read-only form of each keeps the slot
            #expect(try list.readOnly().slot() == (try list.slot()))
            #expect(try countedMap.readOnly().count() == 0)
            #expect(try set.readOnly().getCursor(key("x")) == nil)
            #expect(try countedSet.readOnly().count() == 0)
            #expect(try map.readOnly().getCursor(key("list"))?.slot().tag == .arrayList)
        }
        #expect(try database.rootCursor().slot().tag == .hashMap)
    }

    /// The methods that take a hash accept it as an array and as a span,
    /// and a hash of the wrong size is refused by every one of them.
    @Test func aHashIsASpanOrAnArray() throws {
        let database = try makeDatabase()
        let hash = key("k")
        let wrong = [UInt8](repeating: 1, count: 19)
        try database.runContext { cursor in
            let map = try HashMap(cursor)
            try map.put(hash.span, .uint(1))
            try map.putKey(hash, .bytes(Array("k".utf8)))
            try map.putKey(hash.span, .bytes(Array("other".utf8)))
            try map.putKey(hash, .bytes(Array("another".utf8)))
            #expect(try map.getKeyCursor(hash)?.readBytesAlloc() == Array("k".utf8), "a key is only written once")
            #expect(try !map.remove(key("missing").span))
            #expect(try !map.remove(key("missing")))
            #expect(try map.getCursor(hash.span)?.readUint() == 1)
            #expect(try map.getCursor(hash)?.readUint() == 1)
            #expect(try map.getKeyCursor(hash.span)?.readBytesAlloc() == Array("k".utf8))
            #expect(try map.getKeySlot(hash)?.tag == .shortBytes)
            #expect(try map.getSlot(hash.span)?.tag == .uint)
            let pair = try #require(try map.getKeyValuePair(hash.span))
            #expect(pair.hash == hash)
            #expect(pair.withHash { Array($0.indices.map { pair.hash[$0] }) } == hash)
            #expect(try map.putCursor(hash.span).readUint() == 1)
            #expect(try map.putKeyCursor(hash).readBytesAlloc() == Array("k".utf8))

            #expect(throws: XitDBError.invalidHashSize) { try map.put(wrong, .uint(2)) }
            #expect(throws: XitDBError.invalidHashSize) { try map.put(wrong.span, .uint(2)) }
            #expect(throws: XitDBError.invalidHashSize) { try map.putKey(wrong.span, .uint(2)) }
            #expect(throws: XitDBError.invalidHashSize) { try map.getCursor(wrong) }
            #expect(throws: XitDBError.invalidHashSize) { try map.getSlot(wrong.span) }
            #expect(throws: XitDBError.invalidHashSize) { try map.getKeyCursor(wrong) }
            #expect(throws: XitDBError.invalidHashSize) { try map.getKeySlot(wrong.span) }
            #expect(throws: XitDBError.invalidHashSize) { try map.getKeyValuePair(wrong) }
            #expect(throws: XitDBError.invalidHashSize) { try map.putCursor(wrong) }
            #expect(throws: XitDBError.invalidHashSize) { try map.putKeyCursor(wrong.span) }
            #expect(throws: XitDBError.invalidHashSize) { try map.remove(wrong) }
            #expect(throws: XitDBError.invalidHashSize) { try map.remove(wrong.span) }

            let set = try HashSet(try map.putCursor(key("set")))
            try set.put(hash.span, .bytes(Array("k".utf8)))
            try set.put(hash.span, .bytes(Array("other".utf8)))
            try set.put(hash, .bytes(Array("another".utf8)))
            #expect(try set.getCursor(hash)?.readBytesAlloc() == Array("k".utf8))
            #expect(try set.getSlot(hash.span)?.tag == .shortBytes)
            #expect(try set.putCursor(hash).readBytesAlloc() == Array("k".utf8))
            #expect(throws: XitDBError.invalidHashSize) { try set.put(wrong, .uint(2)) }
            #expect(throws: XitDBError.invalidHashSize) { try set.getCursor(wrong.span) }
            #expect(throws: XitDBError.invalidHashSize) { try set.getSlot(wrong) }
            #expect(throws: XitDBError.invalidHashSize) { try set.putCursor(wrong.span) }
            #expect(throws: XitDBError.invalidHashSize) { try set.remove(wrong) }
            #expect(try set.remove(hash.span))
            #expect(try !set.remove(hash))

            let counted = try CountedHashMap(try map.putCursor(key("counted")))
            try counted.put(hash, .uint(3))
            try counted.putKey(hash.span, .bytes([1]))
            try counted.putKey(hash.span, .bytes([9]))
            try counted.putKey(hash, .bytes([9]))
            #expect(try !counted.remove(key("missing")))
            #expect(try !counted.remove(key("missing").span))
            #expect(try counted.count() == 1)
            #expect(try counted.getCursor(hash.span)?.readUint() == 3)
            #expect(try counted.getKeyValuePair(hash)?.keyCursor.readBytesAlloc() == [1])
            #expect(try counted.getKeyCursor(hash)?.readBytesAlloc() == [1])
            #expect(try counted.getKeySlot(hash.span)?.tag == .shortBytes)
            #expect(try counted.getSlot(hash)?.tag == .uint)
            #expect(try counted.putCursor(hash).readUint() == 3)
            #expect(try counted.putKeyCursor(hash.span).readBytesAlloc() == [1])
            #expect(throws: XitDBError.invalidHashSize) { try counted.remove(wrong.span) }
            #expect(try counted.remove(hash))
            #expect(try counted.count() == 0)

            let countedSet = try CountedHashSet(try map.putCursor(key("counted-set")))
            try countedSet.put(hash.span, .bytes([2]))
            try countedSet.put(hash, .bytes([3]))
            try countedSet.put(hash.span, .bytes([4]))
            #expect(try countedSet.count() == 1)
            #expect(try countedSet.getCursor(hash)?.readBytesAlloc() == [2], "a key is only written once")
            #expect(try countedSet.getSlot(hash.span)?.tag == .shortBytes)
            #expect(try countedSet.putCursor(hash.span).readBytesAlloc() == [2])
            #expect(throws: XitDBError.invalidHashSize) { try countedSet.put(wrong.span, .uint(1)) }
            #expect(try countedSet.remove(hash.span))
            #expect(try !countedSet.remove(hash.span))
            #expect(try countedSet.count() == 0)
        }
    }

    /// The list's own edges: a missing index, slicing, and iterating from
    /// an index that names nothing.
    @Test func aListsEdges() throws {
        let database = try makeDatabase()
        try database.runContext { cursor in
            let list = try ArrayList(cursor)
            #expect(throws: XitDBError.keyNotFound) { try list.put(0, .uint(1)) }
            #expect(throws: XitDBError.keyNotFound) { try list.putCursor(-1) }
            try list.append(.uint(10))
            try list.append(.uint(20))
            #expect(try list.appendCursor().slot().isEmpty)
            #expect(try list.count() == 3)
            try list.put(-1, .uint(30))
            try list.put(0, .uint(11))
            #expect(try list.getCursor(0)?.readUint() == 11)
            #expect(try list.getCursor(-1)?.readUint() == 30)
            #expect(try list.getSlot(3) == nil)
            #expect(try list.getSlot(-4) == nil)
            #expect(throws: XitDBError.keyNotFound) { try list.slice(4) }
            try list.slice(2)
            #expect(try list.count() == 2)
            var fromIndex = try list.iteratorFrom(1)
            #expect(try fromIndex.next()?.readUint() == 20)
            #expect(try fromIndex.next() == nil)
            for empty in [Int64(2), 3, -3, .max, .min] {
                var iterator = try list.iteratorFrom(empty)
                #expect(try iterator.next() == nil, "from \(empty)")
            }
            try list.appendContext(.uint(40)) { element in
                #expect(try element.readUint() == 40)
                try element.write(.uint(41))
            }
            #expect(try list.getCursor(2)?.readUint() == 41)
        }
    }

    /// Iterating over a linked array list or a sorted map is not there yet,
    /// and says so rather than reading their blocks as something else. The
    /// array list's start at an index is the array list's alone.
    @Test func iteratingTheLaterCollectionsIsNotImplemented() throws {
        let database = try Database(storage: MemoryStorage(bytes: try FixtureTests.load()), hashSize: 20)
        let moment = try #require(try database.rootCursor().readPath([.arrayListGet(-1)]))
        let todos = try #require(try moment.readPath([.hashMapGet(.value, sha1("todos"))]))
        #expect(try todos.slot().tag == .linkedArrayList)
        #expect(throws: XitDBError.notImplemented) { try todos.iterator() }
        #expect(throws: XitDBError.unexpectedTag) { try todos.iterator(fromArrayListIndex: 0) }
        #expect(throws: XitDBError.unexpectedTag) { try ArrayList(todos) }
    }
}
