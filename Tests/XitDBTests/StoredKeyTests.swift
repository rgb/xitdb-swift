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
private struct Weather: StorableValue, Equatable {
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

/// A key that counts how often it is asked for its bytes.
private final class CountedKey: KeyRepresentable {
    let text: String
    private(set) var asked = 0

    init(_ text: String) {
        self.text = text
    }

    var keyBytes: [UInt8] {
        asked += 1
        return Array(text.utf8)
    }
}

/// A value of the conformance script `put-key-then-value`: text or a
/// number.
private enum ScriptValue {
    case text(String)
    case number(UInt64)

    var data: WritableData {
        switch self {
        case .text(let text): .bytes(Array(text.utf8))
        case .number(let number): .uint(number)
        }
    }
}

/// What the script does to one entry of a map: its key by write-if-empty
/// and then its value, or its value alone.
private struct ScriptStep {
    let key: String
    let value: ScriptValue
    let withKey: Bool

    init(_ key: String, _ value: ScriptValue, withKey: Bool = true) {
        self.key = key
        self.value = value
        self.withKey = withKey
    }
}

/// The ways the library has of doing what the script does to an entry.
enum StoredKeyWriting: CaseIterable, CustomTestStringConvertible {
    /// `putKey` and then `put`, as the script's two paths.
    case twoCalls
    /// The put that stores its key, of a value that is data.
    case oneCall
    /// The put that stores its key, of a typed value.
    case oneTypedCall
    /// The put cursor that stores its key, and a write through it.
    case putCursorAndAWrite

    var testDescription: String {
        switch self {
        case .twoCalls: "putKey and then put"
        case .oneCall: "the one call"
        case .oneTypedCall: "the one call with a typed value"
        case .putCursorAndAWrite: "the put cursor that stores its key, and a write through it"
        }
    }
}

@Suite struct StoredKeyTests {
    /// Keys of each kind a key comes in, short and long.
    static let short = "a"
    static let long = String(repeating: "a long key, longer than a slot holds ", count: 3)
    static let otherLong = String(repeating: "another key that a slot does not hold ", count: 2)
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
        // A new entry whose key and value are both records of their own:
        // the one place where the order of the two writes shows in the
        // file.
        try step("a new long key and long bytes", .bytes(Array(Self.long.utf8)), Self.otherLong)

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
    /// no key is stored. `plainPuts` makes the puts on the map's own type,
    /// which is where the argument's default is; through the tests'
    /// protocol the argument is always given.
    func noKeyIsStored<Map: WritableMapUnderTest>(
        _: Map.Type, plainPuts: (Cursor<ReadWrite>) throws -> Void
    ) throws {
        let pair = try Pair()
        try pair.step(
            "the plain put, and the argument given as false",
            one: plainPuts,
            two: { place in
                let map = try Map(place)
                try map.put(.uint(1), forHash: Pair.hash("a"))
                try map.put(.uint(2), forHash: Pair.hash("b"))
                try map.put(.bytes(Array("text".utf8)), forHash: Pair.hash("c"))
                try map.put(.bytes(Array("more text".utf8)), forHash: Pair.hash("d"))
                try map.put(Weather(place: "Oslo", degrees: -3), forKey: "e", storingKey: false)
            })
        let map = try Map.reading(try pair.placeOfOne())
        for key in ["a", "b", "c", "d", "e"] {
            #expect(try map.keyCursor(forKey: key) == nil, "\(key)")
        }
    }

    @Test func withoutTheArgumentNoKeyIsStored() throws {
        try noKeyIsStored(HashMap<ReadWrite>.self) { place in
            let map = try HashMap<ReadWrite>(place)
            try map.put(.uint(1), forKey: "a")
            try map.put(.uint(2), forKey: "b", storingKey: false)
            try map.put("text", forKey: "c", storingKey: false)
            try map.put("more text", forKey: "d")
            try map.put(Weather(place: "Oslo", degrees: -3), forKey: "e")
        }
        try noKeyIsStored(CountedHashMap<ReadWrite>.self) { place in
            let map = try CountedHashMap<ReadWrite>(place)
            try map.put(.uint(1), forKey: "a")
            try map.put(.uint(2), forKey: "b", storingKey: false)
            try map.put("text", forKey: "c", storingKey: false)
            try map.put("more text", forKey: "d")
            try map.put(Weather(place: "Oslo", degrees: -3), forKey: "e")
        }
    }

