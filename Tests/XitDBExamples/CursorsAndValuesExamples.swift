import Testing
import XitDB
import XitDBHashing

// The article's function that reads a value of any kind, used again by its
// example of iterating over a map.
func describe(_ cursor: Cursor<ReadOnly>) throws -> String {
    switch try cursor.slot.tag {
    case .uint: "\(try cursor.read(UInt64.self))"
    case .int: "\(try cursor.read(Int64.self))"
    case .float: "\(try cursor.read(Double.self))"
    case .bytes, .shortBytes: String(decoding: try cursor.read([UInt8].self), as: UTF8.self)
    case .none: "nothing"
    default: "a collection"
    }
}

// The article's record, a value of the examples' own. Private, as the
// comment of `StorableValue` has a record of the same name in
// CommentExamples.swift.
private struct Person {
    var name: String
    var age: UInt64
}

extension Person: StorableValue {
    init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        let fields = try HashMap<ReadOnly>(cursor)
        guard let name = try fields.value(forKey: "name", as: String.self),
            let age = try fields.value(forKey: "age", as: UInt64.self)
        else { throw .keyNotFound }
        self.name = name
        self.age = age
    }

    func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        // Clear the slot first, so that the record takes the place of
        // whatever was there.
        try cursor.write(.slot(nil))
        let fields = try HashMap<ReadWrite>(cursor)
        try fields.put(name, forKey: "name")
        try fields.put(age, forKey: "age")
    }
}

// The same record without the line that clears the slot, to show what that
// line is for.
private struct UnclearedPerson: StorableValue {
    var name: String

    init(name: String) {
        self.name = name
    }

    init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        name = try HashMap<ReadOnly>(cursor).value(forKey: "name", as: String.self) ?? ""
    }

    func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        let fields = try HashMap<ReadWrite>(cursor)
        try fields.put(name, forKey: "name")
    }
}

// A record that fails once it has cleared its slot, for the article's
// sentence on writing a record through the root cursor.
private struct FailingRecord: StorableValue {
    init() {}

    init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        throw .keyNotFound
    }

    func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.slot(nil))
        throw .keyNotFound
    }
}

@Suite("Cursors and values") struct CursorsAndValuesExamples {
    /// Through the root cursor every write commits on its own, so a record
    /// that fails partway leaves what it wrote; through a collection's typed
    /// call at the root it is one transaction, and nothing of it stays.
    @Test func aRecordThroughTheRootCursor() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { cursor in
            try HashMap<ReadWrite>(cursor).put("Alice", forKey: "name")
        }

        let map = try HashMap<ReadWrite>(database.rootCursor)
        #expect(throws: XitDBError.keyNotFound) { try map.put(FailingRecord(), forKey: "name") }
        #expect(try map.value(forKey: "name", as: String.self) == "Alice")

        var root = database.rootCursor
        #expect(throws: XitDBError.keyNotFound) { try root.write(FailingRecord()) }
        #expect(try database.rootCursor.slot.tag == .none)

