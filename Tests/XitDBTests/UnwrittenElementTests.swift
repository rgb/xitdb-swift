import Foundation
import Testing

@testable import XitDB

/// An element of an array list that was appended and never written (the
/// original's `89da8e7`, decision D31): the append leaves its slot set to
/// nothing and marked full, so the element counts, a lookup finds it and the
/// iterator gives it, as a linked array list's always did. A file written
/// before that holds a truly empty slot there, for which the port keeps its
/// own rules: a lookup finds nothing, and the iterator passes over it and
/// stops at the list's size.
@Suite struct UnwrittenElementTests {
    /// What an append leaves in the storage for an element nobody writes.
    static let setToNothing = Slot(tag: .none, full: true)

    /// A database of a version whose root is a map with a list under
    /// "list": 1, an element appended and never written, 3. Returns the
    /// position of the unwritten element's slot.
    static func makeList(_ version: FormatVersion, in storage: any WritableStorage) throws -> (
        database: Database, unwritten: UInt64
    ) {
        let database = try newDatabase(version, in: storage, random: FixedRandom(FormatVersionTests.commitIDs))
        var position: UInt64?
        try database.withTransaction { cursor in
            let root = try HashMap<ReadWrite>(cursor)
            let list = try ArrayList<ReadWrite>(try root.putCursor(forHash: sha1("list").bytes))
            try list.append(.uint(1))
            let unwritten = try list.appendCursor()
            // the cursor's own copy is empty, as the original's is
            #expect(try unwritten.slot.isEmpty)
            position = unwritten.slotPointer.position
            try list.append(.uint(3))
        }
        return (database, try #require(position))
    }

    static func list(_ database: Database) throws -> ArrayList<ReadOnly> {
        let root = try HashMap<ReadOnly>(database.rootCursor.readOnly)
        return try ArrayList<ReadOnly>(try #require(try root.cursor(forHash: sha1("list").bytes)))
    }

    /// The tags of the elements an iterator gives.
    static func tags(_ iterator: CollectionIterator) throws -> [Tag] {
        var iterator = iterator
        var tags: [Tag] = []
        while let cursor = try iterator.next() {
            tags.append(try cursor.slot.tag)
        }
        return tags
    }

    /// In the storage the unwritten element is a slot set to nothing: the
    /// tag byte's full bit and eight zero bytes. It counts, a lookup gives
    /// a cursor at it and its slot, a typed read of it is `unexpectedTag`,
    /// and the iterator gives it between its neighbours, from the start and
    /// from any index.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func anElementAppendedAndNeverWrittenIsSetToNothing(kind: StorageKind, version: FormatVersion) throws {
        let subject = try StorageUnderTest(kind)
        let (database, position) = try Self.makeList(version, in: subject.storage)
        #expect(try readBytes(subject.storage, at: position, count: 9) == [0x80] + zeros(8))
        #expect(slotBytes(Self.setToNothing) == [0x80] + zeros(8))

        for reading in [database, try Database(opening: subject.storage, hashSize: 20)] {
            let list = try Self.list(reading)
            #expect(try list.count == 3)
            #expect(try list.slot(at: 0) == Slot(value: 1, tag: .uint))
            #expect(try list.slot(at: 1) == Self.setToNothing)
            #expect(try list.slot(at: -2) == Self.setToNothing)
            #expect(try list.slot(at: 2) == Slot(value: 3, tag: .uint))
            let element = try #require(try list.cursor(at: 1))
            #expect(try element.slot == Self.setToNothing)
            #expect(try !element.slot.isEmpty)
            #expect(throws: XitDBError.unexpectedTag) { try element.readUInt64() }

            #expect(try Self.tags(try list.iterator()) == [.uint, .none, .uint])
            #expect(try Self.tags(try list.iterator(fromIndex: 1)) == [.none, .uint])
            #expect(try Self.tags(try list.iterator(fromIndex: 2)) == [.uint])
            #expect(try Self.tags(try list.iterator(fromIndex: -2)) == [.none, .uint])
        }
    }

    /// The element can be written later like any other, through a cursor at
    /// it, and a value written before the path's end goes over the
    /// placeholder.
    @Test(arguments: FormatVersion.allCases)
    func theElementIsWrittenLaterLikeAnyOther(version: FormatVersion) throws {
        let storage = MemoryStorage()
        let (database, _) = try Self.makeList(version, in: storage)
        try database.withTransaction { cursor in
            let root = try HashMap<ReadWrite>(cursor)
            let list = try ArrayList<ReadWrite>(try root.putCursor(forHash: sha1("list").bytes))
            try list.put(.uint(2), at: 1)
            // an append that is written at once never shows the placeholder
            try list.append(.bytes(Array("four".utf8)))
            // and one that makes a collection in the new element
            let inner = try ArrayList<ReadWrite>(try list.appendCursor())
            try inner.append(.uint(50))
        }
        let list = try Self.list(database)
        #expect(try list.count == 5)
        #expect(try list.cursor(at: 1)?.readUInt64() == 2)
        #expect(try list.cursor(at: 3)?.readBytes() == Array("four".utf8))
        #expect(try Self.tags(try list.iterator()) == [.uint, .uint, .uint, .shortBytes, .arrayList])
        let inner = try ArrayList<ReadOnly>(try #require(try list.cursor(at: 4)))
        #expect(try inner.cursor(at: 0)?.readUInt64() == 50)
    }

    /// A file written before the change holds a truly empty slot where an
    /// element was appended and never written: the same bytes with the full
    /// bit clear. There the port keeps its own rules. The element counts, a
    /// lookup finds nothing, and the iterator passes over it and stops at
    /// the list's size, where the original's counts the elements it gives
    /// and so reads one past the end of a list that was cut down.
    @Test(arguments: StorageKind.allCases, FormatVersion.allCases)
    func aTrulyEmptySlotInAnOlderFileKeepsThePortsRules(kind: StorageKind, version: FormatVersion) throws {
        let subject = try StorageUnderTest(kind)
        let (_, position) = try Self.makeList(version, in: subject.storage)
        // as a file written before the change has it
        try writeBytes(subject.storage, zeros(9), at: position)
        try subject.storage.flush()

        let database = try Database(opening: subject.storage, hashSize: 20)
        let list = try Self.list(database)
        #expect(try list.count == 3)
        #expect(try list.slot(at: 1) == nil)
        #expect(try list.cursor(at: 1) == nil)
        #expect(try Self.tags(try list.iterator()) == [.uint, .uint])
        #expect(try Self.tags(try list.iterator(fromIndex: 1)) == [.uint])

        // cut down to two elements, the walk stops at the size and does not
        // give the third, which is still in the list's blocks
        try database.withTransaction { cursor in
            let root = try HashMap<ReadWrite>(cursor)
            let list = try ArrayList<ReadWrite>(try root.putCursor(forHash: sha1("list").bytes))
            try list.truncate(to: 2)
        }
        let cut = try Self.list(database)
        #expect(try cut.count == 2)
        #expect(try Self.tags(try cut.iterator()) == [.uint])
    }

    // MARK: Compaction

    /// A history whose last moment was appended and never written. Returns
    /// the position of that moment's slot.
    static func makeHistory(_ version: FormatVersion, in storage: any WritableStorage) throws -> (
        database: Database, unwritten: UInt64
    ) {
        let database = try newDatabase(version, in: storage, random: FixedRandom(FormatVersionTests.commitIDs))
        try FormatVersionTests.commit(database, 1)
        let moment = try ArrayList<ReadWrite>(database.rootCursor).appendCursor()
        return (database, try #require(moment.slotPointer.position))
    }

    /// A last moment appended and never written is, in the storage, a
    /// moment set to nothing, which compacts: the target's one moment is
    /// set to nothing. It is not `emptyLastMoment` any more, which the
    /// original raised for nothing either.
    @Test(arguments: FormatVersion.allCases)
    func aLastMomentThatWasNeverWrittenCompacts(version: FormatVersion) throws {
        let storage = MemoryStorage()
        let (database, _) = try Self.makeHistory(version, in: storage)
        let history = try ArrayList<ReadOnly>(database.rootCursor.readOnly)
        #expect(try history.count == 2)
        #expect(try history.slot(at: -1) == Self.setToNothing)

        let target = MemoryStorage()
        var offsets = MemoryOffsetMap()
        let compacted = try database.compact(into: target, fileID: 0x20, offsetMap: &offsets)
        let moments = try ArrayList<ReadOnly>(compacted.rootCursor.readOnly)
        #expect(try moments.count == 1)
        #expect(try moments.slot(at: 0) == Self.setToNothing)
        #expect(try Self.tags(try moments.iterator()) == [.none])

        // the same target as for a last moment set to nothing on purpose
        let explicitStorage = MemoryStorage()
        let explicit = try newDatabase(
            version, in: explicitStorage, random: FixedRandom(FormatVersionTests.commitIDs))
        try FormatVersionTests.commit(explicit, 1)
        try ArrayList<ReadWrite>(explicit.rootCursor).append(.slot(nil))
        let explicitTarget = MemoryStorage()
        _ = try explicit.compact(into: explicitTarget, fileID: 0x20, offsetMap: &offsets)
        #expect(firstDifference(target.bytes, explicitTarget.bytes) == nil)
    }

    /// The refusal stays for what it was defined for: a history with no
    /// moment, and a last moment whose slot is truly empty, which only a
    /// file written before the change holds. Nothing is written, the target
    /// included.
    @Test(arguments: FormatVersion.allCases)
    func anEmptyHistoryAndATrulyEmptyLastMomentAreStillRefused(version: FormatVersion) throws {
        var offsets = MemoryOffsetMap()

        let emptyStorage = MemoryStorage()
        let empty = try newDatabase(version, in: emptyStorage, random: FixedRandom(FormatVersionTests.commitIDs))
        _ = try ArrayList<ReadWrite>(empty.rootCursor)
        #expect(try ArrayList<ReadOnly>(empty.rootCursor.readOnly).count == 0)
        let untouched = MemoryStorage()
        #expect(throws: XitDBError.emptyLastMoment) {
            try empty.compact(into: untouched, fileID: 0x20, offsetMap: &offsets)
        }
        #expect(untouched.bytes.isEmpty)

        let storage = MemoryStorage()
        let (_, position) = try Self.makeHistory(version, in: storage)
        var older = storage.bytes
        older.replaceSubrange(Int(position)..<Int(position + 9), with: zeros(9))
        let database = try Database(opening: MemoryStorage(bytes: older), hashSize: 20)
        let history = try ArrayList<ReadOnly>(database.rootCursor.readOnly)
        #expect(try history.count == 2)
        #expect(try history.slot(at: -1) == nil)
        #expect(throws: XitDBError.emptyLastMoment) {
            try database.compact(into: untouched, fileID: 0x20, offsetMap: &offsets)
        }
        #expect(untouched.bytes.isEmpty)
    }
}

/// `writeIfEmpty` (finding 17 as refined with brief package-28): it goes by
/// the slot as it is now. It writes when the slot is empty, and when the
/// cursor was made on an empty slot and the slot is set to nothing now,
/// which is what an append or an insert leaves for the element it hands a
/// cursor to; it holds back when the slot holds a value, and when the
/// cursor was made on a slot that held something.
@Suite struct WriteIfEmptyTests {
    private func makeDatabase(_ kind: StorageKind) throws -> (StorageUnderTest, Database) {
        let subject = try StorageUnderTest(kind)
        let database = try Database(
            storage: subject.storage, hashSize: 20, hashID: nil, fileID: 4,
            random: FixedRandom((1...20).map { UInt64($0) }))
        return (subject, database)
    }

