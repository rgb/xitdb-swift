import Foundation
import Testing
import XitDBHashing

@testable import XitDB

// The keyed put that also stores the key: `put(_:forKey:storingKey:)` on the
// two hashed maps. It is one walk to the entry where `putKey` and then `put`
// are two, and the file it leaves has to be the file those two leave inside
// one transaction. Two databases are written side by side, one with the one
// call and one with the two, and are the same bytes after every step.

/// Two databases made alike, hasher and IDs: one written with the one call,
/// one with `putKey` and then `put` by hash.
private struct Pair {
    let oneStorage = MemoryStorage()
    let twoStorage = MemoryStorage()
    let one: Database
    let two: Database

    init() throws {
        one = try Database(
            creating: oneStorage, hashSize: Insecure.SHA1.size, hashID: "test", fileID: 0x10,
            random: RandomSource(SeededGenerator(seed: 31)), hasher: KeyHasher(Insecure.SHA1.self))
        two = try Database(
            creating: twoStorage, hashSize: Insecure.SHA1.size, hashID: "test", fileID: 0x10,
            random: RandomSource(SeededGenerator(seed: 31)), hasher: KeyHasher(Insecure.SHA1.self))
    }

    static func hash(_ key: some KeyRepresentable) -> [UInt8] {
        Insecure.SHA1.keyHash(of: key)
    }

    /// The slot the map under test lives in: the value under a fixed hash
    /// in a map at the root, so that it is written inside a transaction
    /// like any collection below the root.
    static func place(_ root: Cursor<ReadWrite>) throws -> Cursor<ReadWrite> {
        try HashMap<ReadWrite>(root).putCursor(forHash: [UInt8](repeating: 0x11, count: Insecure.SHA1.size))
    }

    /// One step: a transaction on each database, after which the two files
    /// are the same.
    func step(
        _ what: String,
        one oneBody: (Cursor<ReadWrite>) throws -> Void,
        two twoBody: (Cursor<ReadWrite>) throws -> Void
    ) throws {
        try one.withTransaction { root in try oneBody(try Self.place(root)) }
        try two.withTransaction { root in try twoBody(try Self.place(root)) }
        #expect(oneStorage.bytes == twoStorage.bytes, "after \(what)")
    }

    /// A read-only cursor at the map under test, in the database written
    /// with the one call.
    func placeOfOne() throws -> Cursor<ReadOnly> {
        let root = try HashMap<ReadOnly>(one.rootCursor)
        return try #require(try root.cursor(forHash: [UInt8](repeating: 0x11, count: Insecure.SHA1.size)))
    }
}

/// A value of the test's own that writes itself as two entries of a map.
private struct Reading: StorableValue, Equatable {
    var place: String
    var degrees: Int64

    func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        let map = try HashMap<ReadWrite>(cursor)
        try map.put(place, forKey: "place")
        try map.put(degrees, forKey: "degrees")
    }

    init(place: String, degrees: Int64) {
        self.place = place
        self.degrees = degrees
    }

    init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        let map = try HashMap<ReadOnly>(cursor)
        guard let place = try map.value(forKey: "place", as: String.self),
            let degrees = try map.value(forKey: "degrees", as: Int64.self)
        else { throw .unexpectedTag }
        self.place = place
        self.degrees = degrees
    }
}

/// A value that writes something and then fails.
private struct FailsAfterWriting: StorableValue {
    func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.uint(1))
        throw .invalidUTF8
    }

    init() {}

    init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {}
}

/// A value that freezes the database between its two writes: after the
/// freeze it goes on through its cursor with a write, which only the
/// transaction's own cursor may.
private struct FreezesBetweenWrites: StorableValue, Equatable {
    var number: UInt64

    func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.uint(0))
        try cursor.database.freeze()
        try cursor.write(.uint(number))
    }

    init(number: UInt64) {
        self.number = number
    }

    init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        number = try cursor.readUInt64()
    }
}

@Suite struct StoredKeyTests {
    /// Keys of each kind a key comes in, short and long.
    static let short = "a"
    static let long = String(repeating: "a long key, longer than a slot holds ", count: 3)
    static let tagged = Bytes(Array("tagged".utf8), formatTag: "tg")
    static let bytes: [UInt8] = [0, 1, 2, 250, 251, 252, 253, 254, 255]

