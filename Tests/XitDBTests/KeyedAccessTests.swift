import Foundation
import Testing
import XitDBHashing

@testable import XitDB

// The calls that take a key (decision D35, item 2): on each hashed
// collection, each is the call by hash with the hasher's hash of the key's
// bytes, and nothing more. The fixtures prove the bytes the calls by hash
// write, so what is proved here is that a keyed call is its twin: two
// databases are written side by side, one through the keys and one through
// the hashes the test computes, and are the same file after every step.

/// What the two hashed maps share, so that one test body runs on both.
protocol MapUnderTest {
    associatedtype Access: CursorAccess
    var cursor: Cursor<Access> { get }

    func cursor(forKey key: some KeyRepresentable) throws(XitDBError) -> Cursor<ReadOnly>?
    func slot(forKey key: some KeyRepresentable) throws(XitDBError) -> Slot?
    func keyCursor(forKey key: some KeyRepresentable) throws(XitDBError) -> Cursor<ReadOnly>?
    func keySlot(forKey key: some KeyRepresentable) throws(XitDBError) -> Slot?
    func entry(forKey key: some KeyRepresentable) throws(XitDBError) -> Entry?

    func cursor(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Cursor<ReadOnly>?
    func slot(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Slot?
    func keyCursor(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Cursor<ReadOnly>?
    func keySlot(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Slot?
    func entry(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Entry?
}

protocol WritableMapUnderTest: MapUnderTest where Access == ReadWrite {
    associatedtype Reading: MapUnderTest
    init(_ cursor: Cursor<ReadWrite>) throws(XitDBError)
    static func reading(_ cursor: Cursor<ReadOnly>) throws(XitDBError) -> Reading

    func put(_ value: WritableData, forKey key: some KeyRepresentable) throws(XitDBError)
    func putCursor(forKey key: some KeyRepresentable) throws(XitDBError) -> Cursor<ReadWrite>
    func putKey(_ key: some KeyRepresentable) throws(XitDBError)
    func putKeyCursor(forKey key: some KeyRepresentable) throws(XitDBError) -> Cursor<ReadWrite>
    func remove(forKey key: some KeyRepresentable) throws(XitDBError) -> Bool

    func put(_ value: WritableData, forHash hash: some Sequence<UInt8>) throws(XitDBError)
    func putCursor(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Cursor<ReadWrite>
    func putKey(_ key: WritableData, forHash hash: some Sequence<UInt8>) throws(XitDBError)
    func putKeyCursor(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Cursor<ReadWrite>
    func remove(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Bool
}

extension HashMap: MapUnderTest {}
extension CountedHashMap: MapUnderTest {}
extension HashMap: WritableMapUnderTest where Access == ReadWrite {
    static func reading(_ cursor: Cursor<ReadOnly>) throws(XitDBError) -> HashMap<ReadOnly> {
        try HashMap<ReadOnly>(cursor)
    }
}
extension CountedHashMap: WritableMapUnderTest where Access == ReadWrite {
    static func reading(_ cursor: Cursor<ReadOnly>) throws(XitDBError) -> CountedHashMap<ReadOnly> {
        try CountedHashMap<ReadOnly>(cursor)
    }
}

/// What the two hashed sets share.
protocol SetUnderTest {
    associatedtype Access: CursorAccess
    var cursor: Cursor<Access> { get }

    func cursor(forKey key: some KeyRepresentable) throws(XitDBError) -> Cursor<ReadOnly>?
    func slot(forKey key: some KeyRepresentable) throws(XitDBError) -> Slot?
    func contains(_ key: some KeyRepresentable) throws(XitDBError) -> Bool

    func cursor(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Cursor<ReadOnly>?
    func slot(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Slot?
    func contains(hash: some Sequence<UInt8>) throws(XitDBError) -> Bool
}

protocol WritableSetUnderTest: SetUnderTest where Access == ReadWrite {
    associatedtype Reading: SetUnderTest
    init(_ cursor: Cursor<ReadWrite>) throws(XitDBError)
    static func reading(_ cursor: Cursor<ReadOnly>) throws(XitDBError) -> Reading

    func insert(_ key: some KeyRepresentable) throws(XitDBError)
    func insertCursor(forKey key: some KeyRepresentable) throws(XitDBError) -> Cursor<ReadWrite>
    func remove(forKey key: some KeyRepresentable) throws(XitDBError) -> Bool

    func insert(_ key: WritableData, forHash hash: some Sequence<UInt8>) throws(XitDBError)
    func insertCursor(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Cursor<ReadWrite>
    func remove(forHash hash: some Sequence<UInt8>) throws(XitDBError) -> Bool
}

extension HashSet: SetUnderTest {}
extension CountedHashSet: SetUnderTest {}
extension HashSet: WritableSetUnderTest where Access == ReadWrite {
    static func reading(_ cursor: Cursor<ReadOnly>) throws(XitDBError) -> HashSet<ReadOnly> {
        try HashSet<ReadOnly>(cursor)
    }
}
extension CountedHashSet: WritableSetUnderTest where Access == ReadWrite {
    static func reading(_ cursor: Cursor<ReadOnly>) throws(XitDBError) -> CountedHashSet<ReadOnly> {
        try CountedHashSet<ReadOnly>(cursor)
    }
}

/// The names of a record's fields: a type whose raw value is a key.
private enum Field: String, KeyRepresentable {
    case name
    case age
}

/// A key type of the tests' own, which gives its bytes itself.
private struct Reversed: KeyRepresentable {
    let text: String
    var keyBytes: [UInt8] { Array(text.utf8.reversed()) }
}

/// Two databases with the same header and the same commit IDs: one given a
/// hasher and written through keys, one given none and written through the
/// hashes the test computes with the same hash function.
private struct Twins<Hashing: KeyHashing> {
    let keyedStorage = MemoryStorage()
    let hashedStorage = MemoryStorage()
    let keyed: Database
    let hashed: Database

    init(_ hashing: Hashing.Type) throws {
        keyed = try Database(
            creating: keyedStorage, hashSize: Hashing.size, hashID: "test", fileID: 0x10,
            random: RandomSource(SeededGenerator(seed: 29)), hasher: KeyHasher(hashing))
        hashed = try Database(
            creating: hashedStorage, hashSize: Hashing.size, hashID: "test", fileID: 0x10,
            random: RandomSource(SeededGenerator(seed: 29)))
    }

    /// The hash of a key, as the test computes it: the hash function over
    /// the key's bytes.
    func hash(_ key: some KeyRepresentable) -> [UInt8] {
        Hashing.keyHash(of: key)
    }

    /// The slot the collection under test lives in: the value under a fixed
    /// hash in a map at the root, so that it is written inside a
    /// transaction like any collection below the root.
    private func place(_ root: Cursor<ReadWrite>) throws -> Cursor<ReadWrite> {
        try HashMap<ReadWrite>(root).putCursor(forHash: [UInt8](repeating: 0x11, count: Hashing.size))
    }

    /// One step: a transaction on each database, the first through keys and
    /// the second through hashes, after which the two files are the same.
    func step(
        _ what: String,
        keyed keyedBody: (Cursor<ReadWrite>) throws -> Void,
        hashed hashedBody: (Cursor<ReadWrite>) throws -> Void
    ) throws {
        try keyed.withTransaction { root in try keyedBody(try place(root)) }
        try hashed.withTransaction { root in try hashedBody(try place(root)) }
        #expect(keyedStorage.bytes == hashedStorage.bytes, "after \(what)")
    }

    /// A read-only cursor at the collection under test, in the database
    /// that was given the hasher.
    func keyedPlace() throws -> Cursor<ReadOnly> {
        let root = try HashMap<ReadOnly>(keyed.rootCursor)
        return try #require(try root.cursor(forHash: [UInt8](repeating: 0x11, count: Hashing.size)))
    }
}

@Suite struct KeyedAccessTests {
    // MARK: Keys

    /// A key is its bytes: a string's UTF-8, a substring's, an array
    /// itself, the value of tagged bytes without the tag, the raw value's
    /// bytes for a type that has one, and whatever a type of the caller's
    /// says.
    @Test func aKeyIsItsBytes() {
        let name = utf8("name")
        #expect("name".keyBytes == name)
        #expect("a name"[...].dropFirst(2).keyBytes == name)
        #expect(name.keyBytes == name)
        #expect(Bytes(name).keyBytes == name)
        #expect(Bytes(name, formatTag: "tg").keyBytes == name)
        #expect(Field.name.keyBytes == name)
        #expect(Reversed(text: "eman").keyBytes == name)
        #expect("".keyBytes.isEmpty)
        // UTF-8 as it is, with nothing normalised: the two spellings of é
        // are equal strings and different keys.
        #expect("\u{E9}" == "e\u{301}")
        #expect("\u{E9}".keyBytes == [0xC3, 0xA9])
        #expect("e\u{301}".keyBytes == [0x65, 0xCC, 0x81])
    }

    // MARK: Maps

    /// Every keyed write on a map is the write by hash with the hasher's
    /// hash of the key's bytes: the file is the same after each.
    func mapWritesMatch<Hashing: KeyHashing, Map: WritableMapUnderTest>(
        _ hashing: Hashing.Type, _ map: Map.Type
    ) throws {
        let twins = try Twins(hashing)
        let tagged = Bytes(utf8("three"), formatTag: "tg")

        try twins.step("a put") {
            try Map($0).put(.uint(1), forKey: "one")
        } hashed: {
            try Map($0).put(.uint(1), forHash: twins.hash("one"))
        }
        try twins.step("a put over a value") {
            try Map($0).put(.bytes(utf8("first")), forKey: "one")
        } hashed: {
            try Map($0).put(.bytes(utf8("first")), forHash: twins.hash("one"))
        }
        try twins.step("a put cursor and a write through it") {
            var cursor = try Map($0).putCursor(forKey: "two")
            try cursor.write(.int(-2))
        } hashed: {
            var cursor = try Map($0).putCursor(forHash: twins.hash("two"))
            try cursor.write(.int(-2))
        }
        try twins.step("a put cursor with nothing written") {
            _ = try Map($0).putCursor(forKey: "unwritten")
        } hashed: {
            _ = try Map($0).putCursor(forHash: twins.hash("unwritten"))
        }
        try twins.step("a key stored") {
            try Map($0).putKey("one")
        } hashed: {
            try Map($0).putKey(.bytes(utf8("one")), forHash: twins.hash("one"))
        }
        try twins.step("a key stored again") {
            try Map($0).putKey("one")
        } hashed: {
            try Map($0).putKey(.bytes(utf8("one")), forHash: twins.hash("one"))
        }
        try twins.step("a key stored where the map had no entry") {
            try Map($0).putKey("key alone")
        } hashed: {
            try Map($0).putKey(.bytes(utf8("key alone")), forHash: twins.hash("key alone"))
        }
        try twins.step("a tagged key stored") {
            try Map($0).putKey(tagged)
        } hashed: {
            try Map($0).putKey(.bytes(utf8("three"), formatTag: "tg"), forHash: twins.hash(utf8("three")))
        }
        try twins.step("a key cursor and a write through it") {
            var cursor = try Map($0).putKeyCursor(forKey: "four")
            try cursor.write(.bytes(utf8("4")))
        } hashed: {
            var cursor = try Map($0).putKeyCursor(forHash: twins.hash("four"))
            try cursor.write(.bytes(utf8("4")))
        }
        try twins.step("puts by keys of every type") {
            let map = try Map($0)
            try map.put(.uint(10), forKey: "a substring"[...].dropFirst(2))
            try map.put(.uint(11), forKey: [UInt8]([0, 1, 2, 255]))
            try map.put(.uint(12), forKey: Bytes([9, 9], formatTag: "zz"))
            try map.put(.uint(13), forKey: Field.age)
            try map.put(.uint(14), forKey: Reversed(text: "abc"))
            try map.put(.uint(15), forKey: "")
            try map.put(.uint(16), forKey: "\u{E9}")
            try map.put(.uint(17), forKey: "e\u{301}")
        } hashed: {
            let map = try Map($0)
            try map.put(.uint(10), forHash: twins.hash(utf8("substring")))
            try map.put(.uint(11), forHash: twins.hash([UInt8]([0, 1, 2, 255])))
            try map.put(.uint(12), forHash: twins.hash([UInt8]([9, 9])))
            try map.put(.uint(13), forHash: twins.hash(utf8("age")))
            try map.put(.uint(14), forHash: twins.hash(utf8("cba")))
            try map.put(.uint(15), forHash: twins.hash([UInt8]()))
            try map.put(.uint(16), forHash: twins.hash([UInt8]([0xC3, 0xA9])))
            try map.put(.uint(17), forHash: twins.hash([UInt8]([0x65, 0xCC, 0x81])))
        }
        try twins.step("a remove of a key that is there") {
            let removed = try Map($0).remove(forKey: "two")
            #expect(removed == true)
        } hashed: {
            let removed = try Map($0).remove(forHash: twins.hash("two"))
            #expect(removed)
        }
        try twins.step("a remove of a key that is not there") {
            let removed = try Map($0).remove(forKey: "absent")
            #expect(removed == false)
        } hashed: {
            let removed = try Map($0).remove(forHash: twins.hash("absent"))
            #expect(!removed)
        }

        // What the keys read is what their hashes read, in a transaction's
        // view and in the committed one.
        let keys: [any KeyRepresentable] = [
            "one", "two", "unwritten", "key alone", tagged, "four", "absent", Field.age, Field.name, "",
            "\u{E9}", "e\u{301}", Reversed(text: "abc"), utf8("three"), "substring"[...],
        ]
        let committed = try Map.reading(try twins.keyedPlace())
        for key in keys {
            try Self.expectMapReadsMatch(committed, key, hash: twins.hash(key))
        }
        try twins.keyed.withTransaction { root in
            let map = try Map(
                try HashMap<ReadWrite>(root).putCursor(forHash: [UInt8](repeating: 0x11, count: Hashing.size)))
            for key in keys {
                try Self.expectMapReadsMatch(map, key, hash: twins.hash(key))
            }
        }
        // And in a snapshot, which carries the hasher.
        let snapshot = try twins.keyed.snapshot()
        let pinnedRoot = try HashMap<ReadOnly>(snapshot.rootCursor)
        let pinned = try Map.reading(
            try #require(try pinnedRoot.cursor(forHash: [UInt8](repeating: 0x11, count: Hashing.size))))
        for key in keys {
            try Self.expectMapReadsMatch(pinned, key, hash: twins.hash(key))
        }
        // Some of them are there, so the comparison is not of nothing with
        // nothing.
        #expect(try committed.cursor(forKey: "one")?.readBytes() == utf8("first"))
        #expect(try committed.cursor(forKey: Field.age)?.readUInt64() == 13)
        #expect(try committed.cursor(forKey: "two") == nil)
        #expect(try committed.slot(forKey: "\u{E9}")?.value == 16)
        #expect(try committed.slot(forKey: "e\u{301}")?.value == 17)
    }

    /// Checks that each keyed read of a map gives what its twin by hash
    /// gives.
    static func expectMapReadsMatch(_ map: some MapUnderTest, _ key: some KeyRepresentable, hash: [UInt8]) throws {
        let what = "\(key)"
        #expect(try map.slot(forKey: key) == map.slot(forHash: hash), "slot of \(what)")
        #expect(try map.keySlot(forKey: key) == map.keySlot(forHash: hash), "key slot of \(what)")
        let cursor = try map.cursor(forKey: key)
        let twin = try map.cursor(forHash: hash)
        #expect(try cursor?.slot == twin?.slot, "cursor of \(what)")
        #expect(cursor?.slotPointer.position == twin?.slotPointer.position, "cursor's position of \(what)")
        let keyCursor = try map.keyCursor(forKey: key)
        let keyTwin = try map.keyCursor(forHash: hash)
        #expect(try keyCursor?.slot == keyTwin?.slot, "key cursor of \(what)")
        #expect(keyCursor?.slotPointer.position == keyTwin?.slotPointer.position, "key cursor's position of \(what)")
        let entry = try map.entry(forKey: key)
        let entryTwin = try map.entry(forHash: hash)
        #expect((entry == nil) == (entryTwin == nil), "entry of \(what)")
        if let entry, let entryTwin {
            #expect(entry.hash == hash, "entry's hash of \(what)")
            #expect(entry.hash == entryTwin.hash)
            #expect(try entry.key.slot == entryTwin.key.slot)
            #expect(try entry.value.slot == entryTwin.value.slot)
        }
    }

    @Test func aKeyedWriteOnAMapIsTheWriteByHash() throws {
        try mapWritesMatch(SHA256.self, HashMap<ReadWrite>.self)
        try mapWritesMatch(Insecure.SHA1.self, HashMap<ReadWrite>.self)
        try mapWritesMatch(WideHash.self, HashMap<ReadWrite>.self)
    }

    @Test func aKeyedWriteOnACountedMapIsTheWriteByHash() throws {
        try mapWritesMatch(SHA256.self, CountedHashMap<ReadWrite>.self)
        try mapWritesMatch(Insecure.SHA1.self, CountedHashMap<ReadWrite>.self)
        try mapWritesMatch(WideHash.self, CountedHashMap<ReadWrite>.self)
    }

    /// A keyed put stores the value and not the key: the entry's key is
    /// empty until `putKey` stores it, which writes the key's bytes, once,
    /// with the format tag of tagged bytes.
    func aPutDoesNotStoreTheKey<Map: WritableMapUnderTest>(_ map: Map.Type) throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self, hashID: "sha2")
        try database.withTransaction { root in
            let map = try Map(root)
            try map.put(.uint(25), forKey: "age")
            #expect(try map.keySlot(forKey: "age") == nil)
            #expect(try map.keyCursor(forKey: "age") == nil)
            let entry = try #require(try map.entry(forKey: "age"))
            #expect(try entry.key.slot.isEmpty)
            #expect(try entry.value.readUInt64() == 25)

            try map.putKey("age")
            #expect(try map.keyCursor(forKey: "age")?.readBytesWithFormatTag() == Bytes(utf8("age")))
            // The value is as it was.
            #expect(try map.cursor(forKey: "age")?.readUInt64() == 25)

            // Tagged bytes are one key with the same bytes untagged, and
            // the key that is stored is the one stored first.
            let tagged = Bytes(utf8("name"), formatTag: "tg")
            try map.putKey(tagged)
            #expect(try map.keyCursor(forKey: "name")?.readBytesWithFormatTag() == tagged)
            try map.putKey("name")
            #expect(try map.keyCursor(forKey: utf8("name"))?.readBytesWithFormatTag() == tagged)
            try map.put(.uint(1), forKey: Field.name)
            #expect(try map.cursor(forKey: tagged)?.readUInt64() == 1)

            // A key cursor makes the entry, and its key is what is written
            // through it.
            var keyCursor = try map.putKeyCursor(forKey: "other")
            #expect(try map.keySlot(forKey: "other") == nil)
            try keyCursor.write(.bytes(utf8("anything")))
            #expect(try map.keyCursor(forKey: "other")?.readBytes() == utf8("anything"))
        }
    }

    @Test func aKeyedPutDoesNotStoreTheKey() throws {
        try aPutDoesNotStoreTheKey(HashMap<ReadWrite>.self)
        try aPutDoesNotStoreTheKey(CountedHashMap<ReadWrite>.self)
    }

    /// A counted map counts keyed puts and removes as it counts those by
    /// hash.
    @Test func aCountedMapCountsKeyedWrites() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { root in
            let map = try CountedHashMap<ReadWrite>(root)
            try map.put(.uint(1), forKey: "a")
            try map.put(.uint(2), forKey: "b")
            try map.put(.uint(3), forKey: "a")
            try map.putKey("c")
            #expect(try map.count == 3)
            #expect(try map.remove(forKey: "b") == true)
            #expect(try map.remove(forKey: "b") == false)
            #expect(try map.count == 2)
        }
    }

    // MARK: Sets

    /// Every keyed write on a set is the write by hash with the hasher's
    /// hash of the key's bytes, and an insert writes the key's bytes as
    /// the member.
    func setWritesMatch<Hashing: KeyHashing, Set: WritableSetUnderTest>(
        _ hashing: Hashing.Type, _ set: Set.Type
    ) throws {
        let twins = try Twins(hashing)
        let tagged = Bytes(utf8("tagged"), formatTag: "tg")

        try twins.step("an insert") {
            try Set($0).insert("apple")
        } hashed: {
            try Set($0).insert(.bytes(utf8("apple")), forHash: twins.hash("apple"))
        }
        try twins.step("an insert of a key that is there") {
            try Set($0).insert("apple")
        } hashed: {
            try Set($0).insert(.bytes(utf8("apple")), forHash: twins.hash("apple"))
        }
        try twins.step("an insert of tagged bytes") {
            try Set($0).insert(tagged)
        } hashed: {
            try Set($0).insert(.bytes(utf8("tagged"), formatTag: "tg"), forHash: twins.hash(utf8("tagged")))
        }
        try twins.step("inserts of keys of every type") {
            let set = try Set($0)
            try set.insert("a substring"[...].dropFirst(2))
            try set.insert([UInt8]([0, 1, 2, 255]))
            try set.insert(Field.age)
            try set.insert(Reversed(text: "abc"))
            try set.insert("")
            // A key longer than a slot holds, which gets a record of its
            // own.
            try set.insert(String(repeating: "long ", count: 20))
        } hashed: {
            let set = try Set($0)
            try set.insert(.bytes(utf8("substring")), forHash: twins.hash(utf8("substring")))
            try set.insert(.bytes([0, 1, 2, 255]), forHash: twins.hash([UInt8]([0, 1, 2, 255])))
            try set.insert(.bytes(utf8("age")), forHash: twins.hash(utf8("age")))
            try set.insert(.bytes(utf8("cba")), forHash: twins.hash(utf8("cba")))
            try set.insert(.bytes([]), forHash: twins.hash([UInt8]()))
            let long = utf8(String(repeating: "long ", count: 20))
            try set.insert(.bytes(long), forHash: twins.hash(long))
        }
        try twins.step("an insert cursor and a write through it") {
            var cursor = try Set($0).insertCursor(forKey: "pear")
            try cursor.write(.bytes(utf8("pear")))
        } hashed: {
            var cursor = try Set($0).insertCursor(forHash: twins.hash("pear"))
            try cursor.write(.bytes(utf8("pear")))
        }
        try twins.step("an insert cursor with nothing written") {
            _ = try Set($0).insertCursor(forKey: "unwritten")
        } hashed: {
            _ = try Set($0).insertCursor(forHash: twins.hash("unwritten"))
        }
        try twins.step("a remove of a key that is there") {
            let removed = try Set($0).remove(forKey: Field.age)
            #expect(removed == true)
        } hashed: {
            let removed = try Set($0).remove(forHash: twins.hash(utf8("age")))
            #expect(removed)
        }
        try twins.step("a remove of a key that is not there") {
            let removed = try Set($0).remove(forKey: "absent")
            #expect(removed == false)
        } hashed: {
            let removed = try Set($0).remove(forHash: twins.hash("absent"))
            #expect(!removed)
        }

        let keys: [any KeyRepresentable] = [
            "apple", tagged, utf8("tagged"), "substring", Field.age, Field.name, "", "pear", "unwritten", "absent",
            Reversed(text: "abc"),
        ]
        let committed = try Set.reading(try twins.keyedPlace())
        for key in keys {
            try Self.expectSetReadsMatch(committed, key, hash: twins.hash(key))
        }
        let snapshot = try twins.keyed.snapshot()
        let pinnedRoot = try HashMap<ReadOnly>(snapshot.rootCursor)
        let pinned = try Set.reading(
            try #require(try pinnedRoot.cursor(forHash: [UInt8](repeating: 0x11, count: Hashing.size))))
        for key in keys {
            try Self.expectSetReadsMatch(pinned, key, hash: twins.hash(key))
        }

        // The member is the key's bytes, with the tag of tagged bytes.
        #expect(try committed.contains("apple"))
        #expect(try committed.cursor(forKey: "apple")?.readBytesWithFormatTag() == Bytes(utf8("apple")))
        #expect(try committed.cursor(forKey: utf8("tagged"))?.readBytesWithFormatTag() == tagged)
        #expect(try committed.cursor(forKey: "")?.readBytes() == [])
        #expect(try committed.contains("pear"))
        // An entry whose key was never written is not a member, and a key
        // removed is not one.
        #expect(try !committed.contains("unwritten"), "\(hashing)")
        #expect(try !committed.contains(Field.age), "\(hashing)")
        #expect(try !committed.contains("absent"), "\(hashing)")
    }

    /// Checks that each keyed read of a set gives what its twin by hash
    /// gives.
    static func expectSetReadsMatch(_ set: some SetUnderTest, _ key: some KeyRepresentable, hash: [UInt8]) throws {
        let what = "\(key)"
        #expect(try set.slot(forKey: key) == set.slot(forHash: hash), "slot of \(what)")
        #expect(try set.contains(key) == set.contains(hash: hash), "contains \(what)")
        let cursor = try set.cursor(forKey: key)
        let twin = try set.cursor(forHash: hash)
        #expect(try cursor?.slot == twin?.slot, "cursor of \(what)")
        #expect(cursor?.slotPointer.position == twin?.slotPointer.position, "cursor's position of \(what)")
    }

    @Test func aKeyedWriteOnASetIsTheWriteByHash() throws {
        try setWritesMatch(SHA256.self, HashSet<ReadWrite>.self)
        try setWritesMatch(Insecure.SHA1.self, HashSet<ReadWrite>.self)
        try setWritesMatch(WideHash.self, HashSet<ReadWrite>.self)
    }

    @Test func aKeyedWriteOnACountedSetIsTheWriteByHash() throws {
        try setWritesMatch(SHA256.self, CountedHashSet<ReadWrite>.self)
        try setWritesMatch(Insecure.SHA1.self, CountedHashSet<ReadWrite>.self)
        try setWritesMatch(WideHash.self, CountedHashSet<ReadWrite>.self)
    }

    /// A counted set counts keyed inserts and removes.
    @Test func aCountedSetCountsKeyedWrites() throws {
        let database = try Database(creating: MemoryStorage(), hashing: Insecure.SHA1.self)
        try database.withTransaction { root in
            let set = try CountedHashSet<ReadWrite>(root)
            try set.insert("a")
            try set.insert("b")
            try set.insert("a")
            #expect(try set.count == 2)
            #expect(try set.remove(forKey: "a") == true)
            #expect(try set.remove(forKey: "a") == false)
            #expect(try set.count == 1)
            #expect(try set.contains("b"))
        }
    }

    // MARK: At the root

    /// On a collection at the root every keyed write is a transaction of
    /// its own, as the write by hash is, and writes the same file.
    @Test func aKeyedWriteAtTheRootIsATransactionOfItsOwn() throws {
        let twins = try Twins(SHA256.self)
        let keyed = try HashMap<ReadWrite>(twins.keyed.rootCursor)
        let hashed = try HashMap<ReadWrite>(twins.hashed.rootCursor)
        #expect(twins.keyedStorage.bytes == twins.hashedStorage.bytes)

        try keyed.put(.uint(1), forKey: "one")
        try hashed.put(.uint(1), forHash: twins.hash("one"))
        #expect(twins.keyedStorage.bytes == twins.hashedStorage.bytes)

        try keyed.putKey("one")
        try hashed.putKey(.bytes(utf8("one")), forHash: twins.hash("one"))
        #expect(twins.keyedStorage.bytes == twins.hashedStorage.bytes)

        #expect(try keyed.remove(forKey: "one") == true)
        #expect(try hashed.remove(forHash: twins.hash("one")) == true)
        #expect(twins.keyedStorage.bytes == twins.hashedStorage.bytes)
        #expect(try keyed.readOnly.slot(forKey: "one") == nil)
    }

    // MARK: No hasher

    /// On a database that was given no hasher every keyed call throws
    /// `noKeyHashing`, on every hashed collection, reading and writing,
    /// live and from a snapshot, and writes nothing; the calls by hash go
    /// on working.
    @Test func withoutAHasherEveryKeyedCallIsRefused() throws {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashSize: 20, hashID: "sha1")
        let hash = hashInt("one")
        try database.withTransaction { root in
            let top = try HashMap<ReadWrite>(root)
            try HashMap<ReadWrite>(top.putCursor(forHash: hashInt("map"))).put(.uint(1), forHash: hash)
            try CountedHashMap<ReadWrite>(top.putCursor(forHash: hashInt("counted map"))).put(.uint(1), forHash: hash)
            try HashSet<ReadWrite>(top.putCursor(forHash: hashInt("set"))).insert(.bytes(utf8("one")), forHash: hash)
            try CountedHashSet<ReadWrite>(top.putCursor(forHash: hashInt("counted set")))
                .insert(.bytes(utf8("one")), forHash: hash)
        }
        let before = storage.bytes

        func refused<Result>(_ what: String, _ body: () throws -> Result) {
            #expect(throws: XitDBError.noKeyHashing, "\(what)") { try body() }
        }
        func checkMapReads(_ map: some MapUnderTest, _ what: String) {
            refused("\(what) cursor") { try map.cursor(forKey: "one") }
            refused("\(what) slot") { try map.slot(forKey: "one") }
            refused("\(what) keyCursor") { try map.keyCursor(forKey: "one") }
            refused("\(what) keySlot") { try map.keySlot(forKey: "one") }
            refused("\(what) entry") { try map.entry(forKey: "one") }
        }
        func checkMapWrites(_ map: some WritableMapUnderTest, _ what: String) {
            refused("\(what) put") { try map.put(.uint(2), forKey: "one") }
            refused("\(what) putCursor") { try map.putCursor(forKey: "one") }
            refused("\(what) putKey") { try map.putKey("one") }
            refused("\(what) putKeyCursor") { try map.putKeyCursor(forKey: "one") }
            refused("\(what) remove") { try map.remove(forKey: "one") }
        }
        func checkSetReads(_ set: some SetUnderTest, _ what: String) {
            refused("\(what) cursor") { try set.cursor(forKey: "one") }
            refused("\(what) slot") { try set.slot(forKey: "one") }
            refused("\(what) contains") { try set.contains("one") }
        }
        func checkSetWrites(_ set: some WritableSetUnderTest, _ what: String) {
            refused("\(what) insert") { try set.insert("two") }
            refused("\(what) insertCursor") { try set.insertCursor(forKey: "two") }
            refused("\(what) remove") { try set.remove(forKey: "one") }
        }

        // Committed, through the live database and through a snapshot.
        for (root, where_) in [
            (Cursor<ReadOnly>(viewing: database.rootCursor), "live"), (try database.snapshot().rootCursor, "snapshot"),
        ] {
            let top = try HashMap<ReadOnly>(root)
            checkMapReads(try HashMap<ReadOnly>(try #require(try top.cursor(forHash: hashInt("map")))), "\(where_) map")
            checkMapReads(
                try CountedHashMap<ReadOnly>(try #require(try top.cursor(forHash: hashInt("counted map")))),
                "\(where_) counted map")
            checkSetReads(try HashSet<ReadOnly>(try #require(try top.cursor(forHash: hashInt("set")))), "\(where_) set")
            checkSetReads(
                try CountedHashSet<ReadOnly>(try #require(try top.cursor(forHash: hashInt("counted set")))),
                "\(where_) counted set")
            checkMapReads(top, "\(where_) root map")
        }

        // In a transaction: the refusal comes before anything is written,
        // so the transaction commits what the calls by hash wrote and
        // nothing else, and is not poisoned.
        try database.withTransaction { root in
            let top = try HashMap<ReadWrite>(root)
            let map = try HashMap<ReadWrite>(top.putCursor(forHash: hashInt("map")))
            let counted = try CountedHashMap<ReadWrite>(top.putCursor(forHash: hashInt("counted map")))
            let set = try HashSet<ReadWrite>(top.putCursor(forHash: hashInt("set")))
            let countedSet = try CountedHashSet<ReadWrite>(top.putCursor(forHash: hashInt("counted set")))
            let written = try storage.length
            checkMapReads(map, "map in a transaction")
            checkMapWrites(map, "map")
            checkMapReads(counted, "counted map in a transaction")
            checkMapWrites(counted, "counted map")
            checkSetReads(set, "set in a transaction")
            checkSetWrites(set, "set")
            checkSetReads(countedSet, "counted set in a transaction")
            checkSetWrites(countedSet, "counted set")
            #expect(try storage.length == written)
            #expect(try counted.count == 1)
            #expect(try countedSet.count == 1)
            // The calls by hash work as ever.
            #expect(try map.cursor(forHash: hash)?.readUInt64() == 1)
            #expect(try set.contains(hash: hash))
        }

        // Outside a transaction a keyed write below the root is refused for
        // the hasher before it is refused for the transaction.
        let top = try HashMap<ReadWrite>(database.rootCursor)
        refused("a put cursor at the root") { try top.putCursor(forKey: "map") }
        let below = try HashMap<ReadWrite>(unchecked: top.putCursor(forHash: hashInt("map")))
        let after = storage.bytes
        refused("a put below the root outside a transaction") { try below.put(.uint(3), forKey: "one") }
        #expect(throws: XitDBError.expectedTxStart) { try below.put(.uint(3), forHash: hash) }
        #expect(storage.bytes == after)
        #expect(after.count > before.count)
    }

    /// With a hasher, a keyed call throws what its twin throws.
    @Test func aKeyedCallThrowsWhatItsTwinThrows() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let top = try HashMap<ReadWrite>(database.rootCursor)
        try top.put(.uint(1), forKey: "number")
        // Below the root and outside a transaction.
        let below = try HashMap<ReadWrite>(unchecked: top.putCursor(forKey: "map"))
        #expect(throws: XitDBError.expectedTxStart) { try below.put(.uint(1), forKey: "one") }
        #expect(throws: XitDBError.expectedTxStart) { try below.putKey("one") }
        #expect(throws: XitDBError.expectedTxStart) { try below.remove(forKey: "one") }
        // A slot that holds another kind.
        let number = try #require(try top.readOnly.cursor(forKey: "number"))
        let wrong = HashMap<ReadOnly>(unchecked: number)
        #expect(throws: XitDBError.unexpectedTag) { try wrong.cursor(forKey: "one") }
        #expect(throws: XitDBError.unexpectedTag) { try HashSet<ReadOnly>(unchecked: number).contains("one") }
        // Inside a transaction, through the root.
        try database.withTransaction { root in
            let inside = try HashMap<ReadWrite>(root)
            try inside.put(.uint(2), forKey: "two")
            #expect(throws: XitDBError.nestedTopLevelWrite) { try top.put(.uint(3), forKey: "three") }
        }
        #expect(try top.readOnly.cursor(forKey: "two")?.readUInt64() == 2)
        #expect(try top.readOnly.slot(forKey: "three") == nil)
    }

    /// A hasher that gives fewer bytes than its size: each keyed call is
    /// refused as a hash of the wrong size is, `invalidHashSize`, once
    /// there is a map to look in; an empty slot checks no hash and has no
    /// entry, as for a hash given directly.
    @Test func aHasherThatBreaksItsWordIsRefusedByTheCall() throws {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashing: ShortDigestHash.self)
        let empty = try HashMap<ReadOnly>(database.rootCursor)
        #expect(try empty.cursor(forKey: "one") == nil)
        #expect(try empty.slot(forKey: "one") == nil)
        #expect(try HashSet<ReadOnly>(database.rootCursor).contains("one") == false)

        let top = try HashMap<ReadWrite>(database.rootCursor)
        try top.put(.uint(1), forHash: [UInt8](repeating: 7, count: 20))
        let before = storage.bytes
        #expect(throws: XitDBError.invalidHashSize) { try top.put(.uint(1), forKey: "one") }
        #expect(throws: XitDBError.invalidHashSize) { try top.putCursor(forKey: "one") }
        #expect(throws: XitDBError.invalidHashSize) { try top.putKey("one") }
        #expect(throws: XitDBError.invalidHashSize) { try top.putKeyCursor(forKey: "one") }
        #expect(throws: XitDBError.invalidHashSize) { try top.remove(forKey: "one") }
        #expect(throws: XitDBError.invalidHashSize) { try top.readOnly.cursor(forKey: "one") }
        #expect(throws: XitDBError.invalidHashSize) { try top.readOnly.slot(forKey: "one") }
        #expect(throws: XitDBError.invalidHashSize) { try top.readOnly.keyCursor(forKey: "one") }
        #expect(throws: XitDBError.invalidHashSize) { try top.readOnly.keySlot(forKey: "one") }
        #expect(throws: XitDBError.invalidHashSize) { try top.readOnly.entry(forKey: "one") }
        #expect(storage.bytes == before)
    }
}

/// The sorted collections take a key as its bytes: each call by a key is
/// the call by a span of the key's bytes, and hashes nothing.
@Suite struct SortedKeyFormTests {
    /// Two databases without a hasher, with the same header and commit IDs.
    private static func twins() throws -> (
        text: Database, textBytes: MemoryStorage, bytes: Database, bytesBytes: MemoryStorage
    ) {
        let first = MemoryStorage()
        let second = MemoryStorage()
        let text = try Database(
            creating: first, hashSize: 20, hashID: "sha1", fileID: 0x10, random: SeededGenerator(seed: 3))
        let bytes = try Database(
            creating: second, hashSize: 20, hashID: "sha1", fileID: 0x10, random: SeededGenerator(seed: 3))
        return (text, first, bytes, second)
    }

    static let words = ["pear", "apple", "", "fig", "\u{E9}clair", "e\u{301}clair", "a longer key than a slot holds"]

    /// Every write to a sorted map by a key writes what the write by a
    /// span of the key's bytes writes, and every read by a key reads what
    /// the read by that span reads. The database has no hasher.
    @Test func aSortedMapTakesAKeyAsItsBytes() throws {
        let twins = try Self.twins()
        func step(
            _ what: String, text: (SortedMap<ReadWrite>) throws -> Void, bytes: (SortedMap<ReadWrite>) throws -> Void
        )
            throws
        {
            try twins.text.withTransaction { root in try text(try SortedMap<ReadWrite>(root)) }
            try twins.bytes.withTransaction { root in try bytes(try SortedMap<ReadWrite>(root)) }
            #expect(twins.textBytes.bytes == twins.bytesBytes.bytes, "after \(what)")
        }
        try step("puts") { map in
            for (index, word) in Self.words.enumerated() { try map.put(.uint(UInt64(index)), forKey: word) }
        } bytes: { map in
            for (index, word) in Self.words.enumerated() { try map.put(.uint(UInt64(index)), forKey: utf8(word).span) }
        }
        try step("a put by a substring") { map in
            try map.put(.uint(100), forKey: "a plum"[...].dropFirst(2))
        } bytes: { map in
            try map.put(.uint(100), forKey: utf8("plum").span)
        }
        try step("puts by keys of every type") { map in
            try map.put(.uint(11), forKey: [UInt8]([0, 1, 2, 255]))
            try map.put(.uint(12), forKey: Bytes([9, 9], formatTag: "zz"))
            try map.put(.uint(13), forKey: Field.age)
            try map.put(.uint(14), forKey: Reversed(text: "abc"))
            try map.put("typed", forKey: Field.name)
        } bytes: { map in
            try map.put(.uint(11), forKey: [UInt8]([0, 1, 2, 255]).span)
            try map.put(.uint(12), forKey: [UInt8]([9, 9]).span)
            try map.put(.uint(13), forKey: utf8("age").span)
            try map.put(.uint(14), forKey: utf8("cba").span)
            try map.put(.bytes(utf8("typed")), forKey: utf8("name").span)
        }
        try step("a put cursor and a write through it") { map in
            var cursor = try map.putCursor(forKey: "quince")
            try cursor.write(.int(-1))
        } bytes: { map in
            var cursor = try map.putCursor(forKey: utf8("quince").span)
            try cursor.write(.int(-1))
        }
        try step("removes") { map in
            let removed = try map.remove(forKey: "fig")
            #expect(removed == true)
            #expect(try map.remove(forKey: "fig") == false)
            #expect(try map.remove(forKey: "absent") == false)
        } bytes: { map in
            let removed = try map.remove(forKey: utf8("fig").span)
            #expect(removed == true)
            #expect(try map.remove(forKey: utf8("fig").span) == false)
            #expect(try map.remove(forKey: utf8("absent").span) == false)
        }

        let map = try SortedMap<ReadOnly>(twins.text.rootCursor)
        for word in Self.words + ["plum", "quince", "absent", "b", "zzz"] {
            let key = utf8(word)
            #expect(try map.slot(forKey: word) == map.slot(forKey: key.span), "slot of \(word)")
            #expect(try map.cursor(forKey: word)?.slot == map.cursor(forKey: key.span)?.slot, "cursor of \(word)")
            let entry = try map.entry(forKey: word)
            let twin = try map.entry(forKey: key.span)
            #expect((entry == nil) == (twin == nil), "entry of \(word)")
            #expect(try entry?.key.readBytes() == twin?.key.readBytes())
            #expect(try entry?.value.slot == twin?.value.slot)
            #expect(try map.rank(of: word) == map.rank(of: key.span), "rank of \(word)")
            #expect(
                try Self.keys(from: map.iterator(fromKey: word)) == Self.keys(from: map.iterator(fromKey: key.span)))
        }
        #expect(try map.cursor(forKey: "pear")?.readUInt64() == 0)
        #expect(try map.cursor(forKey: "plum"[...])?.readUInt64() == 100)
        #expect(try map.slot(forKey: "fig") == nil)
        // The two spellings of é are two keys, as their bytes are.
        #expect(try map.cursor(forKey: "\u{E9}clair")?.readUInt64() == 4)
        #expect(try map.cursor(forKey: "e\u{301}clair")?.readUInt64() == 5)
        #expect(try Self.keys(from: map.iterator(fromKey: "q")) == [utf8("quince"), utf8("\u{E9}clair")])
        // Below "b": the empty key, the two keys of bytes, and three texts
        // that begin with "a".
        #expect(try map.rank(of: "b") == 6)
        // A typed read by a key, and the keys of the other types.
        #expect(try map.value(forKey: Field.name, as: String.self) == "typed")
        #expect(try map.value(forKey: Field.age, as: UInt64.self) == 13)
        #expect(try map.cursor(forKey: Reversed(text: "abc"))?.readUInt64() == 14)
        #expect(try map.cursor(forKey: [UInt8]([0, 1, 2, 255]))?.readUInt64() == 11)
        // Of a key of tagged bytes only the bytes are the key: it is found
        // by them with any tag or none, and read back it has no tag.
        #expect(try map.cursor(forKey: Bytes([9, 9], formatTag: "zz"))?.readUInt64() == 12)
        #expect(try map.cursor(forKey: Bytes([9, 9]))?.readUInt64() == 12)
        #expect(try map.cursor(forKey: Bytes([9, 9], formatTag: "ab"))?.readUInt64() == 12)
        #expect(try map.entry(forKey: Bytes([9, 9], formatTag: "zz"))?.key.readBytesWithFormatTag() == Bytes([9, 9]))
    }

    /// The same for a sorted set.
    @Test func aSortedSetTakesAKeyAsItsBytes() throws {
        let twins = try Self.twins()
        func step(
            _ what: String, text: (SortedSet<ReadWrite>) throws -> Void, bytes: (SortedSet<ReadWrite>) throws -> Void
        )
            throws
        {
            try twins.text.withTransaction { root in try text(try SortedSet<ReadWrite>(root)) }
            try twins.bytes.withTransaction { root in try bytes(try SortedSet<ReadWrite>(root)) }
            #expect(twins.textBytes.bytes == twins.bytesBytes.bytes, "after \(what)")
        }
        try step("inserts") { set in
            for word in Self.words { try set.insert(word) }
            try set.insert("a plum"[...].dropFirst(2))
        } bytes: { set in
            for word in Self.words { try set.insert(utf8(word).span) }
            try set.insert(utf8("plum").span)
        }
        try step("inserts of keys of every type") { set in
            try set.insert([UInt8]([0, 1, 2, 255]))
            try set.insert(Bytes([9, 9], formatTag: "zz"))
            try set.insert(Field.age)
            try set.insert(Reversed(text: "abc"))
        } bytes: { set in
            try set.insert([UInt8]([0, 1, 2, 255]).span)
            try set.insert([UInt8]([9, 9]).span)
            try set.insert(utf8("age").span)
            try set.insert(utf8("cba").span)
        }
        try step("removes") { set in
            let removed = try set.remove(forKey: "fig")
            #expect(removed == true)
            #expect(try set.remove(forKey: "fig") == false)
        } bytes: { set in
            let removed = try set.remove(forKey: utf8("fig").span)
            #expect(removed == true)
            #expect(try set.remove(forKey: utf8("fig").span) == false)
        }

        let set = try SortedSet<ReadOnly>(twins.text.rootCursor)
        for word in Self.words + ["plum", "absent", "b"] {
            let key = utf8(word)
            #expect(try set.contains(word) == set.contains(key.span), "contains \(word)")
            #expect(try set.rank(of: word) == set.rank(of: key.span), "rank of \(word)")
            #expect(
                try Self.keys(from: set.iterator(fromKey: word)) == Self.keys(from: set.iterator(fromKey: key.span)))
        }
        #expect(try set.contains("pear"))
        #expect(try set.contains("plum"[...]))
        #expect(try !set.contains("fig"))
        #expect(try set.count == UInt64(Self.words.count) + 4)
        #expect(try Self.keys(from: set.iterator(fromKey: "pe")) == [utf8("pear"), utf8("plum"), utf8("\u{E9}clair")])
        #expect(try set.contains(Field.age))
        #expect(try !set.contains(Field.name))
        #expect(try set.contains(Reversed(text: "abc")))
        #expect(try set.contains([UInt8]([0, 1, 2, 255])))
        // Of a key of tagged bytes only the bytes are the key.
        #expect(try set.contains(Bytes([9, 9], formatTag: "zz")))
        #expect(try set.contains(Bytes([9, 9])))
        // Below it: the empty key and the other key of bytes.
        #expect(try set.rank(of: Bytes([9, 9], formatTag: "ab")) == 2)
        var first = try set.iterator(fromKey: Bytes([9, 9], formatTag: "zz"))
        #expect(try first.next()?.readEntry().key.readBytesWithFormatTag() == Bytes([9, 9]))
    }

    /// A key of bytes and a type whose raw value is a key work on the sorted
    /// collections as they do on the hashed ones: every form of one key
    /// names one entry. They differ in what is kept of a key of tagged
    /// bytes: a hash set keeps the key it is given, its tag included, and a
    /// sorted set keeps the bytes alone.
    @Test func everyFormOfAKeyNamesOneEntryOnTheSortedCollectionsAsOnTheHashed() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let tagged = Bytes(utf8("name"), formatTag: "tg")
        try database.withTransaction { root in
            let moment = try HashMap<ReadWrite>(root)
            let sorted = try SortedMap<ReadWrite>(moment.putCursor(forKey: "sorted map"))
            let hashed = try CountedHashMap<ReadWrite>(moment.putCursor(forKey: "hash map"))
            let sortedSet = try SortedSet<ReadWrite>(moment.putCursor(forKey: "sorted set"))
            let hashedSet = try CountedHashSet<ReadWrite>(moment.putCursor(forKey: "hash set"))

            try sorted.put(UInt64(1), forKey: "name")
            try sorted.put(UInt64(2), forKey: "the name"[...].dropFirst(4))
            try sorted.put(UInt64(3), forKey: utf8("name"))
            try sorted.put(UInt64(4), forKey: Bytes(utf8("name")))
            try sorted.put(UInt64(5), forKey: tagged)
            try sorted.put(UInt64(6), forKey: Field.name)
            try sorted.put(.uint(7), forKey: utf8("name").span)
            try hashed.put(UInt64(1), forKey: "name")
            try hashed.put(UInt64(2), forKey: "the name"[...].dropFirst(4))
            try hashed.put(UInt64(3), forKey: utf8("name"))
            try hashed.put(UInt64(4), forKey: Bytes(utf8("name")))
            try hashed.put(UInt64(5), forKey: tagged)
            try hashed.put(UInt64(6), forKey: Field.name)
            try hashed.put(.uint(7), forHash: SHA256.keyHash(of: "name"))

            try sortedSet.insert(tagged)
            try sortedSet.insert("name")
            try sortedSet.insert(Field.name)
            try sortedSet.insert(utf8("name").span)
            try hashedSet.insert(tagged)
            try hashedSet.insert("name")
            try hashedSet.insert(Field.name)

            #expect(try sorted.count == 1)
            #expect(try hashed.count == 1)
            #expect(try sortedSet.count == 1)
            #expect(try hashedSet.count == 1)
            let keys: [any KeyRepresentable] = [
                "name", "the name"[...].dropFirst(4), utf8("name"), Bytes(utf8("name")), tagged, Field.name,
            ]
            for key in keys {
                #expect(try sorted.readOnly.value(forKey: key, as: UInt64.self) == 7, "\(key)")
                #expect(try hashed.readOnly.value(forKey: key, as: UInt64.self) == 7, "\(key)")
                #expect(try sortedSet.readOnly.contains(key), "\(key)")
                #expect(try hashedSet.readOnly.contains(key), "\(key)")
            }
            // What is kept of the tagged key: a hash set keeps the first
            // key it was given for the entry, with its tag; a sorted set
            // keeps the bytes.
            #expect(try hashedSet.readOnly.cursor(forKey: "name")?.readBytesWithFormatTag() == tagged)
            var iterator = try sortedSet.readOnly.iterator()
            #expect(try iterator.next()?.readEntry().key.readBytesWithFormatTag() == Bytes(utf8("name")))
            #expect(try sorted.readOnly.entry(forKey: tagged)?.key.readBytesWithFormatTag() == Bytes(utf8("name")))
        }
    }

    /// The keys an iterator gives, in its order.
    static func keys(from iterator: consuming CollectionIterator) throws -> [[UInt8]] {
        var keys: [[UInt8]] = []
        while let cursor = try iterator.next() {
            keys.append(try cursor.readEntry().key.readBytes())
        }
        return keys
    }
}
