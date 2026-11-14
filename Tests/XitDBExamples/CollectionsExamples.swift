import Testing
import XitDB
import XitDBHashing

@Suite("The collections") struct CollectionsExamples {
    @Test func nesting() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let history = try ArrayList<ReadWrite>(database.rootCursor)

        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let people = try ArrayList<ReadWrite>(moment.putCursor(forKey: "people"))
            let alice = try HashMap<ReadWrite>(people.appendCursor())
            let scores = try SortedSet<ReadWrite>(alice.putCursor(forKey: "scores"))
            try scores.insert("high")
        }

        let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
        let people = try ArrayList<ReadOnly>(moment.cursor(forKey: "people")!)
        let alice = try HashMap<ReadOnly>(people.cursor(at: 0)!)
        let scores = try SortedSet<ReadOnly>(alice.cursor(forKey: "scores")!)
        #expect(try scores.contains("high"))
        #expect(try scores.contains("high"))
    }

    @Test func aCollectionIsAViewOfASlot() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        var root = database.rootCursor
        try root.write(.uint(1))

        // A slot holding something else is refused, by either form.
        #expect(throws: XitDBError.unexpectedTag) {
            try HashMap<ReadOnly>(database.rootCursor)
        }
        #expect(throws: XitDBError.unexpectedTag) {
            try HashMap<ReadWrite>(database.rootCursor)
        }

        // A slot holding nothing reads as an empty collection, and writes
        // nothing until it is made with the read-write form.
        let empty = try Database(creating: MemoryStorage(), hashSize: 32)
        let before = try empty.committedSize
        #expect(try ArrayList<ReadOnly>(empty.rootCursor).count == 0)
        #expect(try empty.committedSize == before)
        _ = try ArrayList<ReadWrite>(empty.rootCursor)
        #expect(try empty.committedSize > before)
    }

    @Test func theTwoFormsOfACollection() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)

        // The read-write form makes the collection if it is not there yet.
        let writable = try ArrayList<ReadWrite>(database.rootCursor)
        try writable.append(UInt64(1))

        // These are the same list. The read-only forms cannot write: append
        // is not a method of them.
        let viaProperty: ArrayList<ReadOnly> = writable.readOnly
        let viaCursor = try ArrayList<ReadOnly>(database.rootCursor)
        #expect(try viaProperty.count == 1)
        #expect(try viaCursor.count == 1)
    }

    @Test func aMapAndASetAreOneKindToReaders() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let set = try HashSet<ReadWrite>(database.rootCursor)
        try set.insert(.bytes(Array("a".utf8)), forHash: sha256("a"))
        #expect(try HashMap<ReadOnly>(database.rootCursor).keyCursor(forHash: sha256("a")) != nil)
        #expect(throws: XitDBError.unexpectedTag) {
            try CountedHashSet<ReadOnly>(database.rootCursor)
        }
    }

    @Test func theReadWriteFormTakesOverTheOtherKind() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let set = try HashSet<ReadWrite>(database.rootCursor)
        try set.insert(.bytes(Array("a".utf8)), forHash: sha256("a"))
        #expect(try database.rootCursor.slot.tag == .hashSet)

        // A read-write map over a set makes the slot a map, with the same entries.
        let map = try HashMap<ReadWrite>(database.rootCursor)
        #expect(try database.rootCursor.slot.tag == .hashMap)
        #expect(try map.keyCursor(forHash: sha256("a")) != nil)

        let sorted = try Database(creating: MemoryStorage(), hashSize: 32)
        try SortedSet<ReadWrite>(sorted.rootCursor).insert("a")
        _ = try SortedMap<ReadWrite>(sorted.rootCursor)
        #expect(try sorted.rootCursor.slot.tag == .sortedMap)

        #expect(throws: XitDBError.unexpectedTag) {
            try CountedHashMap<ReadWrite>(database.rootCursor)
        }
    }

    @Test func aHashIsCheckedOnceThereIsAMapToLookIn() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        #expect(try HashMap<ReadOnly>(database.rootCursor).cursor(forHash: [1, 2, 3]) == nil)

        let map = try HashMap<ReadWrite>(database.rootCursor)
        #expect(throws: XitDBError.invalidHashSize) {
            try map.cursor(forHash: [1, 2, 3])
        }
    }

    /// A join touches little, and a cut more: neither goes through the list,
    /// as the article says.
    @Test func whatAJoinAndACutCost() throws {
        let first = [UInt8](repeating: 1, count: 8)
        let second = [UInt8](repeating: 2, count: 8)
        let storage = CountingStorage()
        let database = try Database(creating: storage, hashSize: 8)
        try database.withTransaction { cursor in
            let map = try HashMap<ReadWrite>(cursor)
            let a = try LinkedArrayList<ReadWrite>(map.putCursor(forHash: first))
            let b = try LinkedArrayList<ReadWrite>(map.putCursor(forHash: second))
            for number in 0..<4096 as Range<UInt64> {
                try a.append(.uint(number))
                try b.append(.uint(number))
            }
        }

        // What a transaction costs that only reaches the list.
        var size = try database.committedSize
        try database.withTransaction { cursor in
            let map = try HashMap<ReadWrite>(cursor)
            _ = try LinkedArrayList<ReadWrite>(map.putCursor(forHash: first))
        }
        #expect(try database.committedSize - size == 220)

        var reads = storage.reads
        size = try database.committedSize
        try database.withTransaction { cursor in
            let map = try HashMap<ReadWrite>(cursor)
            let a = try LinkedArrayList<ReadWrite>(map.putCursor(forHash: first))
            try a.append(contentsOf: try LinkedArrayList<ReadOnly>(map.cursor(forHash: second)!))
        }
        #expect(storage.reads - reads == 31)
        #expect(try database.committedSize - size == 494)  // 220, and one branch of 274

        reads = storage.reads
        size = try database.committedSize
        try database.withTransaction { cursor in
            let map = try HashMap<ReadWrite>(cursor)
            try LinkedArrayList<ReadWrite>(map.putCursor(forHash: first)).formSlice(offset: 2048, count: 1024)
        }
        #expect(storage.reads - reads == 108)
        #expect(try database.committedSize - size == 8584)
    }

    @Test func aSortedSetHoldsOnlyKeys() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let keys = try SortedSet<ReadWrite>(database.rootCursor)
        try keys.insert("a")
        var iterator = try keys.iterator()
        #expect(try iterator.next()!.slot.tag == .shortBytes)
    }

    @Test func aSortedMapsEntryPointsAtAPairHoldingTheKey() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let map = try SortedMap<ReadWrite>(database.rootCursor)
        try map.put(.uint(1), forKey: "a")

        var iterator = try map.iterator()
        let cursor = try iterator.next()!
        #expect(try cursor.slot.tag == .sortedKvPair)
        #expect(try cursor.readEntry().key.slot.tag == .shortBytes)
    }

    @Test func aLinkedListHasNoSlotNeverWritten() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        try database.withTransaction { cursor in
            let list = try LinkedArrayList<ReadWrite>(cursor)
            _ = try list.appendCursor()

            // What an array list would call never written is here set to nothing.
            let element = try #require(try list.cursor(at: 0))
            #expect(try element.slot.tag == .none)
            #expect(try !element.slot.isEmpty)
            var iterator = try list.iterator()
            #expect(try iterator.next() != nil)
        }
    }

    @Test func anIndexBeyondInt64() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let list = try ArrayList<ReadWrite>(database.rootCursor)
        try list.append(.uint(1))

        // One that fits in an `Int64` but names no element: nothing to give.
        var far = try list.iterator(fromIndex: 99)
        #expect(try far.next() == nil)

        // One that does not fit in an `Int64`: a lookup gives nil, an iterator throws.
        let tooBig = UInt64(1) << 63
        #expect(try list.cursor(at: tooBig) == nil)
        #expect(throws: XitDBError.indexOutOfRange) {
            try list.iterator(fromIndex: tooBig)
        }
    }

    @Test func aCountedMapCostsEightBytesWhereverItIsCopied() throws {
        func cost(counted: Bool) throws -> UInt64 {
            let database = try Database(creating: MemoryStorage(), hashSize: 32)
            let hash = sha256("a")
            if counted {
                let map = try CountedHashMap<ReadWrite>(database.rootCursor)
                try map.put(.uint(1), forHash: hash)
                let before = try database.committedSize
                try map.put(.uint(2), forHash: hash)
                return try database.committedSize - before
            }
            let map = try HashMap<ReadWrite>(database.rootCursor)
            try map.put(.uint(1), forHash: hash)
            let before = try database.committedSize
            try map.put(.uint(2), forHash: hash)
            return try database.committedSize - before
        }
        #expect(try cost(counted: true) == cost(counted: false) + 8)
    }

    @Test func arrayList() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let list = try ArrayList<ReadWrite>(database.rootCursor)

        try list.append(UInt64(1))
        try list.append(UInt64(2))
        try list.append(UInt64(3))
        try list.put(UInt64(20), at: 1)
        try list.truncate(to: 2)

        #expect(try list.count == 2)
        #expect(try list.value(at: 1, as: UInt64.self) == 20)
        #expect(try list.cursor(at: 2) == nil)
    }

    @Test func linkedArrayList() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { cursor in
            let moment = try HashMap<ReadWrite>(cursor)

            let tasks = try LinkedArrayList<ReadWrite>(moment.putCursor(forKey: "tasks"))
            try tasks.append(UInt64(1))
            try tasks.append(UInt64(3))
            try tasks.insert(UInt64(2), at: 1)  // before the element at index 1
            try tasks.remove(at: 0)

            let more = try LinkedArrayList<ReadWrite>(moment.putCursor(forKey: "more"))
            try more.append(UInt64(4))
            try more.append(UInt64(5))

            // Joins in logarithmic time, sharing what it can with both lists.
            // The join freezes the transaction, so the list is made again
            // from the transaction's cursor before it is written to.
            try tasks.append(contentsOf: more)
            let joined = try LinkedArrayList<ReadWrite>(HashMap<ReadWrite>(cursor).putCursor(forKey: "tasks"))
            #expect(try joined.count == 4)

            // Keeps two elements from index 1 on.
            try joined.formSlice(offset: 1, count: 2)
            #expect(try joined.count == 2)
            #expect(try joined.value(at: 0, as: UInt64.self) == 3)
            #expect(try joined.value(at: 1, as: UInt64.self) == 4)
        }
    }

    @Test func insertingAtTheEndIsAppending() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let list = try LinkedArrayList<ReadWrite>(database.rootCursor)
        try list.append(UInt64(1))

        #expect(throws: XitDBError.indexOutOfRange) {
            try list.insert(UInt64(2), at: 1)
        }
        #expect(throws: XitDBError.indexOutOfRange) {
            try list.insert(.uint(2), at: 1)
        }
        try list.append(UInt64(2))
        #expect(try list.count == 2)
    }

    @Test func hashMap() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let map = try HashMap<ReadWrite>(database.rootCursor)

        try map.put(UInt64(25), forKey: "age")
        try map.putKey("age")

        #expect(try map.value(forKey: "age", as: UInt64.self) == 25)
        #expect(try map.keyCursor(forKey: "age")!.read(String.self) == "age")
        // Each keyed call is its call by hash.
        #expect(try map.cursor(forHash: sha256("age"))!.readUInt64() == 25)
        #expect(try map.keyCursor(forHash: sha256("age"))!.readBytes() == Array("age".utf8))
        #expect(try map.remove(forKey: "age"))
        #expect(try !map.remove(forKey: "age"))
        #expect(try map.cursor(forKey: "age") == nil)

        // Without putKey the entry has no key.
        try map.put(UInt64(1), forKey: "anonymous")
        #expect(try map.keyCursor(forKey: "anonymous") == nil)
    }

    @Test func hashSet() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let tags = try HashSet<ReadWrite>(database.rootCursor)

        try tags.insert("swift")
        let hasSwift = try tags.contains("swift")
        #expect(hasSwift)
        #expect(try !tags.contains("zig"))
        #expect(try tags.contains(hash: sha256("swift")))

        // The member is stored: iterating gives it back.
        var iterator = try tags.iterator()
        #expect(try iterator.next()!.readEntry().key.read(String.self) == "swift")
        #expect(try tags.remove(forKey: "swift"))
        #expect(try !tags.contains("swift"))
    }

    @Test func theCountedForms() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { cursor in
            let moment = try HashMap<ReadWrite>(cursor)

            let visits = try CountedHashMap<ReadWrite>(moment.putCursor(forKey: "visits"))
            try visits.put(UInt64(1), forKey: "alice")
            try visits.put(UInt64(2), forKey: "alice")
            try visits.put(UInt64(1), forKey: "bob")
            #expect(try visits.count == 2)

            let tags = try CountedHashSet<ReadWrite>(moment.putCursor(forKey: "tags"))
            try tags.insert("swift")
            #expect(try tags.count == 1)
        }
    }

    @Test func negativeIndices() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let list = try ArrayList<ReadWrite>(database.rootCursor)
        for value: UInt64 in [10, 20, 30] {
            try list.append(value)
        }

        let last = try list.value(at: -1, as: UInt64.self)
        let first = try list.value(at: -3, as: UInt64.self)
        let tooFar = try list.value(at: -4, as: UInt64.self)
        #expect(last == 30)
        #expect(first == 10)
        #expect(tooFar == nil)

        // Starting an iterator from the end.
        var iterator = try list.iterator(fromIndex: -2)
        #expect(try iterator.next()!.readUInt64() == 20)
        #expect(try iterator.next()!.readUInt64() == 30)
        #expect(try iterator.next() == nil)
    }

    @Test func aBadIndexOnWriteIsAnError() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let list = try ArrayList<ReadWrite>(database.rootCursor)
        try list.append(.uint(1))

        // A read of an element that is not there is nil; a write is an error.
        #expect(try list.cursor(at: 5) == nil)
        #expect(throws: XitDBError.indexOutOfRange) {
            try list.put(.uint(2), at: 5)
        }
    }

    @Test func anyIntegerAsAnIndex() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let list = try ArrayList<ReadWrite>(database.rootCursor)
        try list.append(.uint(1))

        // An Int, a UInt64 and a UInt8 are all indices.
        let index: Int = 0
        let count: UInt64 = try list.count
        let byte: UInt8 = 0
        #expect(try list.cursor(at: index) != nil)
        #expect(try list.cursor(at: count - 1) != nil)
        #expect(try list.cursor(at: byte) != nil)

        // An index that does not fit in 64 bits names no element.
        #expect(try list.cursor(at: UInt64.max) == nil)
        #expect(throws: XitDBError.indexOutOfRange) {
            try list.put(.uint(1), at: UInt64.max)
        }
    }

    @Test func textAndBytesAsASortedKey() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let sorted = try SortedMap<ReadWrite>(database.rootCursor)

        try sorted.put(UInt64(1), forKey: "apple")
        try sorted.put(UInt64(2), forKey: Array("pear".utf8))

        // Text is its UTF-8: the two forms name the same keys, in the order of
        // their bytes, and no hash is involved.
        #expect(try sorted.value(forKey: Array("apple".utf8), as: UInt64.self) == 1)
        #expect(try sorted.value(forKey: "pear", as: UInt64.self) == 2)
        #expect(try sorted.entry(at: 0)!.key.read(String.self) == "apple")
        let name = "apple, green"
        try sorted.put(UInt64(3), forKey: name.utf8.prefix(5) + [0x21])
        #expect(try sorted.count == 3)
        #expect(try sorted.rank(of: "pear") == 2)
    }

    @Test func anyBytesAsAHash() throws {
        let hashes = try Database(creating: MemoryStorage(), hashSize: 32)
        let hashed = try HashMap<ReadWrite>(hashes.rootCursor)

        let bytes = [UInt8](repeating: 7, count: 32)
        try hashed.put(.uint(1), forHash: SHA256.hash(data: Array("anything".utf8)))
        try hashed.put(.uint(2), forHash: bytes)
        try hashed.put(.uint(3), forHash: bytes[...])
        try hashed.put(.uint(4), forHash: bytes.span)
        #expect(try hashed.cursor(forHash: sha256("anything"))!.readUInt64() == 1)
        #expect(try hashed.cursor(forHash: bytes)!.readUInt64() == 4)
    }

    @Test func appendingWithABody() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let list = try ArrayList<ReadWrite>(database.rootCursor)

        // `append(_:_:)` gives back what its body returns.
        let lastValue = try list.append(.uint(1)) { cursor in
            try cursor.write(.uint(2))
            return try cursor.readUInt64()
        }
        #expect(lastValue == 2)
    }
}
