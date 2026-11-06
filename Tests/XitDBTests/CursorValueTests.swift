import Testing

@testable import XitDB

/// Reading and writing values through cursors: the parts of the cursor's
/// public surface that the conformance scripts cannot reach, such as reading
/// into a caller's buffer, and the edges of the ones they can.
@Suite struct CursorValueTests {
    /// A database with one hash map at the root, and a way to run a
    /// transaction on it.
    private func makeDatabase(_ storage: any WritableStorage = MemoryStorage()) throws -> Database {
        let database = try Database(
            storage: storage, hashSize: 20, hashID: nil, fileID: 7, random: FixedRandom((1...200).map { UInt64($0) }))
        _ = try database.rootCursor().writePath([.hashMapInit()])
        return database
    }

    /// Writes `data` under a key in the root map, in a transaction.
    private func put(_ database: Database, _ key: String, _ data: WriteableData) throws {
        try database.runContext { cursor in
            _ = try cursor.writePath([.hashMapGet(.value, sha1(key)), .write(data)])
        }
    }

    private func get(_ database: Database, _ key: String) throws -> Cursor<ReadOnly> {
        try #require(try database.rootCursor().readPath([.hashMapGet(.value, sha1(key))]))
    }

    // MARK: Numbers

    @Test func numbersReadBackBitForBit() throws {
        let database = try makeDatabase()
        try put(database, "uint", .uint(.max))
        try put(database, "int", .int(.min))
        try put(database, "minus", .int(-1))
        try put(database, "float", .float(-0.0))
        let nan = Double(bitPattern: 0x7FF8_0000_0000_1234)
        try put(database, "nan", .float(nan))

        #expect(try get(database, "uint").readUint() == .max)
        #expect(try get(database, "int").readInt() == .min)
        #expect(try get(database, "minus").readInt() == -1)
        #expect(try get(database, "float").readFloat().bitPattern == (-0.0).bitPattern)
        #expect(try get(database, "nan").readFloat().bitPattern == 0x7FF8_0000_0000_1234)
        #expect(try get(database, "minus").slot() == Slot(value: .max, tag: .int))
    }

