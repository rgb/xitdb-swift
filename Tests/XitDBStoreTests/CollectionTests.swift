import Testing
import XitDB
import XitDBHashing
import XitDBStore

/// The collections over handles, each through its operations, and the
/// bytes they produce against the faithful layer's.
@Suite("the collections")
struct CollectionTests {
    private func makeStore() throws -> Store {
        try Store(try Database(creating: MemoryStorage(), hashSize: 32), hashing: SHA256.self)
    }

    @Test func aMap() throws {
        let store = try makeStore()
        try store.transaction { moment in
            let ages = moment["ages"].map(String.self, UInt64.self)
            #expect(try ages["alice"] == nil)
            #expect(try !ages.contains("alice"))
            try ages.put(30, forKey: "alice")
            try ages.put(41, forKey: "bob")
            #expect(try ages["alice"] == 30)
            #expect(try ages.contains("bob"))
            try ages.put(31, forKey: "alice")
            #expect(try ages["alice"] == 31)
            #expect(try ages.remove("bob"))
            #expect(try !ages.remove("bob"))
            #expect(try ages["bob"] == nil)
            var values = try ages.values()
            var seen: [UInt64] = []
            while let value = try values.next() {
                seen.append(value)
            }
            #expect(seen == [31])
        }
        let latest = try store.latest
        let ages = latest["ages"].map(String.self, UInt64.self)
        #expect(try ages["alice"] == 31)
        #expect(try latest["missing"].map(String.self, UInt64.self)["x"] == nil)
        var empty = try latest["missing"].map(String.self, UInt64.self).values()
        #expect(try empty.next() == nil)
    }

    @Test func integerKeysAndNestedCollections() throws {
        let store = try makeStore()
        try store.transaction { moment in
            let byID = moment["users"].map(Int.self, String.self)
            try byID.put("alice", forKey: 1)
            try byID.put("bob", forKey: -7)
            #expect(try byID[1] == "alice")
            #expect(try byID[-7] == "bob")
            let tags = byID[handleFor: 1].list(String.self)
            #expect(throws: XitDBError.unexpectedTag) { try tags.append("admin") }
            let nested = moment["profiles"].map(Int.self, UInt64.self)
            try nested[handleFor: 1].list(String.self).append("admin")
            try nested[handleFor: 1].list(String.self).append("ops")
            #expect(try moment["profiles"].map(Int.self, UInt64.self)[handleFor: 1].list(String.self).count == 2)
        }
    }

    @Test func aCountedMapAndTheKeySets() throws {
        let store = try makeStore()
        try store.transaction { moment in
            let counted = moment["c"].countedMap(String.self, UInt64.self)
            #expect(try counted.count == 0)
            try counted.put(1, forKey: "a")
            try counted.put(2, forKey: "b")
            try counted.put(3, forKey: "a")
            #expect(try counted.count == 2)
            #expect(try counted.remove("a"))
            #expect(try counted.count == 1)
            #expect(try counted["b"] == 2)

            let set = moment["s"].keySet(String.self)
            try set.insert("x")
            try set.insert("y")
            try set.insert("x")
            #expect(try set.contains("x"))
            #expect(try !set.contains("z"))
            var keys = try set.keys()
            var seen: Set<String> = []
            while let key = try keys.next() {
                seen.insert(key)
            }
            #expect(seen == ["x", "y"])
            #expect(try set.remove("x"))
            #expect(try !set.contains("x"))

            let countedSet = moment["cs"].countedKeySet(Int32.self)
            try countedSet.insert(5)
            try countedSet.insert(-5)
            #expect(try countedSet.count == 2)
            var ints = try countedSet.keys()
            var seenInts: Set<Int32> = []
            while let key = try ints.next() {
                seenInts.insert(key)
            }
            #expect(seenInts == [5, -5])
        }
    }

    @Test func lists() throws {
        let store = try makeStore()
        try store.transaction { moment in
            let list = moment["l"].list(String.self)
            #expect(try list.count == 0)
            #expect(try list[0] == nil)
            try list.append("a")
            try list.append("b")
            try list.append("c")
            #expect(try list.count == 3)
            #expect(try list[1] == "b")
            #expect(try list[-1] == "c")
            try list.put("B", at: 1)
            #expect(try list[1] == "B")
            #expect(throws: XitDBError.indexOutOfRange) { try list.put("x", at: 3) }
            try list.truncate(to: 2)
            #expect(try list.count == 2)
            var elements = try list.elements()
            var seen: [String] = []
            while let element = try elements.next() {
                seen.append(element)
            }
            #expect(seen == ["a", "B"])

            let linked = moment["ll"].linkedList(UInt64.self)
            try linked.append(1)
            try linked.append(3)
            try linked.insert(2, at: 1)
            #expect(try linked.count == 3)
            #expect(try linked[1] == 2)
            try linked.remove(at: 0)
            #expect(try linked[0] == 2)
            let other = moment["ll2"].linkedList(UInt64.self)
            try other.append(10)
            try other.append(11)
            try linked.join(other)
            #expect(try linked.count == 4)
            #expect(try linked[-1] == 11)
            try linked.slice(offset: 1, count: 2)
            #expect(try linked.count == 2)
            #expect(try linked[0] == 3)
            #expect(try linked[1] == 10)
            #expect(try other.count == 2, "the joined list is unchanged")
        }
    }

