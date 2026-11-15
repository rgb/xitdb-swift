import Testing

@testable import XitDB

/// What no file can make a read do: four things the read side holds what
/// it reads to, so that no file makes a read run without end or outside the
/// file's data.
///
/// - A size the file has no room for is refused (`invalidCount`): an array
///   list's, a sorted map's or set's, and a counted hash map's or set's
///   count.
/// - No record is read before where data starts (`endOfStream`).
/// - A walk of a hash trie enters no more blocks than the file has room for
///   (`keyOffsetExceeded`).
/// - A walk of a tree enters no more nodes than its file, or the elements
///   it gives, allow (`invalidBTreeNode`): a sorted map's or set's no more
///   than the file has room for, a linked array list's no more than
///   sixty-five for each element given and for the next.
///
/// No count is held against the tree under it: the files whose header or
/// whose branch disagrees with its tree are in `DamagedTreeTests` and
/// `DamagedSortedTreeTests`, read as they were, and the ones a copy by slot
/// leaves are in the examples' `FreezeHazardTable`.
@Suite struct ReadBoundTests {
    /// The forty keys of the sorted collections, "k00" to "k39", which sort
    /// in the order of their numbers.
    static let keys = (0..<40).map { Array("k\($0 < 10 ? "0" : "")\($0)".utf8) }

    /// The hashes of the three entries each hashed collection holds.
    static let entries = (0..<3).map { sha1("entry \($0)") }

    /// A database with one of every kind of collection under a map at the
    /// root, written in one transaction: an array list and a linked array
    /// list of the numbers 0 to 39, a sorted map from the forty keys to
    /// those numbers and a sorted set of the keys, and a hash map, a hash
    /// set and their counted kinds of three entries each. The two lists'
    /// and the two sorted collections' trees are a root over four leaves of
    /// 8, 8, 8 and 16.
    private struct Subject {
        let subject: StorageUnderTest
        let database: Database

        /// - Parameter room: The length of a byte array stored under
        ///   "room", for a test that writes blocks of its own into bytes
        ///   that are committed; nothing is stored for zero.
        init(_ kind: StorageKind, version: FormatVersion = .two, room: Int = 0) throws {
            subject = try StorageUnderTest(kind)
            database = try newDatabase(version, in: subject.storage, random: FixedRandom((1...50).map { UInt64($0) }))
            try database.withTransaction { cursor in
                let root = try HashMap(cursor)
                let arrayList = try ArrayList(try root.putCursor(forHash: sha1("arrayList").bytes))
                let linked = try LinkedArrayList(try root.putCursor(forHash: sha1("linkedArrayList").bytes))
                for number in 0..<40 {
                    try arrayList.append(.uint(UInt64(number)))
                    try linked.append(.uint(UInt64(number)))
                }
                let sortedMap = try SortedMap(try root.putCursor(forHash: sha1("sortedMap").bytes))
                let sortedSet = try SortedSet(try root.putCursor(forHash: sha1("sortedSet").bytes))
                for (number, key) in ReadBoundTests.keys.enumerated() {
                    try sortedMap.put(.uint(UInt64(number)), forKey: key)
                    try sortedSet.insert(key)
                }
                let hashMap = try HashMap(try root.putCursor(forHash: sha1("hashMap").bytes))
                let hashSet = try HashSet(try root.putCursor(forHash: sha1("hashSet").bytes))
                let countedHashMap = try CountedHashMap(try root.putCursor(forHash: sha1("countedHashMap").bytes))
                let countedHashSet = try CountedHashSet(try root.putCursor(forHash: sha1("countedHashSet").bytes))
                for (number, hash) in ReadBoundTests.entries.enumerated() {
                    try hashMap.put(.uint(UInt64(number)), forHash: hash.bytes)
                    try hashSet.insert(.uint(UInt64(number)), forHash: hash.bytes)
                    try countedHashMap.put(.uint(UInt64(number)), forHash: hash.bytes)
                    try countedHashSet.insert(.uint(UInt64(number)), forHash: hash.bytes)
                }
                if room > 0 {
                    try root.put(.bytes(zeros(room)), forHash: sha1("room").bytes)
                }
            }
        }

        /// The storage's length now.
        var length: UInt64 {
            get throws { try subject.storage.length }
        }

        /// The slot the root map has for the collection of that name.
        func slot(_ name: String) throws -> Slot {
            try #require(try database.rootCursor.readPathSlot([.hashMapGet(.value, sha1(name))]))
        }

        /// Where the root map keeps the slot of that name.
        func slotPosition(_ name: String) throws -> UInt64 {
            let cursor = try #require(try database.rootCursor.readPath([.hashMapGet(.value, sha1(name))]))
            return try #require(cursor.slotPointer.position)
        }

        /// The header of the tree of that name.
        func tree(_ name: String) throws -> (headerPtr: UInt64, rootPtr: UInt64) {
            let headerPtr = try slot(name).value
            return (headerPtr, try database.reader.bTreeHeader(at: headerPtr).rootPtr)
        }

        /// Writes `bytes` over the file at `position`, and through to the
        /// file where the storage has a buffer, so that a snapshot, which
        /// reads the file, sees them.
        func write(_ bytes: [UInt8], at position: UInt64) throws {
            try writeBytes(subject.storage, bytes, at: position)
            try subject.storage.flush()
        }

        /// The database opened again on the file as it is now.
        func reopened() throws -> Database {
            try Database(opening: subject.storage, hashSize: 20, random: FixedRandom([99]))
        }

        /// Writes `bytes` over the file at `position` and opens the
        /// database again on it.
        func damaged(_ bytes: [UInt8], at position: UInt64) throws -> Database {
            try write(bytes, at: position)
            return try reopened()
        }
    }

    /// A cursor at the collection of that name, as the last commit of
    /// `database` has it.
    private func cursor(_ name: String, in database: Database) throws -> Cursor<ReadOnly> {
        try #require(try database.rootCursor.readPath([.hashMapGet(.value, sha1(name))]))
    }

