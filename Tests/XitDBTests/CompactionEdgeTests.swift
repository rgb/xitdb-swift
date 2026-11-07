import Testing

@testable import XitDB

/// What compaction does at the edges: a source nested as deep as a writer
/// cared to go, which is valid and must not need a stack to match; damaged
/// sources, each reported without a trap and without committing anything
/// in the target; and a target whose failed compaction the next one
/// truncates.
@Suite struct CompactionEdgeTests {
    /// Every pair of storage kinds, source and target.
    static let pairs: [(StorageKind, StorageKind)] = StorageKind.allCases.flatMap { source in
        StorageKind.allCases.map { (source, $0) }
    }

    private func makeDatabase(_ subject: StorageUnderTest) throws -> Database {
        try Database(
            storage: subject.storage, hashSize: 20, hashID: nil, fileID: 6,
            random: FixedRandom((1...50).map { UInt64($0) }))
    }

    /// Three thousand lists, each the only element of the one above it, with
    /// a number at the bottom: a depth that Zig's compactor would recurse
    /// through, and that the explicit stack walks in a debug build on the
    /// test thread's half-megabyte stack.
    @Test(arguments: StorageKind.allCases)
    func aDeeplyNestedSourceCompacts(kind: StorageKind) throws {
        let depth = 3000
        let subject = try StorageUnderTest(kind)
        let source = try makeDatabase(subject)
        var path: [PathPart] = []
        for _ in 0..<depth {
            path.append(.arrayListInit)
            path.append(.arrayListAppend)
        }
        path.append(.write(.uint(7)))
        _ = try source.rootCursor().writePath(path)

        let targetSubject = try StorageUnderTest(kind)
        var map = MemoryOffsetMap()
        let target = try source.compact(into: targetSubject.storage, fileID: 8, offsetMap: &map)

        // the root is a history: its one moment is the list at depth two,
        // and so on down
        var down: [PathPart] = []
        for _ in 0..<depth {
            down.append(.arrayListGet(0))
        }
        let bottom = try #require(try target.rootCursor().readPath(down))
        #expect(try bottom.readUint() == 7)
        #expect(try target.rootCursor().count() == 1)
        #expect(try target.committedSize() == (try targetSubject.storage.length()))
    }

    /// A source with every kind of object a damage can be put in, as a
    /// history of one moment.
    private struct Subject {
        let subject: StorageUnderTest
        let database: Database
        let moment: Cursor<ReadOnly>

        init(_ kind: StorageKind, makeDatabase: (StorageUnderTest) throws -> Database) throws {
            subject = try StorageUnderTest(kind)
            database = try makeDatabase(subject)
            try ArrayList(database.rootCursor()).appendContext(.slot(nil)) { cursor in
                let map = try HashMap(cursor)
                try map.put(sha1("bytes").bytes, .bytes(Array("a value long enough for a record".utf8)))
                let list = try ArrayList(try map.putCursor(sha1("list").bytes))
                for index in 0..<5 {
                    try list.append(.uint(UInt64(index)))
                }
                let linked = try LinkedArrayList(try map.putCursor(sha1("linked").bytes))
                for index in 0..<3 {
                    try linked.append(.uint(UInt64(index)))
                }
                let inner = try HashMap(try map.putCursor(sha1("map").bytes))
                try inner.put(sha1("k").bytes, .uint(9))
            }
            moment = try #require(try database.rootCursor().readPath([.arrayListGet(-1)]))
        }

        func slot(_ name: String) throws -> Slot {
            try #require(try moment.readPathSlot([.hashMapGet(.value, sha1(name))]))
        }

        func damage(_ bytes: [UInt8], at position: UInt64) throws {
            try writeBytes(subject.storage, bytes, at: position)
        }
    }

    /// Compacts the subject into a new target of `kind` and returns the
    /// error, or `nil` if it went through. A failure leaves the target as a
    /// transaction that did not commit: the write path rolls it back, so
    /// the target's root is still empty and its storage ends where its
    /// commits do.
    private func compacting(_ subject: Subject, into kind: StorageKind) throws -> (
        error: XitDBError?, target: Database, storage: StorageUnderTest
    ) {
        let targetSubject = try StorageUnderTest(kind)
        let target = try Database(
            storage: targetSubject.storage, hashSize: 20, hashID: nil, fileID: 8, random: FixedRandom([3, 4, 5]))
        var map = MemoryOffsetMap()
        do throws(XitDBError) {
            try subject.database.compact(into: target, offsetMap: &map)
        } catch {
            #expect(try target.rootCursor().slot().isEmpty)
            #expect(try targetSubject.storage.length() == (try target.committedSize()))
            return (error, target, targetSubject)
        }
        return (nil, target, targetSubject)
    }

