import Testing

@testable import XitDB

// A port of Zig's test "compaction" (`src/test.zig`, lines 2775 to 2865) with the `testCompaction` it calls (lines
// 2956 to 3360), and of "compaction with disk-backed offsets map" (lines 2867 to 2934), through the public API.
//
// Zig runs `testCompaction` for a memory source compacted into memory, a file into a file, a buffered file into a
// buffered file, and a buffered file into memory (lines 2781 to 2864), with one offsets map for all four runs. The
// compaction here does not care about the kinds of the storages, so the tests take the source kind and the target
// kind as arguments and run for every pair of the kinds the storages under test come in; each pair has an offsets
// map of its own, reused across the blocks of the run, since the pairs run in parallel.
//
// The comments inside the tests are Zig's. Zig's `history.appendContext(.{ .slot = ... }, Ctx{})` with a `Ctx`
// whose `run` method does the writing is `history.appendContext(.slot(...)) { cursor in ... }` here. Zig's
// `clearStorage` of the source and the target at the start of a block is a new storage of each kind here. Zig's
// `source.compact(target_db_kind, target_opts, offset_map)`, which opens the target over the target's options, is
// `source.compact(into: targetStorage, offsetMap: &offsetMap)`. Zig's `source.core.length` is the source
// storage's `length()`. Zig's `DiskOffsets` (lines 2874 to 2891) is `DiskOffsetMap` in `DiskOffsetMap.swift`, and
// its `Ctx.run` under `offsets_db.withTransaction` (lines 2911 to 2933) is `DiskOffsets.use`. Zig's allocator arguments
// and `defer allocator.free` lines have no counterpart.
//
// Every assertion Zig makes in those lines is here. Left out:
// - The condition on the last two blocks, `if (db_kind != .memory)` (line 3265), which skips them for a memory
//   source because, as Zig's comment says, reopening is only meaningful for a file. A memory storage is reopened
//   like any other here, and Zig itself reopens a memory target in its buffered-file-to-memory run, so the blocks
//   run for every pair.
// - `_ = &compacted;` (line 3287), which only keeps Zig from reporting an unused variable.
// - Zig's `max_size = 5_000_000` for its memory databases and `.fsync = false` for its files, which configure its
//   storages: the storages under test have no size limit and no durability.

