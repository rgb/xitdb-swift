import Testing

@testable import XitDB

/// The guards of the engine (decisions D18 and D22, findings 1, 2, 3, 12,
/// 16, 17 and 22): each refuses before it writes. Every test here reads the
/// whole storage through the storage protocol before and after a refused
/// operation and compares the two byte for byte, on every kind of storage.
@Suite struct GuardTests {
    /// The storage kinds the tests run on: every one there is.
    static let storageKinds = StorageKind.allCases

    /// A database with a hash map at its root on a storage of one kind, and
    /// the checks the tests share.
    private struct Fixture {
        let subject: StorageUnderTest
        let database: Database

        init(_ kind: StorageKind) throws {
            subject = try StorageUnderTest(kind)
            database = try Database(
                storage: subject.storage, hashSize: 20, hashID: nil, fileID: 7,
                random: FixedRandom((1...200).map { UInt64($0) }))
            _ = try database.rootCursor.writePath([.hashMapInit()])
        }

        /// Every byte the storage holds now, buffered ones included.
        var bytes: [UInt8] {
            get throws { try wholeStorage(subject.storage) }
        }

        /// A cursor at a key of the root map, in the last commit.
        func value(_ key: String) throws -> Cursor<ReadOnly> {
            try #require(try database.rootCursor.readPath([.hashMapGet(.value, sha1(key))]))
        }

        /// Runs `body`, which has to throw `error`, and checks that the
        /// storage is byte for byte what it was before: the refusal came
        /// before any write. One `#expect(throws:)` cannot hold another,
        /// which is why `body` runs outside it.
        func expectRefused(
            _ error: XitDBError, _ body: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation
        ) throws {
            let before = try bytes
            let outcome = Result { try body() }
            #expect(throws: error, sourceLocation: sourceLocation) { try outcome.get() }
            #expect(try bytes == before, "the refused operation changed the storage", sourceLocation: sourceLocation)
        }

        /// Runs `body`, which has to succeed, and checks that the storage
        /// is byte for byte what it was before.
        func expectWritesNothing(_ body: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let before = try bytes
            try body()
            #expect(try bytes == before, "the operation changed the storage", sourceLocation: sourceLocation)
        }
    }

    // MARK: Stale cursors

