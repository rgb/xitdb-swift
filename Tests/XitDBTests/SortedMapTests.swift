import Testing

@testable import XitDB

// A port of `testSortedMap` from the Zig original (`src/test.zig`, lines 3393 to 3640), through the public
// collections. Zig runs it once for each of the memory, file and buffered-file databases ("sorted map and set",
// test.zig 3362-3391), so the test takes the storage kind as its argument.
//
// The comments inside the tests are Zig's. Zig's `root_cursor.writePath(Ctx, ...)` with a `Ctx` whose `run`
// method does the writing is `rootCursor.writePath([...]) { cursor in ... }` here. Zig's allocator argument has
// no counterpart, nor do the buffers it hands to `readBytes` and `cursor.reader`: `kv.key_cursor.readBytes(&kbuf)`
// with a buffer of eight or sixty-four bytes is `readBytes(kv.key, bufferSize:)`, and
// `std.mem.print(&kbuf, "k{d:0>4}", .{i})` is `paddedKey(i, width: 4)`. Zig's `expectError(error.X, call)` is
// `#expect(throws: XitDBError.x) { call }`, and `map.cursor.writePath(void, ...)` is `map.cursor.writePath(...)`.
//
// The port also has the test that the fix branch of the Zig original (`xitdb-fixes`) added to this function, in
// the place that branch's test.zig has it: lines 3650-3675 of that file at its commit d6f3fee (commit 1486fbf), a
// short key of a sorted set, whose cursor has no position, read with a reader. It pins a read behaviour the
// Swift port has from the start (finding 9 of the director's list of Zig behaviours to correct).
//
// Left out, with what it tests and the change it waits for:
//
// - 3689-3718 of the fix branch's test.zig (commit 0124779): the key cursor of an entry obtained with
//   `sorted_map_get {kv_pair}` cannot be written through, with `write` or with a writer, while the entry's value
//   can, and a hash map's keys still can. The port reproduces the original here, where the key can be
//   overwritten (finding 2); the guard comes after parity.
//
// Everything in lines 3393 to 3640 is ported.

/// Zig's "sorted map and set" test: the sorted map and set, used through the collections.
@Suite struct SortedMapTests {
    /// The storage kinds of the three databases Zig runs the test for.
    static let storageKinds: [StorageKind] = [.memory, .file, .bufferedFile]

    /// Zig's `COUNT`: keys "k0000".."k0059" sort lexicographically in numeric order.
    private let count = 60

    /// The UTF-8 bytes of a string.
    private func utf8(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    /// Zig's `hashInt(text)`: the SHA-1 of the text, as the twenty bytes the collections take.
    private func hashInt(_ text: String) -> [UInt8] {
        sha1(text).bytes
    }

    /// Zig's `std.mem.print(&kbuf, "k{d:0>4}", .{i})`: the key for a number, its digits padded with zeros on
    /// the left to `width`.
    private func paddedKey(_ number: Int, width: Int) -> [UInt8] {
        let digits = String(number)
        return utf8("k" + String(repeating: "0", count: max(0, width - digits.count)) + digits)
    }

    /// Zig's `cursor.readBytes(&buffer)` with a buffer of `bufferSize` zero bytes: the part of the buffer that
    /// holds the value.
    private func readBytes<Access>(_ cursor: Cursor<Access>, bufferSize: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var span = buffer.mutableSpan
        let count = try cursor.readBytes(into: &span)
        return Array(buffer[..<count])
    }

    /// Zig's `reader.interface.readSliceAll(&buffer)` and `take(n)` with `size` bytes: the buffer, filled.
    private func readAll(_ reader: inout ByteReader, size: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: size)
        var span = buffer.mutableSpan
        try reader.readAll(into: &span)
        return buffer
    }

    /// Zig's `reader.interface.readSliceShort(&buffer)` with a buffer of `size` zero bytes: the number of bytes
    /// read, and the buffer.
    private func readShort(_ reader: inout ByteReader, size: Int) throws -> (count: Int, buffer: [UInt8]) {
        var buffer = [UInt8](repeating: 0, count: size)
        var span = buffer.mutableSpan
        let count = try reader.read(into: &span)
        return (count, buffer)
    }

    /// The key of the entry an iterator gives next, Zig's
    /// `(try (try iter.next()).?.readEntry()).key_cursor.readBytes(&kbuf)` with an eight-byte buffer.
    private func nextKey(_ iter: inout CollectionIterator) throws -> [UInt8] {
        let entry = try #require(try iter.next())
        return try readBytes(try entry.readEntry().key, bufferSize: 8)
    }

    /// test.zig 3393-3639: `testSortedMap`. The function is one database from start to finish, each block
    /// reading what the blocks before it wrote, so it is one test; its blocks are the methods below, in order.
    @Test(arguments: storageKinds)
    func sortedMapAndSet(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)