    /// Whether `read` ends in `endOfStream`.
    private func endsTheStream(_ read: () throws -> Void) -> Bool {
        do {
            try read()
            return false
        } catch let error as XitDBError {
            return error == .endOfStream
        } catch {
            return false
        }
    }

    // MARK: A size within the file

    /// The collections whose size is held against what the file could hold.
    enum Sized: String, CaseIterable, CustomTestStringConvertible {
        case arrayList, sortedMap, sortedSet, countedHashMap, countedHashSet

        var testDescription: String { rawValue }

        /// The bytes one element has to itself: a slot, or a pair of a
        /// hash of twenty bytes and two slots.
        var bytesEach: UInt64 {
            switch self {
            case .arrayList, .sortedMap, .sortedSet: 9
            case .countedHashMap, .countedHashSet: 38
            }
        }
    }

    /// Every read that takes the collection's size, by name.
    private func reads(of sized: Sized) -> [(String, (Cursor<ReadOnly>) throws -> Void)] {
        let key = Self.keys[5]
        switch sized {
        case .arrayList:
            return [
                ("count", { _ = try $0.count }),
                ("the list's count", { _ = try ArrayList($0).count }),
                ("get", { _ = try ArrayList($0).cursor(at: 0) }),
                ("get from the end", { _ = try ArrayList($0).cursor(at: -1) }),
                ("slot", { _ = try ArrayList($0).slot(at: 0) }),
                ("walk", { _ = try ArrayList($0).iterator() }),
                ("walk from a position", { _ = try ArrayList($0).iterator(fromIndex: 3) }),
                ("the cursor's walk", { _ = try $0.iterator() }),
            ]
        case .sortedMap:
            return [
                ("count", { _ = try $0.count }),
                ("the map's count", { _ = try SortedMap($0).count }),
                ("get", { _ = try SortedMap($0).cursor(forKey: key) }),
                ("entry at", { _ = try SortedMap($0).entry(at: 0) }),
                ("rank", { _ = try SortedMap($0).rank(of: key) }),
                ("walk", { _ = try SortedMap($0).iterator() }),
                ("walk from a position", { _ = try SortedMap($0).iterator(fromIndex: 3) }),
                ("walk from a key", { _ = try SortedMap($0).iterator(fromKey: key) }),
                ("the cursor's walk", { _ = try $0.iterator() }),
            ]
        case .sortedSet:
            return [
                ("count", { _ = try $0.count }),
                ("the set's count", { _ = try SortedSet($0).count }),
                ("contains", { _ = try SortedSet($0).contains(key) }),
                ("entry at", { _ = try SortedSet($0).entry(at: 0) }),
                ("rank", { _ = try SortedSet($0).rank(of: key) }),
                ("walk", { _ = try SortedSet($0).iterator() }),
                ("walk from a position", { _ = try SortedSet($0).iterator(fromIndex: 3) }),
                ("walk from a key", { _ = try SortedSet($0).iterator(fromKey: key) }),
                ("the cursor's walk", { _ = try $0.iterator() }),
            ]
        case .countedHashMap:
            return [
                ("count", { _ = try $0.count }),
                ("the map's count", { _ = try CountedHashMap($0).count }),
            ]
        case .countedHashSet:
            return [
                ("count", { _ = try $0.count }),
                ("the set's count", { _ = try CountedHashSet($0).count }),
            ]
        }
    }

    /// The largest size the file has room for is read as it is, and one
    /// more is refused by every read that takes the size, on every storage:
    /// each element of an array list or a sorted collection has a slot of
    /// its own, and each entry of a counted map or set a pair of its own.
    @Test(arguments: StorageKind.allCases, Sized.allCases)
    func aSizeTheFileHasNoRoomForIsRefused(kind: StorageKind, sized: Sized) throws {
        // A file whose length is a multiple of a slot's nine bytes and of a
        // pair's thirty-eight, so that the largest size fills it exactly.
        let measured = try Subject(kind, room: 400)
        let subject = try Subject(kind, room: 400 + Int((342 - (try measured.length) % 342) % 342))
        try #require(try subject.length % 342 == 0)
        // the size is the first eight bytes of each of these headers
        let sizePtr = try subject.slot(sized.rawValue).value
        let most = try subject.length / sized.bytesEach

        let fitting = try subject.damaged(bigEndianBytes(most), at: sizePtr)
        #expect(try cursor(sized.rawValue, in: fitting).count == most)

        let refused = try subject.damaged(bigEndianBytes(most + 1), at: sizePtr)
        let collection = try cursor(sized.rawValue, in: refused)
        for (name, read) in reads(of: sized) {
            #expect(throws: XitDBError.invalidCount, "\(name)") { try read(collection) }
        }
        // and so is one whose bytes come to more than a number holds
        let overflowing = try subject.damaged(bigEndianBytes(UInt64.max / sized.bytesEach + 1), at: sizePtr)
        #expect(throws: XitDBError.invalidCount) { try cursor(sized.rawValue, in: overflowing).count }
    }

