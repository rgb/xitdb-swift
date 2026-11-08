import Testing

@testable import XitDB

/// What compaction does at the edges: a source nested as deep as a writer
/// cared to go, which is valid and must not need a stack to match; damaged
/// sources, each reported without a trap and without committing anything
/// in the target; and a target whose failed compaction is discarded at
/// once, so that the next one writes into it as into a fresh target.
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
        _ = try source.rootCursor.writePath(path)

        let targetSubject = try StorageUnderTest(kind)
        var map = MemoryOffsetMap()
        let target = try source.compact(into: targetSubject.storage, fileID: 8, offsetMap: &map)

        // the root is a history: its one moment is the list at depth two,
        // and so on down
        var down: [PathPart] = []
        for _ in 0..<depth {
            down.append(.arrayListGet(0))
        }
        let bottom = try #require(try target.rootCursor.readPath(down))
        #expect(try bottom.readUInt64() == 7)
        #expect(try target.rootCursor.count == 1)
        #expect(try target.committedSize == (try targetSubject.storage.length))
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
            try ArrayList(database.rootCursor).append(.slot(nil)) { cursor in
                let map = try HashMap(cursor)
                try map.put(.bytes(Array("a value long enough for a record".utf8)), forHash: sha1("bytes").bytes)
                let list = try ArrayList(try map.putCursor(forHash: sha1("list").bytes))
                for index in 0..<5 {
                    try list.append(.uint(UInt64(index)))
                }
                let linked = try LinkedArrayList(try map.putCursor(forHash: sha1("linked").bytes))
                for index in 0..<3 {
                    try linked.append(.uint(UInt64(index)))
                }
                let inner = try HashMap(try map.putCursor(forHash: sha1("map").bytes))
                try inner.put(.uint(9), forHash: sha1("k").bytes)
            }
            moment = try #require(try database.rootCursor.readPath([.arrayListGet(-1)]))
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
            #expect(try target.rootCursor.slot.isEmpty)
            #expect(try targetSubject.storage.length == (try target.committedSize))
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
        let moment = try #require(try target.rootCursor.readPath([.arrayListGet(-1)]))
        #expect(
            try #require(try moment.readPath([.hashMapGet(.value, sha1("map")), .hashMapGet(.value, sha1("k"))]))
                .readUInt64() == 9)
        #expect(
            try #require(try moment.readPath([.hashMapGet(.value, sha1("linked")), .linkedArrayListGet(2)]))
                .readUInt64()
                == 2)
    }

    /// A slot whose tag is not a tag: the first child of the moment's hash
    /// map that holds something.
    @Test(arguments: StorageKind.allCases)
    func aSlotWithAnUnknownTag(kind: StorageKind) throws {
        let subject = try Subject(kind, makeDatabase: makeDatabase)
        let block = try subject.moment.slot.value
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

    /// A tree node whose kind byte is the last byte of the source: Zig
    /// reads the kind and checks it before it reads the count, so a kind
    /// that is not one is reported before the end, and a kind that is one
    /// reaches the end at the count.
    @Test(arguments: StorageKind.allCases)
    func aNodeWhoseKindIsTheLastByte(kind: StorageKind) throws {
        let subject = try Subject(kind, makeDatabase: makeDatabase)
        let header = try subject.slot("linked").value
        let end = try subject.subject.storage.length
        try subject.damage([5], at: end)
        try subject.damage(bigEndianBytes(end), at: header + 8)
        #expect(try compacting(subject, into: kind).error == .invalidBTreeNodeKind)
        try subject.damage([0], at: end)
        #expect(try compacting(subject, into: kind).error == .endOfStream)
    }

    /// A block whose first child runs past the end of the source, and whose
    /// next slot has a tag that is not one: Zig checks each slot as it
    /// reaches it, so the child's end is reported, not the later tag.
    @Test(arguments: StorageKind.allCases)
    func aChildPastTheEndBeforeATagThatIsNotOne(kind: StorageKind) throws {
        let subject = try Subject(kind, makeDatabase: makeDatabase)
        let block = try subject.moment.slot.value
        let slots = try subject.database.reader.indexBlock(at: block)
        let index = try #require((0..<16).first { slots.slots[$0].tag != .none })
        let slot = slots.slots[index]
        let end = try subject.subject.storage.length
        try subject.damage(
            slotBytes(Slot(value: end - 5, tag: slot.tag, full: slot.full)), at: block + UInt64(index) * 9)
        try subject.damage([0x7F], at: block + UInt64(index + 1) * 9)
        #expect(try compacting(subject, into: kind).error == .endOfStream)
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

    /// An array list whose header says the largest size there is: a trie
    /// of fifteen levels whose blocks of sixteen are nearly all full, so
    /// that the walk's arithmetic has no room for an overflow (it trapped
    /// on rounding the size up to blocks), and whose root block holds
    /// numbers where blocks are expected, which Zig reports as
    /// `UnexpectedTag`. The read path meets the same header and reports
    /// an error too: a get at the front of the list finds a number where a
    /// block should be, and one at the end finds nothing.
    @Test(arguments: StorageKind.allCases)
    func aHeaderAtTheLargestSize(kind: StorageKind) throws {
        let subject = try Subject(kind, makeDatabase: makeDatabase)
        let header = try subject.slot("list").value
        try subject.damage(bigEndianBytes(UInt64.max), at: header)
        #expect(try compacting(subject, into: kind).error == .unexpectedTag)

        let list = try #require(try subject.moment.readPath([.hashMapGet(.value, sha1("list"))]))
        #expect(try ArrayList(list).count == UInt64.max)
        for index in [Int64(0), 4, 15] {
            #expect(throws: XitDBError.unexpectedTag) { try list.readPath([.arrayListGet(index)]) }
            #expect(throws: XitDBError.unexpectedTag) { try ArrayList(list).cursor(at: index) }
        }
        #expect(try list.readPath([.arrayListGet(-1)]) == nil)
        #expect(try ArrayList(list).cursor(at: -1) == nil)
        #expect(try ArrayList(list).cursor(at: Int64.max) == nil)
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
        let moment = try #require(try target.rootCursor.readPath([.arrayListGet(-1)]))
        let copied = try #require(try moment.readPathSlot([.hashMapGet(.value, sha1("map"))]))
        let slots = try target.reader.indexBlock(at: copied.value)
        #expect(slots.slots[15] == Slot(value: copied.value, tag: .index))
        #expect(
            try #require(try moment.readPath([.hashMapGet(.value, sha1("map")), .hashMapGet(.value, sha1("k"))]))
                .readUInt64() == 9)
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
        let bytesAfter = try readBytes(storage.storage, at: 0, count: Int(try storage.storage.length))
        let bytesFresh = try readBytes(fresh.storage.storage, at: 0, count: Int(try fresh.storage.storage.length))
        #expect(bytesAfter == bytesFresh)
    }

    /// A sorted map whose tree has a branch, and whose keys are long enough
    /// to be records, so that its separators are records too: every one is
    /// copied, and the keys are found through them in the target.
    @Test(arguments: StorageKind.allCases)
    func aSortedMapWithRecordSeparatorsCompacts(kind: StorageKind) throws {
        let keys = (0..<40).map { Array("a key long enough for a record \($0 < 10 ? "0" : "")\($0)".utf8) }
        let subject = try StorageUnderTest(kind)
        let source = try makeDatabase(subject)
        try source.withTransaction { cursor in
            let map = try SortedMap(try HashMap(cursor).putCursor(forHash: sha1("sorted").bytes))
            for (index, key) in keys.enumerated() {
                try map.put(.uint(UInt64(index)), forKey: key)
            }
        }
        let sourceHeader = try source.reader.bTreeHeader(
            at: try #require(try source.rootCursor.readPathSlot([.hashMapGet(.value, sha1("sorted"))])).value)
        #expect(try source.reader.sortedNode(at: sourceHeader.rootPtr).kind == .branch)

        let targetSubject = try StorageUnderTest(kind)
        var map = MemoryOffsetMap()
        let target = try source.compact(into: targetSubject.storage, fileID: 8, offsetMap: &map)
        let copied = try SortedMap(
            try #require(try HashMap(target.rootCursor.readOnly).cursor(forHash: sha1("sorted").bytes)))
        for (index, key) in keys.enumerated() {
            #expect(try #require(try copied.cursor(forKey: key)).readUInt64() == UInt64(index))
            #expect(try copied.rank(of: key) == UInt64(index))
        }
        // the separators are records in the target, not in the source
        let header = try target.reader.bTreeHeader(at: try copied.slot.value)
        let root = try target.reader.sortedNode(at: header.rootPtr)
        let length = try targetSubject.storage.length
        for index in 1..<Int(root.num) {
            #expect(root.separators[index].tag == .bytes)
            #expect(root.separators[index].value < length)
            let key = keys[8 * index]
            let order = try SortedKey(key).withBytes { (bytes: Span<UInt8>) throws(XitDBError) in
                try target.reader.compareKey(root.separators[index], to: bytes)
            }
            #expect(order == .equal)
        }
    }

    /// An empty source commits nothing in the target, which is left as it
    /// was byte for byte; a root set to nothing is not empty, and is copied
    /// as a commit.
    @Test(arguments: StorageKind.allCases)
    func anEmptySourceCommitsNothing(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let source = try makeDatabase(subject)
        let targetSubject = try StorageUnderTest(kind)
        let target = try Database(storage: targetSubject.storage, hashSize: 20, fileID: 8)
        let before = try readBytes(targetSubject.storage, at: 0, count: Int(try targetSubject.storage.length))
        var map = MemoryOffsetMap()
        try source.compact(into: target, offsetMap: &map)
        let after = try readBytes(targetSubject.storage, at: 0, count: Int(try targetSubject.storage.length))
        #expect(after == before)
        #expect(try target.rootCursor.slot.isEmpty)

        // but a root set to nothing is copied, as a commit
        var root = source.rootCursor
        try root.write(.slot(nil))
        try source.compact(into: target, offsetMap: &map)
        #expect(try targetSubject.storage.length > UInt64(before.count))
        #expect(try target.rootCursor.slot == Slot(value: 0, tag: .none, full: true))
    }

    /// A list at the root whose last element is empty, because the list
    /// has no elements or its last element was appended and never written,
    /// is refused before anything is written: Zig compacts it to an empty
    /// database, losing the list and every element before the empty one
    /// (finding 28). The source is checked before the target, so a target
    /// that holds data is refused for the source's reason, and the shape
    /// that opens the target refuses before opening it. A last element set
    /// to nothing is a moment, and compacts.
    @Test(arguments: StorageKind.allCases)
    func aRootListWhoseLastElementIsEmptyIsRefused(kind: StorageKind) throws {
        func allBytes(_ subject: StorageUnderTest) throws -> [UInt8] {
            try readBytes(subject.storage, at: 0, count: Int(try subject.storage.length))
        }
        func refusing(_ prepare: (Database) throws -> Void) throws {
            let subject = try StorageUnderTest(kind)
            let source = try makeDatabase(subject)
            try prepare(source)
            let sourceBefore = try allBytes(subject)
            var map = MemoryOffsetMap()

            // a target opened by the caller is left as it was
            let targetSubject = try StorageUnderTest(kind)
            let target = try Database(storage: targetSubject.storage, hashSize: 20, fileID: 8)
            let targetBefore = try allBytes(targetSubject)
            #expect(throws: XitDBError.emptyLastMoment) { try source.compact(into: target, offsetMap: &map) }
            #expect(try allBytes(targetSubject) == targetBefore)

            // a target that holds data is refused for the source's reason
            let heldSubject = try StorageUnderTest(kind)
            let held = try Database(storage: heldSubject.storage, hashSize: 20, fileID: 9)
            try HashMap<ReadWrite>(held.rootCursor).put(.uint(1), forHash: sha1("held").bytes)
            let heldBefore = try allBytes(heldSubject)
            #expect(throws: XitDBError.emptyLastMoment) { try source.compact(into: held, offsetMap: &map) }
            #expect(try allBytes(heldSubject) == heldBefore)

            // the shape that opens the target refuses before opening it
            let emptySubject = try StorageUnderTest(kind)
            #expect(throws: XitDBError.emptyLastMoment) {
                _ = try source.compact(into: emptySubject.storage, offsetMap: &map)
            }
            #expect(try emptySubject.storage.length == 0)

            #expect(try allBytes(subject) == sourceBefore)
        }

        // three written moments and one appended, never written
        try refusing { source in
            let history = try ArrayList<ReadWrite>(source.rootCursor)
            for round in 1...3 {
                try history.append(.slot(try history.slot(at: -1))) { cursor in
                    try HashMap<ReadWrite>(cursor).put(.uint(UInt64(round)), forHash: sha1("round-\(round)").bytes)
                }
            }
            _ = try history.appendCursor()
            #expect(try history.count == 4)
        }
        // a history with no moments
        try refusing { source in
            _ = try source.rootCursor.writePath([.arrayListInit])
            #expect(try source.rootCursor.count == 0)
        }

        // but a last moment set to nothing is a moment, and compacts
        let subject = try StorageUnderTest(kind)
        let source = try makeDatabase(subject)
        let history = try ArrayList<ReadWrite>(source.rootCursor)
        try history.append(.uint(1))
        try history.append(.slot(nil))
        var map = MemoryOffsetMap()
        let targetSubject = try StorageUnderTest(kind)
        let target = try source.compact(into: targetSubject.storage, offsetMap: &map)
        let compacted = try ArrayList<ReadOnly>(target.rootCursor)
        #expect(try compacted.count == 1)
        #expect(try compacted.slot(at: 0) == Slot(value: 0, tag: .none, full: true))
    }

    /// A tree branch whose child points back at its root: the memo ends the
    /// walk, and the copy has the same cycle. For the linked array list and
    /// the sorted map, whose nodes are memoised by their own offsets.
    @Test(arguments: StorageKind.allCases)
    func aTreeThatPointsAtItselfEnds(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let source = try makeDatabase(subject)
        try source.withTransaction { cursor in
            let map = try HashMap(cursor)
            let linked = try LinkedArrayList(try map.putCursor(forHash: sha1("linked").bytes))
            for index in 0..<40 {
                try linked.append(.uint(UInt64(index)))
            }
            let sorted = try SortedMap(try map.putCursor(forHash: sha1("sorted").bytes))
            for index in 0..<40 {
                try sorted.put(.uint(UInt64(index)), forKey: Array("k\(index)".utf8))
            }
        }
        // the last child of each root points at the root
        for name in ["linked", "sorted"] {
            let header = try source.reader.bTreeHeader(
                at: try #require(try source.rootCursor.readPathSlot([.hashMapGet(.value, sha1(name))])).value)
            let num = try source.reader.sortedNode(at: header.rootPtr).num
            try writeBytes(
                subject.storage, slotBytes(Slot(value: header.rootPtr, tag: .index)),
                at: header.rootPtr + 2 + UInt64(num - 1) * 9)
        }
        let targetSubject = try StorageUnderTest(kind)
        var map = MemoryOffsetMap()
        let target = try source.compact(into: targetSubject.storage, fileID: 8, offsetMap: &map)
        for name in ["linked", "sorted"] {
            let header = try target.reader.bTreeHeader(
                at: try #require(try target.rootCursor.readPathSlot([.hashMapGet(.value, sha1(name))])).value)
            let root = try target.reader.sortedNode(at: header.rootPtr)
            #expect(root.children[Int(root.num) - 1] == Slot(value: header.rootPtr, tag: .index))
            #expect(root.children[0].tag == .index)
            #expect(root.children[0].value != header.rootPtr)
        }
    }

    /// The target that `compact(into:hashID:fileID:offsetMap:)` opens takes
    /// the source's hash ID unless one is given, and draws from the
    /// source's random source, as Zig's target is opened with the source's
    /// `io`: its file ID when none is given, then its commit ID, and the
    /// source's next commit draws after them. A storage that holds an
    /// empty database keeps that database's IDs.
    @Test(arguments: StorageKind.allCases)
    func theOpenedTargetTakesTheSourcesHashIDAndRandom(kind: StorageKind) throws {
        let random = FixedRandom([11, 12, 13, 14, 15, 16])
        let subject = try StorageUnderTest(kind)
        let source = try Database(storage: subject.storage, hashSize: 20, hashID: "sha1", fileID: 6, random: random)
        try source.withTransaction { cursor in try HashMap(cursor).put(.uint(1), forHash: sha1("k").bytes) }
        #expect(random.remaining == 5)
        var map = MemoryOffsetMap()

        // nothing given: the source's hash ID, the next value as the file
        // ID, the one after as the commit ID
        let target = try source.compact(into: try StorageUnderTest(kind).storage, offsetMap: &map)
        #expect(target.header.hashID == "sha1")
        #expect(target.header.hashSize == 20)
        #expect(target.header.fileID == 12)
        #expect(try target.reader.rootTrailer(endingAt: try target.committedSize).commitID == 13)
        #expect(random.remaining == 3)

        // both given: only the commit ID is drawn
        let named = try source.compact(
            into: try StorageUnderTest(kind).storage, hashID: "blk3", fileID: 99, offsetMap: &map)
        #expect(named.header.hashID == "blk3")
        #expect(named.header.fileID == 99)
        #expect(try named.reader.rootTrailer(endingAt: try named.committedSize).commitID == 14)
        #expect(random.remaining == 2)

        // an existing empty database keeps its IDs, and only the commit ID
        // is drawn
        let existingSubject = try StorageUnderTest(kind)
        _ = try Database(
            storage: existingSubject.storage, hashSize: 20, hashID: "md5?", fileID: 77, random: FixedRandom([1]))
        let existing = try source.compact(into: existingSubject.storage, hashID: "blk3", fileID: 99, offsetMap: &map)
        #expect(existing.header.hashID == "md5?")
        #expect(existing.header.fileID == 77)
        #expect(try existing.reader.rootTrailer(endingAt: try existing.committedSize).commitID == 15)
        #expect(random.remaining == 1)

        // the source's next commit continues after them
        try source.withTransaction { cursor in try HashMap(cursor).put(.uint(2), forHash: sha1("k").bytes) }
        #expect(try source.reader.rootTrailer(endingAt: try source.committedSize).commitID == 16)
        #expect(random.remaining == 0)
        #expect(!random.exhausted)
        for compacted in [target, named, existing] {
            #expect(
                try #require(try HashMap(compacted.rootCursor.readOnly).cursor(forHash: sha1("k").bytes)).readUInt64()
                    == 1)
        }
    }

    /// The source itself as the target, and a target with something in its
    /// root, are refused and left as they were.
    @Test(arguments: StorageKind.allCases)
    func aTargetThatIsNotEmptyIsRefused(kind: StorageKind) throws {
        let subject = try Subject(kind, makeDatabase: makeDatabase)
        var map = MemoryOffsetMap()
        let lengthBefore = try subject.subject.storage.length
        #expect(throws: XitDBError.targetNotEmpty) {
            try subject.database.compact(into: subject.database, offsetMap: &map)
        }
        #expect(try subject.subject.storage.length == lengthBefore)
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

    /// What an offset map of the tests' own throws.
    private struct Refused: Error, CustomStringConvertible {
        var description: String { "refused by the test" }
    }

    /// An offset map that throws on one of its operations and otherwise
    /// keeps its mappings in memory.
    private struct ThrowingOffsetMap: OffsetMap {
        enum Operation {
            case reset, get, put
        }
        let failing: Operation
        private var memory = MemoryOffsetMap()

        init(failing: Operation) {
            self.failing = failing
        }

        mutating func reset() throws {
            if failing == .reset { throw Refused() }
            memory.reset()
        }

        mutating func get(_ sourceOffset: UInt64) throws -> UInt64? {
            if failing == .get { throw Refused() }
            return memory.get(sourceOffset)
        }

        mutating func put(_ sourceOffset: UInt64, _ targetOffset: UInt64) throws {
            if failing == .put { throw Refused() }
            memory.put(sourceOffset, targetOffset)
        }
    }

    /// An offset map that throws has its error carried as `callerError`,
    /// from whichever operation: the reset before anything is written, a
    /// lookup or a record during the walk. The source is left as it was
    /// and the target as a transaction that did not commit; through the
    /// compaction that opens its target, a reset that throws leaves the
    /// storage untouched, since the map is reset before the target is
    /// opened, as in Zig.
    @Test(arguments: StorageKind.allCases)
    func anOffsetMapThatThrows(kind: StorageKind) throws {
        let subject = try Subject(kind, makeDatabase: makeDatabase)
        let sourceStorage = subject.subject.storage
        let sourceBytes = try readBytes(sourceStorage, at: 0, count: Int(try sourceStorage.length))
        for operation in [ThrowingOffsetMap.Operation.reset, .get, .put] {
            let targetSubject = try StorageUnderTest(kind)
            let target = try Database(
                storage: targetSubject.storage, hashSize: 20, hashID: nil, fileID: 8, random: FixedRandom([3]))
            var map = ThrowingOffsetMap(failing: operation)
            #expect(throws: XitDBError.callerError(Refused())) {
                try subject.database.compact(into: target, offsetMap: &map)
            }
            #expect(try target.rootCursor.slot.isEmpty)
            #expect(try targetSubject.storage.length == (try target.committedSize))
        }
        #expect(try readBytes(sourceStorage, at: 0, count: Int(try sourceStorage.length)) == sourceBytes)

        let untouched = try StorageUnderTest(kind)
        var map = ThrowingOffsetMap(failing: .reset)
        #expect(throws: XitDBError.callerError(Refused())) {
            try subject.database.compact(into: untouched.storage, fileID: 8, offsetMap: &map)
        }
        #expect(try untouched.storage.length == 0)
    }

    /// The target's storage failing during a compaction: at a write of the
    /// walk, at the first sync of the commit, and at its second. The error
    /// is reported and the source left as it was; the target is a
    /// transaction that did not commit, until the root header is written,
    /// after which the commit is made and only its last sync is missing.
    @Test(arguments: StorageKind.allCases)
    func aTargetStorageThatFails(kind: StorageKind) throws {
        let subject = try Subject(kind, makeDatabase: makeDatabase)
        let sourceStorage = subject.subject.storage
        let sourceBytes = try readBytes(sourceStorage, at: 0, count: Int(try sourceStorage.length))

        func compacting(faults: (FaultInjectingStorage) -> [FaultInjectingStorage.Fault]) throws -> (
            target: Database, storage: FaultInjectingStorage
        ) {
            let faulty = FaultInjectingStorage(try StorageUnderTest(kind).storage)
            let target = try Database(storage: faulty, hashSize: 20, hashID: nil, fileID: 8, random: FixedRandom([3]))
            faulty.faults = faults(faulty)
            var map = MemoryOffsetMap()
            #expect(throws: FaultInjectingStorage.failure) {
                try subject.database.compact(into: target, offsetMap: &map)
            }
            faulty.faults = []
            return (target, faulty)
        }

        // a write in the middle of the walk
        let midway = try compacting { [.failWrite($0.writeCount + 6)] }
        #expect(try midway.target.rootCursor.slot.isEmpty)
        #expect(try midway.storage.length == (try midway.target.committedSize))

        // the sync before the root header
        let unsynced = try compacting { [.failSync($0.syncCount + 1)] }
        #expect(try unsynced.target.rootCursor.slot.isEmpty)
        #expect(try unsynced.storage.length == (try unsynced.target.committedSize))

        // the sync after it: the commit is made
        let committed = try compacting { [.failSync($0.syncCount + 2)] }
        #expect(try committed.target.rootCursor.count == 1)
        #expect(try committed.storage.length == (try committed.target.committedSize))
        let moment = try #require(try committed.target.rootCursor.readPath([.arrayListGet(-1)]))
        #expect(
            try #require(try moment.readPath([.hashMapGet(.value, sha1("map")), .hashMapGet(.value, sha1("k"))]))
                .readUInt64() == 9)

        #expect(try readBytes(sourceStorage, at: 0, count: Int(try sourceStorage.length)) == sourceBytes)
    }
}
