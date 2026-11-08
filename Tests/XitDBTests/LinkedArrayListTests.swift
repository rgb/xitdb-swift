import Testing

@testable import XitDB

// A port of `testSlice`, `testConcat` and `testInsertAndRemove` from the Zig original (`src/test.zig`, lines 958
// to 1312), which slice, concatenate, insert into and remove from linked array lists through the path API. Zig
// calls them from "low level api" (test.zig 2576-2599), once for each of the size and offset combinations
// listed there, on each of the memory, file and buffered-file databases. Here each of those calls is a test
// case: the tests take the storage kind and the sizes as their arguments, and the combinations are Zig's, in
// Zig's order. They are here rather than in `LowLevelAPITests`, whose header says so, because each combination
// is a test case of its own this way.
//
// The comments inside the tests are Zig's. Zig's `Ctx` structs with a `run` method are the trailing closures
// of `writePath` here, and its `values` array lists are Swift arrays. Zig's allocator arguments and
// `defer ... deinit` lines have no counterpart. Zig's `cursor.slot_ptr.slot.value` is `cursor.slotPointer.slot
// .value`.
//
// Nothing in lines 958 to 1312 is left out.

/// Zig's `testSlice`, `testConcat` and `testInsertAndRemove`.
@Suite struct LinkedArrayListTests {
    /// The storage kinds of the three databases Zig runs the tests for.
    static let storageKinds: [StorageKind] = [.memory, .file, .bufferedFile]

    /// Zig's `xitdb.SLOT_COUNT`.
    static let slotCount: UInt64 = Trie.slotsPerBlock

    /// The arguments of one call of `testSlice`.
    struct SliceCase: Sendable, CustomTestStringConvertible {
        let originalSize: UInt64
        let sliceOffset: UInt64
        let sliceSize: UInt64

        var testDescription: String { "size \(originalSize), slice \(sliceOffset)..+\(sliceSize)" }
    }

    /// The arguments of one call of `testConcat`.
    struct ConcatCase: Sendable, CustomTestStringConvertible {
        let listASize: UInt64
        let listBSize: UInt64

        var testDescription: String { "sizes \(listASize) and \(listBSize)" }
    }

    /// The arguments of one call of `testInsertAndRemove`.
    struct InsertCase: Sendable, CustomTestStringConvertible {
        let originalSize: UInt64
        let insertIndex: UInt64

        var testDescription: String { "size \(originalSize), insert at \(insertIndex)" }
    }

    /// test.zig 2577-2585: the calls of `testSlice`.
    static let sliceCases: [SliceCase] = [
        SliceCase(originalSize: slotCount * 5 + 1, sliceOffset: 10, sliceSize: 5),
        SliceCase(originalSize: slotCount * 5 + 1, sliceOffset: 0, sliceSize: slotCount * 2),
        SliceCase(originalSize: slotCount * 5, sliceOffset: slotCount * 3, sliceSize: slotCount),
        SliceCase(originalSize: slotCount * 5, sliceOffset: slotCount * 3, sliceSize: slotCount * 2),
        SliceCase(originalSize: slotCount * 2, sliceOffset: 10, sliceSize: slotCount),
        SliceCase(originalSize: 2, sliceOffset: 0, sliceSize: 2),
        SliceCase(originalSize: 2, sliceOffset: 1, sliceSize: 1),
        SliceCase(originalSize: 1, sliceOffset: 0, sliceSize: 0),
    ]

    /// test.zig 2587-2591: the calls of `testConcat`.
    static let concatCases: [ConcatCase] = [
        ConcatCase(listASize: slotCount * 5 + 1, listBSize: slotCount + 1),
        ConcatCase(listASize: slotCount, listBSize: slotCount),
        ConcatCase(listASize: 1, listBSize: 1),
        ConcatCase(listASize: 0, listBSize: 0),
    ]

    /// test.zig 2593-2598: the calls of `testInsertAndRemove`.
    static let insertCases: [InsertCase] = [
        InsertCase(originalSize: 1, insertIndex: 0),
        InsertCase(originalSize: 10, insertIndex: 0),
        InsertCase(originalSize: 10, insertIndex: 5),
        InsertCase(originalSize: 10, insertIndex: 9),
        InsertCase(originalSize: slotCount * 5, insertIndex: slotCount * 2),
    ]

    /// Zig's `hashInt(text)`: the SHA-1 of the text.
    private func hashInt(_ text: String) -> KeyHash {
        sha1(text)
    }