    /// A linked array list's size is not held against the file: a list
    /// joined to itself holds its nodes twice, so it can have more elements
    /// than the file has slots.
    @Test(arguments: StorageKind.allCases)
    func aLinkedArrayListsSizeIsNotHeldToTheFile(kind: StorageKind) throws {
        let subject = try Subject(kind)
        // a list of sixteen joined to itself twelve times over, each join in a transaction of its own
        try subject.database.withTransaction { cursor in
            let list = try LinkedArrayList(try HashMap(cursor).putCursor(forHash: sha1("doubled").bytes))
            for number in 0..<16 {
                try list.append(.uint(UInt64(number)))
            }
        }
        for _ in 0..<12 {
            try subject.database.withTransaction { cursor in
                let list = try LinkedArrayList(try HashMap(cursor).putCursor(forHash: sha1("doubled").bytes))
                try list.append(contentsOf: try list.slot)
            }
        }
        let doubled = try LinkedArrayList(try cursor("doubled", in: subject.database))
        #expect(try doubled.count == 65536)
        #expect(try subject.length < 65536 * 9, "the list has more elements than the file has room for slots")
        #expect(try #require(try doubled.cursor(at: 65535)).readUInt64() == 15)
        var walked: UInt64 = 0
        var iterator = try doubled.iterator()
        while let element = try iterator.next() {
            #expect(try element.readUInt64() == walked % 16)
            walked += 1
        }
        #expect(walked == 65536)

        // A size that no file has room for is read as it is. Nothing holds
        // it against the tree either: a position the tree has answers, and
        // one it does not have is where the descent runs out of tree.
        let sizePtr = try subject.slot("linkedArrayList").value
        let damaged = try subject.damaged(bigEndianBytes(UInt64.max), at: sizePtr)
        let list = try cursor("linkedArrayList", in: damaged)
        #expect(try list.count == .max)
        #expect(try #require(try LinkedArrayList(list).cursor(at: 39)).readUInt64() == 39)
        #expect(throws: XitDBError.invalidBTreeNode) { try LinkedArrayList(list).cursor(at: 40) }
    }

    /// A snapshot is bounded by its commit's size and a live database by
    /// its file's length, which it asks for again when a size does not fit
    /// the length it knew.
    @Test(arguments: StorageKind.allCases)
    func aSnapshotIsBoundedByItsCommitAndALiveDatabaseByItsFile(kind: StorageKind) throws {
        let subject = try Subject(kind)
        let sizePtr = try subject.slot("arrayList").value
        // a size the file has no room for until it has grown by nine thousand bytes
        let size = try subject.length / 9 + 1000
        let database = try subject.damaged(bigEndianBytes(size), at: sizePtr)
        #expect(throws: XitDBError.invalidCount) { try cursor("arrayList", in: database).count }
        let snapshot = try database.snapshot()
        func countInSnapshot() throws -> UInt64 {
            try #require(try snapshot.rootCursor.readPath([.hashMapGet(.value, sha1("arrayList"))])).count
        }
        #expect(throws: XitDBError.invalidCount) { try countInSnapshot() }

        try database.withTransaction { cursor in
            try HashMap(cursor).put(.bytes(zeros(10_000)), forHash: sha1("more").bytes)
        }
        #expect(try cursor("arrayList", in: database).count == size)
        #expect(throws: XitDBError.invalidCount) { try countInSnapshot() }
    }

    // MARK: No record before where data starts

    /// Every reader of a record refuses a position before where data
    /// starts, 32 in a version 2 file and 37 in a version 1 file, whatever
    /// the bytes there would decode as, and reads the first byte of data as
    /// any other.
    @Test(arguments: FormatVersion.allCases)
    func noRecordIsReadBeforeWhereDataStarts(version: FormatVersion) throws {
        let subject = try Subject(.memory, version: version)
        let reader = subject.database.reader
        let dataStart: UInt64 = version == .one ? 37 : 32
        #expect(subject.database.header.dataStart == dataStart)

        func reads(at position: UInt64) -> [(String, () throws -> Void)] {
            [
                ("slot", { _ = try reader.slot(at: position) }),
                ("number", { _ = try reader.uint64(at: position) }),
                ("array list header", { _ = try reader.arrayListHeader(at: position) }),
                ("tree header", { _ = try reader.bTreeHeader(at: position) }),
                ("index block", { _ = try reader.indexBlock(at: position) }),
                ("sorted pair", { _ = try reader.sortedPair(at: position) }),
                ("hashed pair", { _ = try reader.hashedPair(at: position) }),
                ("list node", { _ = try reader.bTreeNode(at: position) }),
                ("sorted node", { _ = try reader.sortedNode(at: position) }),
                ("list descent", { _ = try reader.linkedArrayListSlot(rootPtr: position, rank: 0) }),
                ("sorted descent", { _ = try reader.sortedSlot(rootPtr: position, rank: 0) }),
            ]
        }
        for (name, read) in reads(at: dataStart - 1) {
            #expect(throws: XitDBError.endOfStream, "\(name)") { try read() }
        }
        for (name, read) in reads(at: 0) {
            #expect(throws: XitDBError.endOfStream, "\(name)") { try read() }
        }
        for (name, read) in reads(at: dataStart) {
            #expect(!endsTheStream(read), "\(name)")
        }
    }

    /// A pair is read by its own function, in one of two ways by the size
    /// of the database's hashes, up to sixty-four bytes or more: both
    /// refuse a pair before where data starts and read one at the data's
    /// first byte.
    @Test(arguments: [20, 65])
    func aPairOfAnyHashSizeBeforeTheDataIsRefused(hashSize: Int) throws {
        let database = try Database(creating: MemoryStorage(), hashSize: hashSize)
        try LargeHashTests.fill(database, hashSize: hashSize)
        let dataStart = database.header.dataStart
        #expect(throws: XitDBError.endOfStream) { try database.reader.hashedPair(at: dataStart - 1) }
        #expect(throws: XitDBError.endOfStream) { try database.reader.hashedPair(at: 0) }
        #expect(!endsTheStream { _ = try database.reader.hashedPair(at: dataStart) })
    }

    /// A slot that points before where data starts is refused by the read
    /// that follows it, for every kind of thing a slot points at, and one
    /// that points at the first byte of data is read.
    @Test(arguments: FormatVersion.allCases)
    func aSlotThatPointsBeforeTheDataIsRefused(version: FormatVersion) throws {
        let dataStart: UInt64 = version == .one ? 37 : 32
        let reads: [(String, (Cursor<ReadOnly>) throws -> Void)] = [
            ("arrayList", { _ = try $0.count }),
            ("linkedArrayList", { _ = try $0.count }),
            ("sortedMap", { _ = try $0.count }),
            ("sortedSet", { _ = try $0.count }),
            ("countedHashMap", { _ = try $0.count }),
            ("countedHashSet", { _ = try $0.count }),
            ("hashMap", { _ = try $0.iterator() }),
            ("hashSet", { _ = try $0.iterator() }),
            ("room", { _ = try $0.readBytes(maxCount: 16) }),
        ]
        for (name, read) in reads {
            let subject = try Subject(.memory, version: version, room: 300)
            let tag = try subject.slot(name).tag
            let position = try subject.slotPosition(name)

            let before = try subject.damaged(slotBytes(Slot(value: dataStart - 1, tag: tag)), at: position)
            let refused = try cursor(name, in: before)
            #expect(throws: XitDBError.endOfStream, "\(name)") { try read(refused) }

            let atStart = try subject.damaged(slotBytes(Slot(value: dataStart, tag: tag)), at: position)
            let first = try cursor(name, in: atStart)
            #expect(!endsTheStream { try read(first) }, "\(name)")
        }
    }

