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
    /// A database with one of everything this milestone has: a list at the
    /// root with two moments, a map with short and long values, a nested
    /// list deep enough to have two levels, and a counted map.
    static let sound: [UInt8] = {
        (try? makeSound()) ?? []
    }()

    static func makeSound() throws -> [UInt8] {
        let storage = MemoryStorage()
        let database = try Database(
            storage: storage, hashSize: 20, hashID: nil, fileID: 0xC0FFEE, random: FixedRandom([1, 2]))
        let root = database.rootCursor()
        _ = try root.writePath([.arrayListInit, .arrayListAppend, .hashMapInit(), .ctx]) { cursor in
            _ = try cursor.writePath([.hashMapGet(.value, sha1("a")), .write(.uint(1))])
            _ = try cursor.writePath([.hashMapGet(.key, sha1("a")), .write(.bytes(Array("a".utf8)))])
            _ = try cursor.writePath([
                .hashMapGet(.value, sha1("long")),
                .write(.bytesObject(Bytes(Array("a value too long to fit in a slot".utf8), formatTag: [0x74, 0x67]))),
            ])
            let list = try cursor.writePath([.hashMapGet(.value, sha1("list")), .arrayListInit])
            for index in 0..<20 {
                _ = try list.writePath([.arrayListAppend, .write(.uint(UInt64(index)))])
            }
            let counted = try cursor.writePath([.hashMapGet(.value, sha1("counted")), .hashMapInit(counted: true)])
            _ = try counted.writePath([.hashMapGet(.value, sha1("x")), .write(.int(-1))])
            _ = try counted.writePath([.hashMapGet(.value, sha1("y")), .write(.float(1.5))])
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
            tolerating { _ = try database.committedSize() }
            tolerating { _ = try database.rootCursor().count() }
            for index in [Int64(0), -1, 2, .min] {
                var found: Cursor<ReadOnly>?
                tolerating { found = try database.rootCursor().readPath([.arrayListGet(index)]) }
                guard let moment = found else { continue }
                tolerating { _ = try moment.count() }
                for key in ["a", "long", "list", "counted", "b", "missing"] {
                    var value: Cursor<ReadOnly>?
                    tolerating { value = try moment.readPath([.hashMapGet(.value, sha1(key))]) }
                    guard let value else { continue }
                    tolerating { _ = try value.count() }
                    tolerating { _ = try value.readUint() }
                    tolerating { _ = try value.readBytesObjectAlloc() }
                    tolerating {
                        var buffer = [UInt8](repeating: 0, count: 64)
                        var span = buffer.mutableSpan
                        _ = try value.readBytesObject(into: &span)
                    }
                }
                tolerating { _ = try moment.readPath([.hashMapGet(.key, sha1("a"))])?.readBytesAlloc(maxSize: 4) }
                tolerating { _ = try moment.readPath([.hashMapGet(.kvPair, sha1("a"))])?.readKeyValuePair() }
                for element in [Int64(0), 15, 16, 19, 20, -1, -21] {
                    tolerating {
                        _ = try moment.readPath([.hashMapGet(.value, sha1("list")), .arrayListGet(element)])?.readUint()
                    }
                }
                tolerating {
                    _ = try moment.readPath([.hashMapGet(.value, sha1("counted")), .hashMapGet(.value, sha1("x"))])?
                        .readInt()
                }
            }

            // writes: one transaction that goes on after each part that
            // fails, so that every kind of write meets the damage
            tolerating { _ = try database.rootCursor().writePath([.arrayListInit]) }
            tolerating {
                let root = database.rootCursor()
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
                try database.runContext { cursor in
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
            tolerating { _ = try database.rootCursor().writePath([.write(.uint(1))]) }
            // Nothing here writes more than a few kilobytes. A storage that
            // grew out of all proportion was sent a write it should not get.
            #expect(storage.bytes.count < bytes.count + 100_000)
        }
    }

    @Test func theSoundDatabaseIsWhatTheTestsExpect() throws {
        let bytes = Self.sound
        try #require(bytes.count > 1500)
        let database = try Database(storage: MemoryStorage(bytes: bytes), hashSize: 20)
        #expect(try database.rootCursor().count() == 2)
        let moment = try #require(try database.rootCursor().readPath([.arrayListGet(-1)]))
        #expect(try #require(try moment.readPath([.hashMapGet(.value, sha1("list"))])).count() == 20)
        #expect(try #require(try moment.readPath([.hashMapGet(.value, sha1("counted"))])).count() == 2)
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

    /// Eight bytes anywhere in the file replaced by a wild 64-bit value: the
    /// largest ones, and the position of the root header. Wherever the eight
    /// bytes are an offset, a size or a count, the engine now has a wild
    /// one.
    @Test(arguments: [UInt64.max, .max - 8, 1 << 63, 1 << 40, 0, 20] as [UInt64])
    func anyEightBytesCanBeAWildNumber(value: UInt64) {
        let sound = Self.sound
        for offset in 0...(sound.count - 8) {
            var bytes = sound
            bytes.replaceSubrange(offset..<(offset + 8), with: bigEndianBytes(value))
            exercise(bytes)
        }
    }

    /// More wild numbers, at every third offset.
    @Test(arguments: [.max - 1, .max - 143, (1 << 63) - 1, 1 << 62, 1, 29, 37] as [UInt64])
    func anyEightBytesCanBeAnotherWildNumber(value: UInt64) {
        let sound = Self.sound
        for offset in stride(from: 0, through: sound.count - 8, by: 3) {
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
            for offset in stride(from: 0, through: sound.count - 8, by: 3) {
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

        try database.runContext { cursor in
            let map = try cursor.writePath([.hashMapInit(counted: true)])
            _ = try map.writePath([.hashMapGet(.value, KeyHash(first)), .write(.uint(1))])
            _ = try map.writePath([.hashMapGet(.value, KeyHash(second)), .write(.uint(2))])
        }
        // 4,095 index blocks below the root block were needed to tell the two apart
        #expect(storage.bytes.count > 4095 * 144)

        let root = database.rootCursor()
        #expect(try root.count() == 2)
        #expect(try #require(try root.readPath([.hashMapGet(.value, KeyHash(first))])).readUint() == 1)
        #expect(try #require(try root.readPath([.hashMapGet(.value, KeyHash(second))])).readUint() == 2)

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
        try database.runContext { cursor in
            _ = try cursor.writePath([.hashMapGet(.value, KeyHash(second)), .write(.uint(3))])
            _ = try cursor.writePath([.hashMapRemove(KeyHash(first))])
            #expect(throws: XitDBError.keyNotFound) { try cursor.writePath([.hashMapRemove(KeyHash(first))]) }
        }
        #expect(try root.count() == 1)
        #expect(try root.readPath([.hashMapGet(.value, KeyHash(first))]) == nil)
        #expect(try #require(try root.readPath([.hashMapGet(.value, KeyHash(second))])).readUint() == 3)

        // a hash of the wrong size is refused
        #expect(throws: XitDBError.invalidHashSize) { try root.readPath([.hashMapGet(.value, sha1("a"))]) }
    }

    /// An index block that points at itself: the trie has no bottom. A
    /// lookup follows it for as many levels as the hash has and then stops.
    @Test func aTrieThatPointsAtItselfEnds() throws {
        var bytes = Self.sound
        let database = try Database(storage: MemoryStorage(bytes: bytes), hashSize: 20)
        let moment = try #require(try database.rootCursor().readPath([.arrayListGet(-1)]))
        let mapPosition = Int(try moment.slot().value)
        // every slot of the map's root block now points back at the block
        for slot in 0..<16 {
            bytes.replaceSubrange(
                (mapPosition + slot * 9)..<(mapPosition + slot * 9 + 9),
                with: slotBytes(Slot(value: UInt64(mapPosition), tag: .index))
            )
        }
        // The last trailer does not cover the block, so the file still opens.
        let looped = try Database(storage: MemoryStorage(bytes: bytes), hashSize: 20)
        let loopedMoment = try #require(try looped.rootCursor().readPath([.arrayListGet(-1)]))
        #expect(throws: XitDBError.keyOffsetExceeded) { try loopedMoment.readPath([.hashMapGet(.value, sha1("a"))]) }
        exercise(bytes)
    }
}