        try writesTheFirstMoment(database)
        try theMapPersistsInTheCommittedMoment(database)
        try aSecondMomentInheritsAndMutatesTheMap(database)
    }

    /// test.zig 3403-3584: `Ctx`, the first moment, with the map and the set made and checked inside the
    /// transaction. Its blocks are the methods it calls, in order.
    private func writesTheFirstMoment(_ database: Database) throws {
        let rootCursor = database.rootCursor

        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .hashMapInit(),
            .ctx,
        ]) { (cursor: inout Cursor<ReadWrite>) in
            let moment = try HashMap<ReadWrite>(cursor)
            let map = try SortedMap<ReadWrite>(try moment.putCursor(forHash: hashInt("map")))

            try fillsTheMapInReverseOrder(map)
            try iteratesInOrder(map)
            try getsByIndexAndByRank(map)
            try iteratesFromAKeyAndFromAnIndex(map)
            try removesTheEvenKeys(map)
            try iteratesFromOnAnUnwrittenMap(database)
            let set = try fillsTheSet(moment)
            try readsShortKeysWithAReader(set)
            try removesFromTheSet(set)
            try guardsTheKeysAndTheEntries(map)
            try keepsTheCountConsistentAfterAFailedWrite(map)
        }
    }

    /// test.zig 3408-3422: the keys in reverse order, and a key put twice.
    private func fillsTheMapInReverseOrder(_ map: SortedMap<ReadWrite>) throws {
        // insert in reverse order to exercise front-insertions and splits
        var i = count
        while i > 0 {
            i -= 1
            let key = paddedKey(i, width: 4)
            try map.put(.uint(UInt64(i)), forKey: key)
        }
        #expect(try map.count == UInt64(count))

        // dedup: re-putting an existing key replaces the value, not the count
        try map.put(.uint(999), forKey: utf8("k0005"))
        #expect(try map.count == UInt64(count))
        #expect(try #require(try map.cursor(forKey: utf8("k0005"))).readUInt64() == 999)
        try map.put(.uint(5), forKey: utf8("k0005"))
    }

    /// test.zig 3424-3441: the iterator, and lookups of a present and an absent key.
    private func iteratesInOrder(_ map: SortedMap<ReadWrite>) throws {
        // ordered iteration yields k0000..k0059 in order with intact values
        do {
            var iter = try map.iterator()
            var n = 0
            while let c = try iter.next() {
                let kv = try c.readEntry()
                let expect = paddedKey(n, width: 4)
                #expect(try readBytes(kv.key, bufferSize: 8) == expect)
                #expect(try kv.value.readUInt64() == UInt64(n))
                n += 1
            }
            #expect(n == count)
        }

        #expect(try map.cursor(forKey: utf8("k0042")) != nil)
        #expect(try map.cursor(forKey: utf8("nope")) == nil)
    }

    /// test.zig 3443-3458: `getIndexKeyValuePair` and `rank`.
    private func getsByIndexAndByRank(_ map: SortedMap<ReadWrite>) throws {
        // getByIndex (positive and negative) and rank are inverses
        var idx = 0
        while idx < count {
            let kv = try #require(try map.entry(at: Int64(idx)))
            let key = try readBytes(kv.key, bufferSize: 8)
            #expect(key == paddedKey(idx, width: 4))
            #expect(try map.rank(of: key) == UInt64(idx))
            idx += 1
        }
        let last = try #require(try map.entry(at: -1))
        #expect(try readBytes(last.key, bufferSize: 8) == utf8("k0059"))
        #expect(try map.entry(at: Int64(count)) == nil)
    }

    /// test.zig 3460-3495: `iteratorFrom` and `iteratorFromIndex`, with indexes in and out of range.
    private func iteratesFromAKeyAndFromAnIndex(_ map: SortedMap<ReadWrite>) throws {
        // lower-bound iteration from a present and an absent key
        do {
            var iter = try map.iterator(fromKey: utf8("k0030"))
            #expect(try nextKey(&iter) == utf8("k0030"))
        }
        do {
            // "k00095" sorts between "k0009" and "k0010"
            var iter = try map.iterator(fromKey: utf8("k00095"))
            #expect(try nextKey(&iter) == utf8("k0010"))
        }
        do {
            var iter = try map.iterator(fromIndex: Int64(count - 2))
            #expect(try nextKey(&iter) == utf8("k0058"))
        }
        // negative indexes count from the end: -1 is the last entry, -COUNT the first
        do {
            var iter = try map.iterator(fromIndex: -1)
            #expect(try nextKey(&iter) == utf8("k0059"))
            let afterLast = try iter.next()
            #expect(afterLast == nil)  // -1 is the last entry, so nothing follows
        }
        do {
            var iter = try map.iterator(fromIndex: -Int64(count))
            #expect(try nextKey(&iter) == utf8("k0000"))
        }
        // out of range past either end yields nothing
        do {
            var itHi = try map.iterator(fromIndex: Int64(count))
            let firstHi = try itHi.next()
            #expect(firstHi == nil)
            var itLo = try map.iterator(fromIndex: -Int64(count) - 1)
            let firstLo = try itLo.next()
            #expect(firstLo == nil)
        }
    }

    /// test.zig 3497-3519: `remove`, and the iterator afterwards.
    private func removesTheEvenKeys(_ map: SortedMap<ReadWrite>) throws {
        // remove the even keys, then re-verify order, count, and presence
        var j = 0
        while j < count {
            #expect(try map.remove(forKey: paddedKey(j, width: 4)))
            j += 2
        }
        #expect(try map.count == UInt64(count / 2))
        #expect(try !map.remove(forKey: utf8("k0000")))  // already gone

        var iter = try map.iterator()
        var expectI = 1
        var seen = 0
        while let c = try iter.next() {
            let kv = try c.readEntry()
            #expect(try readBytes(kv.key, bufferSize: 8) == paddedKey(expectI, width: 4))
            expectI += 2
            seen += 1
        }
        #expect(seen == count / 2)
    }

    /// test.zig 3521-3529: the two iterators from a position on a cursor at nothing. Zig's
    /// `DB.Cursor(.read_only){ .slot_ptr = .{ .position = null, .slot = .{} }, .db = cursor.db }` is the cursor
    /// made here.
    private func iteratesFromOnAnUnwrittenMap(_ database: Database) throws {
        // iterating-from on an unwritten (.none) map yields nothing, like iterator()
        let noneCursor = Cursor<ReadOnly>(slotPointer: SlotPointer(position: nil, slot: Slot()), database: database)
        let empty = try SortedMap<ReadOnly>(noneCursor)
        var it1 = try empty.iterator(fromKey: utf8("anything"))
        let first1 = try it1.next()
        #expect(first1 == nil)
        var it2 = try empty.iterator(fromIndex: 0)
        let first2 = try it2.next()
        #expect(first2 == nil)
    }

    /// test.zig 3531-3551: the set, filled and iterated.
    private func fillsTheSet(_ moment: HashMap<ReadWrite>) throws -> SortedSet<ReadWrite> {
        // SortedSet with mixed short (inline) and long (external) keys
        let set = try SortedSet<ReadWrite>(try moment.putCursor(forHash: hashInt("set")))
        try set.insert(utf8("short"))
        try set.insert(utf8("a-much-longer-key-stored-externally"))
        try set.insert(utf8("mid"))
        try set.insert(utf8("short"))  // dup is a no-op
        #expect(try set.count == 3)
        #expect(try set.contains(utf8("mid")))
        #expect(try !set.contains(utf8("nope")))
        do {
            var iter = try set.iterator()
            let want = ["a-much-longer-key-stored-externally", "mid", "short"]
            var n = 0
            while let c = try iter.next() {
                let kv = try c.readEntry()
                #expect(try readBytes(kv.key, bufferSize: 64) == utf8(want[n]))
                n += 1
            }
            #expect(n == 3)
        }
        return set
    }

    /// The fix branch's test.zig 3650-3675 (commit 1486fbf): a reader on the key cursor of each entry of the
    /// set, and on the cursor at a short key, which has no position. Zig's `set.map.cursor` is `set.cursor`,
    /// `take(3)` is a `readAll` of three bytes and `takeByte()` one of one byte.
    private func readsShortKeysWithAReader(_ set: SortedSet<ReadWrite>) throws {
        // a short key is stored in a slot, and its cursor has no position.
        // it can be read with a reader like a long key.
        var iter = try set.iterator()
        while let c = try iter.next() {
            let kv = try c.readEntry()
            let key = try readBytes(kv.key, bufferSize: 64)
            var keyReader = try kv.key.reader()
            let whole = try readShort(&keyReader, size: 64)
            #expect(whole.count == key.count)
            #expect(Array(whole.buffer[0..<key.count]) == key)
            keyReader.seek(to: 1)
            let rest = try readShort(&keyReader, size: 64)
            #expect(rest.count == key.count - 1)
            #expect(Array(rest.buffer[0..<(key.count - 1)]) == Array(key[1...]))
        }

        let keyCursor = try #require(try set.cursor.readPath([.sortedMapGet(.key, SortedKey(utf8("mid")))]))
        #expect(keyCursor.slotPointer.position == nil)
        var keyReader = try keyCursor.reader()
        #expect(try readAll(&keyReader, size: 3) == utf8("mid"))
        #expect(throws: XitDBError.endOfStream) { try readAll(&keyReader, size: 1) }
    }

    /// test.zig 3552-3553: a key removed from the set.
    private func removesFromTheSet(_ set: SortedSet<ReadWrite>) throws {
        #expect(try set.remove(forKey: utf8("mid")))
        #expect(try set.count == 2)
    }

    /// test.zig 3555-3563: the path parts that must not write.
    private func guardsTheKeysAndTheEntries(_ map: SortedMap<ReadWrite>) throws {
        // immutability guards: positional access is read-only, and keys/entries
        // cannot be overwritten through the low-level path API
        #expect(throws: XitDBError.writeNotAllowed) {
            try map.cursor.writePath([
                .sortedMapGetIndex(0)
            ])
        }
        #expect(throws: XitDBError.cursorNotWritable) {
            try map.cursor.writePath([
                .sortedMapGet(.key, SortedKey(utf8("k0001"))),
                .write(.bytes(utf8("x"))),
            ])
        }
    }

    /// test.zig 3565-3575: the count after a path that inserts a key and then fails.
    private func keepsTheCountConsistentAfterAFailedWrite(_ map: SortedMap<ReadWrite>) throws {
        // a write that fails after the key is inserted (a missing key written
        // through the non-writeable key slot) must still leave the count
        // consistent with the tree, not inserted-but-uncounted
        let countBeforeFailedWrite = try map.count
        #expect(throws: XitDBError.cursorNotWritable) {
            try map.cursor.writePath([
                .sortedMapGet(.key, SortedKey(utf8("missing-key"))),
                .write(.bytes(utf8("x"))),
            ])
        }
        #expect(try map.count == countBeforeFailedWrite + 1)
        #expect(try map.entry(forKey: utf8("missing-key")) != nil)
        #expect(try map.remove(forKey: utf8("missing-key")))  // restore the map for the assertions below
    }

    /// test.zig 3586-3601: the committed moment, read through a read-only map.
    private func theMapPersistsInTheCommittedMoment(_ database: Database) throws {
        // the map persists in the committed moment
        let history = try ArrayList<ReadOnly>(database.rootCursor.readOnly)
        let moment = try #require(try history.cursor(at: -1))
        let mapCursor = try #require(
            try moment.readPath([
                .hashMapGet(.value, sha1("map"))
            ])
        )
        let map = try SortedMap<ReadOnly>(mapCursor)
        #expect(try map.count == UInt64(count / 2))
        let first = try #require(try map.entry(at: 0))
        #expect(try readBytes(first.key, bufferSize: 8) == utf8("k0001"))

        // entries have no hash
        let entry = try #require(try map.cursor.readPathSlot([.sortedMapGet(.kvPair, SortedKey(utf8("k0001")))]))
        #expect(entry.tag == .sortedKvPair)
    }

    /// test.zig 3603-3638: `Ctx2`, a second moment that changes the map, and the two moments afterwards.
    private func aSecondMomentInheritsAndMutatesTheMap(_ database: Database) throws {
        let rootCursor = database.rootCursor

        // a second moment that inherits and mutates the map must not disturb the first
        // (copy-on-write immutability across transactions)
        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .hashMapInit(),
            .ctx,
        ]) { (cursor: inout Cursor<ReadWrite>) in
            let moment = try HashMap<ReadWrite>(cursor)
            let map = try SortedMap<ReadWrite>(try moment.putCursor(forHash: hashInt("map")))
            #expect(try map.remove(forKey: utf8("k0001")))
            try map.put(.uint(7), forKey: utf8("k0001"))  // not in moment 0
        }
        do {
            let history = try ArrayList<ReadOnly>(database.rootCursor.readOnly)

            // moment 0 (original) is unchanged: k0001 still present with value 1
            let m0 = try #require(try history.cursor(at: 0))
            let map0 = try SortedMap<ReadOnly>(
                try #require(
                    try m0.readPath([
                        .hashMapGet(.value, sha1("map"))
                    ])
                )
            )
            #expect(try map0.count == UInt64(count / 2))
            #expect(try #require(try map0.cursor(forKey: utf8("k0001"))).readUInt64() == 1)

            // moment 1 reflects the mutation: k0001 re-added with value 7
            let m1 = try #require(try history.cursor(at: 1))
            let map1 = try SortedMap<ReadOnly>(
                try #require(
                    try m1.readPath([
                        .hashMapGet(.value, sha1("map"))
                    ])
                )
            )
            #expect(try map1.count == UInt64(count / 2))
            #expect(try #require(try map1.cursor(forKey: utf8("k0001"))).readUInt64() == 7)
        }
    }
}