    /// At the root every write is a transaction of its own: the one call is
    /// one, where `putKey` and `put` are two. The file is the one that
    /// those two calls leave when one transaction holds both, on a map
    /// that exists.
    @Test func atTheRootItIsOneTransaction() throws {
        let pair = try Pair()
        let one = try HashMap<ReadWrite>(pair.one.rootCursor)
        let two = try HashMap<ReadWrite>(pair.two.rootCursor)
        #expect(pair.oneStorage.bytes == pair.twoStorage.bytes)

        let before = pair.one.commitCount
        try one.put(.uint(5), forKey: "root key", storingKey: true)
        #expect(pair.one.commitCount == before + 1)

        // The two calls in one transaction, on the map that exists: the
        // same file. (Making the map at the root is a transaction of its
        // own, which is why both sides made it first.)
        try pair.two.withTransaction { root in
            let map = try HashMap<ReadWrite>(root)
            try map.putKey("root key")
            try map.put(.uint(5), forHash: Pair.hash("root key"))
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
    /// and the value is replaced: for a value that is data and for one
    /// that writes itself.
    func aKeyThatIsThereIsLeft<Map: WritableMapUnderTest>(_: Map.Type) throws {
        let pair = try Pair()
        try pair.one.withTransaction { root in
            let map = try Map(try Pair.place(root))
            // The keys kept under these hashes are not the bytes that were
            // hashed.
            try map.putKey(.bytes(Array("the first".utf8)), forHash: Pair.hash("name"))
            try map.put(.uint(1), forKey: "name", storingKey: true)
            try map.putKey(.bytes(Array("the first weather".utf8)), forHash: Pair.hash("weather"))
            try map.put(Weather(place: "Oslo", degrees: -3), forKey: "weather", storingKey: true)
        }
        try pair.one.withTransaction { root in
            let map = try Map(try Pair.place(root))
            try map.put(.uint(2), forKey: "name", storingKey: true)
            try map.put(Weather(place: "Lima", degrees: 19), forKey: "weather", storingKey: true)
        }
        let map = try Map.reading(try pair.placeOfOne())
        #expect(try map.keyCursor(forKey: "name")?.readBytes() == Array("the first".utf8))
        #expect(try map.cursor(forKey: "name")?.readUInt64() == 2)
        #expect(try map.keyCursor(forKey: "weather")?.readBytes() == Array("the first weather".utf8))
        let weather = try Weather(reading: try #require(try map.cursor(forKey: "weather")))
        #expect(weather == Weather(place: "Lima", degrees: 19))
    }

    @Test func aKeyThatIsThereIsLeftOnBothMaps() throws {
        try aKeyThatIsThereIsLeft(HashMap<ReadWrite>.self)
        try aKeyThatIsThereIsLeft(CountedHashMap<ReadWrite>.self)
    }

    /// The cursor's checks come before the checks of what is written, as
    /// for a path with a write part: with no transaction open a put that
    /// would also be refused for its value is refused for the transaction.
    func theCursorsChecksComeFirst<Map: WritableMapUnderTest>(_: Map.Type) throws {
        let pair = try Pair()
        var kept: Map?
        try pair.one.withTransaction { root in kept = try Map(try Pair.place(root)) }
        let map = try #require(kept)
        let before = pair.oneStorage.bytes
        #expect(throws: XitDBError.expectedTxStart) {
            try map.put(.slot(Slot(value: 57, tag: .index)), forKey: "a", storingKey: true)
        }
        #expect(throws: XitDBError.expectedTxStart) { try map.put(.uint(1), forKey: "a", storingKey: true) }
        #expect(pair.oneStorage.bytes == before)
    }

    @Test func theCursorsChecksComeFirstOnBothMaps() throws {
        try theCursorsChecksComeFirst(HashMap<ReadWrite>.self)
        try theCursorsChecksComeFirst(CountedHashMap<ReadWrite>.self)
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
            try map.put(Weather(place: "Oslo", degrees: -3), forKey: "e", storingKey: true)
            try map.put(Weather(place: "Oslo", degrees: -4), forKey: "e", storingKey: true)
            #expect(try map.count == 4)
        }
    }

    /// The typed put with the argument: a value of the library's own is the
    /// put of its data, and a value of the caller's writes itself after the
    /// key, in the entry the one walk made. Each is held against `putKey`
    /// and then the put, on new entries and on ones that are there, with
    /// keys a slot holds and keys it does not.
    func theTypedPutIsTheTwoCalls<Map: WritableMapUnderTest>(_: Map.Type) throws {
        let pair = try Pair()
        try pair.step(
            "values of the library's own",
            one: { place in
                let map = try Map(place)
                try map.put("Alice Smith", forKey: "alice", storingKey: true)
                try map.put(UInt64(25), forKey: "age", storingKey: true)
                try map.put(Int64(-4), forKey: Self.long, storingKey: true)
                try map.put(1.5, forKey: Self.tagged, storingKey: true)
                // A key and a value that are both records of their own.
                try map.put(Self.long, forKey: Self.otherLong, storingKey: true)
            },
            two: { place in
                let map = try Map(place)
                let all: [(any KeyRepresentable, WritableData)] = [
                    ("alice", .bytes(Array("Alice Smith".utf8))), ("age", .uint(25)), (Self.long, .int(-4)),
                    (Self.tagged, .double(1.5)), (Self.otherLong, .bytes(Array(Self.long.utf8))),
                ]
                for (key, value) in all {
                    try map.putKey(key.keyData, forHash: Pair.hash(key))
                    try map.put(value, forHash: Pair.hash(key))
                }
            })
        try pair.step(
            "a value that writes itself, on new entries and on one that is there",
            one: { place in
                let map = try Map(try Map(place).putCursor(forKey: "weather"))
                try map.put(Weather(place: "Oslo", degrees: -3), forKey: "oslo", storingKey: true)
                // A key that is a record of its own, before a value that
                // writes blocks of its own.
                try map.put(Weather(place: "Lima", degrees: 19), forKey: Self.long, storingKey: true)
                try map.put(Weather(place: "Oslo", degrees: -5), forKey: "oslo", storingKey: true)
            },
            two: { place in
                let map = try Map(try Map(place).putCursor(forKey: "weather"))
                let all: [(String, Weather)] = [
                    ("oslo", Weather(place: "Oslo", degrees: -3)), (Self.long, Weather(place: "Lima", degrees: 19)),
                    ("oslo", Weather(place: "Oslo", degrees: -5)),
                ]
                for (key, value) in all {
                    try map.putKey(key)
                    try map.put(value, forKey: key, storingKey: false)
                }
            })
        let top = try Map.reading(try pair.placeOfOne())
        #expect(try top.keyCursor(forKey: "alice")?.readBytes() == Array("alice".utf8))
        #expect(try top.keyCursor(forKey: Self.otherLong)?.readBytes() == Array(Self.otherLong.utf8))
        #expect(try top.keyCursor(forKey: Self.tagged)?.readBytesWithFormatTag() == Self.tagged)
        let weather = try Map.reading(try #require(try top.cursor(forKey: "weather")))
        #expect(
            try Weather(reading: try #require(try weather.cursor(forKey: "oslo")))
                == Weather(place: "Oslo", degrees: -5))
        #expect(try weather.keyCursor(forKey: "oslo")?.readBytes() == Array("oslo".utf8))
        #expect(try weather.keyCursor(forKey: Self.long)?.readBytes() == Array(Self.long.utf8))
    }

    @Test func onAMapTheTypedPutIsPutKeyAndThenPut() throws {
        try theTypedPutIsTheTwoCalls(HashMap<ReadWrite>.self)
    }

    @Test func onACountedMapTheTypedPutIsPutKeyAndThenPut() throws {
        try theTypedPutIsTheTwoCalls(CountedHashMap<ReadWrite>.self)
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

    /// A put that stores its key asks the key for its bytes once: they are
    /// hashed, and they are what is stored. Without the argument it is once
    /// too, as it was. So it is for `putKey` and for a set's `insert`,
    /// which hash the key and store it as well.
    @Test func theKeyIsAskedForItsBytesOnce() throws {
        let pair = try Pair()
        try pair.one.withTransaction { root in
            let map = try HashMap<ReadWrite>(try Pair.place(root))
            let counted = try CountedHashMap<ReadWrite>(map.putCursor(forKey: "counted"))

            let data = CountedKey("data")
            try map.put(.uint(1), forKey: data, storingKey: true)
            #expect(data.asked == 1)
            let own = CountedKey("a value of the library's own")
            try map.put("text", forKey: own, storingKey: true)
            #expect(own.asked == 1)
            let itself = CountedKey("a value that writes itself")
            try map.put(Weather(place: "Oslo", degrees: -3), forKey: itself, storingKey: true)
            #expect(itself.asked == 1)
            let plain = CountedKey("without the argument")
            try map.put(.uint(2), forKey: plain)
            #expect(plain.asked == 1)

            let countedData = CountedKey("data")
            try counted.put(.uint(1), forKey: countedData, storingKey: true)
            #expect(countedData.asked == 1)
            let countedItself = CountedKey("a value that writes itself")
            try counted.put(Weather(place: "Lima", degrees: 19), forKey: countedItself, storingKey: true)
            #expect(countedItself.asked == 1)

            let mapKey = CountedKey("put as a key")
            try map.putKey(mapKey)
            #expect(mapKey.asked == 1)
            let countedMapKey = CountedKey("put as a key")
            try counted.putKey(countedMapKey)
            #expect(countedMapKey.asked == 1)
            let set = try HashSet<ReadWrite>(map.putCursor(forKey: "set"))
            let member = CountedKey("a member")
            try set.insert(member)
            #expect(member.asked == 1)
            let countedSet = try CountedHashSet<ReadWrite>(map.putCursor(forKey: "counted set"))
            let countedMember = CountedKey("a member")
            try countedSet.insert(countedMember)
            #expect(countedMember.asked == 1)
            #expect(try map.keyCursor(forKey: "put as a key")?.readBytes() == Array("put as a key".utf8))
            #expect(try counted.keyCursor(forKey: "put as a key")?.readBytes() == Array("put as a key".utf8))
            #expect(try set.readOnly.cursor(forKey: "a member")?.readBytes() == Array("a member".utf8))
            #expect(try countedSet.readOnly.cursor(forKey: "a member")?.readBytes() == Array("a member".utf8))
            #expect(try countedSet.count == 1)

            // What was hashed is what was stored.
            #expect(try map.keyCursor(forKey: "data")?.readBytes() == Array("data".utf8))
            #expect(
                try map.keyCursor(forKey: "a value that writes itself")?.readBytes()
                    == Array("a value that writes itself".utf8))
            #expect(try counted.keyCursor(forKey: "data")?.readBytes() == Array("data".utf8))
        }
    }

    /// The layout of an entry is the engine's, written down once: the hash,
    /// the key's slot, the value's slot. From the pair to the key, from the
    /// key to the value, and from the value back to the key.
    @Test func theEngineLaysAnEntryOutBothWays() throws {
        let hashSizes: [UInt16] = [1, 20, 32, 64]
        let pairs: [UInt64] = [0, 12, 1 << 40]
        for hashSize in hashSizes {
            for pair in pairs {
                let key = try DatabaseReader.keySlotPosition(inPairAt: pair, hashSize: hashSize)
                let value = try DatabaseReader.valueSlotPosition(afterKeySlotAt: key)
                #expect(key == pair + UInt64(hashSize))
                #expect(value == key + Slot.byteCount)
                #expect(try DatabaseReader.keySlotPosition(beforeValueSlotAt: value) == key)
            }
        }
        #expect(try DatabaseReader.keySlotPosition(beforeValueSlotAt: Slot.byteCount) == 0)
        // No pair's value is where there is no room for a key's slot before
        // it, and no slot is beyond the last position.
        #expect(throws: XitDBError.endOfStream) {
            try DatabaseReader.keySlotPosition(beforeValueSlotAt: Slot.byteCount - 1)
        }
        let last = UInt64.max
        #expect(throws: XitDBError.endOfStream) { try DatabaseReader.valueSlotPosition(afterKeySlotAt: last) }
        #expect(throws: XitDBError.endOfStream) {
            try DatabaseReader.keySlotPosition(inPairAt: last, hashSize: 20)
        }
    }