    /// The one call and the two it stands for, on a map of either kind: a
    /// new entry, an entry that has its key from an earlier transaction, an
    /// entry that was put without a key before, and the same key twice in
    /// one transaction.
    func oneCallIsTheTwoCalls<Map: WritableMapUnderTest>(_: Map.Type) throws {
        let pair = try Pair()
        func both(_ value: WritableData, _ key: some KeyRepresentable) -> (
            (Cursor<ReadWrite>) throws -> Void, (Cursor<ReadWrite>) throws -> Void
        ) {
            (
                { place in try Map(place).put(value, forKey: key, storingKey: true) },
                { place in
                    let map = try Map(place)
                    try map.putKey(key.keyData, forHash: Pair.hash(key))
                    try map.put(value, forHash: Pair.hash(key))
                }
            )
        }
        func step(_ what: String, _ value: WritableData, _ key: some KeyRepresentable) throws {
            let (one, two) = both(value, key)
            try pair.step(what, one: one, two: two)
        }

        // New entries: a short and a long key, a tagged one and plain bytes;
        // a number, bytes a slot holds and bytes it does not.
        try step("a short key and a number", .uint(1), Self.short)
        try step("a long key and short bytes", .bytes(Array("hi".utf8)), Self.long)
        try step("a tagged key and long bytes", .bytes(Array(Self.long.utf8)), Self.tagged)
        try step("a key of bytes and a double", .double(2.5), Self.bytes)

        // The same entries in later transactions: the keys are there.
        try step("the short key again", .uint(2), Self.short)
        try step("the long key again", .bytes(Array(Self.long.utf8)), Self.long)
        try step("the tagged key again", .int(-3), Self.tagged)

        // An entry that was put without its key, then with it: the key is
        // written now.
        try pair.step(
            "a put without the key",
            one: { place in try Map(place).put(.uint(7), forKey: "later") },
            two: { place in try Map(place).put(.uint(7), forHash: Pair.hash("later")) })
        try step("the key stored afterwards", .uint(8), "later")

        // Several in one transaction, one of them twice.
        try pair.step(
            "four puts in one transaction",
            one: { place in
                let map = try Map(place)
                try map.put(.uint(10), forKey: "x", storingKey: true)
                try map.put(.uint(11), forKey: "y", storingKey: true)
                try map.put(.uint(12), forKey: "x", storingKey: true)
                try map.put(.bytes(Array(Self.long.utf8)), forKey: Self.long, storingKey: true)
            },
            two: { place in
                let map = try Map(place)
                for (key, value) in [("x", WritableData.uint(10)), ("y", .uint(11)), ("x", .uint(12))] {
                    try map.putKey(key.keyData, forHash: Pair.hash(key))
                    try map.put(value, forHash: Pair.hash(key))
                }
                try map.putKey(Self.long.keyData, forHash: Pair.hash(Self.long))
                try map.put(.bytes(Array(Self.long.utf8)), forHash: Pair.hash(Self.long))
            })

        // What was written reads back, keys and values.
        let map = try Map.reading(try pair.placeOfOne())
        #expect(try map.cursor(forKey: Self.short)?.readUInt64() == 2)
        #expect(try map.keyCursor(forKey: Self.short)?.readBytes() == Array(Self.short.utf8))
        #expect(try map.keyCursor(forKey: Self.long)?.readBytes() == Array(Self.long.utf8))
        #expect(try map.keyCursor(forKey: Self.tagged)?.readBytesWithFormatTag() == Self.tagged)
        #expect(try map.keyCursor(forKey: Self.bytes)?.readBytes() == Self.bytes)
        #expect(try map.keyCursor(forKey: "later")?.readBytes() == Array("later".utf8))
        #expect(try map.cursor(forKey: "x")?.readUInt64() == 12)
    }

    @Test func onAMapTheOneCallIsPutKeyAndThenPut() throws {
        try oneCallIsTheTwoCalls(HashMap<ReadWrite>.self)
    }

    @Test func onACountedMapTheOneCallIsPutKeyAndThenPut() throws {
        try oneCallIsTheTwoCalls(CountedHashMap<ReadWrite>.self)
    }

    /// Without the argument, and with `false`, the put is the put it was:
    /// no key is stored.
    @Test func withoutTheArgumentNoKeyIsStored() throws {
        let pair = try Pair()
        try pair.step(
            "the plain put, and the argument given as false",
            one: { place in
                let map = try HashMap<ReadWrite>(place)
                try map.put(.uint(1), forKey: "a")
                try map.put(.uint(2), forKey: "b", storingKey: false)
                try map.put("text", forKey: "c", storingKey: false)
            },
            two: { place in
                let map = try HashMap<ReadWrite>(place)
                try map.put(.uint(1), forHash: Pair.hash("a"))
                try map.put(.uint(2), forHash: Pair.hash("b"))
                try map.put(.bytes(Array("text".utf8)), forHash: Pair.hash("c"))
            })
        let map = try HashMap<ReadOnly>(try pair.placeOfOne())
        for key in ["a", "b", "c"] {
            #expect(try map.keyCursor(forKey: key) == nil, "\(key)")
        }
    }