    /// The sound subject compacts, on every pair of kinds.
    @Test(arguments: pairs)
    func theSoundSourceCompacts(kinds: (StorageKind, StorageKind)) throws {
        let subject = try Subject(kinds.0, makeDatabase: makeDatabase)
        let (error, target, _) = try compacting(subject, into: kinds.1)
        #expect(error == nil)
        let moment = try #require(try target.rootCursor().readPath([.arrayListGet(-1)]))
        #expect(
            try #require(try moment.readPath([.hashMapGet(.value, sha1("map")), .hashMapGet(.value, sha1("k"))]))
                .readUint() == 9)
        #expect(
            try #require(try moment.readPath([.hashMapGet(.value, sha1("linked")), .linkedArrayListGet(2)])).readUint()
                == 2)
    }

    /// A slot whose tag is not a tag: the first child of the moment's hash
    /// map that holds something.
    @Test(arguments: StorageKind.allCases)
    func aSlotWithAnUnknownTag(kind: StorageKind) throws {
        let subject = try Subject(kind, makeDatabase: makeDatabase)
        let block = try subject.moment.slot().value
        let slots = try subject.database.reader.indexBlock(at: block)
        let index = try #require((0..<16).first { slots.slots[$0].tag != .none })
        try subject.damage([0x7F], at: block + UInt64(index) * 9)
        #expect(try compacting(subject, into: kind).error == .invalidEnumTag)
    }

    /// A byte record whose length reaches past the end of the source is
    /// reported before any of it is copied.
    @Test(arguments: StorageKind.allCases)
    func aByteRecordPastTheSource(kind: StorageKind) throws {
        let subject = try Subject(kind, makeDatabase: makeDatabase)
        let record = try subject.slot("bytes")
        #expect(record.tag == .bytes)
        try subject.damage(bigEndianBytes(UInt64.max - 4), at: record.value)
        let (error, _, _) = try compacting(subject, into: kind)
        #expect(error == .endOfStream)
    }

    /// A tree node that says it has seventeen entries, and one that is
    /// neither leaf nor branch.
    @Test(arguments: StorageKind.allCases)
    func aNodeThatIsNotOne(kind: StorageKind) throws {
        let subject = try Subject(kind, makeDatabase: makeDatabase)
        let header = try subject.database.reader.bTreeHeader(at: try subject.slot("linked").value)
        try subject.damage([17], at: header.rootPtr + 1)
        #expect(try compacting(subject, into: kind).error == .invalidBTreeNode)
        try subject.damage([5, 3], at: header.rootPtr)
        #expect(try compacting(subject, into: kind).error == .invalidBTreeNodeKind)
    }

    /// An array list whose header says a hundred elements where its index
    /// holds five: the walk expects blocks of sixteen beneath the root and
    /// finds numbers.
    @Test(arguments: StorageKind.allCases)
    func aHeaderThatDisagreesWithItsTree(kind: StorageKind) throws {
        let subject = try Subject(kind, makeDatabase: makeDatabase)
        let header = try subject.slot("list").value
        try subject.damage(bigEndianBytes(100), at: header)
        #expect(try compacting(subject, into: kind).error == .unexpectedTag)
    }

    /// A hash trie whose block points at itself ends in the memo: the copy
    /// has the same block pointing at itself.
    @Test(arguments: StorageKind.allCases)
    func aTrieThatPointsAtItselfEnds(kind: StorageKind) throws {
        let subject = try Subject(kind, makeDatabase: makeDatabase)
        let block = try subject.slot("map").value
        try subject.damage(slotBytes(Slot(value: block, tag: .index)), at: block + 15 * 9)
        let (error, target, _) = try compacting(subject, into: kind)
        #expect(error == nil)
        let moment = try #require(try target.rootCursor().readPath([.arrayListGet(-1)]))
        let copied = try #require(try moment.readPathSlot([.hashMapGet(.value, sha1("map"))]))
        let slots = try target.reader.indexBlock(at: copied.value)
        #expect(slots.slots[15] == Slot(value: copied.value, tag: .index))
        #expect(
            try #require(try moment.readPath([.hashMapGet(.value, sha1("map")), .hashMapGet(.value, sha1("k"))]))
                .readUint() == 9)
    }

    /// A compaction that fails leaves the target as a transaction that did
    /// not commit, and the next compaction into it writes the same bytes as
    /// into a target that was never touched.
    @Test(arguments: StorageKind.allCases)
    func aFailedCompactionLeavesTheTargetForTheNext(kind: StorageKind) throws {
        let damaged = try Subject(kind, makeDatabase: makeDatabase)
        try damaged.damage(bigEndianBytes(UInt64.max - 4), at: try damaged.slot("bytes").value)
        let (error, target, storage) = try compacting(damaged, into: kind)
        #expect(error == .endOfStream)

        let sound = try Subject(kind, makeDatabase: makeDatabase)
        var map = MemoryOffsetMap()
        try sound.database.compact(into: target, offsetMap: &map)
        let fresh = try compacting(sound, into: kind)
        #expect(fresh.error == nil)
        let bytesAfter = try readBytes(storage.storage, at: 0, count: Int(try storage.storage.length()))
        let bytesFresh = try readBytes(fresh.storage.storage, at: 0, count: Int(try fresh.storage.storage.length()))
        #expect(bytesAfter == bytesFresh)
    }

    /// The source itself as the target, and a target with something in its
    /// root, are refused and left as they were.
    @Test(arguments: StorageKind.allCases)
    func aTargetThatIsNotEmptyIsRefused(kind: StorageKind) throws {
        let subject = try Subject(kind, makeDatabase: makeDatabase)
        var map = MemoryOffsetMap()
        let lengthBefore = try subject.subject.storage.length()
        #expect(throws: XitDBError.targetNotEmpty) {
            try subject.database.compact(into: subject.database, offsetMap: &map)
        }
        #expect(try subject.subject.storage.length() == lengthBefore)
        let other = try Subject(kind, makeDatabase: makeDatabase)
        #expect(throws: XitDBError.targetNotEmpty) {
            try subject.database.compact(into: other.database, offsetMap: &map)
        }
        // a target of another hash size is refused too
        let small = try StorageUnderTest(kind)
        let smallTarget = try Database(storage: small.storage, hashSize: 8)
        #expect(throws: XitDBError.invalidHashSize) {
            try subject.database.compact(into: smallTarget, offsetMap: &map)
        }
    }
}