    /// The key's slot the engine hands out beside a value's is the entry's
    /// own, as the storage holds it; and a cursor with no position has no
    /// entry to have a key beside.
    @Test func theKeyBesideAValueIsTheEntrysOwn() throws {
        let pair = try Pair()
        try pair.one.withTransaction { root in
            let map = try HashMap<ReadWrite>(try Pair.place(root))
            try map.putKey("with a key")
            let value = try map.putCursor(forKey: "with a key")
            let key = try value.keyCursorBesideValue()
            #expect(try key.slot == (try map.putKeyCursor(forKey: "with a key").slot))
            #expect(try key.readOnly.readBytes() == Array("with a key".utf8))

            let bare = try map.putCursor(forKey: "without")
            #expect(try bare.keyCursorBesideValue().slot.isEmpty)

            let nowhere = Cursor<ReadWrite>(
                slotPointer: SlotPointer(position: nil, slot: Slot()), database: pair.one)
            #expect(throws: XitDBError.cursorNotWritable) { try nowhere.keyCursorBesideValue() }
        }
    }

    // MARK: Against the original

    /// The first transaction of the conformance script
    /// `put-key-then-value`, on each of its two maps: two entries with
    /// their keys, a short one and one too long for a slot, and two with a
    /// value alone.
    private static let firstTransaction = [
        ScriptStep("short", .text("one")),
        ScriptStep("a key too long for a slot", .text("the long key's first value")),
        ScriptStep("alone", .number(1), withKey: false),
        ScriptStep("alone, with a key too long for a slot", .number(2), withKey: false),
    ]