        // A whole record through the root cursor commits more than once.
        let other = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        var otherRoot = other.rootCursor
        let empty = try other.committedSize
        try otherRoot.write(Person(name: "Bob", age: 42))
        let throughCursor = try other.committedSize - empty
        let third = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let start = try third.committedSize
        try third.withTransaction { cursor in
            var body = cursor
            try body.write(Person(name: "Bob", age: 42))
        }
        #expect(throughCursor > (try third.committedSize) - start)
    }

    private func newMoment(_ body: (HashMap<ReadWrite>) throws -> Void) throws -> HashMap<ReadOnly> {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(nil)) { cursor in
            try body(try HashMap<ReadWrite>(cursor))
        }
        return try HashMap<ReadOnly>(history.cursor(at: -1)!)
    }

    @Test func theValueTypes() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(nil)) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            try moment.put(UInt64(42), forKey: "unsigned")
            try moment.put(-42 as Int64, forKey: "signed")
            try moment.put(2.5, forKey: "double")
            try moment.put("hello", forKey: "greeting")

            let unsigned = try moment.value(forKey: "unsigned", as: UInt64.self)
            let signed: Int64? = try moment.value(forKey: "signed")
            let greeting = try moment.value(forKey: "greeting", as: String.self)
            #expect(unsigned == 42)
            #expect(signed == -42)
            #expect(greeting == "hello")

            try moment.put("hello, world", forKey: "long")
            try moment.put([0x68, 0x69] as [UInt8], forKey: "bytes")
        }
        let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
        #expect(try moment.value(forKey: "double", as: Double.self) == 2.5)

        // The table: each type is the format's own kind of slot.
        #expect(try moment.slot(forKey: "unsigned")!.tag == .uint)
        #expect(try moment.slot(forKey: "signed")!.tag == .int)
        #expect(try moment.slot(forKey: "double")!.tag == .float)
        #expect(try moment.slot(forKey: "greeting")!.tag == .shortBytes)
        #expect(try moment.slot(forKey: "long")!.tag == .bytes)
        #expect(try moment.slot(forKey: "bytes")!.tag == .shortBytes)

        // What the typed calls write is what the format's own calls write,
        // and the format's own reads read it.
        #expect(try moment.cursor(forKey: "unsigned")!.readUInt64() == 42)
        #expect(try moment.cursor(forKey: "signed")!.readInt64() == -42)
        #expect(try moment.cursor(forKey: "double")!.readDouble() == 2.5)
        #expect(try moment.cursor(forKey: "greeting")!.readBytes() == Array("hello".utf8))
        let byHand = try newMoment { moment in
            try moment.put(.uint(42), forKey: "unsigned")
            try moment.put(.bytes(Array("hello".utf8)), forKey: "greeting")
        }
        #expect(try byHand.slot(forKey: "unsigned") == moment.slot(forKey: "unsigned"))
        #expect(try byHand.slot(forKey: "greeting") == moment.slot(forKey: "greeting"))

        // A cursor reads and writes the same way.
        #expect(try moment.cursor(forKey: "greeting")!.read(String.self) == "hello")

        // A short value is held in its slot, a long one behind it.
        #expect(Bytes(Array("eightbyt".utf8)).isShort)
        #expect(!Bytes(Array("ninebytes".utf8)).isShort)
        #expect(!Bytes([1, 0, 2]).isShort)
        #expect(Bytes(Array("sixbyt".utf8), formatTag: "dt").isShort)
        #expect(!Bytes(Array("seven b".utf8), formatTag: "dt").isShort)
    }

    @Test func aReadIsStrictAboutTheKind() throws {
        let moment = try newMoment { moment in
            try moment.put(UInt64(42), forKey: "unsigned")
            try moment.put(-42 as Int64, forKey: "signed")
            try moment.put("hello", forKey: "greeting")
            try moment.put([0xFF, 0xFE] as [UInt8], forKey: "not text")
            try moment.put(Bytes(Array("2026".utf8), formatTag: "dt"), forKey: "tagged")
            _ = try ArrayList<ReadWrite>(moment.putCursor(forKey: "list"))
        }

        // A number is never read from another kind.
        #expect(throws: XitDBError.unexpectedTag) { try moment.value(forKey: "signed", as: UInt64.self) }
        #expect(throws: XitDBError.unexpectedTag) { try moment.value(forKey: "unsigned", as: Int64.self) }
        #expect(throws: XitDBError.unexpectedTag) { try moment.value(forKey: "unsigned", as: Double.self) }
        #expect(throws: XitDBError.unexpectedTag) { try moment.value(forKey: "greeting", as: UInt64.self) }
        #expect(throws: XitDBError.unexpectedTag) { try moment.value(forKey: "unsigned", as: String.self) }
        #expect(throws: XitDBError.unexpectedTag) { try moment.value(forKey: "list", as: String.self) }
        #expect(throws: XitDBError.unexpectedTag) { try moment.value(forKey: "list", as: [UInt8].self) }

        // Bytes that are not UTF-8 are refused as a String, and nothing is
        // repaired; as bytes they read.
        #expect(throws: XitDBError.invalidUTF8) { try moment.value(forKey: "not text", as: String.self) }
        #expect(try moment.value(forKey: "not text", as: [UInt8].self) == [0xFF, 0xFE])

        // A String and a [UInt8] read a byte array whatever its format tag.
        #expect(try moment.value(forKey: "tagged", as: String.self) == "2026")
        #expect(try moment.value(forKey: "tagged", as: [UInt8].self) == Array("2026".utf8))
    }

    @Test func readingWhateverIsThere() throws {
        let moment = try newMoment { moment in
            try moment.put(UInt64(42), forKey: "number")
            try moment.put(-1 as Int64, forKey: "signed")
            try moment.put(0.5, forKey: "float")
            try moment.put("text", forKey: "text")
            try moment.put(.slot(nil), forKey: "nothing")
            _ = try ArrayList<ReadWrite>(moment.putCursor(forKey: "list"))
        }
        #expect(try describe(moment.cursor(forKey: "number")!) == "42")
        #expect(try describe(moment.cursor(forKey: "signed")!) == "-1")
        #expect(try describe(moment.cursor(forKey: "float")!) == "0.5")
        #expect(try describe(moment.cursor(forKey: "text")!) == "text")
        #expect(try describe(moment.cursor(forKey: "nothing")!) == "nothing")
        #expect(try describe(moment.cursor(forKey: "list")!) == "a collection")
    }

    @Test func noValueAndNothing() throws {
        let moment = try newMoment { moment in
            try moment.put("", forKey: "empty")
            try moment.put(.slot(nil), forKey: "cleared")

            let empty = try moment.value(forKey: "empty", as: String.self)  // ""
            let cleared = try moment.value(forKey: "cleared", as: String.self)  // "" as well
            let missing = try moment.value(forKey: "missing", as: String.self)  // nil
            let wasCleared = try moment.slot(forKey: "cleared")?.tag == Slot.Tag.none  // true
            #expect(empty == "")
            #expect(cleared == "")
            #expect(missing == nil)
            #expect(wasCleared)
        }
        #expect(try moment.slot(forKey: "empty")!.tag == .shortBytes)

        // Set to nothing, the value is there: as bytes it is empty, and as a
        // number it is an error, not nil.
        #expect(try moment.value(forKey: "cleared", as: [UInt8].self) == [])
        #expect(try moment.value(forKey: "cleared", as: Bytes.self) == Bytes([]))
        #expect(throws: XitDBError.unexpectedTag) { try moment.value(forKey: "cleared", as: UInt64.self) }
        #expect(throws: XitDBError.unexpectedTag) { try moment.value(forKey: "cleared", as: Int64.self) }
        #expect(throws: XitDBError.unexpectedTag) { try moment.value(forKey: "cleared", as: Double.self) }
        #expect(try moment.value(forKey: "missing", as: UInt64.self) == nil)
    }

    @Test func anEntryNeverWrittenHasNoValue() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let map = try HashMap<ReadWrite>(database.rootCursor)

        // At the root the call is a transaction of its own, which commits an
        // entry whose value was never written.
        _ = try map.putCursor(forKey: "late")
        #expect(try map.entry(forKey: "late") != nil)
        #expect(try map.slot(forKey: "late") == nil)
        #expect(try map.value(forKey: "late", as: String.self) == nil)
        #expect(try map.value(forKey: "late", as: UInt64.self) == nil)
    }

    @Test func nothingAndNeverWritten() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let list = try ArrayList<ReadWrite>(database.rootCursor)
        try list.append(UInt64(1))
        try list.append(.slot(nil))
        _ = try list.appendCursor()

        // Three elements: a value, a slot set to nothing, and one appended
        // and never written.
        #expect(try list.count == 3)
        #expect(try list.slot(at: 0)!.tag == .uint)
        for index in 1...2 {
            let slot = try list.slot(at: index)!
            #expect(slot.tag == .none)
            #expect(!slot.isEmpty)
            #expect(try list.value(at: index, as: String.self) == "")
            #expect(try list.value(at: index, as: [UInt8].self) == [])
            #expect(throws: XitDBError.unexpectedTag) { try list.value(at: index, as: UInt64.self) }
        }
        #expect(try list.value(at: 3, as: String.self) == nil)

        // Iterating gives all three.
        var tags: [Slot.Tag] = []
        var iterator = try list.iterator()
        while let element = try iterator.next() {
            tags.append(try element.slot.tag)
        }
        #expect(tags == [.uint, .none, .none])

        // A linked list does the same with an element it appends and nobody
        // writes.
        let other = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try other.withTransaction { cursor in
            let linked = try LinkedArrayList<ReadWrite>(cursor)
            _ = try linked.appendCursor()
            #expect(try linked.slot(at: 0)!.tag == .none)
            #expect(try linked.value(at: 0, as: String.self) == "")
        }
    }

    @Test func clearingAnEntryIsNotRemovingIt() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let map = try CountedHashMap<ReadWrite>(database.rootCursor)
        try map.put(UInt64(1), forKey: "cleared")
        try map.put(UInt64(2), forKey: "removed")

        try map.put(.slot(nil), forKey: "cleared")
        try map.remove(forKey: "removed")

        #expect(try map.count == 1)
        #expect(try map.slot(forKey: "cleared")!.tag == .none)
        #expect(try map.slot(forKey: "removed") == nil)
    }

    @Test func formatTags() throws {
        var created: Bytes?
        let moment = try newMoment { moment in
            // A date, stored as text, with a tag that says how to read it.
            let date = Bytes(Array("2026-11-07T09:47:00Z".utf8), formatTag: "dt")
            try moment.put(date, forKey: "created")

            let created = try moment.value(forKey: "created", as: Bytes.self)
            #expect(created == date)
        }
        created = try moment.value(forKey: "created", as: Bytes.self)
        #expect(created?.formatTag == "dt")
        #expect(created?.value == Array("2026-11-07T09:47:00Z".utf8))
        #expect(try moment.cursor(forKey: "created")!.readBytesWithFormatTag() == created)
        // Read as text, the tag is not part of it.
        #expect(try moment.value(forKey: "created", as: String.self) == "2026-11-07T09:47:00Z")
    }

    @Test func aRecordOfYourOwn() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let people = try ArrayList<ReadWrite>(moment.putCursor(forKey: "people"))

            try people.append(Person(name: "Alice", age: 25))
            let first = try people.value(at: 0, as: Person.self)
            #expect(first?.name == "Alice")
            #expect(first?.age == 25)

            // It is a map of its fields, which any reader of the format reads.
            let fields = try HashMap<ReadOnly>(people.cursor(at: 0)!)
            #expect(try fields.cursor(forHash: sha256("age"))!.readUInt64() == 25)

            // Written in place of a number, it takes the number's place.
            try moment.put(UInt64(7), forKey: "someone")
            try moment.put(Person(name: "Bob", age: 42), forKey: "someone")
            #expect(try moment.value(forKey: "someone", as: Person.self)?.name == "Bob")
        }

        // Without the line that clears the slot, it writes into the map that
        // is there and keeps the fields it does not write, and a slot that
        // holds a number refuses it.
        try database.withTransaction { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            try moment.put(Person(name: "Carol", age: 30), forKey: "carol")
            try moment.put(UnclearedPerson(name: "Dora"), forKey: "carol")
            let kept = try moment.value(forKey: "carol", as: Person.self)
            #expect(kept?.name == "Dora")
            #expect(kept?.age == 30)
        }
        let root = try HashMap<ReadWrite>(database.rootCursor)
        try root.put(UInt64(7), forKey: "number")
        #expect(throws: XitDBError.unexpectedTag) {
            try root.put(UnclearedPerson(name: "Gus"), forKey: "number")
        }
        #expect(try root.value(forKey: "number", as: UInt64.self) == 7)
    }

    @Test func aCursorHoldsASnapshot() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let list = try ArrayList<ReadWrite>(database.rootCursor)
        try list.append(UInt64(1))

        // A cursor below the root keeps what it saw.
        let element = try list.cursor(at: 0)!
        try list.put(UInt64(2), at: 0)
        #expect(try element.read(UInt64.self) == 1)
        #expect(try list.value(at: 0, as: UInt64.self) == 2)

        // A cursor at the root reads the last commit every time.
        let root = database.rootCursor
        let countBefore = try root.count
        try list.append(UInt64(3))
        #expect(countBefore == 1)
        #expect(try root.count == 2)
    }

    @Test func onlyTheSlotIsASnapshot() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { cursor in
            let list = try ArrayList<ReadWrite>(cursor)
            try list.append(UInt64(1))

            // The slot is the cursor's, but what it points at is read when asked
            // for, and this transaction changes its own list in place.
            let held = list.cursor
            let before = try held.count
            try list.append(UInt64(2))
            #expect(before == 1)
            #expect(try held.count == 2)
        }
    }

    @Test func writingThroughACursor() throws {
        let moment = try newMoment { moment in
            var cursor = try moment.putCursor(forKey: "counter")
            try cursor.write(UInt64(1))
            #expect(try cursor.read(UInt64.self) == 1)
            try cursor.write(UInt64(2))

            var maybe = try moment.putCursor(forKey: "once")
            try maybe.writeIfEmpty(.uint(1))
            try maybe.writeIfEmpty(.uint(2))
        }

        #expect(try moment.value(forKey: "counter", as: UInt64.self) == 2)
        #expect(try moment.value(forKey: "once", as: UInt64.self) == 1)
    }

    @Test func writeIfEmptyGoesByTheSlot() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { cursor in
            let map = try HashMap<ReadWrite>(cursor)
            var first = try map.putCursor(forKey: "a")
            var second = try map.putCursor(forKey: "a")
            try first.write(UInt64(1))
            // `second` still holds its snapshot of the empty slot, but the
            // write goes by the slot as it is now
            try second.writeIfEmpty(.uint(2))
            #expect(try map.value(forKey: "a", as: UInt64.self) == 1)
        }
    }

    /// The article's rule for a slot set to nothing: written over when the
    /// cursor was made on an empty slot, as an appended element's is, and
    /// left when the cursor was made on it after it was set to nothing.
    @Test func writeIfEmptyAndASlotSetToNothing() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { cursor in
            let map = try HashMap<ReadWrite>(cursor)
            let list = try ArrayList<ReadWrite>(map.putCursor(forKey: "list"))
            var appended = try list.appendCursor()
            try appended.writeIfEmpty(.uint(7))
            #expect(try list.value(at: 0, as: UInt64.self) == 7)

            var early = try map.putCursor(forKey: "early")
            var other = try map.putCursor(forKey: "early")
            try other.write(.slot(nil))
            try early.writeIfEmpty(.uint(1))
            #expect(try map.value(forKey: "early", as: UInt64.self) == 1)

            try map.put(.slot(nil), forKey: "late")
            var late = try map.putCursor(forKey: "late")
            try late.writeIfEmpty(.uint(2))
            #expect(try map.slot(forKey: "late")!.tag == .none)

            let tasks = try LinkedArrayList<ReadWrite>(map.putCursor(forKey: "tasks"))
            var task = try tasks.appendCursor()
            try task.writeIfEmpty(.uint(3))
            #expect(try tasks.value(at: 0, as: UInt64.self) == 3)
        }
    }

    @Test func aCursorFromACollectionAtTheRootOutlivesItsCommit() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let map = try HashMap<ReadWrite>(database.rootCursor)

        // At the root the call is a transaction, which has committed by the
        // time it returns, with an entry that has no value.
        var late = try map.putCursor(forKey: "late")
        #expect(throws: XitDBError.expectedTxStart) {
            try late.write(UInt64(1))
        }
        #expect(try map.cursor(forKey: "late") == nil)
        #expect(try map.entry(forKey: "late") != nil)

        // Inside a transaction the cursor has one to write in.
        try database.withTransaction { cursor in
            var value = try HashMap<ReadWrite>(cursor).putCursor(forKey: "value")
            try value.write(UInt64(1))
        }
        #expect(try map.value(forKey: "value", as: UInt64.self) == 1)
    }

    @Test func aCursorThatCanOnlyRead() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let list = try ArrayList<ReadWrite>(database.rootCursor)
        try list.append(UInt64(1))

        let reader: Cursor<ReadOnly> = database.rootCursor.readOnly
        #expect(try ArrayList<ReadOnly>(reader).count == 1)
        #expect(try list.readOnly.count == 1)
    }

    @Test func iteratingOverAList() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let list = try ArrayList<ReadWrite>(database.rootCursor)
        try list.append(UInt64(1))
        try list.append(UInt64(2))
        try list.append(UInt64(3))

        var values: [UInt64] = []
        var iterator = try list.iterator()
        while let element = try iterator.next() {
            values.append(try element.read(UInt64.self))
        }
        #expect(values == [1, 2, 3])
    }

    @Test func iteratingOverAMapGivesEntries() throws {
        let moment = try newMoment { moment in
            try moment.putKey("name")
            try moment.put("Alice", forKey: "name")
            try moment.put(UInt64(25), forKey: "age")
        }

        var iterator = try moment.iterator()
        while let cursor = try iterator.next() {
            let entry = try cursor.readEntry()
            if try entry.key.slot.isEmpty {
                print("a value stored under its hash alone:", try describe(entry.value))
            } else {
                print(try entry.key.read(String.self), try describe(entry.value))
            }
        }

        // What the loop prints, one line for each entry.
        var lines: [String] = []
        var again = try moment.iterator()
        while let cursor = try again.next() {
            let entry = try cursor.readEntry()
            lines.append(
                try entry.key.slot.isEmpty
                    ? "hash alone: \(try describe(entry.value))"
                    : "\(try entry.key.read(String.self)): \(try describe(entry.value))")
        }
        #expect(lines.sorted() == ["hash alone: 25", "name: Alice"])

        // An entry whose key was not stored has an empty key slot, which
        // reads as empty bytes and not as an error.
        let age = try moment.entry(forKey: "age")!
        #expect(try age.key.slot.isEmpty)
        #expect(try age.key.read(String.self) == "")
        // A cursor at a slot never written has no nil to give, and reads as
        // a slot set to nothing does.
        #expect(try age.key.read([UInt8].self) == [])
        #expect(throws: XitDBError.unexpectedTag) { try age.key.read(UInt64.self) }
        #expect(throws: XitDBError.unexpectedTag) { try age.key.read(Int64.self) }
        #expect(throws: XitDBError.unexpectedTag) { try age.key.read(Double.self) }
        #expect(try moment.keyCursor(forKey: "age") == nil)

        let entry = try moment.entry(forKey: "name")!
        #expect(entry.hash == Array(sha256("name")))
        #expect(entry.withHash { $0.count } == 32)
        #expect(try entry.value.read(String.self) == "Alice")
    }

    @Test func aSetStoresItsMembers() throws {
        let moment = try newMoment { moment in
            let tags = try HashSet<ReadWrite>(moment.putCursor(forKey: "tags"))
            try tags.insert("red")
        }
        let tags = try HashSet<ReadOnly>(moment.cursor(forKey: "tags")!)
        var iterator = try tags.iterator()
        let member = try iterator.next()!.readEntry()
        #expect(try member.key.read(String.self) == "red")
        #expect(try member.value.slot.isEmpty)
    }

    @Test func anEmptySlotIsWrittenAsNothing() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let empty = try database.rootCursor.slot
        #expect(empty.isEmpty)

        let list = try ArrayList<ReadWrite>(database.rootCursor)
        try list.append(.slot(empty))
        #expect(try !list.slot(at: 0)!.isEmpty)
    }

    @Test func countingWhatASlotHolds() throws {
        let moment = try newMoment { moment in
            try moment.put("hello", forKey: "short")
            try moment.put("hello, world", forKey: "long")
            try moment.put(UInt64(1), forKey: "number")
            let list = try ArrayList<ReadWrite>(moment.putCursor(forKey: "list"))
            try list.append(UInt64(1))
            _ = try HashMap<ReadWrite>(moment.putCursor(forKey: "map"))
        }
        #expect(try moment.cursor(forKey: "short")!.count == 5)
        #expect(try moment.cursor(forKey: "long")!.count == 12)
        #expect(try moment.cursor(forKey: "list")!.count == 1)
        #expect(throws: XitDBError.unexpectedTag) {
            try moment.cursor(forKey: "number")!.count
        }
        #expect(throws: XitDBError.unexpectedTag) {
            try moment.cursor(forKey: "map")!.count
        }
    }

    @Test func readingIntoABuffer() throws {
        let moment = try newMoment { moment in
            try moment.put("hello, world", forKey: "greeting")
        }

        var buffer = [UInt8](repeating: 0, count: 64)
        var span = buffer.mutableSpan
        let count = try moment.cursor(forKey: "greeting")!.readBytes(into: &span)
        #expect(count == 12)
        #expect(Array(buffer[..<count]) == Array("hello, world".utf8))

        var small = [UInt8](repeating: 0, count: 4)
        var smallSpan = small.mutableSpan
        #expect(throws: XitDBError.streamTooLong) {
            try moment.cursor(forKey: "greeting")!.readBytes(into: &smallSpan)
        }
    }

    @Test func aLimitOnWhatIsRead() throws {
        let moment = try newMoment { moment in
            try moment.put("hello, world", forKey: "greeting")
        }

        // A limit stops a value too large to want from being read at all.
        let cursor = try moment.cursor(forKey: "greeting")!
        #expect(throws: XitDBError.streamTooLong) {
            try cursor.readBytes(maxCount: 4)
        }
    }
}