    /// At the root every write is a transaction of its own: the one call is
    /// one, where `putKey` and `put` are two. The file is the one that the
    /// paths of those two calls leave when one transaction holds both.
    @Test func atTheRootItIsOneTransaction() throws {
        let pair = try Pair()
        let one = try HashMap<ReadWrite>(pair.one.rootCursor)
        let two = try HashMap<ReadWrite>(pair.two.rootCursor)
        #expect(pair.oneStorage.bytes == pair.twoStorage.bytes)

        let before = pair.one.commitCount
        try one.put(.uint(5), forKey: "root key", storingKey: true)
        #expect(pair.one.commitCount == before + 1)

        // The same by the engine's paths in one transaction: the path of
        // `putKey` and then the path of `put` by hash, each from the root
        // as it is, which is where a write at the root starts. (A map made
        // around the transaction's cursor would copy the map's first block
        // into the transaction, which a write at the root does not.)
        let hash = sha1("root key")
        try pair.two.withTransaction { root in
            _ = try root.writePath([.hashMapGet(.key, hash), .ctx]) { key in
                try key.writeIfEmpty(.bytes(Array("root key".utf8)))
            }
            _ = try root.writePath([.hashMapGet(.value, hash), .write(.uint(5))])
        }
        #expect(pair.oneStorage.bytes == pair.twoStorage.bytes)

        // The two calls at the root are two transactions, and the one call
        // is one again; both maps then read the same.
        let commits = pair.two.commitCount
        try two.putKey("another")
        try two.put(.uint(6), forKey: "another")
        #expect(pair.two.commitCount == commits + 2)
        try one.put(.uint(6), forKey: "another", storingKey: true)
        #expect(pair.one.commitCount == before + 2)
        for map in [one.readOnly, two.readOnly] {
            #expect(try map.keyCursor(forKey: "another")?.readBytes() == Array("another".utf8))
            #expect(try map.cursor(forKey: "another")?.readUInt64() == 6)
            #expect(try map.keyCursor(forKey: "root key")?.readBytes() == Array("root key".utf8))
            #expect(try map.cursor(forKey: "root key")?.readUInt64() == 5)
        }
    }

    /// A key the entry has already is left as it is, as `putKey` leaves it,
    /// and the value is replaced.
    @Test func aKeyThatIsThereIsLeft() throws {
        let pair = try Pair()
        try pair.one.withTransaction { root in
            let map = try HashMap<ReadWrite>(try Pair.place(root))
            // The key kept under this hash is not the bytes that were hashed.
            try map.putKey(.bytes(Array("the first".utf8)), forHash: Pair.hash("name"))
            try map.put(.uint(1), forKey: "name", storingKey: true)
        }
        try pair.one.withTransaction { root in
            try HashMap<ReadWrite>(try Pair.place(root)).put(.uint(2), forKey: "name", storingKey: true)
        }
        let map = try HashMap<ReadOnly>(try pair.placeOfOne())
        #expect(try map.keyCursor(forKey: "name")?.readBytes() == Array("the first".utf8))
        #expect(try map.cursor(forKey: "name")?.readUInt64() == 2)
    }

