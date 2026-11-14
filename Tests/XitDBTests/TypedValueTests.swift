import Foundation
import Testing
import XitDBHashing

@testable import XitDB

// Values as types (decision D35, items 3 to 5): a value writes itself to a
// slot and reads itself back. The library's types add no bytes of their
// own, so each typed write is proved against the write of `WritableData`
// it stands for, in two databases written side by side; the reads are
// proved strict, kind by kind; and a record of the tests' own goes through
// every typed call.

/// A record: a type that writes itself as a map of its fields, as the
/// documentation's example does.
struct Person: StorableValue, Equatable {
    var name: String
    var age: UInt64

    init(name: String, age: UInt64) {
        self.name = name
        self.age = age
    }

    init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        let fields = try HashMap<ReadOnly>(cursor)
        guard let name = try fields.value(forKey: "name", as: String.self),
            let age = try fields.value(forKey: "age", as: UInt64.self)
        else { throw .keyNotFound }
        self.name = name
        self.age = age
    }

    func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        // Whatever the slot held goes, a value of another kind included.
        try cursor.write(.slot(nil))
        let fields = try HashMap<ReadWrite>(cursor)
        try fields.put(name, forKey: "name")
        try fields.put(age, forKey: "age")
    }
}

/// A record of records: a name and a list of people, each written by its
/// own conformance.
struct Team: StorableValue, Equatable {
    var name: String
    var members: [Person]

    init(name: String, members: [Person]) {
        self.name = name
        self.members = members
    }

    init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        let fields = try HashMap<ReadOnly>(cursor)
        guard let name = try fields.value(forKey: "name", as: String.self),
            let list = try fields.cursor(forKey: "members")
        else { throw .keyNotFound }
        self.name = name
        let members = try ArrayList<ReadOnly>(list)
        var people: [Person] = []
        for index in 0..<(try members.count) {
            guard let person = try members.value(at: index, as: Person.self) else { throw .keyNotFound }
            people.append(person)
        }
        self.members = people
    }

    func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.slot(nil))
        let fields = try HashMap<ReadWrite>(cursor)
        try fields.put(name, forKey: "name")
        let list = try ArrayList<ReadWrite>(fields.putCursor(forKey: "members"))
        for member in members {
            try list.append(member)
        }
    }
}

/// A value whose writing clears its slot and then fails.
private struct FailsAfterClearing: StorableValue {
    init() {}
    init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {}

    func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.slot(nil))
        throw .keyNotFound
    }
}

/// A value whose writing fails before it has written anything.
private struct FailsAtOnce: StorableValue {
    init() {}
    init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {}

    func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        throw .keyNotFound
    }
}

/// A type of the caller's that wraps one of the library's own values and
/// writes itself as something else: a temperature kept as a `UInt64` and
/// written as a signed integer.
private struct Celsius: StorableValue, Equatable {
    var degrees: UInt64

    init(degrees: UInt64) { self.degrees = degrees }

    init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        degrees = UInt64(bitPattern: try cursor.readInt64())
    }

    func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.int(Int64(bitPattern: degrees)))
    }
}

/// A type of the caller's whose raw value is one of the library's own
/// values, written as tagged bytes of its name.
private enum Unit: UInt64, StorableValue {
    case metre = 1
    case second = 2

    init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        let bytes = try cursor.readBytesWithFormatTag()
        guard bytes.formatTag == "un", let unit = Unit(name: bytes.value) else { throw .unexpectedTag }
        self = unit
    }

    init?(name: [UInt8]) {
        switch name {
        case utf8("metre"): self = .metre
        case utf8("second"): self = .second
        default: return nil
        }
    }

    func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.bytes(utf8(self == .metre ? "metre" : "second"), formatTag: "un"))
    }
}

/// A value and the data it stands for.
private struct Case {
    let name: String
    let value: any StorableValue
    let data: WritableData
}

private let longText = String(repeating: "a longer text than a slot holds, ", count: 4)

/// One of each of the library's value types, with the short and the long
/// form of those that have two.
private var cases: [Case] {
    [
        Case(name: "UInt64", value: UInt64(7), data: .uint(7)),
        Case(name: "UInt64.max", value: UInt64.max, data: .uint(.max)),
        Case(name: "Int64", value: Int64(-7), data: .int(-7)),
        Case(name: "Int64.min", value: Int64.min, data: .int(.min)),
        Case(name: "Double", value: Double(2.5), data: .double(2.5)),
        Case(name: "a float literal", value: 2.5, data: .double(2.5)),
        Case(name: "String", value: "text", data: .bytes(utf8("text"))),
        Case(name: "an empty String", value: "", data: .bytes([])),
        Case(name: "a long String", value: longText, data: .bytes(utf8(longText))),
        Case(name: "a String that is not ASCII", value: "\u{E9}t\u{E9}", data: .bytes(utf8("\u{E9}t\u{E9}"))),
        Case(name: "[UInt8]", value: [UInt8]([1, 2, 3]), data: .bytes([1, 2, 3])),
        Case(name: "[UInt8] with a zero", value: [UInt8]([0, 255]), data: .bytes([0, 255])),
        Case(
            name: "long [UInt8]", value: [UInt8](repeating: 9, count: 100),
            data: .bytes([UInt8](repeating: 9, count: 100))),
        Case(name: "Bytes", value: Bytes([4, 5]), data: .bytes([4, 5])),
        Case(name: "tagged Bytes", value: Bytes([4, 5], formatTag: "tg"), data: .bytes([4, 5], formatTag: "tg")),
        Case(
            name: "long tagged Bytes", value: Bytes([UInt8](repeating: 8, count: 50), formatTag: "tg"),
            data: .bytes([UInt8](repeating: 8, count: 50), formatTag: "tg")),
    ]
}

/// Two databases with the same header, hasher and commit IDs: one written
/// through the typed calls, one through `WritableData`.
private struct TypedTwins {
    let typedStorage = MemoryStorage()
    let dataStorage = MemoryStorage()
    let typed: Database
    let data: Database

    init() throws {
        typed = try Database(
            creating: typedStorage, hashSize: 20, hashID: "sha1", fileID: 0x10,
            random: RandomSource(SeededGenerator(seed: 41)), hasher: KeyHasher(Insecure.SHA1.self))
        data = try Database(
            creating: dataStorage, hashSize: 20, hashID: "sha1", fileID: 0x10,
            random: RandomSource(SeededGenerator(seed: 41)), hasher: KeyHasher(Insecure.SHA1.self))
    }

    /// One step: a transaction on each database, after which the two files
    /// are the same. Each body gets the cursor of a place below the root.
    func step(
        _ what: String,
        typed typedBody: (Cursor<ReadWrite>) throws -> Void,
        data dataBody: (Cursor<ReadWrite>) throws -> Void
    ) throws {
        try typed.withTransaction { root in try typedBody(try HashMap<ReadWrite>(root).putCursor(forKey: "place")) }
        try data.withTransaction { root in try dataBody(try HashMap<ReadWrite>(root).putCursor(forKey: "place")) }
        #expect(typedStorage.bytes == dataStorage.bytes, "after \(what)")
    }
}

/// A place a typed read is made at: a key of a map or an index of a list.
private protocol TypedPlace {
    func read<Value: StorableValue>(_ type: Value.Type) throws -> Value?
}

private struct InHashMap: TypedPlace {
    let map: HashMap<ReadOnly>
    let key: String
    func read<Value: StorableValue>(_ type: Value.Type) throws -> Value? { try map.value(forKey: key, as: type) }
}

private struct InCountedHashMap: TypedPlace {
    let map: CountedHashMap<ReadOnly>
    let key: String
    func read<Value: StorableValue>(_ type: Value.Type) throws -> Value? { try map.value(forKey: key, as: type) }
}