    @Test func readingTheWrongKindIsUnexpectedTag() throws {
        let database = try makeDatabase()
        try put(database, "uint", .uint(1))
        try put(database, "bytes", .bytes([1, 2, 3]))
        let uint = try get(database, "uint")
        let bytes = try get(database, "bytes")

        #expect(throws: XitDBError.unexpectedTag) { try uint.readInt() }
        #expect(throws: XitDBError.unexpectedTag) { try uint.readFloat() }
        #expect(throws: XitDBError.unexpectedTag) { try bytes.readUint() }
        #expect(throws: XitDBError.unexpectedTag) { try uint.readBytesAlloc() }
        #expect(throws: XitDBError.unexpectedTag) { try uint.readBytesObjectAlloc() }
        #expect(throws: XitDBError.unexpectedTag) { try uint.readKeyValuePair() }
        #expect(throws: XitDBError.unexpectedTag) { try uint.count() }
        var buffer = [UInt8](repeating: 0, count: 8)
        #expect(throws: XitDBError.unexpectedTag) {
            var span = buffer.mutableSpan
            return try uint.readBytes(into: &span)
        }
        #expect(throws: XitDBError.unexpectedTag) { try database.rootCursor().readUint() }
        #expect(throws: XitDBError.unexpectedTag) { try database.rootCursor().count() }
    }

    // MARK: Bytes

    static let longValue: [UInt8] = (0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) }

    @Test func bytesAreStoredInTheSlotWhenTheyFit() throws {
        let database = try makeDatabase()
        try put(database, "short", .bytes(Array("12345678".utf8)))
        try put(database, "long", .bytes(Array("123456789".utf8)))
        try put(database, "zero", .bytes([1, 0, 2]))
        try put(database, "empty", .bytes([]))
        try put(database, "tagged", .bytesObject(Bytes(Array("123456".utf8), formatTag: [0x62, 0x69])))
        try put(database, "tagged7", .bytesObject(Bytes(Array("1234567".utf8), formatTag: [0x62, 0x69])))

        #expect(try get(database, "short").slot().tag == .shortBytes)
        #expect(try get(database, "long").slot().tag == .bytes)
        #expect(try get(database, "zero").slot().tag == .bytes)
        #expect(try get(database, "empty").slot() == Slot(value: 0, tag: .shortBytes))
        #expect(try get(database, "tagged").slot().tag == .shortBytes)
        #expect(try get(database, "tagged").slot().full)
        #expect(try get(database, "tagged7").slot().tag == .bytes)
        #expect(try get(database, "tagged7").slot().full)

        #expect(try get(database, "short").readBytesAlloc() == Array("12345678".utf8))
        #expect(try get(database, "long").readBytesAlloc() == Array("123456789".utf8))
        #expect(try get(database, "zero").readBytesAlloc() == [1, 0, 2])
        #expect(try get(database, "empty").readBytesAlloc() == [])
        #expect(
            try get(database, "tagged").readBytesObjectAlloc() == Bytes(Array("123456".utf8), formatTag: [0x62, 0x69]))
        #expect(
            try get(database, "tagged7").readBytesObjectAlloc()
                == Bytes(Array("1234567".utf8), formatTag: [0x62, 0x69]))
        #expect(try get(database, "long").readBytesObjectAlloc().formatTag == nil)

        #expect(try get(database, "short").count() == 8)
        #expect(try get(database, "long").count() == 9)
        #expect(try get(database, "empty").count() == 0)
        #expect(try get(database, "tagged").count() == 6)
        #expect(try get(database, "tagged7").count() == 7)
    }

    @Test func bytesIsShortAgreesWithWhereTheValueGoes() {
        #expect(Bytes(Array("12345678".utf8)).isShort)
        #expect(!Bytes(Array("123456789".utf8)).isShort)
        #expect(!Bytes([1, 0]).isShort)
        #expect(Bytes([]).isShort)
        #expect(Bytes(Array("123456".utf8), formatTag: [0, 0]).isShort)
        #expect(!Bytes(Array("1234567".utf8), formatTag: [0, 0]).isShort)
        #expect(Bytes([1], formatTag: [1, 2]) != Bytes([1]))
        #expect(Bytes([1], formatTag: [1, 2]) != Bytes([1], formatTag: [1, 3]))
        #expect(Bytes([1], formatTag: [1, 2]) == Bytes([1], formatTag: [1, 2]))
    }

    @Test func aMaximumSizeIsEnforcedBeforeReading() throws {
        let database = try makeDatabase()
        try put(database, "long", .bytes(Self.longValue))
        try put(database, "short", .bytes([1, 2, 3]))
        let long = try get(database, "long")
        let short = try get(database, "short")

        #expect(try long.readBytesAlloc(maxSize: 3000) == Self.longValue)
        #expect(throws: XitDBError.streamTooLong) { try long.readBytesAlloc(maxSize: 2999) }
        #expect(throws: XitDBError.streamTooLong) { try long.readBytesAlloc(maxSize: 0) }
        #expect(try short.readBytesAlloc(maxSize: 3) == [1, 2, 3])
        #expect(throws: XitDBError.streamTooLong) { try short.readBytesAlloc(maxSize: 2) }
        #expect(throws: XitDBError.streamTooLong) { try short.readBytesObjectAlloc(maxSize: 0) }
    }

    @Test func readingIntoABufferLeavesTheRestOfItAlone() throws {
        let database = try makeDatabase()
        try put(database, "long", .bytesObject(Bytes(Self.longValue, formatTag: [0x74, 0x67])))
        try put(database, "short", .bytes([1, 2, 3]))
        try put(database, "tagged", .bytesObject(Bytes([4, 5], formatTag: [0x62, 0x69])))

        // a buffer larger than the value
        var large = [UInt8](repeating: 0xEE, count: 5000)
        var largeSpan = large.mutableSpan
        let long = try get(database, "long").readBytesObject(into: &largeSpan)
        #expect(long.count == 3000)
        #expect(long.formatTag.map { array($0) } == [0x74, 0x67])
        #expect(Array(large[..<3000]) == Self.longValue)
        #expect(large[3000...].allSatisfy { $0 == 0xEE })

        // a buffer of exactly the value's size
        var exact = [UInt8](repeating: 0xEE, count: 3000)
        var exactSpan = exact.mutableSpan
        #expect(try get(database, "long").readBytes(into: &exactSpan) == 3000)
        #expect(exact == Self.longValue)

        // a buffer too small
        var small = [UInt8](repeating: 0xEE, count: 2999)
        #expect(throws: XitDBError.streamTooLong) {
            var span = small.mutableSpan
            return try get(database, "long").readBytes(into: &span)
        }
        #expect(small.allSatisfy { $0 == 0xEE })

        // short values
        var eight = [UInt8](repeating: 0xEE, count: 8)
        var eightSpan = eight.mutableSpan
        #expect(try get(database, "short").readBytes(into: &eightSpan) == 3)
        #expect(eight == [1, 2, 3, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE])
        var eightAgain = [UInt8](repeating: 0xEE, count: 8)
        var eightAgainSpan = eightAgain.mutableSpan
        let tagged = try get(database, "tagged").readBytesObject(into: &eightAgainSpan)
        #expect(tagged.count == 2)
        #expect(tagged.formatTag.map { array($0) } == [0x62, 0x69])
        var two = [UInt8](repeating: 0xEE, count: 2)
        #expect(throws: XitDBError.streamTooLong) {
            var span = two.mutableSpan
            return try get(database, "short").readBytes(into: &span)
        }
        // a short value that fills the buffer exactly
        var three = [UInt8](repeating: 0xEE, count: 3)
        var threeSpan = three.mutableSpan
        #expect(try get(database, "short").readBytes(into: &threeSpan) == 3)
        #expect(three == [1, 2, 3])
    }

    /// A value read into a larger buffer takes one read of the storage for
    /// its length and one for its bytes, whatever its size.
    @Test func readingAValueIntoALargerBufferIsOneRead() throws {
        let counting = FaultInjectingStorage(MemoryStorage())
        let database = try makeDatabase(counting)
        try put(database, "long", .bytes(Self.longValue))
        let cursor = try get(database, "long")

        var buffer = [UInt8](repeating: 0xEE, count: 100_000)
        var span = buffer.mutableSpan
        let before = counting.readCount
        #expect(try cursor.readBytes(into: &span) == 3000)
        #expect(counting.readCount - before == 2)
        #expect(Array(buffer[..<3000]) == Self.longValue)
    }

    /// A slot set to nothing reads as no bytes, into a buffer too. Zig's
    /// read into a buffer reports the end of the stream there, while its
    /// allocating read gives no bytes; the port gives no bytes in both
    /// (finding 8 of the director's list of Zig behaviours to correct).
    @Test func anEmptySlotReadsAsNoBytes() throws {
        let database = try makeDatabase()
        try put(database, "none", .slot(nil))
        let none = try get(database, "none")
        #expect(try none.slot() == Slot(tag: .none, full: true))
        #expect(try none.readBytesAlloc() == [])
        #expect(try none.readBytesObjectAlloc() == Bytes([]))
        #expect(try none.count() == 0)

        var buffer = [UInt8](repeating: 0xEE, count: 4)
        var span = buffer.mutableSpan
        let read = try none.readBytesObject(into: &span)
        #expect(read.count == 0)
        #expect(read.formatTag == nil)
        #expect(buffer == [0xEE, 0xEE, 0xEE, 0xEE])
        var empty: [UInt8] = []
        var emptySpan = empty.mutableSpan
        #expect(try none.readBytes(into: &emptySpan) == 0)
    }

    // MARK: The byte writer

    /// A streaming reader has a position that reads move and seeks set,
    /// and the read of the rest has a size limit like the whole-value reads.
    @Test func aReaderHasAPositionAndALimit() throws {
        let database = try makeDatabase()
        try put(database, "short", .bytes(Array("123".utf8)))
        try put(database, "long", .bytes(Array("a value too long for a slot".utf8)))
        for name in ["short", "long"] {
            var reader = try get(database, name).reader()
            let value = try get(database, name).readBytesAlloc()
            #expect(reader.size == UInt64(value.count))
            #expect(reader.position == 0)
            #expect(throws: XitDBError.streamTooLong) { try reader.readRemaining(maxSize: value.count - 1) }
            #expect(reader.position == 0, "a refused read moves nothing")
            #expect(try reader.readRemaining(maxSize: value.count) == value)
            #expect(reader.position == UInt64(value.count))
            #expect(try reader.readRemaining(maxSize: 0) == [], "at the end there is nothing to refuse")
            reader.seek(to: 1)
            #expect(try reader.readRemaining() == Array(value[1...]))
            reader.seek(to: .max)
            #expect(reader.position == .max)
            #expect(try reader.readRemaining() == [])
            var one = [UInt8](repeating: 0xEE, count: 1)
            var span = one.mutableSpan
            #expect(try reader.read(into: &span) == 0)
            #expect(throws: XitDBError.endOfStream) { try reader.readAll(into: &span) }
            #expect(one == [0xEE])
        }
    }

    @Test func theWriterAlwaysMakesARecordAndCanSeek() throws {
        let database = try makeDatabase()
        try database.runContext { cursor in
            var short = try cursor.writePath([.hashMapGet(.value, sha1("short"))])
            try short.writer { writer in try writer.write([1, 2, 3]) }
            #expect(try short.slot().tag == .bytes)
            #expect(try short.readBytesAlloc() == [1, 2, 3])

            var empty = try cursor.writePath([.hashMapGet(.value, sha1("empty"))])
            try empty.writer { _ in }
            #expect(try empty.slot().tag == .bytes)
            #expect(try empty.readBytesAlloc() == [])
            #expect(try empty.count() == 0)

            // Zig's test: three bytes, then each overwritten after a seek
            var seek = try cursor.writePath([.hashMapGet(.value, sha1("seek"))])
            try seek.writer { writer in
                try writer.write(Array("x".utf8))
                try writer.write(Array("x".utf8))
                try writer.write(Array("x".utf8))
                writer.seek(to: 0)
                try writer.write(Array("b".utf8))
                writer.seek(to: 2)
                try writer.write(Array("z".utf8))
                writer.seek(to: 1)
                try writer.write(Array("a".utf8))
            }
            #expect(try seek.readBytesAlloc() == Array("baz".utf8))

            // a seek past the end leaves zeros in between
            var gap = try cursor.writePath([.hashMapGet(.value, sha1("gap"))])
            try gap.writer(formatTag: [0x67, 0x70]) { writer in
                try writer.write([1])
                writer.seek(to: 4)
                try writer.write([5, 6].span)
            }
            #expect(try gap.readBytesObjectAlloc() == Bytes([1, 0, 0, 0, 5, 6], formatTag: [0x67, 0x70]))
            #expect(try gap.slot().full)

            // the tag can also be set by the body
            var tagged = try cursor.writePath([.hashMapGet(.value, sha1("tagged"))])
            try tagged.writer { writer in
                try writer.write([9])
                writer.formatTag = [0x74, 0x67]
                #expect(writer.formatTag.map { array($0) } == [0x74, 0x67])
            }
            #expect(try tagged.readBytesObjectAlloc() == Bytes([9], formatTag: [0x74, 0x67]))
        }
        #expect(try get(database, "seek").readBytesAlloc() == Array("baz".utf8))
        #expect(try get(database, "gap").readBytesAlloc() == [1, 0, 0, 0, 5, 6])
    }

    @Test func aWriterWhoseBodyThrowsLeavesTheSlotAsItWas() throws {
        struct Cancel: Error {}
        let database = try makeDatabase()
        try database.runContext { cursor in
            var value = try cursor.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(1))])
            #expect(throws: Cancel.self) {
                try value.writer { writer in
                    try writer.write([1, 2, 3])
                    throw Cancel()
                }
            }
            #expect(try value.readUint() == 1)
        }
        #expect(try get(database, "a").readUint() == 1)
    }

    @Test func theWriterNeedsATransactionAndASlotBelowTheRoot() throws {
        let database = try makeDatabase()
        var root = database.rootCursor()
        #expect(throws: XitDBError.cursorNotWriteable) { try root.writer { _ in } }

        var kept: Cursor<ReadWrite>?
        try database.runContext { cursor in
            kept = try cursor.writePath([.hashMapGet(.value, sha1("a"))])
            var inner = database.rootCursor()
            #expect(throws: XitDBError.cursorNotWriteable) { try inner.writer { _ in } }
        }
        var outside = try #require(kept)
        #expect(throws: XitDBError.expectedTxStart) { try outside.writer { _ in } }
        #expect(throws: XitDBError.expectedTxStart) { try outside.write(.uint(1)) }
        #expect(throws: XitDBError.expectedTxStart) { try outside.freeze() }
        #expect(throws: XitDBError.expectedTxStart) { try database.freeze() }
    }

    /// A byte array can only grow while it is the last thing in the file.
    @Test func aWriterCannotGrowOnceSomethingElseWasWritten() throws {
        let database = try makeDatabase()
        try database.runContext { cursor in
            var value = try cursor.writePath([.hashMapGet(.value, sha1("a"))])
            var other = try cursor.writePath([.hashMapGet(.value, sha1("b"))])
            #expect(throws: XitDBError.unexpectedWriterPosition) {
                try value.writer { writer in
                    try writer.write([1, 2, 3])
                    try other.write(.bytes(Self.longValue))
                    // rewriting what is there is fine
                    writer.seek(to: 0)
                    try writer.write([9])
                    // growing is not
                    writer.seek(to: 3)
                    try writer.write([4])
                }
            }
            // with a format tag the end is checked when finishing too
            #expect(throws: XitDBError.unexpectedWriterPosition) {
                try value.writer(formatTag: [1, 2]) { writer in
                    try writer.write([1, 2, 3])
                    try other.write(.bytes(Self.longValue))
                }
            }
        }
    }

    // MARK: Cursors

    @Test func writeIfEmptyGoesByTheSnapshot() throws {
        let database = try makeDatabase()
        try database.runContext { cursor in
            var first = try cursor.writePath([.hashMapGet(.value, sha1("a"))])
            var stale = first
            try first.writeIfEmpty(.uint(1))
            try first.writeIfEmpty(.uint(2))
            #expect(try first.readUint() == 1)

            // the stale copy still thinks the slot is empty, and overwrites
            #expect(try stale.slot().isEmpty)
            try stale.writeIfEmpty(.uint(3))
            #expect(try stale.readUint() == 3)
            #expect(try first.readUint() == 1)
        }
        #expect(try get(database, "a").readUint() == 3)
    }

    @Test func aReadOnlyCopyReadsTheSameSlot() throws {
        let database = try makeDatabase()
        try put(database, "a", .uint(5))
        try database.runContext { cursor in
            let value = try cursor.writePath([.hashMapGet(.value, sha1("a"))])
            let readOnly = value.readOnly()
            #expect(try readOnly.readUint() == 5)
            #expect(try readOnly.slot() == (try value.slot()))
        }
        // a read-only copy of a root cursor still follows the root
        let root = database.rootCursor().readOnly()
        let before = try root.slot()
        try put(database, "b", .uint(6))
        #expect(try root.slot() != before)
    }

    @Test func aKeyValuePairGivesItsKeyValueAndHash() throws {
        let database = try makeDatabase()
        try database.runContext { cursor in
            _ = try cursor.writePath([.hashMapGet(.key, sha1("k")), .write(.bytes(Array("k".utf8)))])
            _ = try cursor.writePath([.hashMapGet(.value, sha1("k")), .write(.uint(9))])
        }
        let entry = try #require(try database.rootCursor().readPath([.hashMapGet(.kvPair, sha1("k"))]))
        #expect(try entry.slot().tag == .kvPair)
        let pair = try entry.readKeyValuePair()
        #expect(pair.hash == sha1("k").bytes)
        #expect(try pair.keyCursor.readBytesAlloc() == Array("k".utf8))
        #expect(try pair.valueCursor.readUint() == 9)

        // through a read-write cursor the two cursors can be written
        try database.runContext { cursor in
            let entry = try cursor.writePath([.hashMapGet(.kvPair, sha1("k"))])
            var pair = try entry.readKeyValuePair()
            try pair.valueCursor.write(.uint(10))
        }
        #expect(try get(database, "k").readUint() == 10)
    }

    @Test func countReadsHeadersOnly() throws {
        let database = try makeDatabase()
        try database.runContext { cursor in
            _ = try cursor.writePath([.hashMapGet(.value, sha1("list")), .arrayListInit, .arrayListAppend])
            _ = try cursor.writePath([.hashMapGet(.value, sha1("list")), .arrayListAppend])
            _ = try cursor.writePath([
                .hashMapGet(.value, sha1("counted")), .hashMapInit(counted: true),
                .hashMapGet(.value, sha1("x")), .write(.uint(1)),
            ])
            _ = try cursor.writePath([
                .hashMapGet(.value, sha1("countedSet")), .hashMapInit(counted: true, set: true),
                .hashMapGet(.key, sha1("x")), .write(.uint(1)),
            ])
            _ = try cursor.writePath([.hashMapGet(.value, sha1("plain")), .hashMapInit()])
            _ = try cursor.writePath([.hashMapGet(.value, sha1("set")), .hashMapInit(set: true)])
        }
        #expect(try get(database, "list").count() == 2)
        #expect(try get(database, "counted").count() == 1)
        #expect(try get(database, "countedSet").count() == 1)
        #expect(throws: XitDBError.unexpectedTag) { try get(database, "plain").count() }
        #expect(throws: XitDBError.unexpectedTag) { try get(database, "set").count() }
        #expect(try database.rootCursor().readPath([.hashMapGet(.value, sha1("missing"))]) == nil)
    }
}