    /// Its second transaction: the two entries that have their keys, the
    /// two that have none, and a new one, each by its key and then its
    /// value.
    private static let secondTransaction = [
        ScriptStep("short", .text("two")),
        ScriptStep("a key too long for a slot", .text("the long key's second value")),
        ScriptStep("alone", .number(3)),
        ScriptStep("alone, with a key too long for a slot", .number(4)),
        ScriptStep("a new key, too long for a slot", .text("new")),
    ]

    /// One step of the script on one map, in one of the library's ways.
    private static func write<Map: WritableMapUnderTest>(
        _ step: ScriptStep, to map: Map, by writing: StoredKeyWriting
    ) throws {
        guard step.withKey else {
            try map.put(step.value.data, forKey: step.key)
            return
        }
        switch writing {
        case .twoCalls:
            try map.putKey(step.key)
            try map.put(step.value.data, forKey: step.key)
        case .oneCall:
            try map.put(step.value.data, forKey: step.key, storingKey: true)
        case .oneTypedCall:
            switch step.value {
            case .text(let text): try map.put(text, forKey: step.key, storingKey: true)
            case .number(let number): try map.put(number, forKey: step.key, storingKey: true)
            }
        case .putCursorAndAWrite:
            var value = try map.putCursor(forKey: step.key, storingKey: true)
            try value.write(step.value.data)
        }
    }