private struct InSortedMapByText: TypedPlace {
    let map: SortedMap<ReadOnly>
    let key: String
    func read<Value: StorableValue>(_ type: Value.Type) throws -> Value? { try map.value(forKey: key, as: type) }
}

private struct InSortedMapByBytes: TypedPlace {
    let map: SortedMap<ReadOnly>
    let key: String
    func read<Value: StorableValue>(_ type: Value.Type) throws -> Value? { try map.value(forKey: utf8(key), as: type) }
}

private struct InArrayList: TypedPlace {
    let list: ArrayList<ReadOnly>
    let index: Int
    func read<Value: StorableValue>(_ type: Value.Type) throws -> Value? { try list.value(at: index, as: type) }
}

private struct InLinkedArrayList: TypedPlace {
    let list: LinkedArrayList<ReadOnly>
    let index: Int
    func read<Value: StorableValue>(_ type: Value.Type) throws -> Value? { try list.value(at: index, as: type) }
}

private struct ThroughACursor: TypedPlace {
    let cursor: Cursor<ReadOnly>
    func read<Value: StorableValue>(_ type: Value.Type) throws -> Value? { try cursor.read(type) }
}

@Suite struct TypedValueTests {
    // MARK: Writing

    /// A typed put on a hash map leaves the file the put of the value's
    /// data leaves, for every one of the library's types.
    @Test func aTypedPutOnAHashMapWritesTheValuesSlot() throws {
        let twins = try TypedTwins()
        for (index, item) in cases.enumerated() {
            try twins.step("a put of \(item.name)") {
                try HashMap<ReadWrite>($0).put(item.value, forKey: "key \(index)")
            } data: {
                try HashMap<ReadWrite>($0).put(item.data, forKey: "key \(index)")
            }
        }
        // Over a value that is there, of another kind.
        for (index, item) in cases.reversed().enumerated() {
            try twins.step("a put of \(item.name) over a value") {
                try HashMap<ReadWrite>($0).put(item.value, forKey: "key \(index)")
            } data: {
                try HashMap<ReadWrite>($0).put(item.data, forKey: "key \(index)")
            }
        }
    }

    @Test func aTypedPutOnACountedHashMapWritesTheValuesSlot() throws {
        let twins = try TypedTwins()
        for (index, item) in cases.enumerated() {
            try twins.step("a put of \(item.name)") {
                try CountedHashMap<ReadWrite>($0).put(item.value, forKey: "key \(index)")
            } data: {
                try CountedHashMap<ReadWrite>($0).put(item.data, forKey: "key \(index)")
            }
        }
        try twins.step("a put over a value") {
            try CountedHashMap<ReadWrite>($0).put("again", forKey: "key 0")
        } data: {
            try CountedHashMap<ReadWrite>($0).put(.bytes(utf8("again")), forKey: "key 0")
        }
        let map = try CountedHashMap<ReadOnly>(
            try #require(try HashMap<ReadOnly>(twins.typed.rootCursor).cursor(forKey: "place")))
        #expect(try map.count == UInt64(cases.count))
    }

    /// The same on a sorted map, by a key of bytes and by a key that is
    /// text.
    @Test func aTypedPutOnASortedMapWritesTheValuesSlot() throws {
        let twins = try TypedTwins()
        for (index, item) in cases.enumerated() {
            try twins.step("a put of \(item.name) by bytes") {
                try SortedMap<ReadWrite>($0).put(item.value, forKey: utf8("key \(index)"))
            } data: {
                try SortedMap<ReadWrite>($0).put(item.data, forKey: utf8("key \(index)"))
            }
            try twins.step("a put of \(item.name) by text") {
                try SortedMap<ReadWrite>($0).put(item.value, forKey: "text \(index)")
            } data: {
                try SortedMap<ReadWrite>($0).put(item.data, forKey: utf8("text \(index)"))
            }
        }
        try twins.step("a put over a value") {
            try SortedMap<ReadWrite>($0).put(UInt64(1), forKey: "text 0"[...])
        } data: {
            try SortedMap<ReadWrite>($0).put(.uint(1), forKey: utf8("text 0"))
        }
    }

    /// A typed append, put and insert on the lists leave the files the
    /// calls with the value's data leave.
    @Test func aTypedWriteOnAnArrayListWritesTheValuesSlot() throws {
        let twins = try TypedTwins()
        for item in cases {
            try twins.step("an append of \(item.name)") {
                try ArrayList<ReadWrite>($0).append(item.value)
            } data: {
                try ArrayList<ReadWrite>($0).append(item.data)
            }
        }
        for (index, item) in cases.reversed().enumerated() {
            try twins.step("a put of \(item.name) at \(index)") {
                try ArrayList<ReadWrite>($0).put(item.value, at: index)
            } data: {
                try ArrayList<ReadWrite>($0).put(item.data, at: index)
            }
        }
        try twins.step("a put at the last index, counted from the end") {
            try ArrayList<ReadWrite>($0).put("last", at: -1)
        } data: {
            try ArrayList<ReadWrite>($0).put(.bytes(utf8("last")), at: -1)
        }
    }

    @Test func aTypedWriteOnALinkedArrayListWritesTheValuesSlot() throws {
        let twins = try TypedTwins()
        for item in cases {
            try twins.step("an append of \(item.name)") {
                try LinkedArrayList<ReadWrite>($0).append(item.value)
            } data: {
                try LinkedArrayList<ReadWrite>($0).append(item.data)
            }
        }
        for (index, item) in cases.reversed().enumerated() {
            try twins.step("a put of \(item.name) at \(index)") {
                try LinkedArrayList<ReadWrite>($0).put(item.value, at: index)
            } data: {
                try LinkedArrayList<ReadWrite>($0).put(item.data, at: index)
            }
        }
        for (index, item) in cases.enumerated() {
            try twins.step("an insert of \(item.name) at \(index * 2)") {
                try LinkedArrayList<ReadWrite>($0).insert(item.value, at: index * 2)
            } data: {
                try LinkedArrayList<ReadWrite>($0).insert(item.data, at: index * 2)
            }
        }
    }

    /// At the root every typed write is a transaction of its own, as the
    /// write of the value's data is, and leaves the same file.
    @Test func aTypedWriteAtTheRootIsATransactionOfItsOwn() throws {
        func twins() throws -> TypedTwins { try TypedTwins() }

        let lists = try twins()
        let typedList = try ArrayList<ReadWrite>(lists.typed.rootCursor)
        let dataList = try ArrayList<ReadWrite>(lists.data.rootCursor)
        for item in cases {
            try typedList.append(item.value)
            try dataList.append(item.data)
            #expect(lists.typedStorage.bytes == lists.dataStorage.bytes, "an append of \(item.name)")
        }
        try typedList.put(UInt64(1), at: 0)
        try dataList.put(.uint(1), at: 0)
        #expect(lists.typedStorage.bytes == lists.dataStorage.bytes)

        let maps = try twins()
        let typedMap = try HashMap<ReadWrite>(maps.typed.rootCursor)
        let dataMap = try HashMap<ReadWrite>(maps.data.rootCursor)
        for (index, item) in cases.enumerated() {
            try typedMap.put(item.value, forKey: "key \(index)")
            try dataMap.put(item.data, forKey: "key \(index)")
            #expect(maps.typedStorage.bytes == maps.dataStorage.bytes, "a put of \(item.name)")
        }

        let sorted = try twins()
        let typedSorted = try SortedMap<ReadWrite>(sorted.typed.rootCursor)
        let dataSorted = try SortedMap<ReadWrite>(sorted.data.rootCursor)
        try typedSorted.put("value", forKey: "key")
        try dataSorted.put(.bytes(utf8("value")), forKey: utf8("key"))
        #expect(sorted.typedStorage.bytes == sorted.dataStorage.bytes)

        let linked = try twins()
        let typedLinked = try LinkedArrayList<ReadWrite>(linked.typed.rootCursor)
        let dataLinked = try LinkedArrayList<ReadWrite>(linked.data.rootCursor)
        try typedLinked.append(Int64(-1))
        try dataLinked.append(.int(-1))
        try typedLinked.insert("first", at: 0)
        try dataLinked.insert(.bytes(utf8("first")), at: 0)
        #expect(linked.typedStorage.bytes == linked.dataStorage.bytes)
    }

    /// A typed write through a cursor is the write of the value's data.
    @Test func aTypedWriteThroughACursorWritesTheValuesSlot() throws {
        let twins = try TypedTwins()
        for (index, item) in cases.enumerated() {
            try twins.step("a write of \(item.name)") {
                var cursor = try HashMap<ReadWrite>($0).putCursor(forKey: "key \(index)")
                try cursor.write(item.value)
                // The cursor is at what it wrote, as after a write of data.
                #expect(try cursor.slot.tag != .none)
            } data: {
                var cursor = try HashMap<ReadWrite>($0).putCursor(forKey: "key \(index)")
                try cursor.write(item.data)
            }
        }
    }

    // MARK: Through a cursor, at the root and below it

    /// What the root holds before a write through the root cursor: nothing,
    /// a number, a map, a list.
    private static let roots: [(name: String, make: @Sendable (Database) throws -> Void)] = [
        ("an empty root", { _ in }),
        (
            "a number at the root",
            { database in
                var root = database.rootCursor
                try root.write(.uint(1))
            }
        ),
        ("a map at the root", { database in try HashMap<ReadWrite>(database.rootCursor).put(.uint(1), forKey: "k") }),
        ("a list at the root", { database in try ArrayList<ReadWrite>(database.rootCursor).append(.uint(1)) }),
    ]

    /// Through the root cursor a typed write of one of the library's types
    /// leaves the file the write of its data leaves, whatever the root
    /// held.
    @Test func aTypedWriteThroughTheRootCursorWritesTheValuesSlot() throws {
        for root in Self.roots {
            for item in cases {
                let twins = try TypedTwins()
                try root.make(twins.typed)
                try root.make(twins.data)
                var typedRoot = twins.typed.rootCursor
                try typedRoot.write(item.value)
                var dataRoot = twins.data.rootCursor
                try dataRoot.write(item.data)
                #expect(twins.typedStorage.bytes == twins.dataStorage.bytes, "\(item.name) over \(root.name)")
            }
        }
    }

    /// Through the root cursor, with no transaction running, a record is
    /// one transaction: one commit, and the file a transaction with the
    /// one write in it leaves.
    @Test func aRecordThroughTheRootCursorIsOneTransaction() throws {
        let alice = Person(name: "Alice", age: 25)
        for root in Self.roots {
            let twins = try TypedTwins()
            try root.make(twins.typed)
            try root.make(twins.data)
            let commitsBefore = try Database.verifiedCommits(in: twins.typedStorage).count

            var cursor = twins.typed.rootCursor
            try cursor.write(alice)
            try twins.data.withTransaction { body in try body.write(alice) }

            #expect(twins.typedStorage.bytes == twins.dataStorage.bytes, "over \(root.name)")
            #expect(
                try Database.verifiedCommits(in: twins.typedStorage).count == commitsBefore + 1, "over \(root.name)")
            #expect(try twins.typed.rootCursor.read(Person.self) == alice, "over \(root.name)")
            // The root cursor reads the root as it is now.
            #expect(try cursor.read(Person.self) == alice, "over \(root.name)")
        }
    }

