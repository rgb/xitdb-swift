import Testing

@testable import XitDB

/// No content of a file may make the engine trap (requirement R23): a
/// corrupt file is reported as an error, or read as whatever it now says.
///
/// These tests damage a small database in thousands of ways and then use
/// it, for reading and for writing. They pass if every use returns or throws
/// an `XitDBError`. A trap ends the test process, which is the failure.
///
/// The storage is a memory storage with no size limit, on purpose. Such a
/// storage has to allocate all the way to wherever it is asked to write, so
/// if any damage could send one of the engine's writes to an offset beyond
/// the end of the storage, a test here would end with the process.
@Suite struct CorruptFileTests {
    /// A database with one of everything built so far: a list at the root
    /// with two moments, a map with short and long values, a nested list
    /// deep enough to have two levels, a counted map, and a linked array
    /// list whose tree has a branch over two leaves.
    static let sound: [UInt8] = {
        (try? makeSound()) ?? []
    }()

    static func makeSound() throws -> [UInt8] {
        let storage = MemoryStorage()
        let database = try Database(
            storage: storage, hashSize: 20, hashID: nil, fileID: 0xC0FFEE, random: FixedRandom([1, 2]))
        let root = database.rootCursor
        _ = try root.writePath([.arrayListInit, .arrayListAppend, .hashMapInit(), .ctx]) { cursor in
            _ = try cursor.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(1))])
            _ = try cursor.writePath([.hashMapGet(.key, sha1("a")), .write(.bytes(Array("a".utf8)))])
            _ = try cursor.writePath([
                .hashMapGet(.value, sha1("long")),
                .write(.bytes(Array("a value too long to fit in a slot".utf8), formatTag: FormatTag(0x74, 0x67))),
            ])
            let list = try cursor.writePath([.hashMapGet(.value, sha1("list")), .arrayListInit])
            for index in 0..<20 {
                _ = try list.writePath([.arrayListAppend, .write(.uint(UInt64(index)))])
            }
            let counted = try cursor.writePath([.hashMapGet(.value, sha1("counted")), .hashMapInit(counted: true)])
            _ = try counted.writePath([.hashMapGet(.value, sha1("x")), .write(.int(-1))])
            _ = try counted.writePath([.hashMapGet(.value, sha1("y")), .write(.double(1.5))])
            let linked = try LinkedArrayList(try cursor.writePath([.hashMapGet(.value, sha1("linked"))]))
            for index in 0..<20 {
                try linked.append(.uint(UInt64(index)))
            }
        }
        let last = try root.readPathSlot([.arrayListGet(-1)])
        _ = try root.writePath([.arrayListInit, .arrayListAppend, .write(.slot(last)), .hashMapInit(), .ctx]) {
            cursor in
            _ = try cursor.writePath([.hashMapGet(.value, sha1("b")), .write(.uint(2))])
        }
        return storage.bytes
    }

    /// Runs `body`, letting any `XitDBError` pass as a fine outcome.
    private func tolerating(_ body: () throws -> Void) {
        do {
            try body()
        } catch is XitDBError {
            // reported: that is all R23 asks
        } catch {
            Issue.record("an error that is not an XitDBError: \(error)")
        }
    }

    /// Goes through an iterator, up to a limit: a damaged file can make a
    /// finite walk very long by pointing several slots at one block.
    private func drain(_ iterator: CollectionIterator) throws {
        var iterator = iterator
        var left = 2000
        while left > 0, let element = try iterator.next() {
            _ = try element.slot
            left -= 1
        }
    }

    /// Reads through a streaming reader in the ways a caller might.
    private func stream(_ cursor: Cursor<ReadOnly>) throws {
        var reader = try cursor.reader()
        var buffer = [UInt8](repeating: 0, count: 16)
        var span = buffer.mutableSpan
        _ = try reader.read(into: &span)
        reader.seek(to: 1)
        try reader.readAll(into: &span)
        reader.seek(to: .max - 2)
        _ = try reader.read(into: &span)
        reader.seek(to: 0)
        _ = try reader.readRemaining(maxCount: 1 << 20)
    }

    /// What a caller might do with a database, each step on its own so that
    /// one that fails does not hide the next: reads of every kind of value
    /// at every place the sound database has one, then writes of every kind.
    private func exercise(_ bytes: [UInt8]) {
        // A header that states another hash size is also opened by that
        // size, which makes every hash given here the wrong length.
        let statesTwentyBytes = bytes.count >= 8 && bytes[6] == 0 && bytes[7] == 20
        for hashSize in statesTwentyBytes ? [UInt16?.some(20)] : [UInt16?.some(20), nil] {
            let storage = MemoryStorage(bytes: bytes)
            var opened: Database?
            tolerating {
                opened = try Database(
                    storage: storage, hashSize: hashSize, hashID: nil, fileID: nil,
                    random: FixedRandom([3, 4, 5, 6, 7, 8]))
            }
            guard let database = opened else { continue }

            // reads
            tolerating { _ = try database.committedSize }
            tolerating { _ = try database.rootCursor.count }
            for index in [Int64(0), -1, 2, .min] {
                var found: Cursor<ReadOnly>?
                tolerating { found = try database.rootCursor.readPath([.arrayListGet(index)]) }
                guard let moment = found else { continue }
                tolerating { _ = try moment.count }
                for key in ["a", "long", "list", "counted", "linked", "b", "missing"] {
                    var value: Cursor<ReadOnly>?
                    tolerating { value = try moment.readPath([.hashMapGet(.value, sha1(key))]) }
                    guard let value else { continue }
                    tolerating { _ = try value.count }
                    tolerating { _ = try value.readUInt64() }
                    tolerating { _ = try value.readBytesWithFormatTag() }
                    tolerating {
                        var buffer = [UInt8](repeating: 0, count: 64)
                        var span = buffer.mutableSpan
                        _ = try value.readBytesWithFormatTag(into: &span)
                    }
                    tolerating { try stream(value) }
                    tolerating { try drain(try value.iterator()) }
                    tolerating { try drain(try value.iterator(fromArrayListIndex: 3)) }
                    tolerating { try drain(try ArrayList(value).iterator(fromIndex: -1)) }
                    tolerating { try drain(try LinkedArrayList(value).iterator(fromIndex: 17)) }
                    for element in [Int64(0), 19, -21] {
                        tolerating { _ = try LinkedArrayList(value).cursor(at: element)?.readUInt64() }
                    }
                    tolerating {
                        var entries = try CountedHashMap(value).iterator()
                        while let entry = try entries.next() {
                            let pair = try entry.readEntry()
                            _ = try pair.key.readBytes(maxCount: 64)
                            _ = try pair.value.slot
                            _ = pair.withHash { $0.count }
                        }
                    }
                }
                tolerating { try drain(try moment.iterator()) }
                tolerating { _ = try HashMap(moment).entry(forHash: sha1("a").bytes)?.key.readUInt64() }
                tolerating { _ = try moment.readPath([.hashMapGet(.key, sha1("a"))])?.readBytes(maxCount: 4) }
                tolerating { _ = try moment.readPath([.hashMapGet(.kvPair, sha1("a"))])?.readEntry() }
                for element in [Int64(0), 15, 16, 19, 20, -1, -21] {
                    tolerating {
                        _ = try moment.readPath([.hashMapGet(.value, sha1("list")), .arrayListGet(element)])?
                            .readUInt64()
                    }
                }
                tolerating {
                    _ = try moment.readPath([.hashMapGet(.value, sha1("counted")), .hashMapGet(.value, sha1("x"))])?
                        .readInt64()
                }
            }

            // writes: one transaction that goes on after each part that
            // fails, so that every kind of write meets the damage
            tolerating { _ = try database.rootCursor.writePath([.arrayListInit]) }
            tolerating {
                let root = database.rootCursor
                let last = try root.readPathSlot([.arrayListGet(-1)])
                _ = try root.writePath([.arrayListInit, .arrayListAppend, .write(.slot(last)), .hashMapInit(), .ctx]) {
                    cursor in
                    for key in ["a", "list", "new"] {
                        self.tolerating {
                            _ = try cursor.writePath([.hashMapGet(.value, sha1(key)), .write(.uint(7))])
                        }
                    }
                    self.tolerating { _ = try cursor.writePath([.hashMapRemove(sha1("long"))]) }
                    self.tolerating {
                        _ = try cursor.writePath([
                            .hashMapGet(.value, sha1("counted")), .hashMapInit(counted: true),
                            .hashMapRemove(sha1("x")),
                        ])
                    }
                    self.tolerating {
                        _ = try cursor.writePath([
                            .hashMapGet(.value, sha1("counted")), .hashMapInit(counted: true),
                            .hashMapGet(.value, sha1("z")), .write(.bytes([UInt8](repeating: 1, count: 40))),
                        ])
                    }
                }
            }
            tolerating {
                try database.withTransaction { cursor in
                    let list: [PathPart] = [
                        .arrayListGet(0), .hashMapInit(), .hashMapGet(.value, sha1("list")), .arrayListInit,
                    ]
                    self.tolerating { _ = try cursor.writePath(list + [.arrayListAppend, .write(.uint(1))]) }
                    for size in [UInt64(17), 16, 1] {
                        self.tolerating { _ = try cursor.writePath(list + [.arrayListSlice(size: size)]) }
                    }
                    self.tolerating { _ = try cursor.writePath([.arrayListAppend, .write(.uint(1))]) }
                    self.tolerating { _ = try cursor.writePath([.arrayListSlice(size: 1)]) }
                }
            }
            // the linked array list: every operation, through the collection
            tolerating {
                try database.withTransaction { cursor in
                    let map = try HashMap(try cursor.writePath([.arrayListGet(0)]))
                    var linked = try LinkedArrayList(try map.putCursor(forHash: sha1("linked").bytes))
                    self.tolerating { try linked.append(.uint(20)) }
                    self.tolerating { try linked.put(.uint(30), at: 3) }
                    self.tolerating { try linked.insert(.uint(160), at: 16) }
                    self.tolerating { try linked.remove(at: 0) }
                    self.tolerating { try linked.formSlice(offset: 2, count: 5) }
                    self.tolerating { linked = try LinkedArrayList(try map.putCursor(forHash: sha1("linked").bytes)) }
                    self.tolerating { try linked.append(contentsOf: try linked.slot) }
                    self.tolerating { try self.drain(try linked.iterator()) }
                }
            }
            tolerating { _ = try database.rootCursor.writePath([.write(.uint(1))]) }
            // Nothing here writes more than a few kilobytes. A storage that
            // grew out of all proportion was sent a write it should not get.
            #expect(storage.bytes.count < bytes.count + 100_000)
        }
    }

    @Test func theSoundDatabaseIsWhatTheTestsExpect() throws {
        let bytes = Self.sound
        try #require(bytes.count > 1500)
        let database = try Database(storage: MemoryStorage(bytes: bytes), hashSize: 20)
        #expect(try database.rootCursor.count == 2)
        let moment = try #require(try database.rootCursor.readPath([.arrayListGet(-1)]))
        #expect(try #require(try moment.readPath([.hashMapGet(.value, sha1("list"))])).count == 20)
        #expect(try #require(try moment.readPath([.hashMapGet(.value, sha1("counted"))])).count == 2)
        // and the exercise works on it as it is
        exercise(bytes)
    }

    /// Every byte of the file, set to each of four values in turn.
    @Test(arguments: [UInt8(0x00), 0xFF, 0x80, 0x01])
    func anyOneByteCanBeDamaged(replacement: UInt8) {
        let sound = Self.sound
        for offset in sound.indices where sound[offset] != replacement {
            var bytes = sound
            bytes[offset] = replacement
            exercise(bytes)
        }
    }

    /// Every byte of the file with one bit flipped: the low bit, which makes
    /// an offset or a count off by one, and the high bit of the tag byte's
    /// seven, which makes most tags invalid.
    @Test(arguments: [UInt8(0x01), 0x40])
    func anyOneBitCanFlip(mask: UInt8) {
        let sound = Self.sound
        for offset in sound.indices {
            var bytes = sound
            bytes[offset] ^= mask
            exercise(bytes)
        }
    }

    /// Eight bytes at every second offset of the file replaced by a wild
    /// 64-bit value: the largest ones, and the position of the root header.
    /// Wherever the eight bytes are an offset, a size or a count, the engine
    /// now has a wild one. (Every byte is inside several of the windows; the
    /// strides keep the test's time within bounds.)
    @Test(arguments: [UInt64.max, .max - 8, 1 << 63, 1 << 40, 0, 20] as [UInt64])
    func anyEightBytesCanBeAWildNumber(value: UInt64) {
        let sound = Self.sound
        for offset in stride(from: 0, through: sound.count - 8, by: 2) {
            var bytes = sound
            bytes.replaceSubrange(offset..<(offset + 8), with: bigEndianBytes(value))
            exercise(bytes)
        }
    }

    /// More wild numbers, at every fifth offset.
    @Test(arguments: [.max - 1, .max - 143, (1 << 63) - 1, 1 << 62, 1, 24, 29, 32, 37] as [UInt64])
    func anyEightBytesCanBeAnotherWildNumber(value: UInt64) {
        let sound = Self.sound
        for offset in stride(from: 0, through: sound.count - 8, by: 5) {
            var bytes = sound
            bytes.replaceSubrange(offset..<(offset + 8), with: bigEndianBytes(value))
            exercise(bytes)
        }
    }

    /// The same with offsets just around the end of the file, which are the
    /// ones that could pass a check and still be wrong.
    @Test func anyEightBytesCanPointAroundTheEndOfTheFile() {
        let sound = Self.sound
        let end = UInt64(sound.count)
        for value in [end - 144, end - 25, end - 9, end - 1, end, end + 1, end + 9] {
            for offset in stride(from: 0, through: sound.count - 8, by: 5) {
                var bytes = sound
                bytes.replaceSubrange(offset..<(offset + 8), with: bigEndianBytes(value))
                exercise(bytes)
            }
        }
    }

    /// A file cut off at any length.
    @Test func theFileCanEndAnywhere() {
        let sound = Self.sound
        for length in 0..<sound.count {
            exercise(Array(sound[..<length]))
        }
    }

    /// A trie as deep as a hash allows, for a hash of 2,048 bytes: 4,096
    /// levels. Lookups, inserts and removals walk it in loops. If any of
    /// them recursed, as Zig's do, this would overflow the half megabyte of
    /// stack that a test thread has.
    @Test func aTrieThousandsOfLevelsDeepDoesNotOverflowTheStack() throws {
        let hashSize = 2048
        let storage = MemoryStorage()
        let database = try Database(
            storage: storage, hashSize: UInt16(hashSize), hashID: nil, fileID: 1, random: FixedRandom([1, 2, 3, 4]))

        // Two hashes that agree in everything but their first byte, which is
        // the last a trie looks at, so they part ways at the deepest level.
        var first = [UInt8](repeating: 0, count: hashSize)
        var second = first
        first[0] = 0x10
        second[0] = 0x20

        try database.withTransaction { cursor in
            let map = try cursor.writePath([.hashMapInit(counted: true)])
            _ = try map.writePath([.hashMapGet(.value, KeyHash(first)), .write(.uint(1))])
            _ = try map.writePath([.hashMapGet(.value, KeyHash(second)), .write(.uint(2))])
        }
        // 4,095 index blocks below the root block were needed to tell the two apart
        #expect(storage.bytes.count > 4095 * 144)

        let root = database.rootCursor
        #expect(try root.count == 2)
        #expect(try #require(try root.readPath([.hashMapGet(.value, KeyHash(first))])).readUInt64() == 1)
        #expect(try #require(try root.readPath([.hashMapGet(.value, KeyHash(second))])).readUInt64() == 2)

        // a third hash that parts ways at the top is not found, and one that
        // agrees with both to the last level is not found either
        var third = first
        third[hashSize - 1] = 0x01
        #expect(try root.readPath([.hashMapGet(.value, KeyHash(third))]) == nil)
        var fourth = first
        fourth[0] = 0x00
        #expect(try root.readPath([.hashMapGet(.value, KeyHash(fourth))]) == nil)

        // a later transaction copies the whole chain on its way down, and a
        // removal walks it both ways
        try database.withTransaction { cursor in
            _ = try cursor.writePath([.hashMapGet(.value, KeyHash(second)), .write(.uint(3))])
            _ = try cursor.writePath([.hashMapRemove(KeyHash(first))])
            #expect(throws: XitDBError.keyNotFound) { try cursor.writePath([.hashMapRemove(KeyHash(first))]) }
        }
        #expect(try root.count == 1)
        #expect(try root.readPath([.hashMapGet(.value, KeyHash(first))]) == nil)
        #expect(try #require(try root.readPath([.hashMapGet(.value, KeyHash(second))])).readUInt64() == 3)

        // a hash of the wrong size is refused
        #expect(throws: XitDBError.invalidHashSize) { try root.readPath([.hashMapGet(.value, sha1("a"))]) }
    }

    /// An index block that points at itself: the trie has no bottom. A
    /// lookup follows it for as many levels as the hash has and then stops.
    @Test func aTrieThatPointsAtItselfEnds() throws {
        var bytes = Self.sound
        let database = try Database(storage: MemoryStorage(bytes: bytes), hashSize: 20)
        let moment = try #require(try database.rootCursor.readPath([.arrayListGet(-1)]))
        let mapPosition = Int(try moment.slot.value)
        // every slot of the map's root block now points back at the block
        for slot in 0..<16 {
            bytes.replaceSubrange(
                (mapPosition + slot * 9)..<(mapPosition + slot * 9 + 9),
                with: slotBytes(Slot(value: UInt64(mapPosition), tag: .index))
            )
        }
        // The last trailer does not cover the block, so the file still opens.
        let looped = try Database(storage: MemoryStorage(bytes: bytes), hashSize: 20)
        let loopedMoment = try #require(try looped.rootCursor.readPath([.arrayListGet(-1)]))
        #expect(throws: XitDBError.keyOffsetExceeded) { try loopedMoment.readPath([.hashMapGet(.value, sha1("a"))]) }
        // and so does an iterator: forty levels of blocks, then the error
        var iterator = try loopedMoment.iterator()
        #expect(throws: XitDBError.keyOffsetExceeded) { try iterator.next() }
        exercise(bytes)
    }

    /// An array list's blocks can only be as deep as its size needs. An
    /// iterator that finds a block where an element should be stops with an
    /// error instead of going on down, even when that block is a sound one
    /// elsewhere in the list.
    @Test func aListDeeperThanItsSizeAllowsEndsItsIterator() throws {
        var bytes = Self.sound
        let database = try Database(storage: MemoryStorage(bytes: bytes), hashSize: 20)
        let moment = try #require(try database.rootCursor.readPath([.arrayListGet(-1)]))
        let list = try #require(try moment.readPath([.hashMapGet(.value, sha1("list"))]))
        // twenty elements: a root block whose first two slots point at
        // blocks of elements. The second element block now points at the
        // first one in its third slot, where the element 18 was.
        let header = try database.reader.arrayListHeader(at: try list.slot.value)
        let firstBlock = try database.reader.slot(at: header.ptr).value
        let secondBlock = Int(try database.reader.slot(at: header.ptr + 9).value)
        bytes.replaceSubrange(
            (secondBlock + 18)..<(secondBlock + 27), with: slotBytes(Slot(value: firstBlock, tag: .index)))
        let damaged = try Database(storage: MemoryStorage(bytes: bytes), hashSize: 20)
        let damagedMoment = try #require(try damaged.rootCursor.readPath([.arrayListGet(-1)]))
        let damagedList = try #require(try damagedMoment.readPath([.hashMapGet(.value, sha1("list"))]))
        var iterator = try damagedList.iterator()
        var seen: [UInt64] = []
        #expect(throws: XitDBError.maxShiftExceeded) {
            while let element = try iterator.next() {
                seen.append(try element.readUInt64())
            }
        }
        #expect(seen == Array(0..<18))
        var fromIndex = try damagedList.iterator(fromArrayListIndex: 17)
        #expect(try fromIndex.next()?.readUInt64() == 17)
        #expect(throws: XitDBError.maxShiftExceeded) { try fromIndex.next() }
        // reading by index hands the slot over as it is, as Zig does
        #expect(try damagedList.readPathSlot([.arrayListGet(18)])?.tag == .index)
        exercise(bytes)

        // Starting at an index goes down through the blocks above the
        // element. One that holds something other than a block is reported,
        // where Zig would read a block at whatever the slot says.
        var upper = Self.sound
        upper.replaceSubrange(
            Int(header.ptr + 9)..<Int(header.ptr + 18), with: slotBytes(Slot(value: 7, tag: .uint)))
        let damagedUpper = try Database(storage: MemoryStorage(bytes: upper), hashSize: 20)
        let upperMoment = try #require(try damagedUpper.rootCursor.readPath([.arrayListGet(-1)]))
        let upperList = try #require(try upperMoment.readPath([.hashMapGet(.value, sha1("list"))]))
        #expect(throws: XitDBError.unexpectedTag) { try upperList.iterator(fromArrayListIndex: 17) }
        var fromStart = try upperList.iterator(fromArrayListIndex: 15)
        #expect(try fromStart.next()?.readUInt64() == 15)
        exercise(upper)
    }

    /// A byte value whose length reaches past the end of the file: the
    /// stream reports the end of the database where it runs out, rather
    /// than giving fewer bytes as if the value ended there.
    @Test func aValueLongerThanTheFileEndsItsStream() throws {
        var bytes = Self.sound
        let database = try Database(storage: MemoryStorage(bytes: bytes), hashSize: 20)
        let moment = try #require(try database.rootCursor.readPath([.arrayListGet(-1)]))
        let long = try #require(try moment.readPath([.hashMapGet(.value, sha1("long"))]))
        let record = Int(try long.slot.value)
        bytes.replaceSubrange(record..<(record + 8), with: bigEndianBytes(1 << 40))
        let damaged = try Database(storage: MemoryStorage(bytes: bytes), hashSize: 20)
        let damagedMoment = try #require(try damaged.rootCursor.readPath([.arrayListGet(-1)]))
        let damagedLong = try #require(try damagedMoment.readPath([.hashMapGet(.value, sha1("long"))]))
        var reader = try damagedLong.reader()
        #expect(reader.size == 1 << 40)
        var buffer = [UInt8](repeating: 0, count: 16)
        var span = buffer.mutableSpan
        // the start of the value is there
        #expect(try reader.read(into: &span) == 16)
        // the end is not
        reader.seek(to: (1 << 40) - 4)
        #expect(throws: XitDBError.endOfStream) { try reader.read(into: &span) }
        #expect(throws: XitDBError.endOfStream) { try reader.readAll(into: &span) }
        reader.seek(to: 0)
        #expect(throws: XitDBError.endOfStream) { try reader.readRemaining() }
        // the whole-value reads say the same
        #expect(throws: XitDBError.endOfStream) { try damagedLong.readBytes() }
        exercise(bytes)
    }
}
