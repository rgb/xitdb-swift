import Foundation
import Testing
import XitDBTestSupport

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
        try database.withTransaction { cursor in
            _ = try cursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("list")), .arrayListInit])
            _ = try cursor.writePath([.hashMapGet(.value, sha1("map")), .hashMapInit()])
            _ = try cursor.writePath([.hashMapGet(.value, sha1("set")), .hashMapInit(set: true)])
            _ = try cursor.writePath([.hashMapGet(.value, sha1("counted-map")), .hashMapInit(counted: true)])
            _ = try cursor.writePath([.hashMapGet(.value, sha1("counted-set")), .hashMapInit(counted: true, set: true)])
            _ = try cursor.writePath([.hashMapGet(.value, sha1("number")), .write(.uint(1))])
            _ = try cursor.writePath([.hashMapGet(.value, sha1("none")), .write(.slot(nil))])
        }
        let moment = database.rootCursor.readOnly
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

        #expect(try ArrayList(list).count == 0)
        #expect(try ArrayList(none).count == 0)
        for other in [map, set, countedMap, countedSet, number] {
            #expect(throws: XitDBError.unexpectedTag) { try ArrayList(other) }
        }

        // a map and a set are each other's kind to the views, as in Zig
        for fine in [map, set, none] {
            #expect(try HashMap(fine).cursor(forHash: key("x")) == nil)
            #expect(try HashSet(fine).cursor(forHash: key("x")) == nil)
        }
        for other in [list, countedMap, countedSet, number] {
            #expect(throws: XitDBError.unexpectedTag) { try HashMap(other) }
            #expect(throws: XitDBError.unexpectedTag) { try HashSet(other) }
        }
        for fine in [countedMap, countedSet, none] {
            #expect(try CountedHashMap(fine).count == 0)
            #expect(try CountedHashSet(fine).count == 0)
        }
        for other in [list, map, set, number] {
            #expect(throws: XitDBError.unexpectedTag) { try CountedHashMap(other) }
            #expect(throws: XitDBError.unexpectedTag) { try CountedHashSet(other) }
        }

        // a view of nothing gives nothing
        var elements = try ArrayList(none).iterator()
        #expect(try elements.next() == nil)
        var fromIndex = try ArrayList(none).iterator(fromIndex: 0)
        #expect(try fromIndex.next() == nil)
        var entries = try HashMap(none).iterator()
        #expect(try entries.next() == nil)
        #expect(try ArrayList(none).slot(at: 0) == nil)
        #expect(try HashMap(none).entry(forHash: key("x")) == nil)
        #expect(try HashMap(none).keySlot(forHash: key("x")) == nil)
        #expect(try CountedHashSet(none).slot(forHash: key("x")) == nil)
    }

    /// A writing view makes the slot its kind of collection, and the other
    /// kinds refuse the slot afterwards.
    @Test func aWritingViewMakesTheCollection() throws {
        let database = try makeDatabase()
        try database.withTransaction { cursor in
            let map = try HashMap(cursor)
            #expect(try map.slot.tag == .hashMap)
            #expect(try cursor.slot.tag == .none, "the view's cursor is a new one; the caller's is unchanged")
            #expect(try map.cursor.slot.tag == .hashMap)

            let list = try ArrayList(try map.putCursor(forHash: key("list")))
            #expect(try list.slot.tag == .arrayList)
            #expect(try map.slot(forHash: key("list"))?.tag == .arrayList)
            let countedMap = try CountedHashMap(try map.putCursor(forHash: key("counted-map")))
            #expect(try countedMap.slot.tag == .countedHashMap)
            let set = try HashSet(try map.putCursor(forHash: key("set")))
            #expect(try set.slot.tag == .hashSet)
            let countedSet = try CountedHashSet(try map.putCursor(forHash: key("counted-set")))
            #expect(try countedSet.slot.tag == .countedHashSet)

            // the wrong kind of view on each, writing: a list is not a map,
            // and a counted map is not an uncounted one. A map and a set
            // are one kind to the init part, as in Zig, which gives the
            // slot the tag asked for: a map becomes a set, and back.
            #expect(throws: XitDBError.unexpectedTag) { try HashMap(try map.putCursor(forHash: key("list"))) }
            #expect(throws: XitDBError.unexpectedTag) { try ArrayList(try map.putCursor(forHash: key("set"))) }
            #expect(throws: XitDBError.unexpectedTag) { try HashSet(try map.putCursor(forHash: key("counted-set"))) }
            #expect(throws: XitDBError.unexpectedTag) { try CountedHashMap(try map.putCursor(forHash: key("set"))) }
            #expect(try CountedHashSet(try map.putCursor(forHash: key("counted-map"))).slot.tag == .countedHashSet)
            #expect(try HashMap(try map.putCursor(forHash: key("set"))).slot.tag == .hashMap)

            // and the read-only form of each keeps the slot
            #expect(try list.readOnly.slot == (try list.slot))
            #expect(try countedMap.readOnly.count == 0)
            #expect(try set.readOnly.cursor(forHash: key("x")) == nil)
            #expect(try countedSet.readOnly.count == 0)
            #expect(try map.readOnly.cursor(forHash: key("list"))?.slot.tag == .arrayList)
        }
        #expect(try database.rootCursor.slot.tag == .hashMap)
    }

    /// A writing view of the sibling kind rewrites the slot's tag, on the
    /// root too, where it is a transaction of its own: a hash set made on a
    /// root that holds a map commits the root as a set, with the entries
    /// kept. The counted pair and the sorted pair do the same; the two
    /// lists have no sibling and refuse each other (D3).
    @Test func aWritingViewOfTheSiblingKindRetagsTheRoot() throws {
        let storage = MemoryStorage()
        let database = try makeDatabase(storage)
        let hash = key("k")
        try database.withTransaction { cursor in
            try HashMap(cursor).put(.uint(1), forHash: hash)
        }
        let mapSlot = try database.rootCursor.slot
        #expect(mapSlot.tag == .hashMap)
        let committed = storage.bytes.count

        let set = try HashSet(database.rootCursor)
        #expect(try set.slot.tag == .hashSet)
        #expect(try database.rootCursor.slot.tag == .hashSet, "committed on the root")
        #expect(try set.slot.value != mapSlot.value, "the root block was copied into the transaction")
        // the bytes: the transaction's copy of the root slot, the copy of
        // the root block, and the trailer that commits it
        #expect(storage.bytes.count == committed + 9 + 144 + 25)
        #expect(try database.committedSize == UInt64(storage.bytes.count))
        // the entry is still there, with its value, which a map reads
        #expect(try set.cursor(forHash: hash) == nil, "a set reads keys, and none was written")
        #expect(try HashMap<ReadOnly>(database.rootCursor).cursor(forHash: hash)?.readUInt64() == 1)
        // and back
        let map = try HashMap(database.rootCursor)
        #expect(try map.slot.tag == .hashMap)
        #expect(try database.rootCursor.slot.tag == .hashMap)
        #expect(try map.cursor(forHash: hash)?.readUInt64() == 1)
        #expect(storage.bytes.count == committed + 2 * (9 + 144 + 25))

        try database.withTransaction { cursor in
            let root = try HashMap(cursor)
            let counted = try CountedHashMap(try root.putCursor(forHash: key("counted")))
            try counted.put(.uint(2), forHash: hash)
            let countedSet = try CountedHashSet(try root.putCursor(forHash: key("counted")))
            #expect(try countedSet.slot.tag == .countedHashSet)
            #expect(try root.slot(forHash: key("counted"))?.tag == .countedHashSet)
            #expect(try countedSet.count == 1, "the count stays")
            #expect(try CountedHashMap(try root.putCursor(forHash: key("counted"))).slot.tag == .countedHashMap)
            #expect(try counted.cursor(forHash: hash)?.readUInt64() == 2)

            let sorted = try SortedMap(try root.putCursor(forHash: key("sorted")))
            try sorted.put(.uint(3), forKey: Array("a".utf8))
            let sortedSet = try SortedSet(try root.putCursor(forHash: key("sorted")))
            #expect(try sortedSet.slot.tag == .sortedSet)
            #expect(try root.slot(forHash: key("sorted"))?.tag == .sortedSet)
            #expect(try sortedSet.contains(Array("a".utf8)))
            #expect(try SortedMap(try root.putCursor(forHash: key("sorted"))).slot.tag == .sortedMap)
            #expect(try sorted.cursor(forKey: Array("a".utf8))?.readUInt64() == 3)

            let list = try ArrayList(try root.putCursor(forHash: key("list")))
            try list.append(.uint(4))
            #expect(throws: XitDBError.unexpectedTag) { try LinkedArrayList(try root.putCursor(forHash: key("list"))) }
            let linked = try LinkedArrayList(try root.putCursor(forHash: key("linked")))
            try linked.append(.uint(5))
            #expect(throws: XitDBError.unexpectedTag) { try ArrayList(try root.putCursor(forHash: key("linked"))) }
            #expect(try root.slot(forHash: key("list"))?.tag == .arrayList)
            #expect(try root.slot(forHash: key("linked"))?.tag == .linkedArrayList)
            // and a kind that keeps a count is not one that does not
            #expect(throws: XitDBError.unexpectedTag) { try HashSet(try root.putCursor(forHash: key("counted"))) }
            #expect(throws: XitDBError.unexpectedTag) { try CountedHashSet(try root.putCursor(forHash: key("list"))) }
        }
    }

    /// A writing view on the root cursor while a transaction is in progress
    /// is a nested top-level write, for each of the eight kinds; the
    /// read-only views are not writes.
    @Test func aWritingViewOnTheRootInsideATransactionIsANestedWrite() throws {
        let database = try makeDatabase()
        try database.withTransaction { cursor in
            try HashMap(cursor).put(.uint(1), forHash: key("k"))
            let root = database.rootCursor
            #expect(throws: XitDBError.nestedTopLevelWrite) { try HashMap<ReadWrite>(root) }
            #expect(throws: XitDBError.nestedTopLevelWrite) { try HashSet<ReadWrite>(root) }
            #expect(throws: XitDBError.nestedTopLevelWrite) { try CountedHashMap<ReadWrite>(root) }
            #expect(throws: XitDBError.nestedTopLevelWrite) { try CountedHashSet<ReadWrite>(root) }
            #expect(throws: XitDBError.nestedTopLevelWrite) { try ArrayList<ReadWrite>(root) }
            #expect(throws: XitDBError.nestedTopLevelWrite) { try LinkedArrayList<ReadWrite>(root) }
            #expect(throws: XitDBError.nestedTopLevelWrite) { try SortedMap<ReadWrite>(root) }
            #expect(throws: XitDBError.nestedTopLevelWrite) { try SortedSet<ReadWrite>(root) }
            #expect(try HashMap<ReadOnly>(root).cursor(forHash: key("k")) == nil, "the root is not committed yet")
            #expect(try ArrayList<ReadOnly>(root).count == 0)
        }
        #expect(try HashMap(database.rootCursor).cursor(forHash: key("k"))?.readUInt64() == 1)
    }

    /// The methods that take a hash accept it as an array and as a span,
    /// and a hash of the wrong size is refused by every one of them.
    @Test func aHashIsASpanOrAnArray() throws {
        let database = try makeDatabase()
        let hash = key("k")
        let wrong = [UInt8](repeating: 1, count: 19)
        try database.withTransaction { cursor in
            let map = try HashMap(cursor)
            try map.put(.uint(1), forHash: hash.span)
            try map.putKey(.bytes(Array("k".utf8)), forHash: hash)
            try map.putKey(.bytes(Array("other".utf8)), forHash: hash.span)
            try map.putKey(.bytes(Array("another".utf8)), forHash: hash)
            #expect(try map.keyCursor(forHash: hash)?.readBytes() == Array("k".utf8), "a key is only written once")
            #expect(try !map.remove(forHash: key("missing").span))
            #expect(try !map.remove(forHash: key("missing")))
            #expect(try map.cursor(forHash: hash.span)?.readUInt64() == 1)
            #expect(try map.cursor(forHash: hash)?.readUInt64() == 1)
            #expect(try map.keyCursor(forHash: hash.span)?.readBytes() == Array("k".utf8))
            #expect(try map.keySlot(forHash: hash)?.tag == .shortBytes)
            #expect(try map.slot(forHash: hash.span)?.tag == .uint)
            let pair = try #require(try map.entry(forHash: hash.span))
            #expect(pair.hash == hash)
            #expect(pair.withHash { Array($0.indices.map { pair.hash[$0] }) } == hash)
            #expect(try map.putCursor(forHash: hash.span).readUInt64() == 1)
            #expect(try map.putKeyCursor(forHash: hash).readBytes() == Array("k".utf8))

            #expect(throws: XitDBError.invalidHashSize) { try map.put(.uint(2), forHash: wrong) }
            #expect(throws: XitDBError.invalidHashSize) { try map.put(.uint(2), forHash: wrong.span) }
            #expect(throws: XitDBError.invalidHashSize) { try map.putKey(.uint(2), forHash: wrong.span) }
            #expect(throws: XitDBError.invalidHashSize) { try map.cursor(forHash: wrong) }
            #expect(throws: XitDBError.invalidHashSize) { try map.slot(forHash: wrong.span) }
            #expect(throws: XitDBError.invalidHashSize) { try map.keyCursor(forHash: wrong) }
            #expect(throws: XitDBError.invalidHashSize) { try map.keySlot(forHash: wrong.span) }
            #expect(throws: XitDBError.invalidHashSize) { try map.entry(forHash: wrong) }
            #expect(throws: XitDBError.invalidHashSize) { try map.putCursor(forHash: wrong) }
            #expect(throws: XitDBError.invalidHashSize) { try map.putKeyCursor(forHash: wrong.span) }
            #expect(throws: XitDBError.invalidHashSize) { try map.remove(forHash: wrong) }
            #expect(throws: XitDBError.invalidHashSize) { try map.remove(forHash: wrong.span) }

            let set = try HashSet(try map.putCursor(forHash: key("set")))
            try set.insert(.bytes(Array("k".utf8)), forHash: hash.span)
            try set.insert(.bytes(Array("other".utf8)), forHash: hash.span)
            try set.insert(.bytes(Array("another".utf8)), forHash: hash)
            #expect(try set.cursor(forHash: hash)?.readBytes() == Array("k".utf8))
            #expect(try set.slot(forHash: hash.span)?.tag == .shortBytes)
            #expect(try set.insertCursor(forHash: hash).readBytes() == Array("k".utf8))
            #expect(throws: XitDBError.invalidHashSize) { try set.insert(.uint(2), forHash: wrong) }
            #expect(throws: XitDBError.invalidHashSize) { try set.cursor(forHash: wrong.span) }
            #expect(throws: XitDBError.invalidHashSize) { try set.slot(forHash: wrong) }
            #expect(throws: XitDBError.invalidHashSize) { try set.insertCursor(forHash: wrong.span) }
            #expect(throws: XitDBError.invalidHashSize) { try set.remove(forHash: wrong) }
            #expect(try set.remove(forHash: hash.span))
            #expect(try !set.remove(forHash: hash))

            let counted = try CountedHashMap(try map.putCursor(forHash: key("counted")))
            try counted.put(.uint(3), forHash: hash)
            try counted.putKey(.bytes([1]), forHash: hash.span)
            try counted.putKey(.bytes([9]), forHash: hash.span)
            try counted.putKey(.bytes([9]), forHash: hash)
            #expect(try !counted.remove(forHash: key("missing")))
            #expect(try !counted.remove(forHash: key("missing").span))
            #expect(try counted.count == 1)
            #expect(try counted.cursor(forHash: hash.span)?.readUInt64() == 3)
            #expect(try counted.entry(forHash: hash)?.key.readBytes() == [1])
            #expect(try counted.keyCursor(forHash: hash)?.readBytes() == [1])
            #expect(try counted.keySlot(forHash: hash.span)?.tag == .shortBytes)
            #expect(try counted.slot(forHash: hash)?.tag == .uint)
            #expect(try counted.putCursor(forHash: hash).readUInt64() == 3)
            #expect(try counted.putKeyCursor(forHash: hash.span).readBytes() == [1])
            #expect(throws: XitDBError.invalidHashSize) { try counted.remove(forHash: wrong.span) }
            #expect(try counted.remove(forHash: hash))
            #expect(try counted.count == 0)

            let countedSet = try CountedHashSet(try map.putCursor(forHash: key("counted-set")))
            try countedSet.insert(.bytes([2]), forHash: hash.span)
            try countedSet.insert(.bytes([3]), forHash: hash)
            try countedSet.insert(.bytes([4]), forHash: hash.span)
            #expect(try countedSet.count == 1)
            #expect(try countedSet.cursor(forHash: hash)?.readBytes() == [2], "a key is only written once")
            #expect(try countedSet.slot(forHash: hash.span)?.tag == .shortBytes)
            #expect(try countedSet.insertCursor(forHash: hash.span).readBytes() == [2])
            #expect(throws: XitDBError.invalidHashSize) { try countedSet.insert(.uint(1), forHash: wrong.span) }
            #expect(try countedSet.remove(forHash: hash.span))
            #expect(try !countedSet.remove(forHash: hash.span))
            #expect(try countedSet.count == 0)
        }
    }

    /// A digest, CryptoKit's or the support target's, is a sequence of bytes
    /// and not a collection, and the methods that take a hash take it as it
    /// is (D21 item 3, amended):
    /// a SHA-1 digest goes straight into a map with a hash size of twenty,
    /// and names the same entry as the array of its bytes. A digest of
    /// another size is refused as any hash of the wrong size is.
    @Test func aDigestGoesStraightIn() throws {
        let database = try makeDatabase()
        let digest = Insecure.SHA1.hash(data: Data("k".utf8))
        let bytes = Array(digest)
        #expect(bytes.count == 20)
        try database.withTransaction { cursor in
            let map = try HashMap(cursor)
            try map.put(.uint(1), forHash: digest)
            #expect(try map.cursor(forHash: digest)?.readUInt64() == 1)
            #expect(
                try map.cursor(forHash: bytes)?.readUInt64() == 1, "the array of the digest's bytes finds the entry")
            try map.put(.uint(2), forHash: bytes)
            #expect(try map.cursor(forHash: digest)?.readUInt64() == 2, "and the digest finds what the array wrote")
            #expect(try map.cursor(forHash: Insecure.SHA1.hash(data: Data("other".utf8))) == nil)
            #expect(throws: XitDBError.invalidHashSize) {
                try map.put(.uint(3), forHash: SHA256.hash(data: Data("k".utf8)))
            }
            #expect(throws: XitDBError.invalidHashSize) {
                try map.cursor(forHash: SHA256.hash(data: Data("k".utf8)))
            }
        }
    }

    /// A read-only view over a slot that holds nothing checks no hash: a
    /// hash of the wrong size finds nothing there, as in Zig, and is
    /// refused with `invalidHashSize` once the slot holds a map, which the
    /// first put makes it (D6). A writing view's init makes the slot a map,
    /// so it checks from its first call.
    @Test func anEmptyViewChecksNoHash() throws {
        let database = try makeDatabase()
        let wrong = [UInt8](repeating: 1, count: 19)
        let root = database.rootCursor
        #expect(try root.slot.tag == .none)
        #expect(try HashMap<ReadOnly>(root).cursor(forHash: wrong) == nil)
        #expect(try HashMap<ReadOnly>(root).slot(forHash: wrong.span) == nil)
        #expect(try HashMap<ReadOnly>(root).keyCursor(forHash: wrong) == nil)
        #expect(try HashMap<ReadOnly>(root).keySlot(forHash: wrong) == nil)
        #expect(try HashMap<ReadOnly>(root).entry(forHash: wrong) == nil)
        #expect(try HashSet<ReadOnly>(root).cursor(forHash: wrong) == nil)
        #expect(try !HashSet<ReadOnly>(root).contains(hash: wrong))
        #expect(try CountedHashMap<ReadOnly>(root).cursor(forHash: wrong.span) == nil)
        #expect(try !CountedHashSet<ReadOnly>(root).contains(hash: wrong.span))

        try HashMap(root).put(.uint(1), forHash: key("k"))
        #expect(try root.slot.tag == .hashMap)
        let map = try HashMap<ReadOnly>(root)
        #expect(throws: XitDBError.invalidHashSize) { try map.cursor(forHash: wrong) }
        #expect(throws: XitDBError.invalidHashSize) { try map.slot(forHash: wrong.span) }
        #expect(throws: XitDBError.invalidHashSize) { try map.keyCursor(forHash: wrong) }
        #expect(throws: XitDBError.invalidHashSize) { try map.keySlot(forHash: wrong) }
        #expect(throws: XitDBError.invalidHashSize) { try map.entry(forHash: wrong) }
        #expect(throws: XitDBError.invalidHashSize) { try HashSet<ReadOnly>(root).contains(hash: wrong) }
        #expect(try map.cursor(forHash: key("k"))?.readUInt64() == 1)

        // a slot set to nothing below the root is as empty, and a writing
        // view's slot is a map from its init on
        try database.withTransaction { cursor in
            let root = try HashMap(cursor)
            _ = try cursor.writePath([.hashMapGet(.value, sha1("none")), .write(.slot(nil))])
            let none = try #require(try root.cursor(forHash: key("none")))
            #expect(try CountedHashMap(none).cursor(forHash: wrong) == nil)
            #expect(try !CountedHashSet(none).contains(hash: wrong))
            let fresh = try CountedHashMap(try root.putCursor(forHash: key("fresh")))
            #expect(try fresh.count == 0)
            #expect(throws: XitDBError.invalidHashSize) { try fresh.cursor(forHash: wrong) }
            #expect(throws: XitDBError.invalidHashSize) { try fresh.put(.uint(1), forHash: wrong) }
            #expect(throws: XitDBError.invalidHashSize) { try fresh.remove(forHash: wrong) }
        }
    }

    /// A set says whether a key is stored under a hash: not before the key
    /// is written, and not after it is removed.
    @Test func aSetSaysWhetherItContainsAHash() throws {
        let database = try makeDatabase()
        let hash = key("k")
        let other = key("other")
        let wrong = [UInt8](repeating: 1, count: 19)
        try database.withTransaction { cursor in
            let map = try HashMap(cursor)

            let set = try HashSet(try map.putCursor(forHash: key("set")))
            #expect(try !set.contains(hash: hash))
            try set.insert(.bytes([1]), forHash: hash)
            #expect(try set.contains(hash: hash))
            #expect(try set.contains(hash: hash.span))
            #expect(try !set.contains(hash: other))
            #expect(try set.readOnly.contains(hash: hash))
            #expect(throws: XitDBError.invalidHashSize) { try set.contains(hash: wrong) }
            #expect(throws: XitDBError.invalidHashSize) { try set.contains(hash: wrong.span) }
            _ = try set.insertCursor(forHash: other)
            #expect(try !set.contains(hash: other), "an entry whose key was never written does not count")
            #expect(try set.remove(forHash: hash))
            #expect(try !set.contains(hash: hash))
            #expect(try !set.contains(hash: hash.span))

            let countedSet = try CountedHashSet(try map.putCursor(forHash: key("counted-set")))
            #expect(try !countedSet.contains(hash: hash.span))
            try countedSet.insert(.bytes([2]), forHash: hash.span)
            #expect(try countedSet.contains(hash: hash))
            #expect(try countedSet.contains(hash: hash.span))
            #expect(try !countedSet.contains(hash: other.span))
            #expect(try countedSet.readOnly.contains(hash: hash.span))
            #expect(throws: XitDBError.invalidHashSize) { try countedSet.contains(hash: wrong) }
            #expect(throws: XitDBError.invalidHashSize) { try countedSet.contains(hash: wrong.span) }
            _ = try countedSet.insertCursor(forHash: other.span)
            #expect(try !countedSet.contains(hash: other), "an entry whose key was never written does not count")
            #expect(try countedSet.remove(forHash: hash.span))
            #expect(try !countedSet.contains(hash: hash))
            #expect(try !countedSet.contains(hash: hash.span))
        }
    }

    /// A read-only view takes a cursor of either access and checks the slot
    /// as it does for a read-only cursor. A cursor that can write makes the
    /// writing view unless the read-only one is named.
    @Test func aReadOnlyViewTakesACursorOfEitherAccess() throws {
        let database = try makeDatabase()
        let hash = key("k")
        try database.withTransaction { cursor in
            let map = try HashMap(cursor)
            #expect(type(of: map) == HashMap<ReadWrite>.self)
            try map.put(.uint(1), forHash: hash)
            let list = try ArrayList(try map.putCursor(forHash: key("list")))
            let linked = try LinkedArrayList(try map.putCursor(forHash: key("linked")))
            let set = try HashSet(try map.putCursor(forHash: key("set")))
            let countedMap = try CountedHashMap(try map.putCursor(forHash: key("counted-map")))
            let countedSet = try CountedHashSet(try map.putCursor(forHash: key("counted-set")))
            let sortedMap = try SortedMap(try map.putCursor(forHash: key("sorted-map")))
            let sortedSet = try SortedSet(try map.putCursor(forHash: key("sorted-set")))
            let none = try map.putCursor(forHash: key("none"))
            #expect(type(of: list) == ArrayList<ReadWrite>.self)
            #expect(type(of: sortedSet) == SortedSet<ReadWrite>.self)

            // each kind's read-only view from the writing cursor of its own
            // kind, and from a cursor at nothing
            #expect(try ArrayList<ReadOnly>(list.cursor).count == 0)
            #expect(try LinkedArrayList<ReadOnly>(linked.cursor).count == 0)
            #expect(try HashMap<ReadOnly>(map.cursor).cursor(forHash: hash)?.readUInt64() == 1)
            #expect(try HashSet<ReadOnly>(set.cursor).cursor(forHash: hash) == nil)
            #expect(try CountedHashMap<ReadOnly>(countedMap.cursor).count == 0)
            #expect(try CountedHashSet<ReadOnly>(countedSet.cursor).count == 0)
            #expect(try SortedMap<ReadOnly>(sortedMap.cursor).count == 0)
            #expect(try SortedSet<ReadOnly>(sortedSet.cursor).count == 0)
            #expect(try ArrayList<ReadOnly>(none).count == 0)
            #expect(try LinkedArrayList<ReadOnly>(none).count == 0)
            #expect(try HashMap<ReadOnly>(none).cursor(forHash: hash) == nil)
            #expect(try HashSet<ReadOnly>(none).cursor(forHash: hash) == nil)
            #expect(try CountedHashMap<ReadOnly>(none).count == 0)
            #expect(try CountedHashSet<ReadOnly>(none).count == 0)
            #expect(try SortedMap<ReadOnly>(none).count == 0)
            #expect(try SortedSet<ReadOnly>(none).count == 0)

            // and the check of the slot
            #expect(throws: XitDBError.unexpectedTag) { try ArrayList<ReadOnly>(map.cursor) }
            #expect(throws: XitDBError.unexpectedTag) { try LinkedArrayList<ReadOnly>(list.cursor) }
            #expect(throws: XitDBError.unexpectedTag) { try HashMap<ReadOnly>(list.cursor) }
            #expect(throws: XitDBError.unexpectedTag) { try HashSet<ReadOnly>(countedSet.cursor) }
            #expect(throws: XitDBError.unexpectedTag) { try CountedHashMap<ReadOnly>(map.cursor) }
            #expect(throws: XitDBError.unexpectedTag) { try CountedHashSet<ReadOnly>(set.cursor) }
            #expect(throws: XitDBError.unexpectedTag) { try SortedMap<ReadOnly>(linked.cursor) }
            #expect(throws: XitDBError.unexpectedTag) { try SortedSet<ReadOnly>(list.cursor) }
        }

        // the root cursor can write: without a type context it makes the
        // writing view, and the read-only one no longer needs `readOnly`
        let map = try HashMap(database.rootCursor)
        #expect(type(of: map) == HashMap<ReadWrite>.self)
        #expect(try map.cursor(forHash: hash)?.readUInt64() == 1)
        let readOnly = try HashMap<ReadOnly>(database.rootCursor)
        #expect(try readOnly.cursor(forHash: hash)?.readUInt64() == 1)
        #expect(try HashMap<ReadOnly>(database.rootCursor.readOnly).cursor(forHash: hash)?.readUInt64() == 1)
        let fromReadOnly = try HashMap(database.rootCursor.readOnly)
        #expect(type(of: fromReadOnly) == HashMap<ReadOnly>.self)
        #expect(throws: XitDBError.unexpectedTag) { try ArrayList<ReadOnly>(database.rootCursor) }
        #expect(throws: XitDBError.unexpectedTag) { try SortedMap<ReadOnly>(database.rootCursor) }
    }

    /// A linked array list appends another list given as a list of either
    /// access or as its slot, and `append(_:_:)` gives the body's value.
    @Test func aListAppendsAnotherListAndGivesTheBodysValue() throws {
        let database = try makeDatabase()
        try database.withTransaction { cursor in
            let map = try HashMap(cursor)
            var list = try LinkedArrayList(try map.putCursor(forHash: key("list")))
            let other = try LinkedArrayList(try map.putCursor(forHash: key("other")))
            for value in 0..<3 {
                try list.append(.uint(UInt64(value)))
            }
            for value in 3..<6 {
                try other.append(.uint(UInt64(value)))
            }
            // each join freezes the transaction: the list is made again from
            // the transaction's cursor before the next write (D24)
            func joined() throws -> LinkedArrayList<ReadWrite> {
                try LinkedArrayList(try HashMap(cursor).putCursor(forHash: key("list")))
            }
            try list.append(contentsOf: other)
            list = try joined()
            #expect(try list.count == 6)
            try list.append(contentsOf: other.readOnly)
            list = try joined()
            #expect(try list.count == 9)
            try list.append(contentsOf: try other.slot)
            list = try joined()
            #expect(try list.count == 12)
            let values = try (0..<12).map { try list.cursor(at: $0)?.readUInt64() }
            #expect(values == [0, 1, 2, 3, 4, 5, 3, 4, 5, 3, 4, 5])
            #expect(try other.count == 3, "the other list is unchanged")
            #expect(throws: XitDBError.unexpectedTag) { try list.append(contentsOf: try map.slot) }

            let appended = try list.append(.uint(40)) { element in
                try element.write(.uint(41))
                return try element.readUInt64()
            }
            #expect(appended == 41)
            #expect(try list.cursor(at: -1)?.readUInt64() == 41)
            try list.append(.uint(50)) { element in
                let value = try element.readUInt64()
                #expect(value == 50)
            }
            #expect(try list.count == 14)
        }
    }

    /// The list's own edges: a missing index, slicing, and iterating from
    /// an index that names nothing.
    /// An index is any integer type: the format's signed 64-bit index, a
    /// count's unsigned one, `Int`, a small one; negative counts from the
    /// end; one past what the format's index holds names no element, so a
    /// getter gives nil and a writer indexOutOfRange, as for any index past
    /// the end.
    @Test func anIndexIsAnyIntegerType() throws {
        let database = try makeDatabase()
        try database.withTransaction { cursor in
            let list = try ArrayList(try cursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("a"))]))
            for value in 10...14 { try list.append(.uint(UInt64(value))) }
            #expect(try list.cursor(at: 1)?.readUInt64() == 11)
            #expect(try list.cursor(at: Int8(2))?.readUInt64() == 12)
            #expect(try list.cursor(at: UInt64(3))?.readUInt64() == 13)
            #expect(try list.cursor(at: Int64(-1))?.readUInt64() == 14)
            #expect(try list.cursor(at: try list.count - 1)?.readUInt64() == 14)
            #expect(try list.cursor(at: UInt64(Int64.max) + 1) == nil)
            #expect(try list.slot(at: UInt64.max) == nil)
            #expect(throws: XitDBError.indexOutOfRange) { try list.put(.uint(0), at: UInt64(Int64.max) + 1) }
            #expect(throws: XitDBError.indexOutOfRange) { try list.putCursor(at: UInt64.max) }
            #expect(throws: XitDBError.indexOutOfRange) { try list.iterator(fromIndex: UInt64.max) }
            try list.put(.uint(99), at: UInt8(4))
            #expect(try list.cursor(at: -1)?.readUInt64() == 99)

            let linked = try LinkedArrayList(try cursor.writePath([.hashMapGet(.value, sha1("l"))]))
            for value in 20...22 { try linked.append(.uint(UInt64(value))) }
            #expect(try linked.cursor(at: UInt16(1))?.readUInt64() == 21)
            #expect(try linked.cursor(at: UInt64.max) == nil)
            #expect(throws: XitDBError.indexOutOfRange) { try linked.insert(.uint(0), at: UInt64.max) }
            #expect(throws: XitDBError.indexOutOfRange) { try linked.remove(at: UInt64(Int64.max) + 1) }
            try linked.remove(at: UInt(0))
            #expect(try linked.cursor(at: 0)?.readUInt64() == 21)

            let sorted = try SortedMap(try cursor.writePath([.hashMapGet(.value, sha1("s"))]))
            try sorted.put(.uint(1), forKey: Array("a".utf8))
            try sorted.put(.uint(2), forKey: Array("b".utf8))
            #expect(try sorted.entry(at: UInt8(1))?.value.readUInt64() == 2)
            #expect(try sorted.entry(at: -2)?.value.readUInt64() == 1)
            #expect(try sorted.entry(at: UInt64.max) == nil)
            #expect(throws: XitDBError.indexOutOfRange) { try sorted.iterator(fromIndex: UInt64.max) }
        }
    }

    @Test func aListsEdges() throws {
        let database = try makeDatabase()
        try database.withTransaction { cursor in
            let list = try ArrayList(cursor)
            #expect(throws: XitDBError.indexOutOfRange) { try list.put(.uint(1), at: 0) }
            #expect(throws: XitDBError.indexOutOfRange) { try list.putCursor(at: -1) }
            try list.append(.uint(10))
            try list.append(.uint(20))
            #expect(try list.appendCursor().slot.isEmpty)
            #expect(try list.count == 3)
            try list.put(.uint(30), at: -1)
            try list.put(.uint(11), at: 0)
            #expect(try list.cursor(at: 0)?.readUInt64() == 11)
            #expect(try list.cursor(at: -1)?.readUInt64() == 30)
            #expect(try list.slot(at: 3) == nil)
            #expect(try list.slot(at: -4) == nil)
            #expect(throws: XitDBError.indexOutOfRange) { try list.truncate(to: 4) }
            try list.truncate(to: 2)
            #expect(try list.count == 2)
            var fromIndex = try list.iterator(fromIndex: 1)
            #expect(try fromIndex.next()?.readUInt64() == 20)
            #expect(try fromIndex.next() == nil)
            for empty in [Int64(2), 3, -3, .max, .min] {
                var iterator = try list.iterator(fromIndex: empty)
                #expect(try iterator.next() == nil, "from \(empty)")
            }
            try list.append(.uint(40)) { element in
                #expect(try element.readUInt64() == 40)
                try element.write(.uint(41))
            }
            #expect(try list.cursor(at: 2)?.readUInt64() == 41)
        }
    }

    /// Each collection's start at an index or a key is that collection's
    /// alone, and each view checks the slot's tag.
    @Test func eachCollectionsIteratorStartIsItsOwn() throws {
        let database = try Database(storage: MemoryStorage(bytes: try FixtureTests.load()), hashSize: 20)
        let moment = try #require(try database.rootCursor.readPath([.arrayListGet(-1)]))
        let todos = try #require(try moment.readPath([.hashMapGet(.value, sha1("todos"))]))
        #expect(try todos.slot.tag == .linkedArrayList)
        #expect(throws: XitDBError.unexpectedTag) { try todos.iterator(fromArrayListIndex: 0) }
        #expect(throws: XitDBError.unexpectedTag) { try ArrayList(todos) }
        let fruits = try #require(try moment.readPath([.hashMapGet(.value, sha1("fruits"))]))
        #expect(try fruits.slot.tag == .arrayList)
        #expect(throws: XitDBError.unexpectedTag) { try fruits.iterator(fromLinkedArrayListIndex: 0) }
        #expect(throws: XitDBError.unexpectedTag) { try LinkedArrayList(fruits) }

        #expect(throws: XitDBError.unexpectedTag) { try todos.iterator(fromSortedMapIndex: 0) }
        #expect(throws: XitDBError.unexpectedTag) { try todos.iterator(fromSortedMapKey: SortedKey([])) }
        #expect(throws: XitDBError.unexpectedTag) { try fruits.iterator(fromSortedMapIndex: 0) }
        #expect(throws: XitDBError.unexpectedTag) { try SortedMap(fruits) }
        #expect(throws: XitDBError.unexpectedTag) { try SortedSet(todos) }
    }
}