    /// A tree's root and a child whose slots lie before the data are
    /// refused by the walk that would enter them: the root when the walk
    /// starts, the child when the walk comes to it, after the leaf before
    /// it. A walk reads a node's slots, which start two bytes into it, so
    /// the last node refused is three bytes before the data, and one two
    /// bytes before it has its slots at the data's first byte and is read.
    @Test(arguments: FormatVersion.allCases, Tree.allCases)
    func aNodeBeforeTheDataIsRefusedByTheWalk(version: FormatVersion, tree: Tree) throws {
        let dataStart: UInt64 = version == .one ? 37 : 32
        let rooted = try Subject(.memory, version: version)
        let header = try rooted.tree(tree.rawValue)
        let noRoot = try rooted.damaged(bigEndianBytes(dataStart - 3), at: header.headerPtr + 8)
        #expect(throws: XitDBError.endOfStream) { try cursor(tree.rawValue, in: noRoot).iterator() }
        let atStart = try rooted.damaged(bigEndianBytes(dataStart - 2), at: header.headerPtr + 8)
        #expect(!endsTheStream { _ = try cursor(tree.rawValue, in: atStart).iterator() })

        let subject = try Subject(.memory, version: version)
        let rootPtr = try subject.tree(tree.rawValue).rootPtr
        let noChild = try subject.damaged(slotBytes(Slot(value: dataStart - 3, tag: .index)), at: rootPtr + 2 + 9)
        let (numbers, error) = try tree.walkToItsEnd(try cursor(tree.rawValue, in: noChild))
        #expect(numbers == Array(0..<8))
        #expect(error == .endOfStream)
    }

    /// A sorted map's key record that lies before the data is refused by
    /// the search that would compare it.
    @Test(arguments: FormatVersion.allCases)
    func aKeyRecordBeforeTheDataIsRefused(version: FormatVersion) throws {
        let dataStart: UInt64 = version == .one ? 37 : 32
        let subject = try Subject(.memory, version: version)
        let keys = (0..<3).map { Array("a key long enough to be a record \($0)".utf8) }
        try subject.database.withTransaction { cursor in
            let map = try SortedMap(try HashMap(cursor).putCursor(forHash: sha1("long keys").bytes))
            for (number, key) in keys.enumerated() {
                try map.put(.uint(UInt64(number)), forKey: key)
            }
        }
        let rootPtr = try subject.tree("long keys").rootPtr
        let leaf = try subject.database.reader.sortedNode(at: rootPtr)
        let middle = leaf.entries[1]
        #expect(middle.tag == .sortedKvPair)
        #expect(try subject.database.reader.sortedEntryPair(middle).keySlot.tag == .bytes)
        // the pair record starts with its key slot
        let database = try subject.damaged(slotBytes(Slot(value: dataStart - 1, tag: .bytes)), at: middle.value)
        let map = try SortedMap(try cursor("long keys", in: database))
        #expect(throws: XitDBError.endOfStream) { try map.cursor(forKey: keys[1]) }
        #expect(throws: XitDBError.endOfStream) { try map.rank(of: keys[0]) }
        #expect(throws: XitDBError.endOfStream) { try map.iterator(fromKey: keys[2]) }
    }

    /// Where data starts follows the format's version, which a replication
    /// from zero can change: a database that took a file of the other
    /// version by a full copy refuses what that version refuses.
    @Test(arguments: FormatVersion.allCases)
    func aFullCopyOfTheOtherVersionMovesWhereDataStarts(version: FormatVersion) throws {
        let other: FormatVersion = version == .one ? .two : .one
        let source = try Subject(.memory, version: other)
        let whole = try source.subject.stored()

        let storage = MemoryStorage()
        let replica = try newDatabase(version, in: storage, random: FixedRandom([0x7001, 0x7002]))
        #expect(replica.header.dataStart == (version == .one ? 37 : 32))
        try replica.applyReplicated(at: 0, bytes: whole)
        #expect(replica.header.version == other.rawValue)

        let dataStart: UInt64 = other == .one ? 37 : 32
        #expect(throws: XitDBError.endOfStream) { try replica.reader.slot(at: dataStart - 1) }
        #expect(!endsTheStream { _ = try replica.reader.uint64(at: dataStart) })
        // and what the copy holds is read
        let list = try ArrayList(try cursor("arrayList", in: replica))
        #expect(try #require(try list.cursor(at: 39)).readUInt64() == 39)
    }

    // MARK: A trie's walk within the blocks the file has room for

    /// The four collections kept in a hash trie.
    enum Hashed: String, CaseIterable, CustomTestStringConvertible {
        case hashMap, hashSet, countedHashMap, countedHashSet

        var testDescription: String { rawValue }

        /// Whether a count comes before the trie's first block.
        var isCounted: Bool { self == .countedHashMap || self == .countedHashSet }
    }