    @Test func sortedCollections() throws {
        let store = try makeStore()
        try store.transaction { moment in
            let scores = moment["scores"].sortedMap(Int64.self, UInt64.self)
            try scores.put(1, forKey: 10)
            try scores.put(2, forKey: -3)
            try scores.put(3, forKey: 7)
            #expect(try scores.count == 3)
            #expect(try scores[-3] == 2)
            #expect(try scores[4] == nil)
            #expect(try scores.rank(of: 7) == 1)
            #expect(try scores.rank(of: 100) == 3)
            let first = try #require(try scores.entry(at: 0))
            #expect(first.key == -3 && first.value == 2)
            #expect(try scores.entry(at: -1)?.key == 10)
            var entries = try scores.entries()
            var keys: [Int64] = []
            while let entry = try entries.next() {
                keys.append(entry.key)
            }
            #expect(keys == [-3, 7, 10], "signed keys order as values")
            var fromSeven = try scores.entries(from: 7)
            #expect(try fromSeven.next()?.key == 7)
            #expect(try scores.remove(7))
            #expect(try scores.count == 2)

            let words = moment["words"].sortedSet(String.self)
            try words.insert("pear")
            try words.insert("apple")
            try words.insert("fig")
            try words.insert("apple")
            #expect(try words.count == 3)
            #expect(try words.contains("fig"))
            #expect(try words.key(at: 0) == "apple")
            #expect(try words.rank(of: "pear") == 2)
            var fromFig = try words.keys(from: "fig")
            #expect(try fromFig.next() == "fig")
            #expect(try fromFig.next() == "pear")
            #expect(try fromFig.next() == nil)
            #expect(try words.remove("apple"))
            #expect(try words.key(at: 0) == "fig")
        }
    }

    /// The layer writes exactly what the faithful calls write: the same
    /// operations through both give the same bytes.
    @Test func theBytesAreTheFaithfulLayers() throws {
        // The file ID and each commit's ID are drawn at random; both databases
        // draw the same ones, so that only the data can differ.
        let throughStore = MemoryStorage()
        let store = try Store(
            try Database(storage: throughStore, hashSize: 32, fileID: 7, random: SeededGenerator(seed: 11)),
            hashing: SHA256.self)
        try store.transaction { moment in
            let ages = moment["ages"].map(String.self, UInt64.self)
            try ages.put(30, forKey: "alice")
            try ages.put(41, forKey: "bob")
            let list = moment["list"].list(String.self)
            try list.append("x")
            try list.append("y")
            let sorted = moment["sorted"].sortedMap(Int64.self, UInt64.self)
            try sorted.put(1, forKey: 5)
            try sorted.put(2, forKey: -5)
            try moment["flag"].set(true)
        }
        try store.transaction { moment in
            try moment["ages"].map(String.self, UInt64.self).put(31, forKey: "alice")
        }

        let throughCalls = MemoryStorage()
        let database = try Database(storage: throughCalls, hashSize: 32, fileID: 7, random: SeededGenerator(seed: 11))
        func sha(_ key: String) -> [UInt8] { Array(SHA256.hash(data: Array(key.utf8))) }
        try database.withTransaction { root in
            let history = try ArrayList<ReadWrite>(root)
            try history.append(.slot(nil)) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                let ages = try HashMap<ReadWrite>(try moment.putCursor(forHash: sha("ages")))
                try ages.put(.uint(30), forHash: sha("alice"))
                try ages.put(.uint(41), forHash: sha("bob"))
                let list = try ArrayList<ReadWrite>(try moment.putCursor(forHash: sha("list")))
                try list.append(.bytes(Array("x".utf8)))
                try list.append(.bytes(Array("y".utf8)))
                let sorted = try SortedMap<ReadWrite>(try moment.putCursor(forHash: sha("sorted")))
                try sorted.put(.uint(1), forKey: Int64(5).keyBytes)
                try sorted.put(.uint(2), forKey: Int64(-5).keyBytes)
                try moment.put(.uint(1), forHash: sha("flag"))
            }
        }
        try database.withTransaction { root in
            let history = try ArrayList<ReadWrite>(root)
            try history.append(.slot(try history.slot(at: -1))) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                let ages = try HashMap<ReadWrite>(try moment.putCursor(forHash: sha("ages")))
                try ages.put(.uint(31), forHash: sha("alice"))
            }
        }
        let a = throughStore.bytes
        let b = throughCalls.bytes
        let firstDifference = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        func around(_ bytes: [UInt8], _ at: Int?) -> String {
            guard let at else { return "" }
            return bytes[max(0, at - 4)..<min(bytes.count, at + 16)].map { String($0, radix: 16) }.joined(
                separator: " ")
        }
        #expect(
            a == b,
            "lengths \(a.count) and \(b.count); first difference at \(String(describing: firstDifference)): \(around(a, firstDifference)) / \(around(b, firstDifference))"
        )
        #expect(a.count > 200)
    }
}

/// A source of randomness that repeats: the same seed, the same numbers.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