/// The ranged read of the storage protocol, on every storage.
@Suite struct StorageRangedReadTests {
    /// Reads into `range` of a buffer of `size` bytes that all hold 0xEE.
    private func read(
        _ storage: any WritableStorage,
        size: Int,
        range: Range<Int>,
        at offset: UInt64
    ) throws -> (count: Int, buffer: [UInt8]) {
        var buffer = [UInt8](repeating: 0xEE, count: size)
        var span = buffer.mutableSpan
        let count = try storage.read(into: &span, range: range, at: offset)
        return (count, buffer)
    }

    @Test(arguments: StorageKind.allCases)
    func aRangedReadFillsOnlyItsRange(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let storage = subject.storage
        try writeBytes(storage, (0..<50).map { UInt8($0) }, at: 0)
        let untouched = { (count: Int) in [UInt8](repeating: 0xEE, count: count) }

        let middle = try read(storage, size: 20, range: 5..<12, at: 10)
        #expect(middle.count == 7)
        #expect(middle.buffer == untouched(5) + [10, 11, 12, 13, 14, 15, 16] + untouched(8))

        // short at the end of the storage, and nothing beyond it
        let tail = try read(storage, size: 20, range: 2..<20, at: 45)
        #expect(tail.count == 5)
        #expect(tail.buffer == untouched(2) + [45, 46, 47, 48, 49] + untouched(13))
        let beyond = try read(storage, size: 20, range: 0..<20, at: 50)
        #expect(beyond.count == 0)
        #expect(beyond.buffer == untouched(20))
        #expect(try read(storage, size: 20, range: 7..<7, at: 0).count == 0)
        #expect(try read(storage, size: 20, range: 20..<20, at: 0).count == 0)

        // after a flush the same read gives the same bytes
        try storage.flush()
        let again = try read(storage, size: 20, range: 5..<12, at: 10)
        #expect(again.count == 7)
        #expect(again.buffer == middle.buffer)
    }

    /// A ranged read across the file, a gap and the window of a buffered
    /// file.
    @Test func aRangedReadCrossesTheBufferedWindow() throws {
        let directory = try TemporaryDirectory()
        let storage = try BufferedFileStorage(path: directory.path(), durability: .none, bufferLimit: 16)
        try writeBytes(storage, [1, 2, 3], at: 0)
        try writeBytes(storage, [7, 8], at: 6)
        #expect(try directory.contents() == [1, 2, 3])

        let whole = try read(storage, size: 12, range: 3..<11, at: 0)
        #expect(whole.count == 8)
        #expect(whole.buffer == [0xEE, 0xEE, 0xEE, 1, 2, 3, 0, 0, 0, 7, 8, 0xEE])

        let partial = try read(storage, size: 12, range: 1..<5, at: 4)
        #expect(partial.count == 4)
        #expect(partial.buffer == [0xEE, 0, 0, 7, 8, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE])
    }
}
