import Testing
import XitDB

@Suite("Cursors and values") struct CursorsAndValuesExamples {
    private func newMoment(_ body: (HashMap<ReadWrite>) throws -> Void) throws -> HashMap<ReadOnly> {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(nil)) { cursor in
            try body(try HashMap<ReadWrite>(cursor))
        }
        return try HashMap<ReadOnly>(history.cursor(at: -1)!)
    }

    @Test func theValueTypes() throws {
        let moment = try newMoment { moment in
            try moment.put(.uint(42), forHash: sha256("unsigned"))
            try moment.put(.int(-42), forHash: sha256("signed"))
            try moment.put(.double(2.5), forHash: sha256("double"))
            try moment.put(.bytes(Array("hello".utf8)), forHash: sha256("short"))
            try moment.put(.bytes(Array("hello, world".utf8)), forHash: sha256("long"))
        }

        let unsigned = try moment.cursor(forHash: sha256("unsigned"))!.readUInt64()
        let signed = try moment.cursor(forHash: sha256("signed"))!.readInt64()
        let double = try moment.cursor(forHash: sha256("double"))!.readDouble()
        let long = try moment.cursor(forHash: sha256("long"))!.readBytes()
        #expect(unsigned == 42)
        #expect(signed == -42)
        #expect(double == 2.5)
        #expect(long == Array("hello, world".utf8))

        // A short value is held in its slot, a long one behind it.
        #expect(try moment.slot(forHash: sha256("short"))!.tag == .shortBytes)
        #expect(try moment.slot(forHash: sha256("long"))!.tag == .bytes)
        #expect(Bytes(Array("eightbyt".utf8)).isShort)
        #expect(!Bytes(Array("ninebytes".utf8)).isShort)
        #expect(!Bytes([1, 0, 2]).isShort)
        #expect(Bytes(Array("sixbyt".utf8), formatTag: "dt").isShort)
        #expect(!Bytes(Array("seven b".utf8), formatTag: "dt").isShort)

        // A number in a slot does not read as another kind of number.
        #expect(throws: XitDBError.unexpectedTag) {
            try moment.cursor(forHash: sha256("signed"))!.readUInt64()
        }
    }

    @Test func formatTags() throws {
        let moment = try newMoment { moment in
            // A date, stored as text, with a tag that says how to read it.
            let date = Array("2026-11-07T09:47:00Z".utf8)
            try moment.put(.bytes(date, formatTag: "dt"), forHash: sha256("created"))
        }

        let created = try moment.cursor(forHash: sha256("created"))!.readBytesWithFormatTag()
        #expect(created.formatTag == "dt")
        #expect(String(decoding: created.value, as: UTF8.self) == "2026-11-07T09:47:00Z")
    }

    @Test func readingWhateverIsThere() throws {
        let moment = try newMoment { moment in
            try moment.put(.uint(42), forHash: sha256("number"))
        }

        func describe(_ cursor: Cursor<ReadOnly>) throws -> String {
            switch try cursor.slot.tag {
            case .uint: "\(try cursor.readUInt64())"
            case .int: "\(try cursor.readInt64())"
            case .float: "\(try cursor.readDouble())"
            case .bytes, .shortBytes: String(decoding: try cursor.readBytes(), as: UTF8.self)
            case .none: "nothing"
            default: "a collection"
            }
        }
        #expect(try describe(moment.cursor(forHash: sha256("number"))!) == "42")
    }

    @Test func aCursorHoldsASnapshot() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let list = try ArrayList<ReadWrite>(database.rootCursor)
        try list.append(.uint(1))

        // A cursor below the root keeps what it saw.
        let element = try list.cursor(at: 0)!
        try list.put(.uint(2), at: 0)
        #expect(try element.readUInt64() == 1)
        #expect(try list.cursor(at: 0)!.readUInt64() == 2)

        // A cursor at the root reads the last commit every time.
        let root = database.rootCursor
        let countBefore = try root.count
        try list.append(.uint(3))
        #expect(countBefore == 1)
        #expect(try root.count == 2)
    }

    @Test func onlyTheSlotIsASnapshot() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        try database.withTransaction { cursor in
            let list = try ArrayList<ReadWrite>(cursor)
            try list.append(.uint(1))

            // The slot is the cursor's, but what it points at is read when asked
            // for, and this transaction changes its own list in place.
            let held = list.cursor
            let before = try held.count
            try list.append(.uint(2))
            #expect(before == 1)
            #expect(try held.count == 2)
        }
    }

    @Test func writeIfEmptyGoesByTheSlot() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        try database.withTransaction { cursor in
            let map = try HashMap<ReadWrite>(cursor)
            var first = try map.putCursor(forHash: sha256("a"))
            var second = try map.putCursor(forHash: sha256("a"))
            try first.write(.uint(1))
            // `second` still holds its snapshot of the empty slot, but the
            // write goes by the slot as it is now
            try second.writeIfEmpty(.uint(2))
            #expect(try map.cursor(forHash: sha256("a"))!.readUInt64() == 1)
        }
    }

    @Test func anEmptySlotIsWrittenAsNothing() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let empty = try database.rootCursor.slot
        #expect(empty.isEmpty)

        let list = try ArrayList<ReadWrite>(database.rootCursor)
        try list.append(.slot(empty))
        #expect(try !list.slot(at: 0)!.isEmpty)
    }

    @Test func aCursorThatCanOnlyRead() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let list = try ArrayList<ReadWrite>(database.rootCursor)
        try list.append(.uint(1))

        let reader: Cursor<ReadOnly> = database.rootCursor.readOnly
        #expect(try ArrayList<ReadOnly>(reader).count == 1)
        #expect(try list.readOnly.count == 1)
    }

    @Test func writingThroughACursor() throws {
        let moment = try newMoment { moment in
            var cursor = try moment.putCursor(forHash: sha256("counter"))
            try cursor.write(.uint(1))
            #expect(try cursor.readUInt64() == 1)
            try cursor.write(.uint(2))

            var maybe = try moment.putCursor(forHash: sha256("once"))
            try maybe.writeIfEmpty(.uint(1))
            try maybe.writeIfEmpty(.uint(2))
        }

        #expect(try moment.cursor(forHash: sha256("counter"))!.readUInt64() == 2)
        #expect(try moment.cursor(forHash: sha256("once"))!.readUInt64() == 1)
    }

    @Test func aCursorFromACollectionAtTheRootOutlivesItsCommit() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let map = try HashMap<ReadWrite>(database.rootCursor)

        // At the root the call is a transaction, which has committed by the
        // time it returns, with an entry that has no value.
        var late = try map.putCursor(forHash: sha256("late"))
        #expect(throws: XitDBError.expectedTxStart) {
            try late.write(.uint(1))
        }
        #expect(try map.cursor(forHash: sha256("late")) == nil)
        #expect(try map.entry(forHash: sha256("late")) != nil)

        // Inside a transaction the cursor has one to write in.
        try database.withTransaction { cursor in
            var value = try HashMap<ReadWrite>(cursor).putCursor(forHash: sha256("value"))
            try value.write(.uint(1))
        }
        #expect(try map.cursor(forHash: sha256("value"))!.readUInt64() == 1)
    }

    @Test func iteratingOverAList() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let list = try ArrayList<ReadWrite>(database.rootCursor)
        try list.append(.uint(1))
        try list.append(.uint(2))
        try list.append(.uint(3))

        var values: [UInt64] = []
        var iterator = try list.iterator()
        while let element = try iterator.next() {
            values.append(try element.readUInt64())
        }
        #expect(values == [1, 2, 3])
    }

    @Test func iteratingOverAMapGivesEntries() throws {
        let moment = try newMoment { moment in
            try moment.putKey(.bytes(Array("name".utf8)), forHash: sha256("name"))
            try moment.put(.bytes(Array("Alice".utf8)), forHash: sha256("name"))
            try moment.putKey(.bytes(Array("age".utf8)), forHash: sha256("age"))
            try moment.put(.uint(25), forHash: sha256("age"))
        }

        var keys: [String] = []
        var iterator = try moment.iterator()
        while let cursor = try iterator.next() {
            let entry = try cursor.readEntry()
            let key = String(decoding: try entry.key.readBytes(), as: UTF8.self)
            keys.append(key)
            switch try entry.value.slot.tag {
            case .uint:
                print(key, try entry.value.readUInt64())
            default:
                print(key, String(decoding: try entry.value.readBytes(), as: UTF8.self))
            }
        }
        #expect(keys.sorted() == ["age", "name"])

        let entry = try moment.entry(forHash: sha256("name"))!
        #expect(entry.hash == Array(sha256("name")))
        #expect(entry.withHash { $0.count } == 32)
        #expect(try entry.value.readBytes() == Array("Alice".utf8))
    }

    @Test func nothingAndNeverWritten() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let list = try ArrayList<ReadWrite>(database.rootCursor)
        try list.append(.uint(1))
        try list.append(.slot(nil))
        _ = try list.appendCursor()

        // Three elements: a value, a slot set to nothing, a slot never written.
        #expect(try list.count == 3)
        #expect(try list.cursor(at: 0) != nil)

        let cleared = try list.slot(at: 1)!
        #expect(cleared.tag == .none)
        #expect(!cleared.isEmpty)
        #expect(try list.cursor(at: 1)!.readBytes() == [])
        #expect(try list.slot(at: 2) == nil)
        #expect(try list.cursor(at: 2) == nil)

        // Iterating gives the one set to nothing, and passes over the other.
        var tags: [Slot.Tag] = []
        var iterator = try list.iterator()
        while let element = try iterator.next() {
            tags.append(try element.slot.tag)
        }
        #expect(tags == [.uint, .none])
    }

    @Test func clearingAnEntryIsNotRemovingIt() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let map = try CountedHashMap<ReadWrite>(database.rootCursor)
        try map.put(.uint(1), forHash: sha256("cleared"))
        try map.put(.uint(2), forHash: sha256("removed"))

        try map.put(.slot(nil), forHash: sha256("cleared"))
        try map.remove(forHash: sha256("removed"))

        #expect(try map.count == 1)
        #expect(try map.slot(forHash: sha256("cleared"))!.tag == .none)
        #expect(try map.slot(forHash: sha256("removed")) == nil)
    }

    @Test func countingWhatASlotHolds() throws {
        let moment = try newMoment { moment in
            try moment.put(.bytes(Array("hello".utf8)), forHash: sha256("short"))
            try moment.put(.bytes(Array("hello, world".utf8)), forHash: sha256("long"))
            try moment.put(.uint(1), forHash: sha256("number"))
            let list = try ArrayList<ReadWrite>(moment.putCursor(forHash: sha256("list")))
            try list.append(.uint(1))
            _ = try HashMap<ReadWrite>(moment.putCursor(forHash: sha256("map")))
        }
        #expect(try moment.cursor(forHash: sha256("short"))!.count == 5)
        #expect(try moment.cursor(forHash: sha256("long"))!.count == 12)
        #expect(try moment.cursor(forHash: sha256("list"))!.count == 1)
        #expect(throws: XitDBError.unexpectedTag) {
            try moment.cursor(forHash: sha256("number"))!.count
        }
        #expect(throws: XitDBError.unexpectedTag) {
            try moment.cursor(forHash: sha256("map"))!.count
        }
    }

    @Test func readingIntoABuffer() throws {
        let moment = try newMoment { moment in
            try moment.put(.bytes(Array("hello, world".utf8)), forHash: sha256("greeting"))
        }

        var buffer = [UInt8](repeating: 0, count: 64)
        var span = buffer.mutableSpan
        let count = try moment.cursor(forHash: sha256("greeting"))!.readBytes(into: &span)
        #expect(count == 12)
        #expect(Array(buffer[..<count]) == Array("hello, world".utf8))

        var small = [UInt8](repeating: 0, count: 4)
        var smallSpan = small.mutableSpan
        #expect(throws: XitDBError.streamTooLong) {
            try moment.cursor(forHash: sha256("greeting"))!.readBytes(into: &smallSpan)
        }
    }

    @Test func aLimitOnWhatIsRead() throws {
        let moment = try newMoment { moment in
            try moment.put(.bytes(Array("hello, world".utf8)), forHash: sha256("greeting"))
        }

        // A limit stops a value too large to want from being read at all.
        let cursor = try moment.cursor(forHash: sha256("greeting"))!
        #expect(throws: XitDBError.streamTooLong) {
            try cursor.readBytes(maxCount: 4)
        }
    }

    @Test func aHelperGivenACursorReachesTheDatabase() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        func hashSize(of cursor: Cursor<some CursorAccess>) -> UInt16 {
            cursor.database.header.hashSize
        }
        #expect(hashSize(of: database.rootCursor) == 32)
    }
}