    private func map(_ database: Database) throws -> HashMap<ReadOnly> {
        try HashMap<ReadOnly>(database.rootCursor.readOnly)
    }

    /// The cursor an append or an insert hands back is at an element that
    /// nobody has written: `writeIfEmpty` through it writes, on both kinds
    /// of list, and a second one through the same cursor holds back. In
    /// 0.2.1 the linked list's two wrote nothing.
    @Test(arguments: StorageKind.allCases)
    func anAppendedOrInsertedElementIsWritten(kind: StorageKind) throws {
        let (_, database) = try makeDatabase(kind)
        try database.withTransaction { cursor in
            let root = try HashMap<ReadWrite>(cursor)

            let array = try ArrayList<ReadWrite>(try root.putCursor(forHash: sha1("array").bytes))
            var appended = try array.appendCursor()
            try appended.writeIfEmpty(.uint(7))
            try appended.writeIfEmpty(.uint(70))
            #expect(try appended.slot == Slot(value: 7, tag: .uint))

            let linked = try LinkedArrayList<ReadWrite>(try root.putCursor(forHash: sha1("linked").bytes))
            var linkedAppended = try linked.appendCursor()
            try linkedAppended.writeIfEmpty(.uint(8))
            try linkedAppended.writeIfEmpty(.uint(80))
            var inserted = try linked.insertCursor(at: 0)
            try inserted.writeIfEmpty(.bytes(Array("a longer value".utf8)))
            try inserted.writeIfEmpty(.uint(90))
        }
        let root = try map(database)
        let array = try ArrayList<ReadOnly>(try #require(try root.cursor(forHash: sha1("array").bytes)))
        #expect(try array.count == 1)
        #expect(try array.cursor(at: 0)?.readUInt64() == 7)
        let linked = try LinkedArrayList<ReadOnly>(try #require(try root.cursor(forHash: sha1("linked").bytes)))
        #expect(try linked.count == 2)
        #expect(try linked.cursor(at: 0)?.readBytes() == Array("a longer value".utf8))
        #expect(try linked.cursor(at: 1)?.readUInt64() == 8)
    }

    /// Two cursors at one empty slot. A value written through the second is
    /// kept by a `writeIfEmpty` through the first, which goes by the slot
    /// as it is now and not by its own copy, where the original overwrites
    /// it.
    @Test(arguments: StorageKind.allCases)
    func aValueWrittenSinceThroughAnotherCursorIsKept(kind: StorageKind) throws {
        let (_, database) = try makeDatabase(kind)
        try database.withTransaction { cursor in
            let root = try HashMap<ReadWrite>(cursor)
            var first = try root.putCursor(forHash: sha1("k").bytes)
            var second = try root.putCursor(forHash: sha1("k").bytes)
            #expect(try first.slot.isEmpty)
            try second.write(.uint(5))
            try first.writeIfEmpty(.uint(7))
        }
        #expect(try map(database).cursor(forHash: sha1("k").bytes)?.readUInt64() == 5)
    }

    /// What the rule gives up: a cursor made on an empty slot, and the slot
    /// set to nothing since through another cursor. In the storage that is
    /// what an append leaves for an element nobody has written, so it
    /// cannot be told from one, and `writeIfEmpty` writes over it.
    @Test(arguments: StorageKind.allCases)
    func aSlotSetToNothingSinceIsWrittenOver(kind: StorageKind) throws {
        let (_, database) = try makeDatabase(kind)
        try database.withTransaction { cursor in
            let root = try HashMap<ReadWrite>(cursor)
            var first = try root.putCursor(forHash: sha1("k").bytes)
            var second = try root.putCursor(forHash: sha1("k").bytes)
            try second.write(.slot(nil))
            #expect(try second.slot == Slot(tag: .none, full: true))
            try first.writeIfEmpty(.uint(7))
        }
        #expect(try map(database).cursor(forHash: sha1("k").bytes)?.readUInt64() == 7)
    }

    /// A cursor made on a slot that had been set to nothing holds back: a
    /// slot set to nothing is not empty. So does one made on a value, even
    /// when the slot was set to nothing since.
    @Test(arguments: StorageKind.allCases)
    func aCursorMadeOnASlotThatHeldSomethingHoldsBack(kind: StorageKind) throws {
        let (_, database) = try makeDatabase(kind)
        try database.withTransaction { cursor in
            let root = try HashMap<ReadWrite>(cursor)
            try root.put(.slot(nil), forHash: sha1("nothing").bytes)
            try root.put(.uint(1), forHash: sha1("value").bytes)
        }
        try database.withTransaction { cursor in
            let root = try HashMap<ReadWrite>(cursor)
            var onNothing = try root.putCursor(forHash: sha1("nothing").bytes)
            #expect(try onNothing.slot == Slot(tag: .none, full: true))
            try onNothing.writeIfEmpty(.uint(7))

            var onValue = try root.putCursor(forHash: sha1("value").bytes)
            var other = try root.putCursor(forHash: sha1("value").bytes)
            try other.write(.slot(nil))
            try onValue.writeIfEmpty(.uint(7))
        }
        let root = try map(database)
        #expect(try root.cursor(forHash: sha1("nothing").bytes)?.slot == Slot(tag: .none, full: true))
        #expect(try root.cursor(forHash: sha1("value").bytes)?.slot == Slot(tag: .none, full: true))
    }

    /// A map's `putCursor` is at a truly empty slot for a new key, and at
    /// the value for an old one: nothing changes there.
    @Test(arguments: StorageKind.allCases)
    func aMapsPutCursorIsAsItWas(kind: StorageKind) throws {
        let (_, database) = try makeDatabase(kind)
        try database.withTransaction { cursor in
            let root = try HashMap<ReadWrite>(cursor)
            var new = try root.putCursor(forHash: sha1("new").bytes)
            try new.writeIfEmpty(.uint(1))
            var again = try root.putCursor(forHash: sha1("new").bytes)
            try again.writeIfEmpty(.uint(2))
        }
        #expect(try map(database).cursor(forHash: sha1("new").bytes)?.readUInt64() == 1)
    }
}