/// Zig's compaction tests: what the latest moment reaches survives, copied once, and nothing else does.
@Suite struct CompactionTests {
    /// The UTF-8 bytes of a string.
    private func utf8(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    /// Zig's `hashInt(text)`: the SHA-1 of the text, as the twenty bytes the collections take.
    private func hashInt(_ text: String) -> [UInt8] {
        sha1(text).bytes
    }

    /// test.zig 2775-2865: "compaction", with the offsets map in memory.
    @Test(arguments: StorageKind.allCases, StorageKind.allCases)
    func compaction(source: StorageKind, target: StorageKind) throws {
        var offsetMap = MemoryOffsetMap()
        try testCompaction(source: source, target: target, offsetMap: &offsetMap)
    }

    /// test.zig 2867-2934: "compaction with disk-backed offsets map". The offsets database is on a file, as Zig's
    /// is; the source and the target come in every pair of kinds, as in the test above.
    @Test(arguments: StorageKind.allCases, StorageKind.allCases)
    func compactionWithDiskBackedOffsetsMap(source: StorageKind, target: StorageKind) throws {
        // a custom offsets map only needs reset, get, and put. this one stores offsets
        // directly as u64 hashes in a separate xitdb hash map, inside one transaction
        // that lasts for the whole compaction, so each put isn't committed separately.
        let offsetsSubject = try StorageUnderTest(.file)
        let offsets = try DiskOffsets(storage: offsetsSubject.storage)

        try offsets.use { map in
            // exercise the same data types, cycles, sharing, and reopening checks
            // as the in-memory offsets map, reusing the scratch map between runs.
            // reusing it must discard offsets from previous compactions.
            try map.put(0, 123)
            try testCompaction(source: source, target: target, offsetMap: &map)
            let remembered = try map.get(0)
            #expect(remembered == nil)
        }
    }

    /// test.zig 2956-3360: `testCompaction`. Each block starts from new storages, so the blocks are the methods
    /// below, in Zig's order, sharing the one offsets map as Zig's do.
    private func testCompaction<Map: OffsetMap>(
        source sourceKind: StorageKind,
        target targetKind: StorageKind,
        offsetMap: inout Map
    ) throws {
        try compactsAnEmptyDatabase(sourceKind, targetKind, offsetMap: &offsetMap)
        try compactsVariousDataTypes(sourceKind, targetKind, offsetMap: &offsetMap)
        try compactsSharedStructure(sourceKind, targetKind, offsetMap: &offsetMap)
        try reopensAfterCompaction(sourceKind, targetKind, offsetMap: &offsetMap)
        try continuesWritingAfterCompaction(sourceKind, targetKind, offsetMap: &offsetMap)
    }

    /// test.zig 2967-2974: "empty DB compaction".
    private func compactsAnEmptyDatabase<Map: OffsetMap>(
        _ sourceKind: StorageKind,
        _ targetKind: StorageKind,
        offsetMap: inout Map
    ) throws {
        // empty DB compaction
        let sourceSubject = try StorageUnderTest(sourceKind)
        let targetSubject = try StorageUnderTest(targetKind)
        let source = try Database(storage: sourceSubject.storage, hashSize: 20)
        let compacted = try source.compact(into: targetSubject.storage, offsetMap: &offsetMap)
        #expect(try compacted.rootCursor.slot().isEmpty)
    }

    /// test.zig 2976-3207: "basic compaction with various data types": three moments, the third with a map that
    /// holds itself, a list that holds itself and two maps that hold each other, compacted and read back.
    private func compactsVariousDataTypes<Map: OffsetMap>(
        _ sourceKind: StorageKind,
        _ targetKind: StorageKind,
        offsetMap: inout Map
    ) throws {
        // basic compaction with various data types
        let sourceSubject = try StorageUnderTest(sourceKind)
        let targetSubject = try StorageUnderTest(targetKind)
        let source = try Database(storage: sourceSubject.storage, hashSize: 20)

        // moment 1
        do {
            let history = try ArrayList<ReadWrite>(source.rootCursor)
            try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                try moment.put(.bytes(utf8("value1")), forHash: hashInt("key1"))
                try moment.put(.uint(100), forHash: hashInt("key2"))
            }
        }

        // moment 2
        do {
            let history = try ArrayList<ReadWrite>(source.rootCursor)
            try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                try moment.put(.bytes(utf8("updated_value1")), forHash: hashInt("key1"))
                try moment.put(.uint(200), forHash: hashInt("key2"))
                try moment.put(.int(-42), forHash: hashInt("key3"))
                try moment.put(.double(3.14), forHash: hashInt("key4"))
                try moment.put(.bytes(utf8("hi")), forHash: hashInt("short"))

                // long bytes with format_tag
                try moment.put(
                    .bytes(utf8("this is a long tagged string!!"), formatTag: "bi"), forHash: hashInt("tagged"))

                // ArrayList
                let fruitsCursor = try moment.putCursor(forHash: hashInt("fruits"))
                let fruits = try ArrayList<ReadWrite>(fruitsCursor)
                try fruits.append(.bytes(utf8("apple")))
                try fruits.append(.bytes(utf8("banana")))
                try fruits.append(.bytes(utf8("cherry")))

                // LinkedArrayList
                let todosCursor = try moment.putCursor(forHash: hashInt("todos"))
                let todos = try LinkedArrayList<ReadWrite>(todosCursor)
                try todos.append(.bytes(utf8("task1")))
                try todos.append(.bytes(utf8("task2")))
                try todos.append(.bytes(utf8("task3")))

                // CountedHashMap
                let countedCursor = try moment.putCursor(forHash: hashInt("counted"))
                let counted = try CountedHashMap<ReadWrite>(countedCursor)
                try counted.put(.uint(1), forHash: hashInt("a"))
                try counted.putKey(.bytes(utf8("a")), forHash: hashInt("a"))
                try counted.put(.uint(2), forHash: hashInt("b"))
                try counted.putKey(.bytes(utf8("b")), forHash: hashInt("b"))

                // HashSet
                let setCursor = try moment.putCursor(forHash: hashInt("myset"))
                let set = try HashSet<ReadWrite>(setCursor)
                try set.insert(.bytes(utf8("x")), forHash: hashInt("x"))
                try set.insert(.bytes(utf8("y")), forHash: hashInt("y"))

                // CountedHashSet
                let csetCursor = try moment.putCursor(forHash: hashInt("mycset"))
                let cset = try CountedHashSet<ReadWrite>(csetCursor)
                try cset.insert(.bytes(utf8("p")), forHash: hashInt("p"))
                try cset.insert(.bytes(utf8("q")), forHash: hashInt("q"))

                // SortedMap
                let sortedCursor = try moment.putCursor(forHash: hashInt("sorted"))
                let sorted = try SortedMap<ReadWrite>(sortedCursor)
                try sorted.put(utf8("apple"), .uint(1))
                try sorted.put(utf8("banana"), .uint(2))
                try sorted.put(utf8("cherry"), .uint(3))

                // SortedSet
                let sortedSetCursor = try moment.putCursor(forHash: hashInt("sortedset"))
                let sortedSet = try SortedSet<ReadWrite>(sortedSetCursor)
                try sortedSet.put(utf8("foo"))
                try sortedSet.put(utf8("bar"))
            }
        }