    /// A counted map counts an entry once, when it is made.
    @Test func aCountedMapCountsTheEntryOnce() throws {
        let pair = try Pair()
        try pair.one.withTransaction { root in
            let map = try CountedHashMap<ReadWrite>(try Pair.place(root))
            try map.put(.uint(1), forKey: "a", storingKey: true)
            try map.put(.uint(2), forKey: "b", storingKey: true)
            try map.put(.uint(3), forKey: "a", storingKey: true)
            #expect(try map.count == 2)
        }
        try pair.one.withTransaction { root in
            let map = try CountedHashMap<ReadWrite>(try Pair.place(root))
            try map.put(.uint(4), forKey: "b", storingKey: true)
            try map.put(.uint(5), forKey: "c", storingKey: true)
            #expect(try map.count == 3)
            // A put that is refused makes no entry and counts none.
            #expect(throws: XitDBError.structuralSlot) {
                try map.put(.slot(Slot(value: 57, tag: .index)), forKey: "d", storingKey: true)
            }
            #expect(throws: XitDBError.structuralSlot) {
                try map.put(.uint(1), storingKey: .slot(Slot(value: 57, tag: .index)), forHash: sha1("d"))
            }
            #expect(try map.count == 3)
            #expect(try map.cursor(forKey: "d") == nil)
            // A value of the caller's own on a new entry counts it once.
            try map.put(Reading(place: "Oslo", degrees: -3), forKey: "e", storingKey: true)
            try map.put(Reading(place: "Oslo", degrees: -4), forKey: "e", storingKey: true)
            #expect(try map.count == 4)
        }
    }

    /// The typed put with the argument: a value of the library's own is the
    /// put of its data, and a value of the caller's writes itself after the
    /// key, in the entry the one walk made.
    @Test func theTypedPutStoresTheKeyToo() throws {
        let pair = try Pair()
        try pair.step(
            "values of the library's own",
            one: { place in
                let map = try HashMap<ReadWrite>(place)
                try map.put("Alice Smith", forKey: "alice", storingKey: true)
                try map.put(UInt64(25), forKey: "age", storingKey: true)
                try map.put(Int64(-4), forKey: Self.long, storingKey: true)
                try map.put(1.5, forKey: Self.tagged, storingKey: true)
            },
            two: { place in
                let map = try HashMap<ReadWrite>(place)
                let all: [(any KeyRepresentable, WritableData)] = [
                    ("alice", .bytes(Array("Alice Smith".utf8))), ("age", .uint(25)), (Self.long, .int(-4)),
                    (Self.tagged, .double(1.5)),
                ]
                for (key, value) in all {
                    try map.putKey(key.keyData, forHash: Pair.hash(key))
                    try map.put(value, forHash: Pair.hash(key))
                }
            })
        try pair.step(
            "a value that writes itself, on a new entry and on one that is there",
            one: { place in
                let map = try CountedHashMap<ReadWrite>(try HashMap<ReadWrite>(place).putCursor(forKey: "readings"))
                try map.put(Reading(place: "Oslo", degrees: -3), forKey: "oslo", storingKey: true)
                try map.put(Reading(place: "Lima", degrees: 19), forKey: "lima", storingKey: true)
                try map.put(Reading(place: "Oslo", degrees: -5), forKey: "oslo", storingKey: true)
            },
            two: { place in
                let map = try CountedHashMap<ReadWrite>(try HashMap<ReadWrite>(place).putCursor(forKey: "readings"))
                for (key, value) in [
                    ("oslo", Reading(place: "Oslo", degrees: -3)), ("lima", Reading(place: "Lima", degrees: 19)),
                    ("oslo", Reading(place: "Oslo", degrees: -5)),
                ] {
                    try map.putKey(key)
                    try map.put(value, forKey: key)
                }
            })
        let readings = try CountedHashMap<ReadOnly>(
            try #require(try HashMap<ReadOnly>(try pair.placeOfOne()).cursor(forKey: "readings")))
        #expect(try readings.value(forKey: "oslo", as: Reading.self) == Reading(place: "Oslo", degrees: -5))
        #expect(try readings.keyCursor(forKey: "lima")?.readBytes() == Array("lima".utf8))
        #expect(try readings.count == 2)
    }

    /// The value writes itself through the cursor the put without the
    /// argument gives it. At the root that cursor is the transaction's own,
    /// which goes on after a freeze: a value that freezes the database
    /// between its writes is written with the argument as without it.
    @Test func atTheRootTheValuesCursorIsTheTransactionsOwn() throws {
        let pair = try Pair()
        let map = try HashMap<ReadWrite>(pair.one.rootCursor)
        try map.put(FreezesBetweenWrites(number: 7), forKey: "without")
        try map.put(FreezesBetweenWrites(number: 8), forKey: "with", storingKey: true)
        #expect(try map.readOnly.value(forKey: "without", as: FreezesBetweenWrites.self)?.number == 7)
        #expect(try map.readOnly.value(forKey: "with", as: FreezesBetweenWrites.self)?.number == 8)
        #expect(try map.readOnly.keyCursor(forKey: "with")?.readBytes() == Array("with".utf8))
        #expect(try map.readOnly.keyCursor(forKey: "without") == nil)
    }

    /// A value that fails after it has written poisons the transaction, as
    /// the typed put without the argument does: the entry and its key are
    /// written by then, and nothing of the transaction is committed.
    @Test func aValueThatFailsAfterWritingPoisons() throws {
        let pair = try Pair()
        try pair.one.withTransaction { root in
            try HashMap<ReadWrite>(try Pair.place(root)).put(.uint(1), forKey: "before", storingKey: true)
        }
        let committed = pair.oneStorage.bytes
        var failure: XitDBError?
        var next: XitDBError?
        #expect(throws: XitDBError.poisonedTransaction) {
            try pair.one.withTransaction { root in
                let map = try HashMap<ReadWrite>(try Pair.place(root))
                do {
                    try map.put(FailsAfterWriting(), forKey: "broken", storingKey: true)
                } catch {
                    failure = error as? XitDBError
                }
                do {
                    try map.put(.uint(1), forKey: "after")
                } catch {
                    next = error as? XitDBError
                }
            }
        }
        #expect(failure == .invalidUTF8)
        #expect(next == .poisonedTransaction)
        #expect(pair.oneStorage.bytes == committed)
        let map = try HashMap<ReadOnly>(try pair.placeOfOne())
        #expect(try map.cursor(forKey: "broken") == nil)
        #expect(try map.keyCursor(forKey: "before")?.readBytes() == Array("before".utf8))
    }

    /// What is refused is refused before anything is written: a value that
    /// is one of the trees' own slots, and a keyed call on a database given
    /// no hasher.
    @Test func whatIsRefusedWritesNothing() throws {
        let pair = try Pair()
        try pair.one.withTransaction { root in
            let map = try HashMap<ReadWrite>(try Pair.place(root))
            try map.put(.uint(1), forKey: "there", storingKey: true)
        }
        let before = pair.oneStorage.bytes
        try pair.one.withTransaction { root in
            let map = try HashMap<ReadWrite>(try Pair.place(root))
            let length = try pair.one.storage.length
            #expect(throws: XitDBError.structuralSlot) {
                try map.put(.slot(Slot(value: 57, tag: .index)), forKey: "new", storingKey: true)
            }
            #expect(try pair.one.storage.length == length, "nothing written")
            #expect(try map.cursor(forKey: "new") == nil)
            // A key is bytes by every public way in; the walk underneath
            // checks it all the same, as `putKey` by hash checks its key.
            #expect(throws: XitDBError.structuralSlot) {
                try map.put(.uint(1), storingKey: .slot(Slot(value: 57, tag: .index)), forHash: sha1("new"))
            }
            #expect(try pair.one.storage.length == length, "nothing written")
            #expect(try map.cursor(forKey: "new") == nil)
            // The transaction is not poisoned: it goes on.
            try map.put(.uint(2), forKey: "there", storingKey: true)
        }
        #expect(pair.oneStorage.bytes != before)

        let none = try Database(creating: MemoryStorage(), hashSize: 20)
        try none.withTransaction { root in
            let map = try HashMap<ReadWrite>(root)
            #expect(throws: XitDBError.noKeyHashing) { try map.put(.uint(1), forKey: "a", storingKey: true) }
            #expect(throws: XitDBError.noKeyHashing) { try map.put("text", forKey: "a", storingKey: true) }
        }
    }

    /// The argument is given put by put. An entry put without it among
    /// entries put with it has no key, and no error says so: iterating
    /// gives it like the others, its key is at an empty slot, which reads
    /// as no bytes and as an empty text (a number read of it is refused),
    /// and `keyCursor(forKey:)` gives nothing for it.
    @Test func aPutWithoutTheArgumentAmongPutsWithItHasNoKey() throws {
        let pair = try Pair()
        try pair.one.withTransaction { root in
            let map = try HashMap<ReadWrite>(try Pair.place(root))
            try map.put(.uint(1), forKey: "one", storingKey: true)
            try map.put(.uint(2), forKey: "two", storingKey: true)
            try map.put(.uint(3), forKey: "forgotten")
            try map.put(.uint(4), forKey: "four", storingKey: true)
        }
        let map = try HashMap<ReadOnly>(try pair.placeOfOne())
        var names: [String] = []
        var withoutKey = 0
        var iterator = try map.iterator()
        while let next = try iterator.next() {
            let entry = try next.readEntry()
            if try entry.key.slot.isEmpty {
                withoutKey += 1
                #expect(try entry.key.readBytes() == [])
                #expect(try entry.key.read(String.self) == "")
                #expect(try entry.key.read([UInt8].self) == [])
                #expect(try entry.key.read(Bytes.self) == Bytes([]))
                #expect(throws: XitDBError.unexpectedTag) { try entry.key.read(UInt64.self) }
                #expect(try entry.value.readUInt64() == 3)
                #expect(entry.hash == Pair.hash("forgotten"))
            } else {
                names.append(try entry.key.read(String.self))
            }
        }
        #expect(names.sorted() == ["four", "one", "two"])
        #expect(withoutKey == 1)
        #expect(try map.keyCursor(forKey: "forgotten") == nil)
        #expect(try map.cursor(forKey: "forgotten")?.readUInt64() == 3)
    }
}