    /// A value whose writing fails, through the root cursor: the error
    /// comes out, and the root and the file are as they were, even though
    /// the value had cleared the root before it failed.
    @Test func aValueThatFailsThroughTheRootCursorLeavesTheRootAsItWas() throws {
        for root in Self.roots {
            let storage = MemoryStorage()
            let database = try Database(creating: storage, hashing: SHA256.self)
            try root.make(database)
            let before = storage.bytes
            let slotBefore = try database.rootCursor.slot

            var cursor = database.rootCursor
            #expect(throws: XitDBError.keyNotFound, "over \(root.name)") { try cursor.write(FailsAfterClearing()) }
            #expect(storage.bytes == before, "over \(root.name)")
            #expect(try database.rootCursor.slot == slotBefore, "over \(root.name)")
            // And the database goes on: the next write commits.
            try cursor.write(UInt64(9))
            #expect(try database.rootCursor.read(UInt64.self) == 9, "over \(root.name)")
        }
    }

    /// Inside a transaction a typed write through a cursor is the value's
    /// own writes, made in the transaction: the root cursor refuses it as
    /// it refuses any write then, the transaction's own cursor makes it,
    /// also after a freeze, and a value that fails rolls the transaction
    /// back when its error is passed on. Below the root with no
    /// transaction it is refused as the write of data is.
    @Test func insideATransactionATypedWriteIsAWriteOfTheTransaction() throws {
        let alice = Person(name: "Alice", age: 25)
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashing: SHA256.self)
        try database.withTransaction { body in
            var root = database.rootCursor
            #expect(throws: XitDBError.nestedTopLevelWrite) { try root.write(alice) }
            #expect(throws: XitDBError.nestedTopLevelWrite) { try root.write(UInt64(1)) }
            try body.write(UInt64(1))
            try database.freeze()
            // After a freeze the transaction's own cursor goes on.
            try body.write(alice)
            #expect(try body.read(Person.self) == alice)
        }
        #expect(try database.rootCursor.read(Person.self) == alice)