    /// Rewrites the trie of `hashed` so that many slots lead to one block:
    /// the sixteen slots of its first block all lead to one block, whose
    /// sixteen all lead to one copy of the first block as it was. The two
    /// new blocks go into the bytes of the value stored under "room". A
    /// walk enters 272 blocks, of three that are there: 16 times the one
    /// in the middle and 256 times the copy, whose three entries it gives
    /// each time.
    private func leadManySlotsToOneBlock(_ subject: Subject, _ hashed: Hashed) throws -> Database {
        let slot = try subject.slot(hashed.rawValue)
        let first = hashed.isCounted ? slot.value + 8 : slot.value
        let block = try readBytes(subject.subject.storage, at: first, count: 144)
        // no entry of the three is below the first block, so the copy leads nowhere
        let slots = try subject.database.reader.indexBlock(at: first).slots
        #expect((0..<16).allSatisfy { slots[$0].tag != .index })
        // the bytes of the room, after the record's length
        let room = try subject.slot("room").value + 8
        try subject.write(block, at: room)
        try subject.write((0..<16).flatMap { _ in slotBytes(Slot(value: room, tag: .index)) }, at: room + 144)
        return try subject.damaged(
            (0..<16).flatMap { _ in slotBytes(Slot(value: room + 144, tag: .index)) }, at: first)
    }

    /// Walks `iterator` to its end and returns how many entries it gave.
    private func entries(_ iterator: CollectionIterator) throws -> Int {
        var iterator = iterator
        var count = 0
        while try iterator.next() != nil {
            count += 1
        }
        return count
    }

    /// Many slots of a trie leading to one block: the walk is refused when
    /// it has entered more blocks than the file has room for, on every
    /// storage, where it would have given 768 entries of the three there
    /// are. A lookup goes down one block at a level and ends as any other:
    /// it finds an entry where the rewritten trie leads to it, or nothing.
    @Test(arguments: StorageKind.allCases, Hashed.allCases)
    func manySlotsOfATrieLeadingToOneBlockEndTheWalk(kind: StorageKind, hashed: Hashed) throws {
        let subject = try Subject(kind, room: 288)
        // the sound trie gives its three entries
        #expect(try entries(try cursor(hashed.rawValue, in: subject.database).iterator()) == 3)
        #expect(try subject.length / 144 < 272)

        let database = try leadManySlotsToOneBlock(subject, hashed)
        let collection = try cursor(hashed.rawValue, in: database)
        #expect(throws: XitDBError.keyOffsetExceeded) { try entries(try collection.iterator()) }
        for hash in Self.entries {
            #expect(throws: Never.self) { _ = try collection.readPath([.hashMapGet(.kvPair, hash)]) }
        }
    }