        // moment 3
        do {
            let history = try ArrayList<ReadWrite>(source.rootCursor)
            try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                try moment.put(.bytes(utf8("final_value")), forHash: hashInt("key1"))

                // cycles must survive compaction rather than causing the
                // remapper to recurse indefinitely.
                try moment.put(.slot(try moment.slot()), forHash: hashInt("self"))

                let cyclicList = try ArrayList<ReadWrite>(try moment.putCursor(forHash: hashInt("cyclic-list")))
                try cyclicList.append(.slot(try cyclicList.slot()))

                let mapA = try HashMap<ReadWrite>(try moment.putCursor(forHash: hashInt("map-a")))
                let mapB = try HashMap<ReadWrite>(try moment.putCursor(forHash: hashInt("map-b")))
                try mapA.put(.slot(try mapB.slot()), forHash: hashInt("map-b"))
                try mapB.put(.slot(try mapA.slot()), forHash: hashInt("map-a"))
            }
        }

        let sourceSize = try sourceSubject.storage.length

        // compact
        let compacted = try source.compact(into: targetSubject.storage, offsetMap: &offsetMap)

        let targetSize = try targetSubject.storage.length

        // target should be smaller than source (3 moments vs 1)
        #expect(targetSize < sourceSize)

        // target should have exactly 1 moment
        let history = try ArrayList<ReadOnly>(compacted.rootCursor.readOnly)
        #expect(try history.count() == 1)

        // verify all data from latest moment is correct
        let momentCursor = try #require(try history.getCursor(0))
        let moment = try HashMap<ReadOnly>(momentCursor)

        // self-references and mutual references point back to the same compacted
        // objects rather than duplicate objects or dangling source offsets.
        let selfCursor = try #require(try moment.cursor(forHash: hashInt("self")))
        #expect(try selfCursor.slot() == momentCursor.slot())

        let cyclicListCursor = try #require(try moment.cursor(forHash: hashInt("cyclic-list")))
        let cyclicList = try ArrayList<ReadOnly>(cyclicListCursor)
        let cyclicListFirst = try #require(try cyclicList.getSlot(0))
        #expect(try cyclicListFirst == cyclicListCursor.slot())

        let mapACursor = try #require(try moment.cursor(forHash: hashInt("map-a")))
        let mapA = try HashMap<ReadOnly>(mapACursor)
        let mapBCursor = try #require(try mapA.cursor(forHash: hashInt("map-b")))
        let mapB = try HashMap<ReadOnly>(mapBCursor)
        let mapBToA = try #require(try mapB.slot(forHash: hashInt("map-a")))
        #expect(try mapBToA == mapACursor.slot())

        // key1 should have the final value
        let key1Cursor = try #require(try moment.cursor(forHash: hashInt("key1")))
        #expect(try key1Cursor.readBytes(maxCount: 1024) == utf8("final_value"))

        // key2 from moment 2
        let key2Cursor = try #require(try moment.cursor(forHash: hashInt("key2")))
        #expect(try key2Cursor.readUInt64() == 200)

        // key3 - int
        let key3Cursor = try #require(try moment.cursor(forHash: hashInt("key3")))
        #expect(try key3Cursor.readInt64() == -42)

        // key4 - float
        let key4Cursor = try #require(try moment.cursor(forHash: hashInt("key4")))
        #expect(try key4Cursor.readDouble() == 3.14)

        // short bytes
        let shortCursor = try #require(try moment.cursor(forHash: hashInt("short")))
        #expect(try shortCursor.readBytes(maxCount: 1024) == utf8("hi"))

        // tagged bytes
        let taggedCursor = try #require(try moment.cursor(forHash: hashInt("tagged")))
        let taggedObject = try taggedCursor.readBytesWithFormatTag(maxCount: 1024)
        #expect(taggedObject.value == utf8("this is a long tagged string!!"))
        let taggedFormatTag = try #require(taggedObject.formatTag)
        #expect(taggedFormatTag == "bi")

        // ArrayList
        let fruitsCursor = try #require(try moment.cursor(forHash: hashInt("fruits")))
        let fruits = try ArrayList<ReadOnly>(fruitsCursor)
        #expect(try fruits.count() == 3)
        let appleCursor = try #require(try fruits.getCursor(0))
        #expect(try appleCursor.readBytes(maxCount: 1024) == utf8("apple"))
        let cherryCursor = try #require(try fruits.getCursor(2))
        #expect(try cherryCursor.readBytes(maxCount: 1024) == utf8("cherry"))

        // LinkedArrayList
        let todosCursor = try #require(try moment.cursor(forHash: hashInt("todos")))
        let todos = try LinkedArrayList<ReadOnly>(todosCursor)
        #expect(try todos.count() == 3)
        let task1Cursor = try #require(try todos.getCursor(0))
        #expect(try task1Cursor.readBytes(maxCount: 1024) == utf8("task1"))
        let task3Cursor = try #require(try todos.getCursor(2))
        #expect(try task3Cursor.readBytes(maxCount: 1024) == utf8("task3"))

        // CountedHashMap
        let countedCursor = try #require(try moment.cursor(forHash: hashInt("counted")))
        let counted = try CountedHashMap<ReadOnly>(countedCursor)
        #expect(try counted.count() == 2)
        let countedACursor = try #require(try counted.cursor(forHash: hashInt("a")))
        #expect(try countedACursor.readUInt64() == 1)
        let countedBCursor = try #require(try counted.cursor(forHash: hashInt("b")))
        #expect(try countedBCursor.readUInt64() == 2)

        // HashSet
        let setCursor = try #require(try moment.cursor(forHash: hashInt("myset")))
        let set = try HashSet<ReadOnly>(setCursor)
        let xCursor = try #require(try set.cursor(forHash: hashInt("x")))
        #expect(try xCursor.readBytes(maxCount: 1024) == utf8("x"))

        // CountedHashSet
        let csetCursor = try #require(try moment.cursor(forHash: hashInt("mycset")))
        let cset = try CountedHashSet<ReadOnly>(csetCursor)
        #expect(try cset.count() == 2)
        let pCursor = try #require(try cset.cursor(forHash: hashInt("p")))
        #expect(try pCursor.readBytes(maxCount: 1024) == utf8("p"))

        // SortedMap
        let sortedCursor = try #require(try moment.cursor(forHash: hashInt("sorted")))
        let sorted = try SortedMap<ReadOnly>(sortedCursor)
        #expect(try sorted.count() == 3)
        let bananaCursor = try #require(try sorted.getCursor(utf8("banana")))
        #expect(try bananaCursor.readUInt64() == 2)
        // lexicographic order is preserved across compaction
        let firstPair = try #require(try sorted.getIndexKeyValuePair(0))
        #expect(try firstPair.key.readBytes(maxCount: 1024) == utf8("apple"))
        let lastPair = try #require(try sorted.getIndexKeyValuePair(-1))
        #expect(try lastPair.key.readBytes(maxCount: 1024) == utf8("cherry"))

        // SortedSet
        let sortedSetCursor = try #require(try moment.cursor(forHash: hashInt("sortedset")))
        let sortedSet = try SortedSet<ReadOnly>(sortedSetCursor)
        #expect(try sortedSet.count() == 2)
        #expect(try sortedSet.contains(utf8("foo")))
        #expect(try sortedSet.contains(utf8("bar")))
        #expect(try !sortedSet.contains(utf8("baz")))
    }

    /// test.zig 3209-3261: "structural sharing": one moment of twenty keys and four more that each change one.
    private func compactsSharedStructure<Map: OffsetMap>(
        _ sourceKind: StorageKind,
        _ targetKind: StorageKind,
        offsetMap: inout Map
    ) throws {
        // structural sharing (most data shared, only 1 key changes per moment)
        let sourceSubject = try StorageUnderTest(sourceKind)
        let targetSubject = try StorageUnderTest(targetKind)
        let source = try Database(storage: sourceSubject.storage, hashSize: 20)

        // moment 1: create many keys
        do {
            let history = try ArrayList<ReadWrite>(source.rootCursor)
            try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                for i in 0..<20 {
                    try moment.put(.uint(UInt64(i)), forHash: hashInt("shared_key_\(i)"))
                }
            }
        }

        // moments 2-5: change only one key each time
        for round in 0..<4 {
            let history = try ArrayList<ReadWrite>(source.rootCursor)
            try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                try moment.put(.uint(UInt64(round) + 100), forHash: hashInt("changing_key"))
            }
        }

        let compacted = try source.compact(into: targetSubject.storage, offsetMap: &offsetMap)

        let history = try ArrayList<ReadOnly>(compacted.rootCursor.readOnly)
        #expect(try history.count() == 1)

        let momentCursor = try #require(try history.getCursor(0))
        let moment = try HashMap<ReadOnly>(momentCursor)

        // verify shared keys are intact
        for i in 0..<20 {
            let keyCursor = try #require(try moment.cursor(forHash: hashInt("shared_key_\(i)")))
            #expect(try keyCursor.readUInt64() == UInt64(i))
        }

        // verify changing key has latest value
        let changingKeyCursor = try #require(try moment.cursor(forHash: hashInt("changing_key")))
        #expect(try changingKeyCursor.readUInt64() == 103)
    }

    /// test.zig 3263-3301: "re-open after compact". Zig opens a second database over the target's file handle;
    /// here a second database is opened over the target's storage.
    private func reopensAfterCompaction<Map: OffsetMap>(
        _ sourceKind: StorageKind,
        _ targetKind: StorageKind,
        offsetMap: inout Map
    ) throws {
        // re-open after compact and compact-then-continue-writing
        // (only meaningful for file and buffered_file modes)

        // re-open after compact
        let sourceSubject = try StorageUnderTest(sourceKind)
        let targetSubject = try StorageUnderTest(targetKind)
        let source = try Database(storage: sourceSubject.storage, hashSize: 20)

        // write some data
        do {
            let history = try ArrayList<ReadWrite>(source.rootCursor)
            try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                try moment.put(.bytes(utf8("persistent_value")), forHash: hashInt("persist"))
                try moment.put(.uint(999), forHash: hashInt("number"))
            }
        }

        // compact
        _ = try source.compact(into: targetSubject.storage, offsetMap: &offsetMap)

        // re-open the target
        let reopened = try Database(storage: targetSubject.storage, hashSize: 20)

        let history = try ArrayList<ReadOnly>(reopened.rootCursor.readOnly)
        #expect(try history.count() == 1)

        let momentCursor = try #require(try history.getCursor(0))
        let moment = try HashMap<ReadOnly>(momentCursor)
        let persistCursor = try #require(try moment.cursor(forHash: hashInt("persist")))
        #expect(try persistCursor.readBytes(maxCount: 1024) == utf8("persistent_value"))
        let numberCursor = try #require(try moment.cursor(forHash: hashInt("number")))
        #expect(try numberCursor.readUInt64() == 999)
    }

    /// test.zig 3303-3358: "compact then continue writing".
    private func continuesWritingAfterCompaction<Map: OffsetMap>(
        _ sourceKind: StorageKind,
        _ targetKind: StorageKind,
        offsetMap: inout Map
    ) throws {
        // compact then continue writing
        let sourceSubject = try StorageUnderTest(sourceKind)
        let targetSubject = try StorageUnderTest(targetKind)
        let source = try Database(storage: sourceSubject.storage, hashSize: 20)

        // write initial data
        do {
            let history = try ArrayList<ReadWrite>(source.rootCursor)
            try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                try moment.put(.bytes(utf8("original_data")), forHash: hashInt("original"))
            }
        }

        // compact
        let compacted = try source.compact(into: targetSubject.storage, offsetMap: &offsetMap)

        // add new moment to compacted DB
        do {
            let history = try ArrayList<ReadWrite>(compacted.rootCursor)
            try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                try moment.put(.bytes(utf8("new_data")), forHash: hashInt("new_key"))
            }
        }

        // verify both old and new data
        let history = try ArrayList<ReadOnly>(compacted.rootCursor.readOnly)
        #expect(try history.count() == 2)

        // moment 0 (compacted original)
        let m0Cursor = try #require(try history.getCursor(0))
        let m0 = try HashMap<ReadOnly>(m0Cursor)
        let originalCursor = try #require(try m0.cursor(forHash: hashInt("original")))
        #expect(try originalCursor.readBytes(maxCount: 1024) == utf8("original_data"))

        // moment 1 (new data added after compact)
        let m1Cursor = try #require(try history.getCursor(1))
        let m1 = try HashMap<ReadOnly>(m1Cursor)
        let newCursor = try #require(try m1.cursor(forHash: hashInt("new_key")))
        #expect(try newCursor.readBytes(maxCount: 1024) == utf8("new_data"))

        // original data should still be in moment 1 (inherited)
        let originalInM1Cursor = try #require(try m1.cursor(forHash: hashInt("original")))
        #expect(try originalInM1Cursor.readBytes(maxCount: 1024) == utf8("original_data"))
    }
}