    /// A cursor from an earlier transaction cannot write in a later one,
    /// whatever the path: a value, a path, one that begins with an init
    /// part, an empty one, `writeIfEmpty` and a byte writer are all
    /// `staleCursor`. The refusals do not poison the later transaction,
    /// which goes on and commits.
    @Test(arguments: storageKinds)
    func aCursorFromAnEarlierTransactionCannotWrite(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        var kept: Cursor<ReadWrite>?
        try database.withTransaction { cursor in
            kept = try cursor.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(1))])
        }
        var stale = try #require(kept)

        try database.withTransaction { cursor in
            try fixture.expectRefused(.staleCursor) { try stale.write(.uint(2)) }
            try fixture.expectRefused(.staleCursor) { _ = try stale.writePath([.write(.uint(2))]) }
            try fixture.expectRefused(.staleCursor) { _ = try stale.writePath([.hashMapInit()]) }
            try fixture.expectRefused(.staleCursor) { _ = try stale.writePath([]) }
            try fixture.expectRefused(.staleCursor) { try stale.writeIfEmpty(.uint(2)) }
            try fixture.expectRefused(.staleCursor) { try stale.writeBytes(bodyOfARefusedWriter) }
            #expect(!database.poisoned)
            _ = try cursor.writePath([.hashMapGet(.value, sha1("b")), .write(.uint(2))])
        }
        #expect(try fixture.value("a").readUInt64() == 1)
        #expect(try fixture.value("b").readUInt64() == 2)
    }

    /// After `Database.freeze()` no cursor from before it writes, inits
    /// included, with one exception: a path that begins with an init part
    /// through the transaction's own cursor, which is how the transaction
    /// goes on (D24). A value cursor, a map cursor and a wrapper from before
    /// the freeze are refused for everything, an init through them too; the
    /// transaction's cursor is refused for a plain path and an empty one and
    /// writes through an init part, and everything made from it afterwards
    /// is fresh.
    @Test(arguments: storageKinds)
    func afterAFreezeOnlyTheTransactionsCursorGoesOnThroughAnInit(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        try database.withTransaction { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let map = try cursor.writePath([.hashMapGet(.value, sha1("map")), .hashMapInit()])
            var value = try map.writePath([.hashMapGet(.value, sha1("k")), .write(.uint(1))])
            try database.freeze()

            // handles from before the freeze: refused for every write
            try fixture.expectRefused(.staleCursor) { try value.write(.uint(2)) }
            try fixture.expectRefused(.staleCursor) { try value.writeIfEmpty(.uint(2)) }
            try fixture.expectRefused(.staleCursor) { try value.writeBytes(bodyOfARefusedWriter) }
            try fixture.expectRefused(.staleCursor) {
                _ = try map.writePath([.hashMapGet(.value, sha1("k")), .write(.uint(2))])
            }
            try fixture.expectRefused(.staleCursor) {
                _ = try map.writePath([.hashMapInit(), .hashMapGet(.value, sha1("k")), .write(.uint(2))])
            }
            try fixture.expectRefused(.staleCursor) { _ = try HashMap<ReadWrite>(map) }
            try fixture.expectRefused(.staleCursor) { _ = try map.writePath([]) }
            try fixture.expectRefused(.staleCursor) { try moment.put(.uint(3), forHash: sha1("a").bytes) }
            // a wrapper made from the transaction's cursor before the freeze
            // sits at the transaction's slot, which the engine knows by its
            // position: an init through it is the same init, and is allowed
            let viaMoment = try HashMap<ReadWrite>(moment.cursor)
            try viaMoment.put(.uint(6), forHash: sha1("c").bytes)

            // the transaction's cursor: a plain path and an empty path are
            // refused, a path that begins with an init part writes
            try fixture.expectRefused(.staleCursor) {
                _ = try cursor.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(3))])
            }
            try fixture.expectRefused(.staleCursor) { _ = try cursor.writePath([]) }
            _ = try cursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("a")), .write(.uint(3))])
            _ = try cursor.writePath([
                .hashMapInit(), .hashMapGet(.value, sha1("map")), .hashMapInit(), .hashMapGet(.value, sha1("k")),
                .write(.uint(2)),
            ])
            // and what is made from it afterwards is fresh
            let again = try HashMap<ReadWrite>(cursor)
            let list = try ArrayList<ReadWrite>(try again.putCursor(forHash: sha1("list").bytes))
            try list.append(.uint(4))
            try again.put(.uint(5), forHash: sha1("b").bytes)
        }
        #expect(try fixture.value("map").readPath([.hashMapGet(.value, sha1("k"))])?.readUInt64() == 2)
        #expect(try fixture.value("a").readUInt64() == 3)
        #expect(try fixture.value("b").readUInt64() == 5)
        #expect(try fixture.value("c").readUInt64() == 6)
        #expect(try fixture.value("list").readPath([.arrayListGet(0)])?.readUInt64() == 4)
    }

    /// A concat counts as a freeze: afterwards the list that made it, the
    /// other list, a value cursor and the transaction's cursor cannot write
    /// a plain path, an empty one included, and an init part through the
    /// transaction's cursor is the way on.
    @Test(arguments: storageKinds)
    func aConcatFreezesTheTransaction(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        try database.withTransaction { cursor in
            let list = try LinkedArrayList<ReadWrite>(try cursor.writePath([.hashMapGet(.value, sha1("list"))]))
            let other = try LinkedArrayList<ReadWrite>(try cursor.writePath([.hashMapGet(.value, sha1("other"))]))
            try list.append(.uint(1))
            try other.append(.uint(2))
            var value = try cursor.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(1))])
            let freezesBefore = database.freezeNumber
            try list.append(contentsOf: other)
            #expect(database.freezeNumber == freezesBefore + 1)

            try fixture.expectRefused(.staleCursor) { try value.write(.uint(2)) }
            try fixture.expectRefused(.staleCursor) { try other.append(.uint(3)) }
            try fixture.expectRefused(.staleCursor) { try list.append(.uint(3)) }
            try fixture.expectRefused(.staleCursor) {
                _ = try cursor.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(2))])
            }
            try fixture.expectRefused(.staleCursor) { _ = try cursor.writePath([]) }
            _ = try cursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("a")), .write(.uint(2))])
        }
        #expect(try fixture.value("a").readUInt64() == 2)
        let list = try LinkedArrayList<ReadOnly>(try fixture.value("list"))
        #expect(try list.count == 2)
        #expect(try list.cursor(at: 0)?.readUInt64() == 1)
        #expect(try list.cursor(at: 1)?.readUInt64() == 2)
        #expect(try LinkedArrayList<ReadOnly>(try fixture.value("other")).count == 1)
    }

    /// A cursor from a transaction that rolled back may not read the file:
    /// its bytes were truncated and the offsets reused. Its `slot` is a
    /// snapshot and stays; reading the value, the bytes, the count, the
    /// entry or a path through it is refused, and so is a write in the
    /// next transaction.
    @Test(arguments: storageKinds)
    func aCursorFromARolledBackTransactionCannotRead(kind: StorageKind) throws {
        struct Cancel: Error {}
        let fixture = try Fixture(kind)
        let database = fixture.database
        let before = try fixture.bytes
        var keptValue: Cursor<ReadWrite>?
        var keptBytes: Cursor<ReadWrite>?
        var keptMap: Cursor<ReadWrite>?
        var keptList: Cursor<ReadWrite>?
        let outcome = Result { () throws -> Void in
            try database.withTransaction { cursor in
                keptValue = try cursor.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(1))])
                keptBytes = try cursor.writePath([
                    .hashMapGet(.value, sha1("bytes")), .write(.bytes(utf8("a value too long for a slot"))),
                ])
                let map = try cursor.writePath([.hashMapGet(.value, sha1("map")), .hashMapInit(counted: true)])
                _ = try map.writePath([.hashMapGet(.value, sha1("k")), .write(.uint(7))])
                keptMap = map
                let list = try cursor.writePath([.hashMapGet(.value, sha1("list")), .arrayListInit])
                _ = try list.writePath([.arrayListAppend, .write(.uint(8))])
                keptList = list
                throw Cancel()
            }
        }
        #expect(throws: Cancel.self) { try outcome.get() }
        #expect(try fixture.bytes == before)

        var value = try #require(keptValue)
        let bytes = try #require(keptBytes)
        let map = try #require(keptMap)
        let list = try #require(keptList)
        #expect(try value.slot == Slot(value: 1, tag: .uint))
        #expect(try map.slot.tag == .countedHashMap)
        try fixture.expectRefused(.staleCursor) { _ = try value.readUInt64() }
        try fixture.expectRefused(.staleCursor) { _ = try bytes.readBytes() }
        try fixture.expectRefused(.staleCursor) { _ = try bytes.count }
        try fixture.expectRefused(.staleCursor) { _ = try bytes.readEntry() }
        try fixture.expectRefused(.staleCursor) { _ = try map.count }
        try fixture.expectRefused(.staleCursor) { _ = try map.readPath([.hashMapGet(.value, sha1("k"))]) }
        try fixture.expectRefused(.staleCursor) { _ = try map.readPathSlot([.hashMapGet(.value, sha1("k"))]) }
        try fixture.expectRefused(.staleCursor) { _ = try list.readPath([.arrayListGet(0)]) }
        try fixture.expectRefused(.staleCursor) { _ = try list.count }

        try database.withTransaction { _ in
            try fixture.expectRefused(.staleCursor) { try value.write(.uint(2)) }
            try fixture.expectRefused(.staleCursor) { _ = try value.readUInt64() }
        }
    }

    /// A cursor's own `freeze()` moves only its freeze point: it counts no
    /// freeze of the database, so no other cursor is stale after it, and
    /// the cursor itself still writes.
    @Test(arguments: storageKinds)
    func aCursorsOwnFreezeStalesNoCursor(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        try database.withTransaction { cursor in
            var a = try cursor.writePath([.hashMapGet(.value, sha1("a"))])
            var b = try cursor.writePath([.hashMapGet(.value, sha1("b"))])
            let freezes = database.freezeNumber
            try a.freeze()
            #expect(database.freezeNumber == freezes)
            try b.write(.uint(2))
            try a.write(.uint(1))
            _ = try cursor.writePath([.hashMapGet(.value, sha1("c")), .write(.uint(3))])
        }
        #expect(try fixture.value("a").readUInt64() == 1)
        #expect(try fixture.value("b").readUInt64() == 2)
        #expect(try fixture.value("c").readUInt64() == 3)
    }

    /// The root cursor is never stale: one taken before a transaction that
    /// froze, and one taken inside a transaction that rolled back, both
    /// read and write afterwards. Inside a transaction a write through it
    /// is a nested one, as it always was.
    @Test(arguments: storageKinds)
    func theRootCursorIsNeverStale(kind: StorageKind) throws {
        struct Cancel: Error {}
        let fixture = try Fixture(kind)
        let database = fixture.database
        let early = database.rootCursor
        try database.withTransaction { cursor in
            _ = try cursor.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(1))])
            try database.freeze()
            _ = try cursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("b")), .write(.uint(2))])
        }
        var inFailed: Cursor<ReadWrite>?
        let outcome = Result { () throws -> Void in
            try database.withTransaction { cursor in
                inFailed = database.rootCursor
                _ = try cursor.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(9))])
                throw Cancel()
            }
        }
        #expect(throws: Cancel.self) { try outcome.get() }
        let late = try #require(inFailed)

        #expect(try early.readPath([.hashMapGet(.value, sha1("a"))])?.readUInt64() == 1)
        #expect(try late.readPath([.hashMapGet(.value, sha1("b"))])?.readUInt64() == 2)
        _ = try early.writePath([.hashMapGet(.value, sha1("c")), .write(.uint(3))])
        _ = try late.writePath([.hashMapGet(.value, sha1("d")), .write(.uint(4))])
        #expect(try fixture.value("c").readUInt64() == 3)
        #expect(try fixture.value("d").readUInt64() == 4)
        try database.withTransaction { _ in
            #expect(throws: XitDBError.nestedTopLevelWrite) {
                try early.writePath([.hashMapGet(.value, sha1("e")), .write(.uint(5))])
            }
        }
    }

    /// A cursor from an earlier transaction that committed reads as
    /// before, outside and inside a later transaction, and what it reads
    /// is its snapshot.
    @Test(arguments: storageKinds)
    func aCursorFromACommittedTransactionReads(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        var keptValue: Cursor<ReadWrite>?
        var keptMap: Cursor<ReadWrite>?
        try database.withTransaction { cursor in
            keptValue = try cursor.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(1))])
            let map = try cursor.writePath([.hashMapGet(.value, sha1("map")), .hashMapInit(counted: true)])
            _ = try map.writePath([.hashMapGet(.value, sha1("k")), .write(.uint(7))])
            keptMap = map
        }
        let value = try #require(keptValue)
        let map = try #require(keptMap)
        #expect(try value.readUInt64() == 1)
        #expect(try map.count == 1)
        #expect(try map.readPath([.hashMapGet(.value, sha1("k"))])?.readUInt64() == 7)
        var iterator = try map.iterator()
        #expect(try iterator.next()?.readEntry().value.readUInt64() == 7)

        try database.withTransaction { cursor in
            _ = try cursor.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(2))])
            #expect(try value.readUInt64() == 1)
            #expect(try map.count == 1)
        }
        #expect(try value.readUInt64() == 1)
        #expect(try fixture.value("a").readUInt64() == 2)
    }

    /// A write through a cursor keeps the cursor's numbers: a cursor that
    /// wrote just before a freeze, with `write`, `writeIfEmpty` or a byte
    /// writer, is stale after it like one that only was made before it.
    @Test(arguments: storageKinds)
    func aWriteDoesNotMakeACursorFresh(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        try database.withTransaction { cursor in
            var written = try cursor.writePath([.hashMapGet(.value, sha1("a"))])
            try written.write(.uint(1))
            var ifEmpty = try cursor.writePath([.hashMapGet(.value, sha1("b"))])
            try ifEmpty.writeIfEmpty(.uint(2))
            var bytes = try cursor.writePath([.hashMapGet(.value, sha1("c"))])
            try bytes.writeBytes { writer in try writer.write([1, 2, 3]) }
            try database.freeze()

            try fixture.expectRefused(.staleCursor) { try written.write(.uint(9)) }
            try fixture.expectRefused(.staleCursor) { try ifEmpty.writeIfEmpty(.uint(9)) }
            try fixture.expectRefused(.staleCursor) { try ifEmpty.write(.uint(9)) }
            try fixture.expectRefused(.staleCursor) { try bytes.writeBytes(bodyOfARefusedWriter) }
            try fixture.expectRefused(.staleCursor) { try bytes.write(.uint(9)) }
            // what they wrote stands, and they read it
            #expect(try written.readUInt64() == 1)
            #expect(try ifEmpty.readUInt64() == 2)
            #expect(try bytes.readBytes() == [1, 2, 3])
        }
        #expect(try fixture.value("a").readUInt64() == 1)
        #expect(try fixture.value("b").readUInt64() == 2)
        #expect(try fixture.value("c").readBytes() == [1, 2, 3])
    }

    // MARK: The concat's own wrapper

    /// The list that calls `append(contentsOf:)` is as stale as every other
    /// handle afterwards (D24): its next write, a copy's and that of a
    /// wrapper made from the same cursor are refused with nothing written,
    /// and the way on is a new list from the transaction's cursor, whose
    /// appends are the ones that commit. Its reads still give its snapshot.
    @Test(arguments: storageKinds)
    func aConcatStalesItsOwnListToo(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        try database.withTransaction { cursor in
            let list = try LinkedArrayList<ReadWrite>(try cursor.writePath([.hashMapGet(.value, sha1("list"))]))
            let other = try LinkedArrayList<ReadWrite>(try cursor.writePath([.hashMapGet(.value, sha1("other"))]))
            try list.append(.uint(1))
            try other.append(.uint(2))
            let copy = list
            let sameCursor = try LinkedArrayList<ReadWrite>(list.cursor)

            try list.append(contentsOf: other)
            try fixture.expectRefused(.staleCursor) { try list.append(.uint(9)) }
            try fixture.expectRefused(.staleCursor) { try list.remove(at: 0) }
            try fixture.expectRefused(.staleCursor) { try copy.append(.uint(3)) }
            try fixture.expectRefused(.staleCursor) { try sameCursor.append(.uint(3)) }
            try fixture.expectRefused(.staleCursor) { _ = try sameCursor.putCursor(at: 0) }
            #expect(try list.count == 2, "the stale list still reads its snapshot of the joined list")

            let again = try LinkedArrayList<ReadWrite>(
                try cursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("list"))]))
            try again.append(.uint(9))
            try again.append(.uint(10))
            #expect(try again.count == 4)
        }
        let list = try LinkedArrayList<ReadOnly>(try fixture.value("list"))
        #expect(try list.count == 4)
        for (index, expected) in [1, 2, 9, 10].enumerated() {
            #expect(try list.cursor(at: index)?.readUInt64() == UInt64(expected))
        }
    }

    // MARK: A sorted map's key

    /// A sorted map's key cursor has no position (finding 2): the key of an
    /// entry from `readEntry()`, the key the path API gives and the entry
    /// itself all refuse `write(_:)` and a write path with
    /// `cursorNotWritable`, and the entry is as it was.
    @Test(arguments: storageKinds)
    func aSortedMapsKeyCannotBeWritten(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        try database.withTransaction { cursor in
            let map = try SortedMap<ReadWrite>(try cursor.writePath([.hashMapGet(.value, sha1("map"))]))
            try map.put(.uint(1), forKey: utf8("k"))
            let entry = try #require(try map.entry(forKey: utf8("k")))
            #expect(entry.key.slotPointer.position == nil)

            // a read-write cursor at the key's pointer, which only the
            // package can make
            var key = Cursor<ReadWrite>(
                slotPointer: entry.key.slotPointer, database: database, frozenAt: entry.key.frozenAt)
            try fixture.expectRefused(.cursorNotWritable) { try key.write(.bytes(utf8("j"))) }
            try fixture.expectRefused(.cursorNotWritable) { _ = try key.writePath([.write(.bytes(utf8("j")))]) }
            try fixture.expectRefused(.cursorNotWritable) { _ = try key.writePath([.hashMapInit()]) }
            try fixture.expectRefused(.cursorNotWritable) { try key.writeIfEmpty(.bytes(utf8("j"))) }

            // the key and the entry the path API gives in a write path
            var pathKey = try map.cursor.writePath([.sortedMapGet(.key, SortedKey(utf8("k")))])
            #expect(pathKey.slotPointer.position == nil)
            try fixture.expectRefused(.cursorNotWritable) { try pathKey.write(.bytes(utf8("j"))) }
            var pair = try map.cursor.writePath([.sortedMapGet(.kvPair, SortedKey(utf8("k")))])
            #expect(pair.slotPointer.position == nil)
            try fixture.expectRefused(.cursorNotWritable) { try pair.write(.uint(5)) }

            #expect(try map.entry(forKey: utf8("k"))?.key.readBytes() == utf8("k"))
            #expect(try map.cursor(forKey: utf8("k"))?.readUInt64() == 1)
            #expect(try map.count == 1)
        }
    }

    // MARK: Structural slots

    /// A slot with one of the trees' own tags, `index`, `kvPair` or
    /// `sortedKvPair`, is refused as a value (finding 3) before anything is
    /// written, through `write(_:)` and through a path. The same value
    /// with another tag is written.
    @Test(arguments: storageKinds)
    func aStructuralSlotIsRefusedAsAValue(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        try database.withTransaction { cursor in
            var value = try cursor.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(1))])
            for tag in [Tag.index, .kvPair, .sortedKvPair] {
                let slot = Slot(value: 100, tag: tag)
                try fixture.expectRefused(.structuralSlot) { try value.write(.slot(slot)) }
                try fixture.expectRefused(.structuralSlot) { _ = try value.writePath([.write(.slot(slot))]) }
                // the get reaches an entry this transaction made, so it
                // writes nothing on the way
                try fixture.expectRefused(.structuralSlot) {
                    _ = try cursor.writePath([.hashMapGet(.value, sha1("a")), .write(.slot(slot))])
                }
            }
            #expect(try value.readUInt64() == 1)
            try value.write(.slot(Slot(value: 100, tag: .uint)))
            #expect(try value.readUInt64() == 100)
        }
        #expect(try fixture.value("a").readUInt64() == 100)
    }

    // MARK: Nothing after a remove

    /// A part after `.hashMapRemove` or `.sortedMapRemove` is
    /// `pathPartMustBeAtEnd` (finding 12), reported before anything is
    /// removed: the entry is still there and the storage is unchanged. A
    /// remove at the end of the path removes.
    @Test(arguments: storageKinds)
    func nothingFollowsARemove(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        try database.withTransaction { cursor in
            let map = try HashMap<ReadWrite>(try cursor.writePath([.hashMapGet(.value, sha1("map"))]))
            try map.put(.uint(1), forHash: hashInt("k"))
            let sorted = try SortedMap<ReadWrite>(try cursor.writePath([.hashMapGet(.value, sha1("sorted"))]))
            try sorted.put(.uint(2), forKey: utf8("k"))

            for trailing in [PathPart.write(.uint(3)), .hashMapGet(.value, sha1("k")), .ctx] {
                try fixture.expectRefused(.pathPartMustBeAtEnd) {
                    _ = try map.cursor.writePath([.hashMapRemove(sha1("k")), trailing])
                }
                try fixture.expectRefused(.pathPartMustBeAtEnd) {
                    _ = try sorted.cursor.writePath([.sortedMapRemove(SortedKey(utf8("k"))), trailing])
                }
            }
            #expect(try map.cursor(forHash: hashInt("k"))?.readUInt64() == 1)
            #expect(try sorted.cursor(forKey: utf8("k"))?.readUInt64() == 2)
            #expect(try sorted.count == 1)

            _ = try map.cursor.writePath([.hashMapRemove(sha1("k"))])
            _ = try sorted.cursor.writePath([.sortedMapRemove(SortedKey(utf8("k")))])
            #expect(try map.cursor(forHash: hashInt("k")) == nil)
            #expect(try sorted.cursor(forKey: utf8("k")) == nil)
            #expect(try sorted.count == 0)
        }
    }

    // MARK: Poisoning

    /// A byte writer whose body throws after it has written poisons the
    /// transaction (finding 16): every further write through any cursor is
    /// `poisonedTransaction` and writes nothing, reads still work, the
    /// commit is `poisonedTransaction`, and the rollback leaves the storage
    /// byte for byte what it was before the transaction. The next
    /// transaction is clean.
    @Test(arguments: storageKinds)
    func aWriterThatFailsAfterWritingPoisonsTheTransaction(kind: StorageKind) throws {
        struct Cancel: Error {}
        let fixture = try Fixture(kind)
        let database = fixture.database
        try database.withTransaction { cursor in
            _ = try cursor.writePath([.hashMapGet(.value, sha1("committed")), .write(.uint(1))])
        }
        let before = try fixture.bytes

        // The transaction's body as a function: the compiler at hand rejects
        // a refused byte writer in a closure nested this deep, with a
        // function type mismatch in its SIL, and accepts the function.
        func transaction(_ cursor: inout Cursor<ReadWrite>) throws {
            // the transaction's cursor as a value, for the closures below
            let transactionCursor = cursor
            var a = try cursor.writePath([.hashMapGet(.value, sha1("a"))])
            var b = try cursor.writePath([.hashMapGet(.value, sha1("b")), .write(.uint(2))])
            let list = try ArrayList<ReadWrite>(try cursor.writePath([.hashMapGet(.value, sha1("list"))]))
            #expect(!database.poisoned)
            #expect(throws: Cancel.self) {
                try a.writeBytes { writer in
                    try writer.write([1, 2, 3])
                    throw Cancel()
                }
            }
            #expect(database.poisoned)

            try fixture.expectRefused(.poisonedTransaction) { try b.write(.uint(3)) }
            try fixture.expectRefused(.poisonedTransaction) { try a.writeIfEmpty(.uint(3)) }
            try fixture.expectRefused(.poisonedTransaction) { try a.writeBytes(bodyOfARefusedWriter) }
            try fixture.expectRefused(.poisonedTransaction) { try list.append(.uint(3)) }
            try fixture.expectRefused(.poisonedTransaction) {
                _ = try transactionCursor.writePath([.hashMapGet(.value, sha1("c")), .write(.uint(3))])
            }
            try fixture.expectRefused(.poisonedTransaction) { _ = try transactionCursor.writePath([.hashMapInit()]) }
            try fixture.expectRefused(.poisonedTransaction) { _ = try transactionCursor.writePath([]) }
            #expect(try b.readUInt64() == 2)
            #expect(try a.slot.isEmpty)
        }
        expectPoisoned { try database.withTransaction(transaction) }
        #expect(try fixture.bytes == before)
        #expect(try database.rootCursor.readPath([.hashMapGet(.value, sha1("b"))]) == nil)
        #expect(try fixture.value("committed").readUInt64() == 1)

        try database.withTransaction { cursor in
            #expect(!database.poisoned)
            _ = try cursor.writePath([.hashMapGet(.value, sha1("b")), .write(.uint(5))])
        }
        #expect(try fixture.value("b").readUInt64() == 5)
    }

    /// A path that writes and then meets a part its slot refuses poisons
    /// too: the get makes an entry and writes a value, then the list part
    /// on a number is `unexpectedTag`, and the transaction can only roll
    /// back.
    @Test(arguments: storageKinds)
    func aPathThatFailsAfterWritingPoisonsTheTransaction(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        let before = try fixture.bytes
        func transaction(_ cursor: inout Cursor<ReadWrite>) throws {
            let transactionCursor = cursor
            var a = try cursor.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(1))])
            let lengthBefore = try fixture.subject.storage.length
            #expect(throws: XitDBError.unexpectedTag) {
                try transactionCursor.writePath([.hashMapGet(.value, sha1("new")), .write(.uint(1)), .arrayListAppend])
            }
            #expect(try fixture.subject.storage.length > lengthBefore, "the path had written")
            #expect(database.poisoned)
            try fixture.expectRefused(.poisonedTransaction) { try a.write(.uint(2)) }
            try fixture.expectRefused(.poisonedTransaction) { try a.writeBytes(bodyOfARefusedWriter) }
            try fixture.expectRefused(.poisonedTransaction) {
                _ = try transactionCursor.writePath([.hashMapGet(.value, sha1("c")), .write(.uint(3))])
            }
        }
        expectPoisoned { try database.withTransaction(transaction) }
        #expect(try fixture.bytes == before)
        #expect(try database.rootCursor.readPath([.hashMapGet(.value, sha1("a"))]) == nil)
    }

    /// An operation that fails before it writes does not poison: a missing
    /// key, an index out of range and each of the refused guards leave the
    /// transaction able to write and to commit.
    @Test(arguments: storageKinds)
    func aFailureBeforeWritingDoesNotPoison(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        try database.withTransaction { cursor in
            let map = try HashMap<ReadWrite>(try cursor.writePath([.hashMapGet(.value, sha1("map"))]))
            let list = try LinkedArrayList<ReadWrite>(try cursor.writePath([.hashMapGet(.value, sha1("list"))]))
            let sorted = try SortedMap<ReadWrite>(try cursor.writePath([.hashMapGet(.value, sha1("sorted"))]))
            try sorted.put(.uint(1), forKey: utf8("k"))
            var value = try cursor.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(1))])

            // lookups that fail
            try fixture.expectRefused(.keyNotFound) { _ = try map.cursor.writePath([.hashMapRemove(sha1("missing"))]) }
            try fixture.expectRefused(.indexOutOfRange) { try list.remove(at: 3) }
            try fixture.expectRefused(.indexOutOfRange) { try list.put(.uint(1), at: 0) }
            // the guards
            try fixture.expectRefused(.structuralSlot) { try value.write(.slot(Slot(value: 1, tag: .kvPair))) }
            try fixture.expectRefused(.pathPartMustBeAtEnd) {
                _ = try map.cursor.writePath([.hashMapRemove(sha1("x")), .write(.uint(1))])
            }
            var key = try sorted.cursor.writePath([.sortedMapGet(.key, SortedKey(utf8("k")))])
            try fixture.expectRefused(.cursorNotWritable) { try key.write(.bytes(utf8("j"))) }
            try database.freeze()
            try fixture.expectRefused(.staleCursor) { try value.write(.uint(2)) }
            #expect(!database.poisoned)

            _ = try cursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("a")), .write(.uint(2))])
        }
        #expect(try fixture.value("a").readUInt64() == 2)
        #expect(try SortedMap<ReadOnly>(try fixture.value("sorted")).cursor(forKey: utf8("k"))?.readUInt64() == 1)
    }

    // MARK: writeIfEmpty

    /// `writeIfEmpty` goes by the slot as it is now (finding 17): on a slot
    /// another cursor has written it writes nothing, even through a cursor
    /// whose snapshot saw the slot empty, and a slot set to nothing is not
    /// empty either; on an empty slot it writes.
    @Test(arguments: storageKinds)
    func writeIfEmptyGoesByTheSlotAsItIsNow(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        try database.withTransaction { cursor in
            var first = try cursor.writePath([.hashMapGet(.value, sha1("a"))])
            var snapshot = first
            try first.write(.uint(1))
            #expect(try snapshot.slot.isEmpty)
            try fixture.expectWritesNothing { try snapshot.writeIfEmpty(.uint(2)) }
            try fixture.expectWritesNothing { try first.writeIfEmpty(.uint(2)) }
            #expect(try snapshot.slot.isEmpty, "the snapshot is not what the write goes by")
            #expect(try first.readUInt64() == 1)

            var cleared = try cursor.writePath([.hashMapGet(.value, sha1("b")), .write(.slot(nil))])
            try fixture.expectWritesNothing { try cleared.writeIfEmpty(.uint(3)) }
            #expect(try cleared.slot == Slot(tag: .none, full: true))

            var empty = try cursor.writePath([.hashMapGet(.value, sha1("c"))])
            let before = try fixture.bytes
            try empty.writeIfEmpty(.uint(4))
            #expect(try fixture.bytes != before)
            #expect(try empty.readUInt64() == 4)
        }
        #expect(try fixture.value("a").readUInt64() == 1)
        #expect(try fixture.value("b").slot == Slot(tag: .none, full: true))
        #expect(try fixture.value("c").readUInt64() == 4)
    }

    // MARK: What the first run of these tests found

    /// A byte writer through a cursor with no position, a sorted map's key,
    /// is refused before the record is started: the body never runs, the
    /// storage is unchanged and the transaction is not poisoned. Before
    /// this was pinned, the writer appended the record's length and ran the
    /// body, and the refusal came from `finish`, after the writes.
    @Test(arguments: storageKinds)
    func aByteWriterThroughASortedKeyIsRefusedBeforeItWrites(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        try database.withTransaction { cursor in
            let map = try SortedMap<ReadWrite>(try cursor.writePath([.hashMapGet(.value, sha1("map"))]))
            try map.put(.uint(1), forKey: utf8("k"))
            var key = try map.cursor.writePath([.sortedMapGet(.key, SortedKey(utf8("k")))])
            #expect(key.slotPointer.position == nil)
            try fixture.expectRefused(.cursorNotWritable) { try key.writeBytes(bodyOfARefusedWriter) }
            try fixture.expectRefused(.cursorNotWritable) { _ = try key.writePath([]) }
            #expect(!database.poisoned)
        }
        let value = try fixture.value("map").readPath([.sortedMapGet(.value, SortedKey(utf8("k")))])
        #expect(try value?.readUInt64() == 1)
    }

    /// An iterator over a cursor from a transaction that did not commit,
    /// and the read-only view of such a cursor (``Cursor/readOnly``, or a
    /// read-only collection made from it), are as stale as the cursor:
    /// refused with `staleCursor`, before and after a later transaction has
    /// reused the offsets. Before this was pinned, the iterator read the
    /// file without the check, and the view was a new cursor from no
    /// transaction: both read past the end, and then the other
    /// transaction's bytes.
    @Test(arguments: storageKinds)
    func anIteratorAndAReadOnlyViewOfAStaleCursorAreRefused(kind: StorageKind) throws {
        struct Cancel: Error {}
        let fixture = try Fixture(kind)
        let database = fixture.database
        var keptBytes: Cursor<ReadWrite>?
        var keptList: Cursor<ReadWrite>?
        let outcome = Result { () throws -> Void in
            try database.withTransaction { cursor in
                keptBytes = try cursor.writePath([
                    .hashMapGet(.value, sha1("bytes")), .write(.bytes(utf8("a value too long for a slot"))),
                ])
                let list = try cursor.writePath([.hashMapGet(.value, sha1("list")), .arrayListInit])
                _ = try list.writePath([.arrayListAppend, .write(.uint(8))])
                keptList = list
                throw Cancel()
            }
        }
        #expect(throws: Cancel.self) { try outcome.get() }
        let bytes = try #require(keptBytes)
        let list = try #require(keptList)

        func expectAllRefused(_ when: Comment) {
            #expect(throws: XitDBError.staleCursor, when) { try list.iterator() }
            #expect(throws: XitDBError.staleCursor, when) { try ArrayList<ReadOnly>(list).iterator() }
            #expect(throws: XitDBError.staleCursor, when) { try ArrayList<ReadOnly>(list).cursor(at: 0) }
            #expect(bytes.readOnly.transaction == bytes.transaction, when)
            #expect(throws: XitDBError.staleCursor, when) { try bytes.readOnly.readBytes() }
            #expect(throws: XitDBError.staleCursor, when) { try bytes.readBytes() }
        }
        expectAllRefused("before the offsets are reused")

        try database.withTransaction { cursor in
            _ = try cursor.writePath([
                .hashMapGet(.value, sha1("other")), .write(.bytes(utf8("other bytes, long enough for a record"))),
            ])
            for key in ["x", "y", "z"] {
                _ = try cursor.writePath([.hashMapGet(.value, sha1(key)), .write(.uint(1))])
            }
        }
        expectAllRefused("after a later transaction reused the offsets")
    }

    /// Every public read, through a cursor from a transaction that did not
    /// commit, is `staleCursor`: the cursor's own reads, its reader and its
    /// iterator, the read-only view, every read of every read-only
    /// collection made from it, and the reads of an iterator and a byte
    /// reader made through the cursor before the rollback, before and after
    /// a later transaction has reused the offsets. The table names each
    /// entry point, so that a new one is added here and not forgotten; the
    /// ones that escaped the check before this test (`reader()`,
    /// `rank(of:)`, the kept iterator and reader) are in it.
    @Test(arguments: storageKinds)
    func everyReadThroughARolledBackCursorIsRefused(kind: StorageKind) throws {
        struct Cancel: Error {}
        let fixture = try Fixture(kind)
        let database = fixture.database
        let hash = sha1("k").bytes
        let key = utf8("k")
        var kept: [String: Cursor<ReadWrite>] = [:]
        var keptIterator: CollectionIterator?
        var keptReader: ByteReader?
        let outcome = Result { () throws -> Void in
            try database.withTransaction { cursor in
                kept["number"] = try cursor.writePath([.hashMapGet(.value, sha1("number")), .write(.uint(7))])
                kept["bytes"] = try cursor.writePath([
                    .hashMapGet(.value, sha1("bytes")), .write(.bytes(utf8("a value too long for a slot"))),
                ])
                keptReader = try kept["bytes"]?.reader()
                let list = try ArrayList<ReadWrite>(try cursor.writePath([.hashMapGet(.value, sha1("list"))]))
                try list.append(.uint(1))
                kept["list"] = list.cursor
                keptIterator = try list.iterator()
                let linked = try LinkedArrayList<ReadWrite>(
                    try cursor.writePath([.hashMapGet(.value, sha1("linked"))]))
                try linked.append(.uint(1))
                kept["linked"] = linked.cursor
                let map = try HashMap<ReadWrite>(try cursor.writePath([.hashMapGet(.value, sha1("map"))]))
                try map.put(.uint(1), forHash: hash)
                kept["map"] = map.cursor
                let set = try HashSet<ReadWrite>(try cursor.writePath([.hashMapGet(.value, sha1("set"))]))
                try set.insert(.uint(1), forHash: hash)
                kept["set"] = set.cursor
                let counted = try CountedHashMap<ReadWrite>(
                    try cursor.writePath([.hashMapGet(.value, sha1("counted"))]))
                try counted.put(.uint(1), forHash: hash)
                kept["counted"] = counted.cursor
                let countedSet = try CountedHashSet<ReadWrite>(
                    try cursor.writePath([.hashMapGet(.value, sha1("countedSet"))]))
                try countedSet.insert(.uint(1), forHash: hash)
                kept["countedSet"] = countedSet.cursor
                let sorted = try SortedMap<ReadWrite>(try cursor.writePath([.hashMapGet(.value, sha1("sorted"))]))
                try sorted.put(.uint(1), forKey: key)
                kept["sorted"] = sorted.cursor
                let sortedSet = try SortedSet<ReadWrite>(
                    try cursor.writePath([.hashMapGet(.value, sha1("sortedSet"))]))
                try sortedSet.insert(key)
                kept["sortedSet"] = sortedSet.cursor
                throw Cancel()
            }
        }
        #expect(throws: Cancel.self) { try outcome.get() }
        func stale(_ name: String) throws -> Cursor<ReadWrite> {
            guard let cursor = kept[name] else {
                Issue.record("no cursor was kept under \(name)")
                throw Cancel()
            }
            return cursor
        }
        let number = try stale("number")
        let bytes = try stale("bytes")
        let list = try ArrayList<ReadOnly>(try stale("list"))
        let linked = try LinkedArrayList<ReadOnly>(try stale("linked"))
        let map = try HashMap<ReadOnly>(try stale("map"))
        let set = try HashSet<ReadOnly>(try stale("set"))
        let counted = try CountedHashMap<ReadOnly>(try stale("counted"))
        let countedSet = try CountedHashSet<ReadOnly>(try stale("countedSet"))
        let sorted = try SortedMap<ReadOnly>(try stale("sorted"))
        let sortedSet = try SortedSet<ReadOnly>(try stale("sortedSet"))
        guard let staleIterator = keptIterator, let staleReader = keptReader else {
            Issue.record("the iterator and the reader were not kept")
            return
        }

        let reads: [(String, () throws -> Void)] = [
            // the two handles that are not cursors, made before the rollback
            (
                "CollectionIterator.next",
                {
                    var iterator = staleIterator
                    _ = try iterator.next()
                }
            ),
            (
                "ByteReader.read(into:)",
                {
                    var reader = staleReader
                    var buffer = [UInt8](repeating: 0, count: 8)
                    var span = buffer.mutableSpan
                    _ = try reader.read(into: &span)
                }
            ),
            (
                "ByteReader.readAll(into:)",
                {
                    var reader = staleReader
                    var buffer = [UInt8](repeating: 0, count: 8)
                    var span = buffer.mutableSpan
                    try reader.readAll(into: &span)
                }
            ),
            (
                "ByteReader.readRemaining",
                {
                    var reader = staleReader
                    _ = try reader.readRemaining()
                }
            ),
            ("Cursor.count", { _ = try list.cursor.count }),
            ("Cursor.readUInt64", { _ = try number.readUInt64() }),
            ("Cursor.readInt64", { _ = try number.readInt64() }),
            ("Cursor.readDouble", { _ = try number.readDouble() }),
            ("Cursor.readBytes", { _ = try bytes.readBytes() }),
            ("Cursor.readBytes(maxCount:)", { _ = try bytes.readBytes(maxCount: 4) }),
            (
                "Cursor.readBytes(into:)",
                {
                    var buffer = [UInt8](repeating: 0, count: 64)
                    var span = buffer.mutableSpan
                    _ = try bytes.readBytes(into: &span)
                }
            ),
            ("Cursor.readBytesWithFormatTag", { _ = try bytes.readBytesWithFormatTag() }),
            (
                "Cursor.readBytesWithFormatTag(into:)",
                {
                    var buffer = [UInt8](repeating: 0, count: 64)
                    var span = buffer.mutableSpan
                    _ = try bytes.readBytesWithFormatTag(into: &span)
                }
            ),
            ("Cursor.reader", { _ = try bytes.reader() }),
            ("Cursor.readEntry", { _ = try map.cursor.readEntry() }),
            ("Cursor.iterator", { _ = try list.cursor.iterator() }),
            ("Cursor.readPath", { _ = try map.cursor.readPath([.hashMapGet(.value, sha1("k"))]) }),
            ("Cursor.readPathSlot", { _ = try map.cursor.readPathSlot([.hashMapGet(.value, sha1("k"))]) }),
            ("Cursor.readOnly.readUInt64", { _ = try number.readOnly.readUInt64() }),
            ("Cursor.readOnly.reader", { _ = try bytes.readOnly.reader() }),
            ("ArrayList.count", { _ = try list.count }),
            ("ArrayList.iterator", { _ = try list.iterator() }),
            ("ArrayList.iterator(fromIndex:)", { _ = try list.iterator(fromIndex: 0) }),
            ("ArrayList.cursor(at:)", { _ = try list.cursor(at: 0) }),
            ("ArrayList.slot(at:)", { _ = try list.slot(at: 0) }),
            ("LinkedArrayList.count", { _ = try linked.count }),
            ("LinkedArrayList.iterator", { _ = try linked.iterator() }),
            ("LinkedArrayList.iterator(fromIndex:)", { _ = try linked.iterator(fromIndex: 0) }),
            ("LinkedArrayList.cursor(at:)", { _ = try linked.cursor(at: 0) }),
            ("LinkedArrayList.slot(at:)", { _ = try linked.slot(at: 0) }),
            ("HashMap.iterator", { _ = try map.iterator() }),
            ("HashMap.cursor(forHash:)", { _ = try map.cursor(forHash: hash) }),
            ("HashMap.slot(forHash:)", { _ = try map.slot(forHash: hash) }),
            ("HashMap.keyCursor(forHash:)", { _ = try map.keyCursor(forHash: hash) }),
            ("HashMap.keySlot(forHash:)", { _ = try map.keySlot(forHash: hash) }),
            ("HashMap.entry(forHash:)", { _ = try map.entry(forHash: hash) }),
            ("HashSet.iterator", { _ = try set.iterator() }),
            ("HashSet.cursor(forHash:)", { _ = try set.cursor(forHash: hash) }),
            ("HashSet.slot(forHash:)", { _ = try set.slot(forHash: hash) }),
            ("HashSet.contains(hash:)", { _ = try set.contains(hash: hash) }),
            ("CountedHashMap.count", { _ = try counted.count }),
            ("CountedHashMap.iterator", { _ = try counted.iterator() }),
            ("CountedHashMap.cursor(forHash:)", { _ = try counted.cursor(forHash: hash) }),
            ("CountedHashMap.slot(forHash:)", { _ = try counted.slot(forHash: hash) }),
            ("CountedHashMap.keyCursor(forHash:)", { _ = try counted.keyCursor(forHash: hash) }),
            ("CountedHashMap.keySlot(forHash:)", { _ = try counted.keySlot(forHash: hash) }),
            ("CountedHashMap.entry(forHash:)", { _ = try counted.entry(forHash: hash) }),
            ("CountedHashSet.count", { _ = try countedSet.count }),
            ("CountedHashSet.iterator", { _ = try countedSet.iterator() }),
            ("CountedHashSet.cursor(forHash:)", { _ = try countedSet.cursor(forHash: hash) }),
            ("CountedHashSet.slot(forHash:)", { _ = try countedSet.slot(forHash: hash) }),
            ("CountedHashSet.contains(hash:)", { _ = try countedSet.contains(hash: hash) }),
            ("SortedMap.count", { _ = try sorted.count }),
            ("SortedMap.iterator", { _ = try sorted.iterator() }),
            ("SortedMap.iterator(fromIndex:)", { _ = try sorted.iterator(fromIndex: 0) }),
            ("SortedMap.iterator(fromKey:)", { _ = try sorted.iterator(fromKey: key) }),
            ("SortedMap.rank(of:)", { _ = try sorted.rank(of: key) }),
            ("SortedMap.entry(at:)", { _ = try sorted.entry(at: 0) }),
            ("SortedMap.cursor(forKey:)", { _ = try sorted.cursor(forKey: key) }),
            ("SortedMap.slot(forKey:)", { _ = try sorted.slot(forKey: key) }),
            ("SortedMap.entry(forKey:)", { _ = try sorted.entry(forKey: key) }),
            ("SortedSet.count", { _ = try sortedSet.count }),
            ("SortedSet.iterator", { _ = try sortedSet.iterator() }),
            ("SortedSet.iterator(fromIndex:)", { _ = try sortedSet.iterator(fromIndex: 0) }),
            ("SortedSet.iterator(fromKey:)", { _ = try sortedSet.iterator(fromKey: key) }),
            ("SortedSet.rank(of:)", { _ = try sortedSet.rank(of: key) }),
            ("SortedSet.entry(at:)", { _ = try sortedSet.entry(at: 0) }),
            ("SortedSet.contains", { _ = try sortedSet.contains(key) }),
        ]
        func expectAllRefused(_ when: String) {
            for (name, read) in reads {
                #expect(throws: XitDBError.staleCursor, "\(name), \(when)") { try read() }
            }
        }
        expectAllRefused("before the offsets are reused")

        try database.withTransaction { cursor in
            _ = try cursor.writePath([
                .hashMapGet(.value, sha1("other")), .write(.bytes(utf8("other bytes, long enough for a record"))),
            ])
            for name in ["x", "y", "z", "w"] {
                let other = try HashMap<ReadWrite>(try cursor.writePath([.hashMapGet(.value, sha1(name))]))
                try other.put(.uint(2), forHash: hash)
            }
        }
        expectAllRefused("after a later transaction reused the offsets")
    }

    /// A structural slot is refused before any part of the path runs: a path
    /// that would first create an entry or a list writes nothing, and so do
    /// the collection methods, whose paths write an entry or a list's header
    /// before they arrive at the value (a put on a new key and on a key
    /// committed earlier, the appends, a sorted put, a counted put, the
    /// sets' inserts and the maps' putKey, which write the key inside a
    /// callback); the transaction is not poisoned and goes on; `writeIfEmpty`
    /// refuses it whatever the slot holds; through the root cursor outside a
    /// transaction nothing is written and no transaction begins; below the
    /// root outside a transaction `expectedTxStart` comes first.
    @Test(arguments: storageKinds)
    func aStructuralSlotIsRefusedBeforeAnyPartRuns(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        let structural = WritableData.slot(Slot(value: 100, tag: .kvPair))
        try HashMap<ReadWrite>(database.rootCursor).put(.uint(1), forHash: sha1("committed").bytes)
        var outside: Cursor<ReadWrite>?
        try database.withTransaction { cursor in
            // the collection methods: each path writes before the value
            let moment = try HashMap<ReadWrite>(cursor)
            try fixture.expectRefused(.structuralSlot) { try moment.put(structural, forHash: sha1("put").bytes) }
            try fixture.expectRefused(.structuralSlot) {
                try moment.put(structural, forHash: sha1("committed").bytes)
            }
            let list = try ArrayList<ReadWrite>(try moment.putCursor(forHash: sha1("alist").bytes))
            try fixture.expectRefused(.structuralSlot) { try list.append(structural) }
            let linked = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha1("linked").bytes))
            try fixture.expectRefused(.structuralSlot) { try linked.append(structural) }
            let sorted = try SortedMap<ReadWrite>(try moment.putCursor(forHash: sha1("sorted").bytes))
            try fixture.expectRefused(.structuralSlot) { try sorted.put(structural, forKey: utf8("k")) }
            let counted = try CountedHashMap<ReadWrite>(try moment.putCursor(forHash: sha1("counted").bytes))
            try fixture.expectRefused(.structuralSlot) { try counted.put(structural, forHash: sha1("k").bytes) }
            let set = try HashSet<ReadWrite>(try moment.putCursor(forHash: sha1("set").bytes))
            try fixture.expectRefused(.structuralSlot) { try set.insert(structural, forHash: sha1("k").bytes) }
            let countedSet = try CountedHashSet<ReadWrite>(try moment.putCursor(forHash: sha1("cset").bytes))
            try fixture.expectRefused(.structuralSlot) {
                try countedSet.insert(structural, forHash: sha1("k").bytes)
            }
            try fixture.expectRefused(.structuralSlot) { try moment.putKey(structural, forHash: sha1("key").bytes) }
            try fixture.expectRefused(.structuralSlot) {
                try counted.putKey(structural, forHash: sha1("key").bytes)
            }
            #expect(!database.poisoned)

            // a path that would write before it arrives at the write part
            try fixture.expectRefused(.structuralSlot) {
                _ = try cursor.writePath([.hashMapGet(.value, sha1("new")), .write(structural)])
            }
            try fixture.expectRefused(.structuralSlot) {
                _ = try cursor.writePath([
                    .hashMapGet(.value, sha1("list")), .arrayListInit, .arrayListAppend, .write(structural),
                ])
            }
            // writeIfEmpty, on an empty slot and on a written one
            var empty = try cursor.writePath([.hashMapGet(.value, sha1("empty"))])
            try fixture.expectRefused(.structuralSlot) { try empty.writeIfEmpty(structural) }
            var written = try cursor.writePath([.hashMapGet(.value, sha1("written")), .write(.uint(1))])
            try fixture.expectRefused(.structuralSlot) { try written.writeIfEmpty(structural) }
            #expect(!database.poisoned)
            _ = try cursor.writePath([.hashMapGet(.value, sha1("after")), .write(.uint(2))])
            outside = written
        }
        #expect(try fixture.value("after").readUInt64() == 2)
        #expect(try fixture.value("written").readUInt64() == 1)
        #expect(try database.rootCursor.readPath([.hashMapGet(.value, sha1("new"))]) == nil)

        // the root cursor outside a transaction: refused before a transaction begins
        var root = database.rootCursor
        try fixture.expectRefused(.structuralSlot) { try root.write(structural) }
        try fixture.expectRefused(.structuralSlot) { try root.writeIfEmpty(structural) }

        // below the root outside a transaction, the missing transaction comes first
        var kept = try #require(outside)
        try fixture.expectRefused(.expectedTxStart) { try kept.write(structural) }
        try fixture.expectRefused(.structuralSlot) { try kept.writeIfEmpty(structural) }
    }

    // MARK: The position check

    /// A write that would land below the transaction's frozen point by a
    /// route the handle check does not catch, a fresh cursor whose path has
    /// no init part in front of a frozen structure, is `immutableBytes`,
    /// refused before it writes (D24). Two shapes: when the parts before it
    /// wrote nothing, because an earlier path had copied the block and the
    /// entry on the way, the transaction is not poisoned and commits
    /// afterwards; when a part before it copied something, that copy was a
    /// write, so the transaction is poisoned and rolls back.
    @Test(arguments: storageKinds)
    func aWriteBelowTheFrozenPointIsImmutableBytes(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        try database.withTransaction { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha1("list").bytes))
            try list.append(.uint(1))
            try database.freeze()
            // this path copies the map's block and the list's entry; the
            // path after it reaches the frozen header through gets alone
            let entry = try cursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("list"))])
            let fresh = try cursor.writePath([.hashMapInit()])
            try fixture.expectRefused(.immutableBytes) {
                _ = try fresh.writePath([
                    .hashMapGet(.value, sha1("list")), .linkedArrayListAppend, .write(.uint(2)),
                ])
            }
            #expect(!database.poisoned)
            // with the list's init in front the header is copied first, and
            // the write lands in the copy
            _ = try entry.writePath([.linkedArrayListInit, .linkedArrayListAppend, .write(.uint(2))])
        }
        let committed = try LinkedArrayList<ReadOnly>(try fixture.value("list"))
        #expect(try committed.count == 2)

        // the shape that poisons: the inner map's init copies its block
        // before the write into the frozen header is refused
        expectPoisoned {
            try database.withTransaction { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                let inner = try HashMap<ReadWrite>(try moment.putCursor(forHash: sha1("inner").bytes))
                let deep = try LinkedArrayList<ReadWrite>(try inner.putCursor(forHash: sha1("deep").bytes))
                try deep.append(.uint(1))
                try database.freeze()
                let fresh = try cursor.writePath([.hashMapInit()])
                let outcome = Result { () throws -> Void in
                    _ = try fresh.writePath([
                        .hashMapGet(.value, sha1("inner")), .hashMapInit(), .hashMapGet(.value, sha1("deep")),
                        .linkedArrayListAppend, .write(.uint(2)),
                    ])
                }
                #expect(throws: XitDBError.immutableBytes) { try outcome.get() }
                #expect(database.poisoned)
            }
        }
        #expect(try database.rootCursor.readPath([.hashMapGet(.value, sha1("inner"))]) == nil)
    }

    // MARK: What the init exception lost (findings 29 and 30)

    /// Finding 30: after a join, the list that made it and a second handle
    /// for the same list from the transaction's cursor. The stale list's
    /// append is refused with nothing written, the second handle's commits,
    /// and nothing is lost; the original silently dropped the first.
    @Test(arguments: storageKinds)
    func aHeldListAfterAJoinLosesNothing(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        try database.withTransaction { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let tasks = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha1("tasks").bytes))
            let more = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha1("more").bytes))
            try tasks.append(.uint(1))
            try more.append(.uint(2))
            try tasks.append(contentsOf: more)
            let again = try HashMap<ReadWrite>(cursor)
            let tasksAgain = try LinkedArrayList<ReadWrite>(try again.putCursor(forHash: sha1("tasks").bytes))
            try fixture.expectRefused(.staleCursor) { try tasks.append(.uint(5)) }
            try tasksAgain.append(.uint(6))
            #expect(!database.poisoned)
        }
        let committed = try LinkedArrayList<ReadOnly>(try fixture.value("tasks"))
        let values = try (0..<Int(try committed.count)).map { try committed.cursor(at: $0)?.readUInt64() }
        #expect(values == [1, 2, 6])
    }

    /// Finding 29: after `Database.freeze()`, a held list and a second
    /// handle for it from the transaction's cursor. The held list's init is
    /// refused, as it would rewrite its slot in a record the second handle's
    /// copy leaves behind, its append is refused, the second handle's append
    /// commits, and nothing is lost.
    @Test(arguments: storageKinds)
    func aHeldHandleAfterAFreezeLosesNothing(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        try database.withTransaction { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let tasks = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha1("tasks").bytes))
            try tasks.append(.uint(1))
            try database.freeze()
            try fixture.expectRefused(.staleCursor) { _ = try LinkedArrayList<ReadWrite>(tasks.cursor) }
            let again = try HashMap<ReadWrite>(cursor)
            let tasksAgain = try LinkedArrayList<ReadWrite>(try again.putCursor(forHash: sha1("tasks").bytes))
            try tasksAgain.append(.uint(6))
            try fixture.expectRefused(.staleCursor) { try tasks.append(.uint(5)) }
            #expect(!database.poisoned)
        }
        let committed = try LinkedArrayList<ReadOnly>(try fixture.value("tasks"))
        let values = try (0..<Int(try committed.count)).map { try committed.cursor(at: $0)?.readUInt64() }
        #expect(values == [1, 6])
    }

    // MARK: A freeze while a byte writer is open

    /// `Database.freeze()` and a concat inside a byte writer's body are
    /// refused with `byteWriterOpen` before they move the frozen point,
    /// which would leave the writer's record below it; the body passes the
    /// error on, and the transaction is poisoned as after any body that
    /// throws, since the writer had appended. A freeze with no writer open
    /// is as before.
    @Test(arguments: storageKinds)
    func aFreezeWhileAByteWriterIsOpenIsRefused(kind: StorageKind) throws {
        let fixture = try Fixture(kind)
        let database = fixture.database
        let before = try fixture.bytes

        func freezeInsideTheBody(_ cursor: inout Cursor<ReadWrite>) throws {
            var value = try cursor.writePath([.hashMapGet(.value, sha1("bytes"))])
            let freezes = database.freezeNumber
            let outcome = Result { () throws -> Void in
                try value.writeBytes { writer in
                    try writer.write([1, 2, 3])
                    try database.freeze()
                }
            }
            #expect(throws: XitDBError.byteWriterOpen) { try outcome.get() }
            #expect(database.freezeNumber == freezes, "the frozen point did not move")
            #expect(database.poisoned)
        }
        expectPoisoned { try database.withTransaction(freezeInsideTheBody) }
        #expect(try fixture.bytes == before)

        func concatInsideTheBody(_ cursor: inout Cursor<ReadWrite>) throws {
            let moment = try HashMap<ReadWrite>(cursor)
            let list = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha1("list").bytes))
            let other = try LinkedArrayList<ReadWrite>(try moment.putCursor(forHash: sha1("other").bytes))
            try other.append(.uint(1))
            var value = try moment.putCursor(forHash: sha1("bytes").bytes)
            let freezes = database.freezeNumber
            let outcome = Result { () throws -> Void in
                try value.writeBytes { writer in
                    try writer.write([1, 2, 3])
                    try list.append(contentsOf: other)
                }
            }
            #expect(throws: XitDBError.byteWriterOpen) { try outcome.get() }
            #expect(database.freezeNumber == freezes)
        }
        expectPoisoned { try database.withTransaction(concatInsideTheBody) }
        #expect(try fixture.bytes == before)

        try database.withTransaction { cursor in
            try database.freeze()
            _ = try cursor.writePath([.hashMapInit(), .hashMapGet(.value, sha1("a")), .write(.uint(1))])
        }
        #expect(try fixture.value("a").readUInt64() == 1)
    }

}

/// Every byte of a storage, read through the storage protocol: its length,
/// then one read from the start. The protocol's read sees what a buffered
/// file still holds in memory, which the file on disk does not.
func wholeStorage(_ storage: some ReadableStorage) throws -> [UInt8] {
    let length = Int(try storage.length)
    var buffer = [UInt8](repeating: 0, count: length)
    var span = buffer.mutableSpan
    let read = try storage.read(into: &span, at: 0)
    try #require(read == length, "the storage read fewer bytes than its length")
    return buffer
}

/// The body for a byte writer that has to be refused before it runs: a
/// guard refuses the writer before the record is started, so the body
/// never sees a writer. It records an issue if it does.
private func bodyOfARefusedWriter(_ writer: inout ByteWriter) throws {
    Issue.record("the body of a refused byte writer ran")
}