    /// The bound is the file's length over a block's size, exactly: a file
    /// with room for the 272 blocks the walk enters is walked to its end,
    /// and a file one byte shorter, with room for 271, is refused.
    @Test(arguments: Hashed.allCases)
    func theWalkOfATrieIsBoundedByTheBlocksTheFileHasRoomFor(hashed: Hashed) throws {
        let needed: UInt64 = 272 * 144
        let measured = try Subject(.memory, room: 288)
        let room = 288 + Int(needed - (try measured.length))

        let fitting = try Subject(.memory, room: room)
        try #require(try fitting.length == needed)
        let walked = try leadManySlotsToOneBlock(fitting, hashed)
        #expect(try entries(try cursor(hashed.rawValue, in: walked).iterator()) == 768)

        let short = try Subject(.memory, room: room - 1)
        try #require(try short.length == needed - 1)
        let refused = try leadManySlotsToOneBlock(short, hashed)
        #expect(throws: XitDBError.keyOffsetExceeded) {
            try entries(try cursor(hashed.rawValue, in: refused).iterator())
        }
    }

    // MARK: A tree's walk within the nodes its file or its elements allow

    /// The three collections kept in a tree, with the reads they share. In
    /// each the element at position `n` stands for the number `n`: the
    /// list's element, the map's value, the set's key "k" and the number.
    enum Tree: String, CaseIterable, CustomTestStringConvertible {
        case linkedArrayList, sortedMap, sortedSet

        var testDescription: String { rawValue }

        /// Where a branch's counts start in a node.
        var countsOffset: UInt64 { self == .linkedArrayList ? 146 : 290 }

        /// The number a key of the sorted set stands for.
        private func number(ofKey cursor: Cursor<ReadOnly>) throws -> UInt64 {
            let key = try cursor.readBytes(maxCount: 100)
            return try #require(UInt64(String(decoding: key.dropFirst(), as: UTF8.self)))
        }

        /// The number an element given by a walk stands for.
        func number(of element: Cursor<ReadOnly>) throws -> UInt64 {
            switch self {
            case .linkedArrayList: try element.readUInt64()
            case .sortedMap: try element.readEntry().value.readUInt64()
            case .sortedSet: try number(ofKey: try element.readEntry().key)
            }
        }

        /// The number at a position, or `nil` where the collection has none.
        func number(at index: Int, in collection: Cursor<ReadOnly>) throws -> UInt64? {
            switch self {
            case .linkedArrayList:
                return try LinkedArrayList(collection).cursor(at: index)?.readUInt64()
            case .sortedMap:
                return try SortedMap(collection).entry(at: index)?.value.readUInt64()
            case .sortedSet:
                guard let entry = try SortedSet(collection).entry(at: index) else { return nil }
                return try number(ofKey: entry.key)
            }
        }

        /// The numbers a walk gives, to its end.
        func numbers(_ iterator: CollectionIterator) throws -> [UInt64] {
            var iterator = iterator
            var numbers: [UInt64] = []
            while let element = try iterator.next() {
                numbers.append(try number(of: element))
            }
            return numbers
        }

        /// The numbers the walk of the collection gives.
        func walk(_ collection: Cursor<ReadOnly>) throws -> [UInt64] {
            try numbers(try collection.iterator())
        }

        /// The numbers the walk gives until it ends or is refused, and what
        /// refused it.
        func walkToItsEnd(_ collection: Cursor<ReadOnly>) throws -> (numbers: [UInt64], error: XitDBError?) {
            var iterator = try collection.iterator()
            var numbers: [UInt64] = []
            do {
                while let element = try iterator.next() {
                    numbers.append(try number(of: element))
                }
            } catch let error as XitDBError {
                return (numbers, error)
            }
            return (numbers, nil)
        }

        /// The numbers a walk from a position gives.
        func walk(_ collection: Cursor<ReadOnly>, from index: Int) throws -> [UInt64] {
            switch self {
            case .linkedArrayList: try numbers(try LinkedArrayList(collection).iterator(fromIndex: index))
            case .sortedMap: try numbers(try SortedMap(collection).iterator(fromIndex: index))
            case .sortedSet: try numbers(try SortedSet(collection).iterator(fromIndex: index))
            }
        }

        /// Whether a sorted collection holds the key of a number.
        func holds(_ number: Int, in collection: Cursor<ReadOnly>) throws -> Bool {
            let key = ReadBoundTests.keys[number]
            switch self {
            case .linkedArrayList: preconditionFailure("a list has no keys")
            case .sortedMap: return try SortedMap(collection).cursor(forKey: key) != nil
            case .sortedSet: return try SortedSet(collection).contains(key)
            }
        }

        /// The rank of the key of a number in a sorted collection.
        func rank(_ number: Int, in collection: Cursor<ReadOnly>) throws -> UInt64 {
            let key = ReadBoundTests.keys[number]
            switch self {
            case .linkedArrayList: preconditionFailure("a list has no keys")
            case .sortedMap: return try SortedMap(collection).rank(of: key)
            case .sortedSet: return try SortedSet(collection).rank(of: key)
            }
        }

        /// The numbers a walk of a sorted collection gives from the key of
        /// a number.
        func walk(_ collection: Cursor<ReadOnly>, fromKey number: Int) throws -> [UInt64] {
            let key = ReadBoundTests.keys[number]
            switch self {
            case .linkedArrayList: preconditionFailure("a list has no keys")
            case .sortedMap: return try numbers(try SortedMap(collection).iterator(fromKey: key))
            case .sortedSet: return try numbers(try SortedSet(collection).iterator(fromKey: key))
            }
        }
    }

    /// The sound trees are what the tests take them for: a root that is a
    /// branch of four over leaves of 8, 8, 8 and 16, read in order by
    /// every read.
    @Test(arguments: Tree.allCases)
    func theSoundTreesAreARootOverFourLeaves(tree: Tree) throws {
        let subject = try Subject(.memory)
        let rootPtr = try subject.tree(tree.rawValue).rootPtr
        let reader = subject.database.reader
        #expect(try reader.uint64(at: rootPtr + tree.countsOffset) == 8)
        #expect(try reader.uint64(at: rootPtr + tree.countsOffset + 24) == 16)
        #expect(try readBytes(subject.subject.storage, at: rootPtr, count: 2) == [1, 4])
        let collection = try cursor(tree.rawValue, in: subject.database)
        #expect(try tree.walk(collection) == Array(0..<40))
        #expect(try tree.walk(collection, from: 5) == Array(5..<40))
        #expect(try (0..<40).allSatisfy { try tree.number(at: $0, in: collection) == UInt64($0) })
    }

    /// A sorted collection leaves a leaf whose entries were all removed in
    /// its place, with a count of nothing, and every read passes it over,
    /// on every storage. That is why a sorted tree may have many more
    /// nodes than entries, and why its walk is bounded by the file and not
    /// by what it gives.
    @Test(arguments: StorageKind.allCases, [Tree.sortedMap, .sortedSet])
    func aLeafEmptiedByRemovalsIsPassedOver(kind: StorageKind, tree: Tree) throws {
        let subject = try Subject(kind)
        try subject.database.withTransaction { cursor in
            let root = try HashMap(cursor)
            for key in Self.keys[8..<16] {
                switch tree {
                case .sortedMap:
                    #expect(try SortedMap(try root.putCursor(forHash: sha1("sortedMap").bytes)).remove(forKey: key))
                case .sortedSet:
                    #expect(try SortedSet(try root.putCursor(forHash: sha1("sortedSet").bytes)).remove(forKey: key))
                case .linkedArrayList:
                    break
                }
            }
        }
        let rootPtr = try subject.tree(tree.rawValue).rootPtr
        let root = try subject.database.reader.sortedNode(at: rootPtr)
        #expect(root.num == 4)
        #expect((0..<4).map { root.count($0) } == [8, 0, 8, 16])

        let left = Array(0..<8) + Array(16..<40).map { UInt64($0) }
        let collection = try cursor(tree.rawValue, in: subject.database)
        #expect(try collection.count == 32)
        #expect(try tree.walk(collection) == left)
        #expect(try tree.walk(collection, from: 8) == Array(16..<40))
        #expect(try tree.number(at: 8, in: collection) == 16)
        #expect(try !tree.holds(10, in: collection))
        #expect(try tree.rank(10, in: collection) == 8)
        #expect(try tree.walk(collection, fromKey: 10) == Array(16..<40))
        #expect(try tree.holds(16, in: collection))
        #expect(try tree.rank(16, in: collection) == 8)
    }

    /// Writes nodes of a test's own into the bytes of the value stored
    /// under "room", and gives the slot of a node whose walk enters a
    /// wanted number of nodes and gives nothing: a leaf without entries
    /// for one, and above that a branch over such nodes, one node serving
    /// wherever two are alike. Many slots then lead to one node, as no
    /// writer leaves them.
    private final class NodesThatGiveNothing {
        private let subject: Subject
        private let branchByteCount: Int
        private var next: UInt64
        private let end: UInt64
        private var made: [Int: Slot] = [:]

        init(_ subject: Subject, _ tree: Tree) throws {
            self.subject = subject
            branchByteCount = Int(tree.countsOffset) + 128
            let room = try subject.slot("room")
            next = room.value + 8
            end = next + (try subject.database.reader.uint64(at: room.value))
        }

        /// The slot of a node whose walk enters `count` nodes, itself
        /// among them, and gives nothing.
        func node(entering count: Int) throws -> Slot {
            if let slot = made[count] { return slot }
            // a leaf with no entries
            var bytes = zeros(146)
            if count > 1 {
                // a branch whose children enter the rest between them
                bytes = zeros(branchByteCount)
                let below = count - 1
                let children = min(below, 16)
                bytes[0] = 1
                bytes[1] = UInt8(children)
                for index in 0..<children {
                    let child = try node(entering: below / children + (index < below % children ? 1 : 0))
                    bytes.replaceSubrange((2 + 9 * index)..<(2 + 9 * index + 9), with: slotBytes(child))
                }
            }
            try #require(next + UInt64(bytes.count) <= end, "the room is too small for the nodes")
            let slot = Slot(value: next, tag: .index)
            try subject.write(bytes, at: next)
            next += UInt64(bytes.count)
            made[count] = slot
            return slot
        }
    }

    /// Nodes that lead to each other end the walk of a tree, on every
    /// storage: the root's second child is made to lead to five thousand
    /// nodes that give nothing, of a dozen that are there. The walk gives
    /// the first leaf's eight and is refused, a sorted tree's when it has
    /// entered more nodes than the file has room for and a list's when it
    /// has entered more than sixty-five for each of the eight and the
    /// next; before it counted nodes it went through all five thousand and
    /// gave the rest. A read by position or by key goes down one node at a
    /// level and answers as it did.
    @Test(arguments: StorageKind.allCases, Tree.allCases)
    func nodesThatLeadToEachOtherEndTheWalkOfATree(kind: StorageKind, tree: Tree) throws {
        let subject = try Subject(kind, room: 4000)
        #expect(try subject.length / 146 < 5000)
        let rootPtr = try subject.tree(tree.rawValue).rootPtr
        let nodes = try NodesThatGiveNothing(subject, tree)
        try subject.write(slotBytes(try nodes.node(entering: 5000)), at: rootPtr + 2 + 9)
        let collection = try cursor(tree.rawValue, in: try subject.reopened())

        let (numbers, error) = try tree.walkToItsEnd(collection)
        #expect(numbers == Array(0..<8))
        #expect(error == .invalidBTreeNode)
        #expect(throws: XitDBError.invalidBTreeNode) { try tree.walk(collection, from: 3) }
        #expect(try tree.walk(collection, from: 16) == Array(16..<40))
        #expect(try tree.number(at: 3, in: collection) == 3)
        #expect(try tree.number(at: 20, in: collection) == 20)
        if tree != .linkedArrayList {
            #expect(throws: XitDBError.invalidBTreeNode) { try tree.walk(collection, fromKey: 3) }
            #expect(try tree.holds(35, in: collection))
            #expect(try tree.rank(35, in: collection) == 35)
        }
    }

    /// The sorted tree's bound is the file's length over a node's least
    /// size, 146 bytes, exactly: the root is made to lead to 272 nodes that
    /// give nothing and to nothing else. In a file with room for 272 nodes
    /// the walk goes through them and ends, having given nothing; in a file
    /// one byte shorter, with room for 271, it is refused.
    @Test(arguments: [Tree.sortedMap, .sortedSet])
    func theWalkOfASortedTreeIsBoundedByTheNodesTheFileHasRoomFor(tree: Tree) throws {
        let needed: UInt64 = 272 * 146
        let measured = try Subject(.memory, room: 4000)
        let room = 4000 + Int(needed - (try measured.length))
        for (short, refused) in [(0, false), (1, true)] {
            let subject = try Subject(.memory, room: room - short)
            try #require(try subject.length == needed - UInt64(short))
            let rootPtr = try subject.tree(tree.rawValue).rootPtr
            let nodes = try NodesThatGiveNothing(subject, tree)
            try subject.write(slotBytes(try nodes.node(entering: 272)) + zeros(27), at: rootPtr + 2)
            let (numbers, error) = try tree.walkToItsEnd(try cursor(tree.rawValue, in: try subject.reopened()))
            #expect(numbers == [])
            #expect(error == (refused ? .invalidBTreeNode : nil), "a file \(short) short")
        }
    }

    /// The list's bound is sixty-five nodes for each element given so far
    /// and for the next, exactly. With nothing given, the root leads to
    /// sixty-five nodes that give nothing, and then to sixty-six; with the
    /// first leaf's eight given, which is one node entered, to 584 more,
    /// nine times sixty-five in all, and then to 585. The walk goes
    /// through the first of each pair and ends, and is refused in the
    /// second.
    @Test(arguments: [0, 8])
    func theWalkOfAListIsBoundedByTheElementsItHasGiven(given: Int) throws {
        let allowed = (given + 1) * 65
        for (over, refused) in [(0, false), (1, true)] {
            let subject = try Subject(.memory, room: 4000)
            let rootPtr = try subject.tree("linkedArrayList").rootPtr
            let nodes = try NodesThatGiveNothing(subject, .linkedArrayList)
            // The root's four children: the first leaf, kept when its
            // eight are to be given, then the nodes that give nothing,
            // then nothing.
            var children: [UInt8] = []
            var entered = 0
            if given == 8 {
                children += try readBytes(subject.subject.storage, at: rootPtr + 2, count: 9)
                entered = 1
            }
            children += slotBytes(try nodes.node(entering: allowed + over - entered))
            children += zeros(36 - children.count)
            try subject.write(children, at: rootPtr + 2)

            let list = try cursor("linkedArrayList", in: try subject.reopened())
            let (numbers, error) = try Tree.linkedArrayList.walkToItsEnd(list)
            #expect(numbers == Array(0..<UInt64(given)))
            #expect(error == (refused ? .invalidBTreeNode : nil), "\(over) over")
        }
    }

    /// A real sorted tree with many more nodes than entries: of two
    /// thousand keys all but the last ten are removed, which leaves more
    /// than a hundred emptied leaves in place before the first entry. The
    /// walk enters them all and gives the ten: a bound by what a walk
    /// gives, as a list has, would have refused this file.
    @Test(arguments: [Tree.sortedMap, .sortedSet])
    func aRealSortedTreeOfEmptiedLeavesIsWalked(tree: Tree) throws {
        let storage = MemoryStorage()
        let database = try newDatabase(.two, in: storage, random: FixedRandom((1...9).map { UInt64($0) }))
        let keys = (0..<2000).map { Array("key-\(String(repeating: "0", count: 4 - "\($0)".count))\($0)".utf8) }
        try database.withTransaction { cursor in
            let root = try HashMap(cursor)
            switch tree {
            case .sortedMap:
                let map = try SortedMap(try root.putCursor(forHash: sha1("sorted").bytes))
                for (number, key) in keys.enumerated() {
                    try map.put(.uint(UInt64(number)), forKey: key)
                }
                for key in keys[..<1990] {
                    #expect(try map.remove(forKey: key))
                }
            case .sortedSet:
                let set = try SortedSet(try root.putCursor(forHash: sha1("sorted").bytes))
                for key in keys {
                    try set.insert(key)
                }
                for key in keys[..<1990] {
                    #expect(try set.remove(forKey: key))
                }
            case .linkedArrayList:
                break
            }
        }
        let collection = try cursor("sorted", in: database)
        // the leaves without entries that the tree still has
        var emptied = 0
        var nodes = [try database.reader.bTreeHeader(at: try collection.slot.value).rootPtr]
        while let position = nodes.popLast() {
            let node = try database.reader.sortedNode(at: position)
            switch node.kind {
            case .leaf: emptied += node.num == 0 ? 1 : 0
            case .branch: nodes += (0..<Int(node.num)).map { node.child($0).value }
            }
        }
        #expect(emptied > 100)
        #expect(try collection.count == 10)

        var given: [[UInt8]] = []
        var iterator = try collection.iterator()
        while let entry = try iterator.next() {
            given.append(try entry.readEntry().key.readBytes(maxCount: 100))
        }
        #expect(given == Array(keys[1990...]))
    }

    /// A real list is nowhere near its bound: the most nodes a walk of one
    /// enters before an element is the height of its tree. Here are lists
    /// as thin as a writer leaves them, read to their ends: two thousand
    /// elements of which every hundredth is kept, and a list made by
    /// inserting at its front.
    @Test func realListsOfThinLeavesAreWalked() throws {
        let storage = MemoryStorage()
        let database = try newDatabase(.two, in: storage, random: FixedRandom((1...9).map { UInt64($0) }))
        try database.withTransaction { cursor in
            let root = try HashMap(cursor)
            let thinned = try LinkedArrayList(try root.putCursor(forHash: sha1("thinned").bytes))
            for number in 0..<2000 {
                try thinned.append(.uint(UInt64(number)))
            }
            // from the end, so that the positions before stay what they were
            for number in (0..<2000).reversed() where number % 100 != 0 {
                try thinned.remove(at: number)
            }
            let fronted = try LinkedArrayList(try root.putCursor(forHash: sha1("fronted").bytes))
            try fronted.append(.uint(0))
            for number in 1..<500 {
                try fronted.insert(.uint(UInt64(number)), at: 0)
            }
        }
        let list = Tree.linkedArrayList
        #expect(try list.walk(try cursor("thinned", in: database)) == (0..<20).map { UInt64($0 * 100) })
        #expect(try list.walk(try cursor("thinned", in: database), from: 7) == (7..<20).map { UInt64($0 * 100) })
        #expect(try list.walk(try cursor("fronted", in: database)) == (0..<500).reversed().map { UInt64($0) })
    }

    /// A tree that holds its leaves many times over: the root's sixteen
    /// children are one branch, whose sixteen are the one leaf of sixteen
    /// entries; 4,096 entries by the header and by every count, in a file
    /// with room for a few hundred slots. A linked array list is read so,
    /// as a list joined to itself is. A sorted map or set, where no writer
    /// puts a node in the tree twice, is refused by its size, which is all
    /// that tells it from a sound one: every read by key and every walk
    /// would answer.
    @Test(arguments: Tree.allCases)
    func aTreeThatHoldsItsLeavesManyTimesOver(tree: Tree) throws {
        let subject = try Subject(.memory, room: 900)
        let (headerPtr, rootPtr) = try subject.tree(tree.rawValue)
        let branchByteCount = Int(tree.countsOffset) + 128
        let root = try readBytes(subject.subject.storage, at: rootPtr, count: branchByteCount)
        // the sound root's fourth child is the leaf of sixteen: its slot,
        // and in a sorted tree its separator
        let leaf = Array(root[29..<38])
        let separator = Array(root[(146 + 27)..<(146 + 36)])
        func branch(over child: [UInt8], each count: UInt64) -> [UInt8] {
            var bytes = root
            bytes[1] = 16
            for index in 0..<16 {
                bytes.replaceSubrange((2 + 9 * index)..<(2 + 9 * index + 9), with: child)
                if tree != .linkedArrayList {
                    bytes.replaceSubrange((146 + 9 * index)..<(146 + 9 * index + 9), with: separator)
                }
                let at = Int(tree.countsOffset) + 8 * index
                bytes.replaceSubrange(at..<(at + 8), with: bigEndianBytes(count))
            }
            return bytes
        }
        let room = try subject.slot("room").value + 8
        let upper = room + UInt64(branchByteCount)
        try subject.write(branch(over: leaf, each: 16), at: room)
        try subject.write(branch(over: slotBytes(Slot(value: room, tag: .index)), each: 256), at: upper)
        try subject.write(bigEndianBytes(4096) + bigEndianBytes(upper), at: headerPtr)
        #expect(try subject.length < 4096 * 9)

        let collection = try cursor(tree.rawValue, in: try subject.reopened())
        switch tree {
        case .linkedArrayList:
            #expect(try collection.count == 4096)
            #expect(try tree.number(at: 4095, in: collection) == 39)
            #expect(try tree.walk(collection) == (0..<256).flatMap { _ in (24..<40).map { UInt64($0) } })
            #expect(try tree.walk(collection, from: 4090) == Array(34..<40))
        case .sortedMap, .sortedSet:
            for (name, read) in reads(of: tree == .sortedMap ? .sortedMap : .sortedSet) {
                #expect(throws: XitDBError.invalidCount, "\(name)") { try read(collection) }
            }
        }
    }
}