        // A value that fails after it has written, inside a transaction:
        // the error comes out, and passed on it rolls the transaction
        // back, so the database is as it was.
        let committed = storage.bytes
        #expect(throws: XitDBError.keyNotFound) {
            try database.withTransaction { body in try body.write(FailsAfterClearing()) }
        }
        #expect(storage.bytes == committed)
        #expect(try database.rootCursor.read(Person.self) == alice)

        let fields = try HashMap<ReadWrite>(database.rootCursor)
        var below = try fields.putCursor(forKey: "other")
        #expect(throws: XitDBError.expectedTxStart) { try below.write(alice) }
        #expect(throws: XitDBError.expectedTxStart) { try below.write(UInt64(1)) }
    }

    /// The ways a value is written into a place below the root, each given
    /// the map of a moment being written: through a cursor, and through
    /// each collection's typed write.
    private static let doors:
        [(name: String, write: @Sendable (HashMap<ReadWrite>, any StorableValue) throws -> Void)] = [
            (
                "a cursor",
                { moment, value in
                    var cursor = try moment.putCursor(forKey: "cursor")
                    try cursor.write(value)
                }
            ),
            (
                "a hash map",
                { moment, value in try HashMap<ReadWrite>(moment.putCursor(forKey: "map")).put(value, forKey: "k") }
            ),
            (
                "a counted hash map",
                { moment, value in
                    try CountedHashMap<ReadWrite>(moment.putCursor(forKey: "counted")).put(value, forKey: "k")
                }
            ),
            (
                "a sorted map, by bytes",
                { moment, value in
                    try SortedMap<ReadWrite>(moment.putCursor(forKey: "sorted")).put(value, forKey: utf8("k"))
                }
            ),
            (
                "a sorted map, by text",
                { moment, value in
                    try SortedMap<ReadWrite>(moment.putCursor(forKey: "sorted 2")).put(value, forKey: "k")
                }
            ),
            (
                "a list's append",
                { moment, value in try ArrayList<ReadWrite>(moment.putCursor(forKey: "list")).append(value) }
            ),
            (
                "a list's put",
                { moment, value in
                    let list = try ArrayList<ReadWrite>(moment.putCursor(forKey: "list 2"))
                    try list.append(.uint(0))
                    try list.put(value, at: 0)
                }
            ),
            (
                "a linked list's append",
                { moment, value in try LinkedArrayList<ReadWrite>(moment.putCursor(forKey: "linked")).append(value) }
            ),
            (
                "a linked list's put",
                { moment, value in
                    let list = try LinkedArrayList<ReadWrite>(moment.putCursor(forKey: "linked 2"))
                    try list.append(.uint(0))
                    try list.put(value, at: 0)
                }
            ),
            (
                "a linked list's insert",
                { moment, value in
                    let list = try LinkedArrayList<ReadWrite>(moment.putCursor(forKey: "linked 3"))
                    try list.append(.uint(0))
                    try list.insert(value, at: 0)
                }
            ),
        ]

    /// A typed write is one thing to its caller: through every door, a
    /// value that fails after it has written poisons the transaction. A
    /// body that swallows the error cannot commit half a value: the next
    /// write fails with `poisonedTransaction`, and so does the commit.
    @Test func aValueThatFailsAfterWritingPoisonsTheTransactionThroughEveryDoor() throws {
        for door in Self.doors {
            let storage = MemoryStorage()
            let database = try Database(creating: storage, hashing: SHA256.self)
            try database.withTransaction { root in try HashMap<ReadWrite>(root).put(UInt64(1), forKey: "before") }
            let committed = storage.bytes

            var failure: XitDBError?
            var next: XitDBError?
            #expect(throws: XitDBError.poisonedTransaction, "\(door.name)") {
                try database.withTransaction { root in
                    let moment = try HashMap<ReadWrite>(root)
                    do {
                        try door.write(moment, FailsAfterClearing())
                    } catch {
                        failure = error as? XitDBError
                    }
                    do {
                        try moment.put(UInt64(2), forKey: "after")
                    } catch {
                        next = error as? XitDBError
                    }
                }
            }
            #expect(failure == .keyNotFound, "\(door.name)")
            #expect(next == .poisonedTransaction, "\(door.name)")
            #expect(storage.bytes == committed, "\(door.name)")
            // The database goes on with the next transaction.
            try database.withTransaction { root in try HashMap<ReadWrite>(root).put(UInt64(3), forKey: "later") }
            #expect(
                try HashMap<ReadOnly>(database.rootCursor).value(forKey: "later", as: UInt64.self) == 3, "\(door.name)")
        }
    }

    /// A value that fails before it has written anything poisons nothing
    /// by itself: through a cursor nothing is written at all, and the
    /// transaction goes on. Through a collection it depends on whether the
    /// collection had written on the way to the value's place: an append
    /// and an insert have always made room, and a put has where the entry
    /// is new or its blocks are older than the transaction.
    @Test func aValueThatFailsBeforeWritingPoisonsOnlyWhereTheCollectionHadWritten() throws {
        /// Whether the transaction is poisoned after `door` was given a
        /// value that fails at once.
        func poisons(_ door: (HashMap<ReadWrite>) throws -> Void) throws -> Bool {
            let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
            var poisoned = false
            do {
                try database.withTransaction { root in
                    let moment = try HashMap<ReadWrite>(root)
                    #expect(throws: XitDBError.keyNotFound) { try door(moment) }
                    do {
                        try moment.put(UInt64(2), forKey: "after")
                    } catch XitDBError.poisonedTransaction {
                        poisoned = true
                    }
                }
            } catch XitDBError.poisonedTransaction {
                #expect(poisoned)
            }
            if !poisoned {
                #expect(try HashMap<ReadOnly>(database.rootCursor).value(forKey: "after", as: UInt64.self) == 2)
            }
            return poisoned
        }

        // Through a cursor: nothing is written before the value.
        #expect(
            try !poisons { moment in
                var cursor = try moment.putCursor(forKey: "cursor")
                try cursor.write(FailsAtOnce())
            })
        // A put where the entry is there already, in blocks the
        // transaction has written: the collection writes nothing first.
        #expect(
            try !poisons { moment in
                try moment.put(UInt64(1), forKey: "k")
                try moment.put(FailsAtOnce(), forKey: "k")
            })
        #expect(
            try !poisons { moment in
                let list = try ArrayList<ReadWrite>(moment.putCursor(forKey: "list"))
                try list.append(.uint(0))
                try list.put(FailsAtOnce(), at: 0)
            })
        // A put that makes the entry, an append and an insert: the
        // collection has grown by the time the value fails.
        #expect(try poisons { moment in try moment.put(FailsAtOnce(), forKey: "new") })
        #expect(
            try poisons { moment in
                try SortedMap<ReadWrite>(moment.putCursor(forKey: "sorted")).put(FailsAtOnce(), forKey: "new")
            })
        #expect(
            try poisons { moment in try ArrayList<ReadWrite>(moment.putCursor(forKey: "list")).append(FailsAtOnce()) })
        #expect(
            try poisons { moment in
                try LinkedArrayList<ReadWrite>(moment.putCursor(forKey: "linked")).append(FailsAtOnce())
            })
        #expect(
            try poisons { moment in
                let list = try LinkedArrayList<ReadWrite>(moment.putCursor(forKey: "linked"))
                try list.append(.uint(0))
                try list.insert(FailsAtOnce(), at: 0)
            })
    }

    /// The library's own values are told by their type alone. A type of
    /// the caller's that wraps one of them, or whose raw value is one, is
    /// the caller's: through every door it is written by its own
    /// `write(to:)`, and not as the value it wraps would be.
    @Test func aValueOfTheCallersThatWrapsOneOfTheLibrarysWritesWhatItSays() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { root in
            let moment = try HashMap<ReadWrite>(root)
            for door in Self.doors {
                try door.write(
                    try HashMap<ReadWrite>(moment.putCursor(forKey: "celsius, \(door.name)")), Celsius(degrees: 21))
                try door.write(try HashMap<ReadWrite>(moment.putCursor(forKey: "unit, \(door.name)")), Unit.second)
            }
        }
        struct NothingThere: Error {}
        func there(_ cursor: Cursor<ReadOnly>?) throws -> Cursor<ReadOnly> {
            guard let cursor else { throw NothingThere() }
            return cursor
        }
        /// The slot a door wrote the value into.
        func written(_ kind: String, _ door: String) throws -> Cursor<ReadOnly> {
            let moment = try HashMap<ReadOnly>(database.rootCursor)
            let place = try HashMap<ReadOnly>(try there(try moment.cursor(forKey: "\(kind), \(door)")))
            func under(_ name: String) throws -> Cursor<ReadOnly> { try there(try place.cursor(forKey: name)) }
            switch door {
            case "a cursor": return try under("cursor")
            case "a hash map": return try there(try HashMap<ReadOnly>(try under("map")).cursor(forKey: "k"))
            case "a counted hash map":
                return try there(try CountedHashMap<ReadOnly>(try under("counted")).cursor(forKey: "k"))
            case "a sorted map, by bytes":
                return try there(try SortedMap<ReadOnly>(try under("sorted")).cursor(forKey: "k"))
            case "a sorted map, by text":
                return try there(try SortedMap<ReadOnly>(try under("sorted 2")).cursor(forKey: "k"))
            case "a list's append": return try there(try ArrayList<ReadOnly>(try under("list")).cursor(at: 0))
            case "a list's put": return try there(try ArrayList<ReadOnly>(try under("list 2")).cursor(at: 0))
            case "a linked list's append":
                return try there(try LinkedArrayList<ReadOnly>(try under("linked")).cursor(at: 0))
            case "a linked list's put":
                return try there(try LinkedArrayList<ReadOnly>(try under("linked 2")).cursor(at: 0))
            default: return try there(try LinkedArrayList<ReadOnly>(try under("linked 3")).cursor(at: 0))
            }
        }
        for door in Self.doors {
            let celsius = try written("celsius", door.name)
            // A signed integer, as `Celsius` writes itself, not the
            // unsigned one a `UInt64` is.
            #expect(try celsius.slot.tag == .int, "\(door.name)")
            #expect(try celsius.readInt64() == 21, "\(door.name)")
            #expect(try celsius.read(Celsius.self) == Celsius(degrees: 21), "\(door.name)")
            #expect(throws: XitDBError.unexpectedTag, "\(door.name)") { try celsius.read(UInt64.self) }
            let unit = try written("unit", door.name)
            #expect(try unit.readBytesWithFormatTag() == Bytes(utf8("second"), formatTag: "un"), "\(door.name)")
            #expect(try unit.read(Unit.self) == .second, "\(door.name)")
        }
    }

    /// After a typed write the cursor is at what was written, as after a
    /// write of data: a record, which makes its map from a copy of the
    /// cursor it is given, reads back through the cursor that wrote it,
    /// and so does a number, below the root and at it.
    @Test func afterATypedWriteTheCursorIsAtWhatWasWritten() throws {
        let alice = Person(name: "Alice", age: 25)
        let team = Team(name: "A", members: [alice, Person(name: "Bob", age: 31)])
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { root in
            let map = try HashMap<ReadWrite>(root)

            var record = try map.putCursor(forKey: "record")
            try record.write(alice)
            #expect(try record.slot.tag == .hashMap)
            #expect(try record.slot == map.slot(forKey: "record"))
            #expect(try record.read(Person.self) == alice)
            // And again over the record that is there, and over a number.
            try record.write(team)
            #expect(try record.read(Team.self) == team)
            try record.write(UInt64(3))
            #expect(try record.read(UInt64.self) == 3)
            try record.write(alice)
            #expect(try record.read(Person.self) == alice)

            var number = try map.putCursor(forKey: "number")
            try number.write(UInt64(7))
            #expect(try number.slot.tag == .uint)
            #expect(try number.read(UInt64.self) == 7)
            var text = try map.putCursor(forKey: "text")
            try text.write(longText)
            #expect(try text.read(String.self) == longText)
            #expect(try text.slot == map.slot(forKey: "text"))
        }
        // At the root, where the cursor reads the root as it is.
        var root = database.rootCursor
        try root.write(alice)
        #expect(try root.read(Person.self) == alice)
        try root.write(UInt64(5))
        #expect(try root.read(UInt64.self) == 5)
    }

    // MARK: Reading

    /// What a slot of each kind reads as, as each type: its own type gives
    /// the value, bytes read as any of the three byte types, and every
    /// other pairing is `unexpectedTag`. A read is strict, as the cursor's
    /// read of the same kind is.
    @Test func aTypedReadIsStrictAboutTheKind() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let invalid: [UInt8] = [0x66, 0xFF, 0x6F]
        try database.withTransaction { root in
            let list = try ArrayList<ReadWrite>(root)
            try list.append(.uint(7))
            try list.append(.int(-7))
            try list.append(.double(2.5))
            try list.append(.bytes(utf8("text")))
            try list.append(.bytes(utf8("tagged"), formatTag: "tg"))
            try list.append(.bytes(invalid))
            try list.append(.slot(nil))
            _ = try HashMap<ReadWrite>(list.appendCursor())
            _ = try list.appendCursor()
        }
        let list = try ArrayList<ReadOnly>(database.rootCursor)

        /// Element `index` read as `type` is `expected`, or, where that is
        /// nil, is refused with `unexpectedTag`.
        func expect<Value: StorableValue & Equatable>(_ index: Int, _ type: Value.Type, _ expected: Value?) {
            let result = Result { try list.value(at: index, as: type) }
            switch (result, expected) {
            case (.success(let value), let expected?):
                #expect(value == expected, "element \(index) as \(type)")
            case (.failure(let error), nil):
                #expect(error as? XitDBError == .unexpectedTag, "element \(index) as \(type)")
            default:
                Issue.record("element \(index) as \(type) gave \(result)")
            }
        }
        // An unsigned integer.
        expect(0, UInt64.self, 7)
        expect(0, Int64.self, nil)
        expect(0, Double.self, nil)
        expect(0, String.self, nil)
        expect(0, [UInt8].self, nil)
        expect(0, Bytes.self, nil)
        // A signed integer.
        expect(1, UInt64.self, nil)
        expect(1, Int64.self, -7)
        expect(1, Double.self, nil)
        expect(1, String.self, nil)
        expect(1, [UInt8].self, nil)
        expect(1, Bytes.self, nil)
        // A float.
        expect(2, UInt64.self, nil)
        expect(2, Int64.self, nil)
        expect(2, Double.self, 2.5)
        expect(2, String.self, nil)
        expect(2, [UInt8].self, nil)
        expect(2, Bytes.self, nil)
        // Bytes that are text.
        expect(3, UInt64.self, nil)
        expect(3, Int64.self, nil)
        expect(3, Double.self, nil)
        expect(3, String.self, "text")
        expect(3, [UInt8].self, utf8("text"))
        expect(3, Bytes.self, Bytes(utf8("text")))
        // Tagged bytes: the two plain types read them whatever the tag,
        // and `Bytes` gives it.
        expect(4, String.self, "tagged")
        expect(4, [UInt8].self, utf8("tagged"))
        expect(4, Bytes.self, Bytes(utf8("tagged"), formatTag: "tg"))
        expect(4, UInt64.self, nil)
        // Bytes that are not UTF-8: an error as a string, themselves as
        // bytes.
        #expect(throws: XitDBError.invalidUTF8) { try list.value(at: 5, as: String.self) }
        expect(5, [UInt8].self, invalid)
        expect(5, Bytes.self, Bytes(invalid))
        // A slot set to nothing, and an element appended and never
        // written, which is one: no number, and as bytes the empty array,
        // which is what the cursor's read of bytes gives for it, here and
        // in the original.
        for index in [6, 8] {
            expect(index, UInt64.self, nil)
            expect(index, Int64.self, nil)
            expect(index, Double.self, nil)
            expect(index, String.self, "")
            expect(index, [UInt8].self, [])
            expect(index, Bytes.self, Bytes([]))
            #expect(try list.cursor(at: index)?.readBytes() == [])
        }
        // A collection: no value of any of these types.
        expect(7, UInt64.self, nil)
        expect(7, Int64.self, nil)
        expect(7, Double.self, nil)
        expect(7, String.self, nil)
        expect(7, [UInt8].self, nil)
        expect(7, Bytes.self, nil)
        // Past the end there is no element, which is `nil` and no error.
        #expect(try list.value(at: 9, as: UInt64.self) == nil)
        #expect(try list.value(at: -10, as: String.self) == nil)
        #expect(try list.value(at: -9, as: UInt64.self) == 7)
    }

    /// Every value reads back as it was written, through each typed read,
    /// with the type given and with the type left to the result.
    @Test func everyValueReadsBack() throws {
        let database = try Database(creating: MemoryStorage(), hashing: Insecure.SHA1.self, hashID: "sha1")
        try database.withTransaction { root in
            let top = try HashMap<ReadWrite>(root)
            let map = try HashMap<ReadWrite>(top.putCursor(forKey: "map"))
            let counted = try CountedHashMap<ReadWrite>(top.putCursor(forKey: "counted"))
            let sorted = try SortedMap<ReadWrite>(top.putCursor(forKey: "sorted"))
            let list = try ArrayList<ReadWrite>(top.putCursor(forKey: "list"))
            let linked = try LinkedArrayList<ReadWrite>(top.putCursor(forKey: "linked"))
            for (index, item) in cases.enumerated() {
                try map.put(item.value, forKey: "key \(index)")
                try counted.put(item.value, forKey: "key \(index)")
                try sorted.put(item.value, forKey: "key \(index)")
                try list.append(item.value)
                try linked.append(item.value)
            }
        }

        func check<Value: StorableValue & Equatable>(_ index: Int, _ expected: Value, in root: Cursor<ReadOnly>) throws
        {
            let top = try HashMap<ReadOnly>(root)
            let key = "key \(index)"
            let what = "\(cases[index].name)"
            let map = try HashMap<ReadOnly>(try #require(try top.cursor(forKey: "map")))
            #expect(try map.value(forKey: key, as: Value.self) == expected, "\(what) in a hash map")
            let inferred: Value? = try map.value(forKey: key)
            #expect(inferred == expected, "\(what), the type inferred")
            let counted = try CountedHashMap<ReadOnly>(try #require(try top.cursor(forKey: "counted")))
            #expect(try counted.value(forKey: key, as: Value.self) == expected, "\(what) in a counted map")
            let sorted = try SortedMap<ReadOnly>(try #require(try top.cursor(forKey: "sorted")))
            #expect(try sorted.value(forKey: key, as: Value.self) == expected, "\(what) in a sorted map by text")
            #expect(try sorted.value(forKey: utf8(key), as: Value.self) == expected, "\(what) in a sorted map by bytes")
            let list = try ArrayList<ReadOnly>(try #require(try top.cursor(forKey: "list")))
            #expect(try list.value(at: index, as: Value.self) == expected, "\(what) in a list")
            let last: Value? = try list.value(at: index - cases.count)
            #expect(last == expected, "\(what) in a list, counted from the end")
            let linked = try LinkedArrayList<ReadOnly>(try #require(try top.cursor(forKey: "linked")))
            #expect(try linked.value(at: index, as: Value.self) == expected, "\(what) in a linked list")
            // And through a cursor, of either access.
            let cursor = try #require(try map.cursor(forKey: key))
            #expect(try cursor.read(Value.self) == expected, "\(what) through a cursor")
            let read: Value = try cursor.read()
            #expect(read == expected)
        }
        // Live, and through a snapshot.
        for root in [Cursor<ReadOnly>(viewing: database.rootCursor), try database.snapshot().rootCursor] {
            try check(0, UInt64(7), in: root)
            try check(1, UInt64.max, in: root)
            try check(2, Int64(-7), in: root)
            try check(3, Int64.min, in: root)
            try check(4, 2.5, in: root)
            try check(5, 2.5, in: root)
            try check(6, "text", in: root)
            try check(7, "", in: root)
            try check(8, longText, in: root)
            try check(9, "\u{E9}t\u{E9}", in: root)
            try check(10, [UInt8]([1, 2, 3]), in: root)
            try check(11, [UInt8]([0, 255]), in: root)
            try check(12, [UInt8](repeating: 9, count: 100), in: root)
            try check(13, Bytes([4, 5]), in: root)
            try check(14, Bytes([4, 5], formatTag: "tg"), in: root)
            try check(15, Bytes([UInt8](repeating: 8, count: 50), formatTag: "tg"), in: root)
        }
        // A read-write cursor reads as well.
        try database.withTransaction { root in
            let top = try HashMap<ReadWrite>(root)
            var cursor = try top.putCursor(forKey: "scratch")
            try cursor.write("written")
            #expect(try cursor.read(String.self) == "written")
            try cursor.write(UInt64(3))
            #expect(try cursor.read(UInt64.self) == 3)
            #expect(throws: XitDBError.unexpectedTag) { try cursor.read(String.self) }
        }
    }

    /// Where there is no entry a typed read gives `nil`: a key the map does
    /// not have, a key whose value was never written, an index past the
    /// end.
    @Test func aTypedReadGivesNilWhereThereIsNoEntry() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { root in
            let top = try HashMap<ReadWrite>(root)
            _ = try top.putCursor(forKey: "unwritten")
            try top.put(UInt64(1), forKey: "one")
            let counted = try CountedHashMap<ReadWrite>(top.putCursor(forKey: "counted"))
            _ = try counted.putCursor(forKey: "unwritten")
            let sorted = try SortedMap<ReadWrite>(top.putCursor(forKey: "sorted"))
            _ = try sorted.putCursor(forKey: "unwritten")
            _ = try ArrayList<ReadWrite>(top.putCursor(forKey: "list"))
            _ = try LinkedArrayList<ReadWrite>(top.putCursor(forKey: "linked"))
        }
        let top = try HashMap<ReadOnly>(database.rootCursor)
        #expect(try top.value(forKey: "absent", as: UInt64.self) == nil)
        #expect(try top.value(forKey: "unwritten", as: String.self) == nil)
        #expect(try top.value(forKey: "one", as: UInt64.self) == 1)
        let counted = try CountedHashMap<ReadOnly>(try #require(try top.cursor(forKey: "counted")))
        #expect(try counted.value(forKey: "absent", as: UInt64.self) == nil)
        #expect(try counted.value(forKey: "unwritten", as: UInt64.self) == nil)
        let sorted = try SortedMap<ReadOnly>(try #require(try top.cursor(forKey: "sorted")))
        #expect(try sorted.value(forKey: "absent", as: Double.self) == nil)
        #expect(try sorted.value(forKey: "unwritten", as: Double.self) == nil)
        #expect(try sorted.value(forKey: utf8("absent"), as: Double.self) == nil)
        let list = try ArrayList<ReadOnly>(try #require(try top.cursor(forKey: "list")))
        #expect(try list.value(at: 0, as: String.self) == nil)
        #expect(try list.value(at: -1, as: String.self) == nil)
        let linked = try LinkedArrayList<ReadOnly>(try #require(try top.cursor(forKey: "linked")))
        #expect(try linked.value(at: 0, as: String.self) == nil)
    }

    /// What a typed read gives where there is no value, case by case and
    /// type by type. Where there is nothing under the key or at the index,
    /// it is `nil` for every type: no entry, an entry of a map whose value
    /// was never written, an index past the end. Where there is a slot set
    /// to nothing, it is the cursor's read of that slot, as in the
    /// original: empty as a `String`, a `[UInt8]` or `Bytes`, and
    /// `unexpectedTag` as a number. A value cleared with `.slot(nil)` is
    /// such a slot, and so is a list element appended and never written.
    @Test func whereThereIsNoValueAReadIsNilOrEmptyOrRefused() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { root in
            let top = try HashMap<ReadWrite>(root)
            let map = try HashMap<ReadWrite>(top.putCursor(forKey: "map"))
            _ = try map.putCursor(forKey: "unwritten")
            try map.put(.slot(nil), forKey: "cleared")
            try map.put("was text", forKey: "cleared later")
            try map.put(.slot(nil), forKey: "cleared later")
            let counted = try CountedHashMap<ReadWrite>(top.putCursor(forKey: "counted"))
            _ = try counted.putCursor(forKey: "unwritten")
            try counted.put(.slot(nil), forKey: "cleared")
            let sorted = try SortedMap<ReadWrite>(top.putCursor(forKey: "sorted"))
            _ = try sorted.putCursor(forKey: "unwritten")
            try sorted.put(.slot(nil), forKey: "cleared")
            let list = try ArrayList<ReadWrite>(top.putCursor(forKey: "list"))
            _ = try list.appendCursor()
            try list.append(.slot(nil))
            try list.append(UInt64(1))
            try list.put(.slot(nil), at: 2)
            let linked = try LinkedArrayList<ReadWrite>(top.putCursor(forKey: "linked"))
            _ = try linked.appendCursor()
            try linked.append(.slot(nil))
        }

        /// Nothing under the key or at the index: `nil`, whatever the type.
        func expectNil(_ place: some TypedPlace, _ what: String) throws {
            #expect(try place.read(String.self) == nil, "\(what) as String")
            #expect(try place.read([UInt8].self) == nil, "\(what) as [UInt8]")
            #expect(try place.read(Bytes.self) == nil, "\(what) as Bytes")
            #expect(try place.read(UInt64.self) == nil, "\(what) as UInt64")
            #expect(try place.read(Int64.self) == nil, "\(what) as Int64")
            #expect(try place.read(Double.self) == nil, "\(what) as Double")
        }
        /// A slot set to nothing: empty as bytes, refused as a number.
        func expectEmpty(_ place: some TypedPlace, _ what: String) throws {
            #expect(try place.read(String.self) == "", "\(what) as String")
            #expect(try place.read([UInt8].self) == [], "\(what) as [UInt8]")
            #expect(try place.read(Bytes.self) == Bytes([]), "\(what) as Bytes")
            #expect(throws: XitDBError.unexpectedTag, "\(what) as UInt64") { try place.read(UInt64.self) }
            #expect(throws: XitDBError.unexpectedTag, "\(what) as Int64") { try place.read(Int64.self) }
            #expect(throws: XitDBError.unexpectedTag, "\(what) as Double") { try place.read(Double.self) }
        }

        for (root, view) in [
            (Cursor<ReadOnly>(viewing: database.rootCursor), "live"), (try database.snapshot().rootCursor, "snapshot"),
        ] {
            let top = try HashMap<ReadOnly>(root)
            let map = try HashMap<ReadOnly>(try #require(try top.cursor(forKey: "map")))
            try expectNil(InHashMap(map: map, key: "absent"), "\(view): a hash map, no entry")
            try expectNil(InHashMap(map: map, key: "unwritten"), "\(view): a hash map, an entry never written")
            try expectEmpty(InHashMap(map: map, key: "cleared"), "\(view): a hash map, a value set to nothing")
            try expectEmpty(InHashMap(map: map, key: "cleared later"), "\(view): a hash map, a value cleared")
            // The slot tells what the typed read as a string cannot: there
            // is an entry, and it holds nothing.
            #expect(try map.slot(forKey: "cleared")?.tag == Tag.none)
            #expect(try map.slot(forKey: "unwritten") == nil)

            let counted = try CountedHashMap<ReadOnly>(try #require(try top.cursor(forKey: "counted")))
            try expectNil(InCountedHashMap(map: counted, key: "absent"), "\(view): a counted map, no entry")
            try expectNil(InCountedHashMap(map: counted, key: "unwritten"), "\(view): a counted map, never written")
            try expectEmpty(InCountedHashMap(map: counted, key: "cleared"), "\(view): a counted map, set to nothing")

            let sorted = try SortedMap<ReadOnly>(try #require(try top.cursor(forKey: "sorted")))
            try expectNil(InSortedMapByText(map: sorted, key: "absent"), "\(view): a sorted map, no entry")
            try expectNil(InSortedMapByText(map: sorted, key: "unwritten"), "\(view): a sorted map, never written")
            try expectEmpty(InSortedMapByText(map: sorted, key: "cleared"), "\(view): a sorted map, set to nothing")
            try expectNil(InSortedMapByBytes(map: sorted, key: "absent"), "\(view): a sorted map by bytes, no entry")
            try expectNil(InSortedMapByBytes(map: sorted, key: "unwritten"), "\(view): by bytes, never written")
            try expectEmpty(InSortedMapByBytes(map: sorted, key: "cleared"), "\(view): by bytes, set to nothing")

            let list = try ArrayList<ReadOnly>(try #require(try top.cursor(forKey: "list")))
            try expectEmpty(InArrayList(list: list, index: 0), "\(view): a list, appended and never written")
            try expectEmpty(InArrayList(list: list, index: 1), "\(view): a list, an element set to nothing")
            try expectEmpty(InArrayList(list: list, index: 2), "\(view): a list, an element cleared")
            try expectNil(InArrayList(list: list, index: 3), "\(view): a list, past the end")
            try expectNil(InArrayList(list: list, index: -4), "\(view): a list, before the start")
            try expectEmpty(
                ThroughACursor(cursor: try #require(try list.cursor(at: 0))), "\(view): the element's cursor")

            let linked = try LinkedArrayList<ReadOnly>(try #require(try top.cursor(forKey: "linked")))
            try expectEmpty(InLinkedArrayList(list: linked, index: 0), "\(view): a linked list, never written")
            try expectEmpty(InLinkedArrayList(list: linked, index: 1), "\(view): a linked list, set to nothing")
            try expectNil(InLinkedArrayList(list: linked, index: 2), "\(view): a linked list, past the end")
        }
    }

    // MARK: A record

    /// A type of the caller's that writes itself as a map goes into a list
    /// and into a map, and reads back through `value(at:as:)` and
    /// `value(forKey:as:)`; so does a record of records.
    @Test func aRecordGoesIntoAListAndAMap() throws {
        let alice = Person(name: "Alice", age: 25)
        let bob = Person(name: "Bob", age: 31)
        let team = Team(name: "A", members: [alice, bob])
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self, hashID: "sha2")
        try database.withTransaction { root in
            let top = try HashMap<ReadWrite>(root)
            let people = try ArrayList<ReadWrite>(top.putCursor(forKey: "people"))
            try people.append(alice)
            try people.append(bob)
            let byName = try HashMap<ReadWrite>(top.putCursor(forKey: "by name"))
            try byName.put(alice, forKey: alice.name)
            try byName.put(bob, forKey: bob.name)
            let counted = try CountedHashMap<ReadWrite>(top.putCursor(forKey: "counted"))
            try counted.put(alice, forKey: "first")
            let sorted = try SortedMap<ReadWrite>(top.putCursor(forKey: "sorted"))
            try sorted.put(bob, forKey: "bob")
            try sorted.put(alice, forKey: utf8("alice"))
            let linked = try LinkedArrayList<ReadWrite>(top.putCursor(forKey: "linked"))
            try linked.append(bob)
            try linked.insert(alice, at: 0)
            try top.put(team, forKey: "team")
            var cursor = try top.putCursor(forKey: "through a cursor")
            try cursor.write(alice)
        }

        for root in [Cursor<ReadOnly>(viewing: database.rootCursor), try database.snapshot().rootCursor] {
            let top = try HashMap<ReadOnly>(root)
            let people = try ArrayList<ReadOnly>(try #require(try top.cursor(forKey: "people")))
            #expect(try people.value(at: 0, as: Person.self) == alice)
            #expect(try people.value(at: 1, as: Person.self) == bob)
            #expect(try people.value(at: 2, as: Person.self) == nil)
            let byName = try HashMap<ReadOnly>(try #require(try top.cursor(forKey: "by name")))
            #expect(try byName.value(forKey: "Alice", as: Person.self) == alice)
            #expect(try byName.value(forKey: "Bob", as: Person.self) == bob)
            #expect(try byName.value(forKey: "Carol", as: Person.self) == nil)
            let counted = try CountedHashMap<ReadOnly>(try #require(try top.cursor(forKey: "counted")))
            #expect(try counted.value(forKey: "first", as: Person.self) == alice)
            let sorted = try SortedMap<ReadOnly>(try #require(try top.cursor(forKey: "sorted")))
            #expect(try sorted.value(forKey: "alice", as: Person.self) == alice)
            #expect(try sorted.value(forKey: utf8("bob"), as: Person.self) == bob)
            let linked = try LinkedArrayList<ReadOnly>(try #require(try top.cursor(forKey: "linked")))
            #expect(try linked.value(at: 0, as: Person.self) == alice)
            #expect(try linked.value(at: 1, as: Person.self) == bob)
            #expect(try top.value(forKey: "team", as: Team.self) == team)
            #expect(try top.cursor(forKey: "through a cursor")?.read(Person.self) == alice)
            // A record is what its conformance wrote: a map, whose fields
            // any reader finds by their names.
            let fields = try HashMap<ReadOnly>(try #require(try people.cursor(at: 0)))
            #expect(try fields.value(forKey: "name", as: String.self) == "Alice")
            #expect(try fields.cursor(forKey: "age")?.readUInt64() == 25)
            // And a number is not a record.
            #expect(throws: XitDBError.unexpectedTag) { try fields.value(forKey: "age", as: Person.self) }
        }
    }

    /// A record written over a value takes its place, of whatever kind the
    /// value was, since this record clears the slot first.
    @Test func aRecordReplacesWhatWasThere() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let alice = Person(name: "Alice", age: 25)
        try database.withTransaction { root in
            let top = try HashMap<ReadWrite>(root)
            try top.put(UInt64(1), forKey: "slot")
            try top.put(alice, forKey: "slot")
            #expect(try top.value(forKey: "slot", as: Person.self) == alice)
            try top.put("text", forKey: "slot")
            #expect(try top.value(forKey: "slot", as: String.self) == "text")
            let list = try ArrayList<ReadWrite>(top.putCursor(forKey: "list"))
            try list.append(Int64(-1))
            try list.put(alice, at: 0)
            #expect(try list.value(at: 0, as: Person.self) == alice)
            try list.put(Person(name: "Bob", age: 31), at: 0)
            #expect(try list.value(at: 0, as: Person.self) == Person(name: "Bob", age: 31))
        }
    }

    // MARK: Without a hasher

    /// The typed calls of the hashed maps need the hasher, as every keyed
    /// call does; those of the lists and of the sorted map do not. A
    /// record that writes itself through keys cannot be written to a
    /// database without a hasher, and the transaction it was written in
    /// does not commit.
    @Test func withoutAHasherTheTypedCallsOfHashedMapsAreRefused() throws {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashSize: 20)
        try database.withTransaction { root in
            let top = try HashMap<ReadWrite>(root)
            #expect(throws: XitDBError.noKeyHashing) { try top.put("value", forKey: "key") }
            #expect(throws: XitDBError.noKeyHashing) { try top.value(forKey: "key", as: String.self) }
            let counted = try CountedHashMap<ReadWrite>(top.putCursor(forHash: hashInt("counted")))
            #expect(throws: XitDBError.noKeyHashing) { try counted.put(UInt64(1), forKey: "key") }
            #expect(throws: XitDBError.noKeyHashing) { try counted.value(forKey: "key", as: UInt64.self) }

            let list = try ArrayList<ReadWrite>(top.putCursor(forHash: hashInt("list")))
            try list.append("text")
            try list.append(UInt64(2))
            try list.put(Int64(-3), at: 1)
            #expect(try list.value(at: 0, as: String.self) == "text")
            #expect(try list.value(at: 1, as: Int64.self) == -3)
            let linked = try LinkedArrayList<ReadWrite>(top.putCursor(forHash: hashInt("linked")))
            try linked.append(2.5)
            try linked.insert("first", at: 0)
            #expect(try linked.value(at: 1, as: Double.self) == 2.5)
            let sorted = try SortedMap<ReadWrite>(top.putCursor(forHash: hashInt("sorted")))
            try sorted.put("value", forKey: "key")
            try sorted.put(UInt64(9), forKey: utf8("bytes"))
            #expect(try sorted.value(forKey: "key", as: String.self) == "value")
            #expect(try sorted.value(forKey: utf8("bytes"), as: UInt64.self) == 9)
        }
        let committed = storage.bytes

        // The record's own puts are keyed. The list has grown by the time
        // they are refused, so the transaction is poisoned and rolls back.
        #expect(throws: XitDBError.noKeyHashing) {
            try database.withTransaction { root in
                let top = try HashMap<ReadWrite>(root)
                let list = try ArrayList<ReadWrite>(top.putCursor(forHash: hashInt("list")))
                try list.append(Person(name: "Alice", age: 25))
            }
        }
        #expect(storage.bytes == committed)
        // A body that swallows the refusal cannot commit either.
        var refusal: XitDBError?
        #expect(throws: XitDBError.poisonedTransaction) {
            try database.withTransaction { root in
                let top = try HashMap<ReadWrite>(root)
                let list = try ArrayList<ReadWrite>(top.putCursor(forHash: hashInt("list")))
                do {
                    try list.append(Person(name: "Alice", age: 25))
                } catch {
                    refusal = error as? XitDBError
                }
            }
        }
        #expect(refusal == .noKeyHashing)
        #expect(storage.bytes == committed)
    }

    /// A typed write throws what the write of data throws.
    @Test func aTypedWriteThrowsWhatTheWriteOfDataThrows() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let top = try HashMap<ReadWrite>(database.rootCursor)
        let list = try ArrayList<ReadWrite>(unchecked: top.putCursor(forKey: "list"))
        // Below the root and outside a transaction.
        #expect(throws: XitDBError.expectedTxStart) { try list.append("text") }
        let below = try HashMap<ReadWrite>(unchecked: top.putCursor(forKey: "map"))
        #expect(throws: XitDBError.expectedTxStart) { try below.put("text", forKey: "key") }
        try database.withTransaction { root in
            let top = try HashMap<ReadWrite>(root)
            let list = try ArrayList<ReadWrite>(top.putCursor(forKey: "list"))
            try list.append("only")
            // An index that names no element.
            #expect(throws: XitDBError.indexOutOfRange) { try list.put("text", at: 1) }
            #expect(throws: XitDBError.indexOutOfRange) { try list.put("text", at: -2) }
            let linked = try LinkedArrayList<ReadWrite>(top.putCursor(forKey: "linked"))
            #expect(throws: XitDBError.indexOutOfRange) { try linked.put("text", at: 0) }
            #expect(throws: XitDBError.indexOutOfRange) { try linked.insert("text", at: 1) }
        }
    }

    // MARK: Int

    /// `Int` is no value: the compiler refuses every use of it as one,
    /// which `scripts/must-not-compile.sh` holds. What reaches the
    /// conformance while the program runs, through a cast the compiler
    /// cannot see into, gets an error and no trap, and writes nothing.
    @Test func anIntThatReachesTheConformanceIsRefused() throws {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashing: SHA256.self)
        try ArrayList<ReadWrite>(database.rootCursor).append(Int64(25))
        let hidden: Any = 25
        // A runtime that does not find an unavailable conformance has
        // nothing to refuse.
        guard let value = hidden as? any StorableValue else { return }
        let committed = storage.bytes

        let element = try #require(try ArrayList<ReadOnly>(database.rootCursor).cursor(at: 0))
        #expect(throws: XitDBError.unexpectedTag) { try type(of: value).init(reading: element) }
        #expect(throws: XitDBError.unexpectedTag) {
            try database.withTransaction { root in
                var cursor = root
                try value.write(to: &cursor)
            }
        }
        #expect(throws: XitDBError.unexpectedTag) {
            try ArrayList<ReadWrite>(database.rootCursor).append(value)
        }
        #expect(storage.bytes == committed)
    }
}