    /// The commit IDs a fixture's sidecar records, in order.
    private static func commitIDs(inSidecar path: String) throws -> [UInt64] {
        let json = try JSONSerialization.jsonObject(with: Data(try fixtureFile(path)))
        let ops = try #require((json as? [String: Any])?["ops"] as? [[String: Any]])
        return ops.compactMap { op in
            (op["commit_id"] as? String).map { hex($0).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        }
    }

    /// The file the original writes for `putKey` and then `put` under one
    /// hash in one transaction is the fixture `put-key-then-value`, which
    /// the conformance tests replay through the engine's paths. Here the
    /// script's two transactions are written through the collections, with
    /// the sidecar's commit IDs, in each of the library's ways: by the two
    /// calls in the script's order, by the one call that stores the key,
    /// by that call with a typed value, and by the put cursor that stores
    /// the key with a write through it. Each leaves the original's file,
    /// byte for byte, on the map and on the counted map.
    ///
    /// The script has what the side-by-side tests above cannot hold
    /// against the original: an entry that has its key in a later
    /// transaction, where the walk copies the pair and write-if-empty
    /// writes nothing; an entry that got a value alone and gets its key
    /// later, short and too long for a slot; and the counted map's count,
    /// which moves where the entry is made.
    @Test(arguments: StoredKeyWriting.allCases)
    func everyWritingLeavesTheOriginalsFile(writing: StoredKeyWriting) throws {
        let expected = try fixtureFile("valid/put-key-then-value.db")
        let commitIDs = try Self.commitIDs(inSidecar: "valid/put-key-then-value.db.sidecar.json")
        #expect(commitIDs.count == 2)

        let storage = MemoryStorage()
        let database = try Database(
            creating: storage, hashSize: 20, hashID: "sha1", fileID: 0xc0f0_0000_0000_00b1,
            random: RandomSource(FixedRandom(commitIDs)), hasher: KeyHasher(Insecure.SHA1.self))
        let transactions = [(Self.firstTransaction, UInt64(4)), (Self.secondTransaction, UInt64(5))]
        for (steps, count) in transactions {
            try database.withTransaction { root in
                let top = try HashMap<ReadWrite>(root)
                let plain = try HashMap<ReadWrite>(top.putCursor(forKey: "plain"))
                let counted = try CountedHashMap<ReadWrite>(top.putCursor(forKey: "counted"))
                for step in steps { try Self.write(step, to: plain, by: writing) }
                for step in steps { try Self.write(step, to: counted, by: writing) }
                #expect(try counted.count == count)
            }
        }
        #expect(storage.bytes.count == expected.count)
        #expect(storage.bytes == expected)
    }

    // MARK: The put cursor

    /// The put cursor that stores its key is `putKey` and then the put
    /// cursor, in one walk: the same file, for a new entry whose key is a
    /// record of its own and has a collection made on the cursor, for a
    /// write through the cursor, for an entry that has its key, and for
    /// one that was made without it.
    func thePutCursorIsTheTwoCalls<Map: WritableMapUnderTest>(_: Map.Type) throws {
        let pair = try Pair()
        try pair.step(
            "new entries: a collection made on the cursor, and a write through it",
            one: { place in
                let map = try Map(place)
                let fruits = try ArrayList<ReadWrite>(try map.putCursor(forKey: Self.long, storingKey: true))
                try fruits.append(.bytes(Array("an apple that is longer than a slot".utf8)))
                var value = try map.putCursor(forKey: "a", storingKey: true)
                try value.write(.bytes(Array(Self.otherLong.utf8)))
                try map.put(.uint(7), forKey: "made without its key")
            },
            two: { place in
                let map = try Map(place)
                try map.putKey(Self.long)
                let fruits = try ArrayList<ReadWrite>(try map.putCursor(forKey: Self.long, storingKey: false))
                try fruits.append(.bytes(Array("an apple that is longer than a slot".utf8)))
                try map.putKey("a")
                var value = try map.putCursor(forKey: "a", storingKey: false)
                try value.write(.bytes(Array(Self.otherLong.utf8)))
                try map.put(.uint(7), forHash: Pair.hash("made without its key"))
            })
        try pair.step(
            "a later transaction: the entries with their keys, the one without, and a new one",
            one: { place in
                let map = try Map(place)
                let fruits = try ArrayList<ReadWrite>(try map.putCursor(forKey: Self.long, storingKey: true))
                try fruits.append(.uint(2))
                var value = try map.putCursor(forKey: "a", storingKey: true)
                try value.write(.uint(3))
                var later = try map.putCursor(forKey: "made without its key", storingKey: true)
                try later.write(.uint(8))
                var new = try map.putCursor(forKey: Self.tagged, storingKey: true)
                try new.write(.uint(9))
            },
            two: { place in
                let map = try Map(place)
                try map.putKey(Self.long)
                let fruits = try ArrayList<ReadWrite>(try map.putCursor(forKey: Self.long, storingKey: false))
                try fruits.append(.uint(2))
                try map.putKey("a")
                var value = try map.putCursor(forKey: "a", storingKey: false)
                try value.write(.uint(3))
                try map.putKey("made without its key")
                var later = try map.putCursor(forKey: "made without its key", storingKey: false)
                try later.write(.uint(8))
                try map.putKey(Self.tagged)
                var new = try map.putCursor(forKey: Self.tagged, storingKey: false)
                try new.write(.uint(9))
            })
        let map = try Map.reading(try pair.placeOfOne())
        #expect(try map.keyCursor(forKey: Self.long)?.readBytes() == Array(Self.long.utf8))
        #expect(try map.keyCursor(forKey: "a")?.readBytes() == Array("a".utf8))
        #expect(try map.keyCursor(forKey: "made without its key")?.readBytes() == Array("made without its key".utf8))
        #expect(try map.keyCursor(forKey: Self.tagged)?.readBytesWithFormatTag() == Self.tagged)
        #expect(try map.cursor(forKey: "a")?.readUInt64() == 3)
        #expect(try map.cursor(forKey: "made without its key")?.readUInt64() == 8)
        let fruits = try ArrayList<ReadOnly>(try #require(try map.cursor(forKey: Self.long)))
        #expect(try fruits.count == 2)
    }

    @Test func onAMapThePutCursorIsPutKeyAndThenThePutCursor() throws {
        try thePutCursorIsTheTwoCalls(HashMap<ReadWrite>.self)
    }

    @Test func onACountedMapThePutCursorIsPutKeyAndThenThePutCursor() throws {
        try thePutCursorIsTheTwoCalls(CountedHashMap<ReadWrite>.self)
    }

    /// Without the argument, and with `false`, the put cursor stores no
    /// key, by calls on each map's own type, which is where the argument's
    /// default is; and a key that is there is left by the put cursor that
    /// stores its key.
    @Test func thePutCursorStoresNoKeyUnlessAsked() throws {
        let pair = try Pair()
        try pair.one.withTransaction { root in
            let top = try HashMap<ReadWrite>(try Pair.place(root))
            let map = try HashMap<ReadWrite>(try top.putCursor(forKey: "map"))
            let counted = try CountedHashMap<ReadWrite>(try top.putCursor(forKey: "counted", storingKey: false))
            var plain = try map.putCursor(forKey: "plain")
            try plain.write(.uint(1))
            var given = try map.putCursor(forKey: "given as false", storingKey: false)
            try given.write(.uint(2))
            var countedPlain = try counted.putCursor(forKey: "plain")
            try countedPlain.write(.uint(1))
            var countedGiven = try counted.putCursor(forKey: "given as false", storingKey: false)
            try countedGiven.write(.uint(2))
            #expect(try counted.count == 2)

            // The key kept under this hash is not the bytes that were
            // hashed: the put cursor leaves it.
            try map.putKey(.bytes(Array("the first".utf8)), forHash: Pair.hash("name"))
            var name = try map.putCursor(forKey: "name", storingKey: true)
            try name.write(.uint(3))
            try counted.putKey(.bytes(Array("the first".utf8)), forHash: Pair.hash("name"))
            var countedName = try counted.putCursor(forKey: "name", storingKey: true)
            try countedName.write(.uint(3))
            // The count moves where the entry is made, once.
            _ = try counted.putCursor(forKey: "name", storingKey: true)
            #expect(try counted.count == 3)
        }
        let top = try HashMap<ReadOnly>(try pair.placeOfOne())
        #expect(try top.keyCursor(forKey: "map") == nil)
        #expect(try top.keyCursor(forKey: "counted") == nil)
        let map = try HashMap<ReadOnly>(try #require(try top.cursor(forKey: "map")))
        let counted = try CountedHashMap<ReadOnly>(try #require(try top.cursor(forKey: "counted")))
        for key in ["plain", "given as false"] {
            #expect(try map.keyCursor(forKey: key) == nil, "\(key)")
            #expect(try counted.keyCursor(forKey: key) == nil, "\(key)")
        }
        #expect(try map.keyCursor(forKey: "name")?.readBytes() == Array("the first".utf8))
        #expect(try counted.keyCursor(forKey: "name")?.readBytes() == Array("the first".utf8))
        #expect(try map.cursor(forKey: "name")?.readUInt64() == 3)
        #expect(try counted.cursor(forKey: "name")?.readUInt64() == 3)
    }

    /// At the root the put cursor that stores its key is one transaction,
    /// where `putKey` and the put cursor are two; the entry has its key
    /// and no value, and a write through the cursor that comes back is
    /// refused, as without the argument: the transaction is over.
    @Test func atTheRootThePutCursorIsOneTransaction() throws {
        let pair = try Pair()
        let one = try HashMap<ReadWrite>(pair.one.rootCursor)
        let two = try HashMap<ReadWrite>(pair.two.rootCursor)
        #expect(pair.oneStorage.bytes == pair.twoStorage.bytes)

        let before = pair.one.commitCount
        var value = try one.putCursor(forKey: "root key", storingKey: true)
        #expect(pair.one.commitCount == before + 1)
        #expect(throws: XitDBError.expectedTxStart) { try value.write(.uint(1)) }
        #expect(try one.readOnly.keyCursor(forKey: "root key")?.readBytes() == Array("root key".utf8))
        #expect(try one.readOnly.slot(forKey: "root key") == nil, "the value was never written")

        // The two calls in one transaction, on the map that exists: the
        // same file.
        try pair.two.withTransaction { root in
            let map = try HashMap<ReadWrite>(root)
            try map.putKey("root key")
            _ = try map.putCursor(forKey: "root key")
        }
        #expect(pair.oneStorage.bytes == pair.twoStorage.bytes)

        let commits = pair.two.commitCount
        try two.putKey("another")
        _ = try two.putCursor(forKey: "another")
        #expect(pair.two.commitCount == commits + 2)
    }

    /// The put cursor that stores its key asks the key for its bytes once,
    /// refuses what cannot be a key before anything is written, and lets
    /// the cursor's checks come first.
    @Test func thePutCursorAsksOnceAndRefusesFirst() throws {
        let pair = try Pair()
        var kept: HashMap<ReadWrite>?
        try pair.one.withTransaction { root in
            let map = try HashMap<ReadWrite>(try Pair.place(root))
            let counted = try CountedHashMap<ReadWrite>(try map.putCursor(forKey: "counted"))
            kept = map

            let key = CountedKey("asked once")
            _ = try map.putCursor(forKey: key, storingKey: true)
            #expect(key.asked == 1)
            let plain = CountedKey("without the argument")
            _ = try map.putCursor(forKey: plain)
            #expect(plain.asked == 1)
            let countedKey = CountedKey("asked once")
            _ = try counted.putCursor(forKey: countedKey, storingKey: true)
            #expect(countedKey.asked == 1)
            #expect(try map.keyCursor(forKey: "asked once")?.readBytes() == Array("asked once".utf8))
            #expect(try counted.keyCursor(forKey: "asked once")?.readBytes() == Array("asked once".utf8))

            // A key is bytes by every public way in; the walk underneath
            // checks it all the same, before the entry is made.
            let length = try pair.one.storage.length
            let structural = WritableData.slot(Slot(value: 57, tag: .index))
            #expect(throws: XitDBError.structuralSlot) {
                try map.putCursor(storingKey: structural, forHash: sha1("no"))
            }
            #expect(throws: XitDBError.structuralSlot) {
                try counted.putCursor(storingKey: structural, forHash: sha1("no"))
            }
            #expect(try pair.one.storage.length == length, "nothing written")
            #expect(try map.cursor(forKey: "no") == nil)
            #expect(try counted.count == 1)
        }
        // With no transaction open the cursor's refusal comes before the
        // key's.
        let map = try #require(kept)
        #expect(throws: XitDBError.expectedTxStart) {
            try map.putCursor(storingKey: .slot(Slot(value: 57, tag: .index)), forHash: sha1("no"))
        }
        #expect(throws: XitDBError.expectedTxStart) { try map.putCursor(forKey: "no", storingKey: true) }

        let none = try Database(creating: MemoryStorage(), hashSize: 20)
        try none.withTransaction { root in
            let map = try HashMap<ReadWrite>(root)
            #expect(throws: XitDBError.noKeyHashing) { try map.putCursor(forKey: "a", storingKey: true) }
        }
    }
}
