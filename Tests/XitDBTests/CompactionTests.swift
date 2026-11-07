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
                try moment.put(hashInt("key1"), .bytes(utf8("value1")))
                try moment.put(hashInt("key2"), .uint(100))
            }
        }

        // moment 2
        do {
            let history = try ArrayList<ReadWrite>(source.rootCursor)
            try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                try moment.put(hashInt("key1"), .bytes(utf8("updated_value1")))
                try moment.put(hashInt("key2"), .uint(200))
                try moment.put(hashInt("key3"), .int(-42))
                try moment.put(hashInt("key4"), .double(3.14))
                try moment.put(hashInt("short"), .bytes(utf8("hi")))

                // long bytes with format_tag
                try moment.put(
                    hashInt("tagged"),
                    .bytes(utf8("this is a long tagged string!!"), formatTag: "bi")
                )

                // ArrayList
                let fruitsCursor = try moment.putCursor(hashInt("fruits"))
                let fruits = try ArrayList<ReadWrite>(fruitsCursor)
                try fruits.append(.bytes(utf8("apple")))
                try fruits.append(.bytes(utf8("banana")))
                try fruits.append(.bytes(utf8("cherry")))

                // LinkedArrayList
                let todosCursor = try moment.putCursor(hashInt("todos"))
                let todos = try LinkedArrayList<ReadWrite>(todosCursor)
                try todos.append(.bytes(utf8("task1")))
                try todos.append(.bytes(utf8("task2")))
                try todos.append(.bytes(utf8("task3")))

                // CountedHashMap
                let countedCursor = try moment.putCursor(hashInt("counted"))
                let counted = try CountedHashMap<ReadWrite>(countedCursor)
                try counted.put(hashInt("a"), .uint(1))
                try counted.putKey(hashInt("a"), .bytes(utf8("a")))
                try counted.put(hashInt("b"), .uint(2))
                try counted.putKey(hashInt("b"), .bytes(utf8("b")))

                // HashSet
                let setCursor = try moment.putCursor(hashInt("myset"))
                let set = try HashSet<ReadWrite>(setCursor)
                try set.put(hashInt("x"), .bytes(utf8("x")))
                try set.put(hashInt("y"), .bytes(utf8("y")))

                // CountedHashSet
                let csetCursor = try moment.putCursor(hashInt("mycset"))
                let cset = try CountedHashSet<ReadWrite>(csetCursor)
                try cset.put(hashInt("p"), .bytes(utf8("p")))
                try cset.put(hashInt("q"), .bytes(utf8("q")))

                // SortedMap
                let sortedCursor = try moment.putCursor(hashInt("sorted"))
                let sorted = try SortedMap<ReadWrite>(sortedCursor)
                try sorted.put(utf8("apple"), .uint(1))
                try sorted.put(utf8("banana"), .uint(2))
                try sorted.put(utf8("cherry"), .uint(3))

                // SortedSet
                let sortedSetCursor = try moment.putCursor(hashInt("sortedset"))
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
                try moment.put(hashInt("key1"), .bytes(utf8("final_value")))

                // cycles must survive compaction rather than causing the
                // remapper to recurse indefinitely.
                try moment.put(hashInt("self"), .slot(try moment.slot()))

                let cyclicList = try ArrayList<ReadWrite>(try moment.putCursor(hashInt("cyclic-list")))
                try cyclicList.append(.slot(try cyclicList.slot()))

                let mapA = try HashMap<ReadWrite>(try moment.putCursor(hashInt("map-a")))
                let mapB = try HashMap<ReadWrite>(try moment.putCursor(hashInt("map-b")))
                try mapA.put(hashInt("map-b"), .slot(try mapB.slot()))
                try mapB.put(hashInt("map-a"), .slot(try mapA.slot()))
            }
        }

        let sourceSize = try sourceSubject.storage.length

        // compact
        let compacted = try source.compact(into: targetSubject.storage, offsetMap: &offsetMap)

        let targetSize = try targetSubject.storage.length

        // target should be smaller than source (3 moments vs 1)
        #expect(targetSize < sourceSize)

        // target should have exactly 1 moment
        let history = try ArrayList<ReadOnly>(compacted.rootCursor.readOnly())
        #expect(try history.count() == 1)

        // verify all data from latest moment is correct
        let momentCursor = try #require(try history.getCursor(0))
        let moment = try HashMap<ReadOnly>(momentCursor)

        // self-references and mutual references point back to the same compacted
        // objects rather than duplicate objects or dangling source offsets.
        let selfCursor = try #require(try moment.getCursor(hashInt("self")))
        #expect(try selfCursor.slot() == momentCursor.slot())

        let cyclicListCursor = try #require(try moment.getCursor(hashInt("cyclic-list")))
        let cyclicList = try ArrayList<ReadOnly>(cyclicListCursor)
        let cyclicListFirst = try #require(try cyclicList.getSlot(0))
        #expect(try cyclicListFirst == cyclicListCursor.slot())

        let mapACursor = try #require(try moment.getCursor(hashInt("map-a")))
        let mapA = try HashMap<ReadOnly>(mapACursor)
        let mapBCursor = try #require(try mapA.getCursor(hashInt("map-b")))
        let mapB = try HashMap<ReadOnly>(mapBCursor)
        let mapBToA = try #require(try mapB.getSlot(hashInt("map-a")))
        #expect(try mapBToA == mapACursor.slot())

        // key1 should have the final value
        let key1Cursor = try #require(try moment.getCursor(hashInt("key1")))
        #expect(try key1Cursor.readBytesAlloc(maxSize: 1024) == utf8("final_value"))

        // key2 from moment 2
        let key2Cursor = try #require(try moment.getCursor(hashInt("key2")))
        #expect(try key2Cursor.readUint() == 200)

        // key3 - int
        let key3Cursor = try #require(try moment.getCursor(hashInt("key3")))
        #expect(try key3Cursor.readInt() == -42)

        // key4 - float
        let key4Cursor = try #require(try moment.getCursor(hashInt("key4")))
        #expect(try key4Cursor.readFloat() == 3.14)

        // short bytes
        let shortCursor = try #require(try moment.getCursor(hashInt("short")))
        #expect(try shortCursor.readBytesAlloc(maxSize: 1024) == utf8("hi"))

        // tagged bytes
        let taggedCursor = try #require(try moment.getCursor(hashInt("tagged")))
        let taggedObject = try taggedCursor.readBytesObjectAlloc(maxSize: 1024)
        #expect(taggedObject.value == utf8("this is a long tagged string!!"))
        let taggedFormatTag = try #require(taggedObject.formatTag)
        #expect(taggedFormatTag == "bi")

        // ArrayList
        let fruitsCursor = try #require(try moment.getCursor(hashInt("fruits")))
        let fruits = try ArrayList<ReadOnly>(fruitsCursor)
        #expect(try fruits.count() == 3)
        let appleCursor = try #require(try fruits.getCursor(0))
        #expect(try appleCursor.readBytesAlloc(maxSize: 1024) == utf8("apple"))
        let cherryCursor = try #require(try fruits.getCursor(2))
        #expect(try cherryCursor.readBytesAlloc(maxSize: 1024) == utf8("cherry"))

        // LinkedArrayList
        let todosCursor = try #require(try moment.getCursor(hashInt("todos")))
        let todos = try LinkedArrayList<ReadOnly>(todosCursor)
        #expect(try todos.count() == 3)
        let task1Cursor = try #require(try todos.getCursor(0))
        #expect(try task1Cursor.readBytesAlloc(maxSize: 1024) == utf8("task1"))
        let task3Cursor = try #require(try todos.getCursor(2))
        #expect(try task3Cursor.readBytesAlloc(maxSize: 1024) == utf8("task3"))

        // CountedHashMap
        let countedCursor = try #require(try moment.getCursor(hashInt("counted")))
        let counted = try CountedHashMap<ReadOnly>(countedCursor)
        #expect(try counted.count() == 2)
        let countedACursor = try #require(try counted.getCursor(hashInt("a")))
        #expect(try countedACursor.readUint() == 1)
        let countedBCursor = try #require(try counted.getCursor(hashInt("b")))
        #expect(try countedBCursor.readUint() == 2)

        // HashSet
        let setCursor = try #require(try moment.getCursor(hashInt("myset")))
        let set = try HashSet<ReadOnly>(setCursor)
        let xCursor = try #require(try set.getCursor(hashInt("x")))
        #expect(try xCursor.readBytesAlloc(maxSize: 1024) == utf8("x"))

        // CountedHashSet
        let csetCursor = try #require(try moment.getCursor(hashInt("mycset")))
        let cset = try CountedHashSet<ReadOnly>(csetCursor)
        #expect(try cset.count() == 2)
        let pCursor = try #require(try cset.getCursor(hashInt("p")))
        #expect(try pCursor.readBytesAlloc(maxSize: 1024) == utf8("p"))

        // SortedMap
        let sortedCursor = try #require(try moment.getCursor(hashInt("sorted")))
        let sorted = try SortedMap<ReadOnly>(sortedCursor)
        #expect(try sorted.count() == 3)
        let bananaCursor = try #require(try sorted.getCursor(utf8("banana")))
        #expect(try bananaCursor.readUint() == 2)
        // lexicographic order is preserved across compaction
        let firstPair = try #require(try sorted.getIndexKeyValuePair(0))
        #expect(try firstPair.keyCursor.readBytesAlloc(maxSize: 1024) == utf8("apple"))
        let lastPair = try #require(try sorted.getIndexKeyValuePair(-1))
        #expect(try lastPair.keyCursor.readBytesAlloc(maxSize: 1024) == utf8("cherry"))

        // SortedSet
        let sortedSetCursor = try #require(try moment.getCursor(hashInt("sortedset")))
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
                    try moment.put(hashInt("shared_key_\(i)"), .uint(UInt64(i)))
                }
            }
        }

        // moments 2-5: change only one key each time
        for round in 0..<4 {
            let history = try ArrayList<ReadWrite>(source.rootCursor)
            try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                try moment.put(hashInt("changing_key"), .uint(UInt64(round) + 100))
            }
        }

        let compacted = try source.compact(into: targetSubject.storage, offsetMap: &offsetMap)

        let history = try ArrayList<ReadOnly>(compacted.rootCursor.readOnly())
        #expect(try history.count() == 1)

        let momentCursor = try #require(try history.getCursor(0))
        let moment = try HashMap<ReadOnly>(momentCursor)

        // verify shared keys are intact
        for i in 0..<20 {
            let keyCursor = try #require(try moment.getCursor(hashInt("shared_key_\(i)")))
            #expect(try keyCursor.readUint() == UInt64(i))
        }

        // verify changing key has latest value
        let changingKeyCursor = try #require(try moment.getCursor(hashInt("changing_key")))
        #expect(try changingKeyCursor.readUint() == 103)
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
                try moment.put(hashInt("persist"), .bytes(utf8("persistent_value")))
                try moment.put(hashInt("number"), .uint(999))
            }
        }

        // compact
        _ = try source.compact(into: targetSubject.storage, offsetMap: &offsetMap)

        // re-open the target
        let reopened = try Database(storage: targetSubject.storage, hashSize: 20)

        let history = try ArrayList<ReadOnly>(reopened.rootCursor.readOnly())
        #expect(try history.count() == 1)

        let momentCursor = try #require(try history.getCursor(0))
        let moment = try HashMap<ReadOnly>(momentCursor)
        let persistCursor = try #require(try moment.getCursor(hashInt("persist")))
        #expect(try persistCursor.readBytesAlloc(maxSize: 1024) == utf8("persistent_value"))
        let numberCursor = try #require(try moment.getCursor(hashInt("number")))
        #expect(try numberCursor.readUint() == 999)
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
                try moment.put(hashInt("original"), .bytes(utf8("original_data")))
            }
        }

        // compact
        let compacted = try source.compact(into: targetSubject.storage, offsetMap: &offsetMap)

        // add new moment to compacted DB
        do {
            let history = try ArrayList<ReadWrite>(compacted.rootCursor)
            try history.appendContext(.slot(try history.getSlot(-1))) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                try moment.put(hashInt("new_key"), .bytes(utf8("new_data")))
            }
        }

        // verify both old and new data
        let history = try ArrayList<ReadOnly>(compacted.rootCursor.readOnly())
        #expect(try history.count() == 2)

        // moment 0 (compacted original)
        let m0Cursor = try #require(try history.getCursor(0))
        let m0 = try HashMap<ReadOnly>(m0Cursor)
        let originalCursor = try #require(try m0.getCursor(hashInt("original")))
        #expect(try originalCursor.readBytesAlloc(maxSize: 1024) == utf8("original_data"))

        // moment 1 (new data added after compact)
        let m1Cursor = try #require(try history.getCursor(1))
        let m1 = try HashMap<ReadOnly>(m1Cursor)
        let newCursor = try #require(try m1.getCursor(hashInt("new_key")))
        #expect(try newCursor.readBytesAlloc(maxSize: 1024) == utf8("new_data"))

        // original data should still be in moment 1 (inherited)
        let originalInM1Cursor = try #require(try m1.getCursor(hashInt("original")))
        #expect(try originalInM1Cursor.readBytesAlloc(maxSize: 1024) == utf8("original_data"))
    }
}