    /// test.zig 958-1062: `testSlice`.
    @Test(arguments: storageKinds, sliceCases)
    func slice(kind: StorageKind, testCase: SliceCase) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)
        let rootCursor = database.rootCursor

        let originalSize = testCase.originalSize
        let sliceOffset = testCase.sliceOffset
        let sliceSize = testCase.sliceSize

        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .hashMapInit(),
            .ctx,
        ]) { (cursor: inout Cursor<ReadWrite>) in
            var values: [UInt64] = []

            // create list
            for i in 0..<originalSize {
                let n = i * 2
                values.append(n)
                _ = try cursor.writePath([
                    .hashMapGet(.value, hashInt("even")),
                    .linkedArrayListInit,
                    .linkedArrayListAppend,
                    .write(.uint(n)),
                ])
            }

            // slice list
            let evenListCursor = try #require(
                try cursor.readPath([
                    .hashMapGet(.value, hashInt("even"))
                ])
            )
            let evenListSliceCursor = try cursor.writePath([
                .hashMapGet(.value, hashInt("even-slice")),
                .write(.slot(evenListCursor.slotPointer.slot)),
                .linkedArrayListInit,
                .linkedArrayListSlice(offset: sliceOffset, size: sliceSize),
            ])

            // check all values in the new slice
            for (i, val) in values[Int(sliceOffset)..<Int(sliceOffset + sliceSize)].enumerated() {
                let n = try #require(
                    try cursor.readPath([
                        .hashMapGet(.value, hashInt("even-slice")),
                        .linkedArrayListGet(Int64(i)),
                    ])
                ).slotPointer.slot.value
                #expect(val == n)
            }

            // check all values in the new slice with an iterator
            do {
                var iter = try evenListSliceCursor.iterator()
                var i: UInt64 = 0
                while let numCursor = try iter.next() {
                    #expect(values[Int(sliceOffset + i)] == (try numCursor.readUInt64()))
                    i += 1
                }
                #expect(sliceSize == i)
            }

            // there are no extra items
            #expect(
                try cursor.readPath([
                    .hashMapGet(.value, hashInt("even-slice")),
                    .linkedArrayListGet(Int64(sliceSize)),
                ]) == nil
            )

            // concat the slice with itself
            _ = try cursor.writePath([
                .hashMapGet(.value, hashInt("combo")),
                .write(.slot(evenListSliceCursor.slotPointer.slot)),
                .linkedArrayListInit,
                .linkedArrayListConcat(evenListSliceCursor.slotPointer.slot),
            ])

            // the concat froze the transaction: the callback's cursor goes on
            // through the map's init, and what follows reads and writes
            // through the cursor that gives (D18); Zig's test goes on through
            // the cursor as it is
            let cursor = try cursor.writePath([.hashMapInit()])

            // check all values in the combo list
            var comboValues: [UInt64] = []
            comboValues.append(contentsOf: values[Int(sliceOffset)..<Int(sliceOffset + sliceSize)])
            comboValues.append(contentsOf: values[Int(sliceOffset)..<Int(sliceOffset + sliceSize)])
            for (i, val) in comboValues.enumerated() {
                let n = try #require(
                    try cursor.readPath([
                        .hashMapGet(.value, hashInt("combo")),
                        .linkedArrayListGet(Int64(i)),
                    ])
                ).slotPointer.slot.value
                #expect(val == n)
            }

            // append to the slice
            _ = try cursor.writePath([
                .hashMapGet(.value, hashInt("even-slice")),
                .linkedArrayListInit,
                .linkedArrayListAppend,
                .write(.uint(3)),
            ])

            // read the new value from the slice
            #expect(
                try #require(
                    try cursor.readPath([
                        .hashMapGet(.value, hashInt("even-slice")),
                        .linkedArrayListGet(-1),
                    ])
                ).slotPointer.slot.value == 3
            )
        }
    }

    /// test.zig 1064-1179: `testConcat`.
    @Test(arguments: storageKinds, concatCases)
    func concat(kind: StorageKind, testCase: ConcatCase) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)
        let rootCursor = database.rootCursor

        let listASize = testCase.listASize
        let listBSize = testCase.listBSize

        var values: [UInt64] = []

        do {
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .ctx,
            ]) { (cursor: inout Cursor<ReadWrite>) in
                // create even list
                _ = try cursor.writePath([
                    .hashMapGet(.value, hashInt("even")),
                    .linkedArrayListInit,
                ])
                for i in 0..<listASize {
                    let n = i * 2
                    values.append(n)
                    _ = try cursor.writePath([
                        .hashMapGet(.value, hashInt("even")),
                        .linkedArrayListInit,
                        .linkedArrayListAppend,
                        .write(.uint(n)),
                    ])
                }

                // create odd list
                _ = try cursor.writePath([
                    .hashMapGet(.value, hashInt("odd")),
                    .linkedArrayListInit,
                ])
                for i in 0..<listBSize {
                    let n = (i * 2) + 1
                    values.append(n)
                    _ = try cursor.writePath([
                        .hashMapGet(.value, hashInt("odd")),
                        .linkedArrayListInit,
                        .linkedArrayListAppend,
                        .write(.uint(n)),
                    ])
                }
            }
        }

        do {
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .ctx,
            ]) { (cursor: inout Cursor<ReadWrite>) in
                // get even list
                let evenListCursor = try #require(
                    try cursor.readPath([
                        .hashMapGet(.value, hashInt("even"))
                    ])
                )

                // get odd list
                let oddListCursor = try #require(
                    try cursor.readPath([
                        .hashMapGet(.value, hashInt("odd"))
                    ])
                )

                // concat the lists
                let comboListCursor = try cursor.writePath([
                    .hashMapGet(.value, hashInt("combo")),
                    .write(.slot(evenListCursor.slotPointer.slot)),
                    .linkedArrayListInit,
                    .linkedArrayListConcat(oddListCursor.slotPointer.slot),
                ])

                // check all values in the new list
                for (i, val) in values.enumerated() {
                    let n = try #require(
                        try cursor.readPath([
                            .hashMapGet(.value, hashInt("combo")),
                            .linkedArrayListGet(Int64(i)),
                        ])
                    ).slotPointer.slot.value
                    #expect(val == n)
                }

                // check all values in the new list with an iterator
                do {
                    var iter = try comboListCursor.iterator()
                    var i: UInt64 = 0
                    while let numCursor = try iter.next() {
                        #expect(values[Int(i)] == (try numCursor.readUInt64()))
                        i += 1
                    }
                    #expect(try evenListCursor.count + oddListCursor.count == i)
                }

                // there are no extra items
                #expect(
                    try cursor.readPath([
                        .hashMapGet(.value, hashInt("combo")),
                        .linkedArrayListGet(Int64(values.count)),
                    ]) == nil
                )
            }
        }
    }

    /// test.zig 1181-1311: `testInsertAndRemove`.
    @Test(arguments: storageKinds, insertCases)
    func insertAndRemove(kind: StorageKind, testCase: InsertCase) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)
        let rootCursor = database.rootCursor

        let originalSize = testCase.originalSize
        let insertIndex = testCase.insertIndex

        let insertValue: UInt64 = 12345

        // Zig's `InsertCtx`
        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .hashMapInit(),
            .ctx,
        ]) { (cursor: inout Cursor<ReadWrite>) in
            var values: [UInt64] = []

            // create list
            for i in 0..<originalSize {
                if i == insertIndex {
                    values.append(insertValue)
                }
                let n = i * 2
                values.append(n)
                _ = try cursor.writePath([
                    .hashMapGet(.value, hashInt("even")),
                    .linkedArrayListInit,
                    .linkedArrayListAppend,
                    .write(.uint(n)),
                ])
            }

            // insert into list
            let evenListCursor = try #require(
                try cursor.readPath([
                    .hashMapGet(.value, hashInt("even"))
                ])
            )
            let evenListInsertCursor = try cursor.writePath([
                .hashMapGet(.value, hashInt("even-insert")),
                .write(.slot(evenListCursor.slotPointer.slot)),
                .linkedArrayListInit,
            ])
            _ = try evenListInsertCursor.writePath([
                .linkedArrayListInsert(Int64(insertIndex)),
                .write(.uint(insertValue)),
            ])

            // check all values in the new list
            for (i, val) in values.enumerated() {
                let n = try #require(
                    try cursor.readPath([
                        .hashMapGet(.value, hashInt("even-insert")),
                        .linkedArrayListGet(Int64(i)),
                    ])
                ).slotPointer.slot.value
                #expect(val == n)
            }

            // check all values in the new list with an iterator
            do {
                var iter = try evenListInsertCursor.iterator()
                var i: UInt64 = 0
                while let numCursor = try iter.next() {
                    #expect(values[Int(i)] == (try numCursor.readUInt64()))
                    i += 1
                }
                #expect(UInt64(values.count) == i)
            }

            // there are no extra items
            #expect(
                try cursor.readPath([
                    .hashMapGet(.value, hashInt("even-insert")),
                    .linkedArrayListGet(Int64(values.count)),
                ]) == nil
            )
        }

        // Zig's `RemoveCtx`
        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .hashMapInit(),
            .ctx,
        ]) { (cursor: inout Cursor<ReadWrite>) in
            var values: [UInt64] = []

            for i in 0..<originalSize {
                let n = i * 2
                values.append(n)
            }

            // remove inserted value from the list. Zig writes the committed
            // header in place here (finding 13); the port refuses that as
            // immutableBytes, so the init part copies it first (D24).
            let evenListInsertCursor = try cursor.writePath([
                .hashMapGet(.value, hashInt("even-insert")),
                .linkedArrayListInit,
                .linkedArrayListRemove(Int64(insertIndex)),
            ])

            // check all values in the new list
            for (i, val) in values.enumerated() {
                let n = try #require(
                    try cursor.readPath([
                        .hashMapGet(.value, hashInt("even-insert")),
                        .linkedArrayListGet(Int64(i)),
                    ])
                ).slotPointer.slot.value
                #expect(val == n)
            }

            // check all values in the new list with an iterator
            do {
                var iter = try evenListInsertCursor.iterator()
                var i: UInt64 = 0
                while let numCursor = try iter.next() {
                    #expect(values[Int(i)] == (try numCursor.readUInt64()))
                    i += 1
                }
                #expect(UInt64(values.count) == i)
            }

            // there are no extra items
            #expect(
                try cursor.readPath([
                    .hashMapGet(.value, hashInt("even-insert")),
                    .linkedArrayListGet(Int64(values.count)),
                ]) == nil
            )
        }
    }
}
