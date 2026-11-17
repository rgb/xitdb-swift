import Foundation
import Testing

@testable import XitDB

@Suite struct MemoryStorageTests {
    /// Port of the Zig test "low level memory operations".
    ///
    /// Zig's cores have readers and writers that each keep a position, and
    /// part of the Zig test checks that those positions survive a change of
    /// length. Our storage is positional and has no such state, so those
    /// checks have nothing to apply to. Everything about the bytes is ported.
    @Test func lowLevelMemoryOperations() throws {
        // Zig starts from a buffer whose spare capacity is filled with 0xAA,
        // to show that a gap is zeroed and not left as it was. The equivalent
        // here: fill the storage with 0xAA and cut it back to nothing, which
        // keeps the capacity and what was in it.
        let storage = MemoryStorage(maxSize: 10000)
        try writeBytes(storage, [UInt8](repeating: 0xAA, count: 100), at: 0)
        try storage.truncate(to: 0)

        try writeBytes(storage, Array("Hello".utf8), at: 0)
        #expect(storage.bytes == Array("Hello".utf8))
        try writeBytes(storage, bigEndianBytes(42), at: 5)
        #expect(storage.bytes == Array("Hello".utf8) + bigEndianBytes(42))

        #expect(try readBytes(storage, at: 0, count: 5) == Array("Hello".utf8))
        #expect(try readBytes(storage, at: 5, count: 8) == bigEndianBytes(42))

        // reading past the end reads nothing (Zig: EndOfStream)
        #expect(try readBytes(storage, at: try storage.length + 1, count: 1) == [])

        // a write past the end fills the gap with zeros
        let size = try storage.length
        #expect(size == 13)
        try writeBytes(storage, Array("!".utf8), at: size + 3)
        #expect(Array(storage.bytes[13...]) == [0, 0, 0, 0x21])

        try storage.truncate(to: 0)
        try writeBytes(storage, [1, 2, 3, 4], at: 0)

        // invalid lengths must leave the contents alone
        for length in [5, UInt64.max] {
            #expect(throws: XitDBError.invalidLength) { try storage.truncate(to: length) }
            #expect(storage.bytes == [1, 2, 3, 4])
        }

        try storage.truncate(to: 3)
        #expect(storage.bytes == [1, 2, 3])
        try storage.truncate(to: 3)
        #expect(storage.bytes == [1, 2, 3])
        try storage.truncate(to: 2)
        #expect(try storage.length == 2)
        #expect(storage.bytes == [1, 2])
        #expect(try readBytes(storage, at: 3, count: 1) == [])
        try writeBytes(storage, [9], at: 2)
        #expect(storage.bytes == [1, 2, 9])
    }

    @Test func startsFromExistingBytesAndGivesThemBack() throws {
        let storage = MemoryStorage(bytes: [1, 2, 3])
        #expect(try storage.length == 3)
        #expect(try readBytes(storage, at: 1, count: 10) == [2, 3])
        try writeBytes(storage, [4, 5], at: 3)
        #expect(storage.bytes == [1, 2, 3, 4, 5])
    }

    @Test func bytesObtainedEarlierDoNotChange() throws {
        let storage = MemoryStorage(bytes: [1, 2, 3])
        let before = storage.bytes
        try writeBytes(storage, [9, 9, 9, 9], at: 0)
        #expect(before == [1, 2, 3])
        #expect(storage.bytes == [9, 9, 9, 9])
    }

    @Test func aWriteBeyondTheSizeLimitChangesNothing() throws {
        let storage = MemoryStorage(maxSize: 10)
        #expect(storage.maxSize == 10)
        try writeBytes(storage, [1, 2, 3, 4, 5, 6, 7, 8], at: 0)

        #expect(throws: XitDBError.maxSizeExceeded) { try writeBytes(storage, [1, 2, 3], at: 8) }
        #expect(throws: XitDBError.maxSizeExceeded) { try writeBytes(storage, [1], at: 10) }
        #expect(throws: XitDBError.maxSizeExceeded) { try writeBytes(storage, [1], at: .max) }
        #expect(storage.bytes == [1, 2, 3, 4, 5, 6, 7, 8])

        // up to the limit is allowed, and so is rewriting what is there
        try writeBytes(storage, [9, 10], at: 8)
        try writeBytes(storage, [0, 0], at: 4)
        #expect(storage.bytes == [1, 2, 3, 4, 0, 0, 7, 8, 9, 10])
    }

    @Test func initialBytesMayExceedTheLimitButCannotGrow() throws {
        let storage = MemoryStorage(bytes: [1, 2, 3, 4], maxSize: 2)
        try writeBytes(storage, [9], at: 3)
        #expect(throws: XitDBError.maxSizeExceeded) { try writeBytes(storage, [9], at: 4) }
        #expect(storage.bytes == [1, 2, 3, 9])
    }

    @Test func withoutALimitAnOffsetThatCannotBeAllocatedIsRejected() {
        let storage = MemoryStorage(maxSize: nil)
        #expect(throws: XitDBError.maxSizeExceeded) { try writeBytes(storage, [1, 2], at: .max) }
        #expect(storage.bytes == [])
    }

    // MARK: Growth (the first client's review of 0.5.1, the idiom review's section 3.4)

    /// A write far beyond the end of a storage made without a limit ended
    /// the process: by an integer overflow in the room the array was to be
    /// given (`endIndex + endIndex / 2`), or by an allocation the system
    /// refused, which a Swift array answers by ending the process. Now it
    /// is an error, and the storage is as it was. A storage made without
    /// naming a limit has the machine's physical memory for one, which
    /// refuses these positions as any limit does; one made with no limit
    /// asks the system first, and the system's refusal is the storage's
    /// failure with the system's error.
    ///
    /// The three positions are the reviewer's: just below the largest array
    /// index, where the sum overflowed; a page below it, as a byte writer's
    /// seek and write reaches it; and 2^62, where the sum did not overflow
    /// and the allocation failed.
    @Test(arguments: [UInt64(Int.max) - 16, UInt64(Int.max) - 4096, 1 << 62])
    func aWriteFarBeyondTheEndIsAnErrorAndNotTheProcesssEnd(offset: UInt64) throws {
        let made: [(MemoryStorage, XitDBError)] = [
            (MemoryStorage(), .maxSizeExceeded),
            (MemoryStorage(maxSize: nil), .storageFailure(errno: ENOMEM)),
        ]
        for (storage, refusal) in made {
            try writeBytes(storage, [1, 2, 3, 4], at: 0)
            #expect(throws: refusal) { try writeBytes(storage, [9, 9], at: offset) }
            #expect(storage.bytes == [1, 2, 3, 4])
            #expect(try storage.length == 4)
            // and it goes on as before
            try writeBytes(storage, [5], at: 4)
            #expect(storage.bytes == [1, 2, 3, 4, 5])
        }
    }

    /// The same through a byte writer: a seek far ahead in a value's bytes
    /// and a write, in a database on a storage made without a limit and on
    /// one with no limit. The write reports what the storage does, the
    /// transaction fails, and the database is what it was.
    @Test func aByteWritersSeekFarAheadIsAnErrorAtItsWrite() throws {
        let made: [(MemoryStorage, XitDBError)] = [
            (MemoryStorage(), .maxSizeExceeded),
            (MemoryStorage(maxSize: nil), .storageFailure(errno: ENOMEM)),
        ]
        for (storage, refusal) in made {
            let database = try Database(creating: storage, hashSize: 20)
            #expect(throws: refusal) {
                try database.withTransaction { root in
                    try root.writeBytes { writer throws(XitDBError) in
                        writer.seek(to: UInt64(Int.max) - 4096)
                        try writer.write([1, 2, 3])
                    }
                }
            }
            #expect(try database.rootCursor.slot.isEmpty)
        }
    }

    // MARK: The default limit (decision D59)

    /// A storage made without naming a limit has the machine's physical
    /// memory for one, which the library asks of the system once and a
    /// caller can read; `nil` is still no limit, and a limit that is named
    /// is the limit.
    @Test func theDefaultLimitIsTheMachinesPhysicalMemory() throws {
        let machine = ProcessInfo.processInfo.physicalMemory
        #expect(machine > 0)
        #expect(MemoryStorage.defaultMaxSize == machine)
        #expect(MemoryStorage().maxSize == machine)
        #expect(MemoryStorage(bytes: [1, 2, 3]).maxSize == machine)
        #expect(MemoryStorage(maxSize: nil).maxSize == nil)
        #expect(MemoryStorage(bytes: [1, 2, 3], maxSize: nil).maxSize == nil)
        #expect(MemoryStorage(maxSize: 10).maxSize == 10)
    }

    /// A write past the default limit is refused with the limit's error
    /// and changes nothing: the first byte past it, and a position four
    /// times the machine's memory away, which a system may well grant and
    /// could not back. A write within it goes through.
    @Test func aWritePastTheDefaultLimitIsRefusedWithNothingChanged() throws {
        let limit = try #require(MemoryStorage.defaultMaxSize)
        let storage = MemoryStorage()
        try writeBytes(storage, [1, 2, 3, 4], at: 0)
        #expect(throws: XitDBError.maxSizeExceeded) { try writeBytes(storage, [9], at: limit) }
        #expect(throws: XitDBError.maxSizeExceeded) { try writeBytes(storage, [9, 9], at: limit - 1) }
        #expect(throws: XitDBError.maxSizeExceeded) { try writeBytes(storage, [9], at: limit * 4) }
        #expect(storage.bytes == [1, 2, 3, 4])
        #expect(try storage.length == 4)
        try writeBytes(storage, [5, 6], at: 6)
        #expect(storage.bytes == [1, 2, 3, 4, 0, 0, 5, 6])
    }

    /// Where the system does not say how much memory the machine has, there
    /// is no figure, and so no default limit: none is guessed.
    @Test func aMachineThatDoesNotSayItsMemoryGivesNoFigure() {
        #expect(Platform.memory(pages: 1000, pageSize: 4096) == 4_096_000)
        #expect(Platform.memory(pages: -1, pageSize: 4096) == nil)
        #expect(Platform.memory(pages: 1000, pageSize: -1) == nil)
        #expect(Platform.memory(pages: 0, pageSize: 4096) == nil)
        #expect(Platform.memory(pages: 1000, pageSize: 0) == nil)
        #expect(Platform.memory(pages: Int.max, pageSize: 4096) == nil)
        #expect(Platform.physicalMemory == MemoryStorage.defaultMaxSize)
    }

    /// A limit the caller set is still what refuses first, with its own
    /// error: the system, which would refuse this size with another, is
    /// not asked.
    @Test func aLimitRefusesBeforeTheSystemIsAsked() throws {
        let storage = MemoryStorage(maxSize: 100)
        #expect(throws: XitDBError.maxSizeExceeded) { try writeBytes(storage, [1], at: UInt64(Int.max) - 16) }
        #expect(storage.bytes == [])
    }

    /// The room an array is given when it has to grow, with no sum that
    /// can overflow: half as much again as what is needed, or double what
    /// it has, whichever is more; and where no integer holds those, what is
    /// needed alone.
    @Test func theRoomForMoreIsComputedWithoutOverflow() throws {
        let yes = { (_: Int) -> Int32 in 0 }
        #expect(try MemoryBuffer.capacity(toHold: 100, from: 0, asking: yes) == 150)
        #expect(try MemoryBuffer.capacity(toHold: 100, from: 90, asking: yes) == 180)
        #expect(try MemoryBuffer.capacity(toHold: 1, from: 0, asking: yes) == 1)
        // half as much again of the largest index no integer holds
        #expect(try MemoryBuffer.capacity(toHold: Int.max, from: 0, asking: yes) == Int.max)
        #expect(try MemoryBuffer.capacity(toHold: Int.max - 16, from: 64, asking: yes) == Int.max - 16)
        // the last size whose half as much again an integer holds, and the first whose it does not
        let last = Int.max / 3 * 2
        #expect(try MemoryBuffer.capacity(toHold: last, from: 0, asking: yes) == last + last / 2)
        #expect(try MemoryBuffer.capacity(toHold: last + 2, from: 0, asking: yes) == last + 2)
        // nor does double a capacity that no integer doubles
        #expect(try MemoryBuffer.capacity(toHold: Int.max, from: Int.max - 1, asking: yes) == Int.max)
        #expect(try MemoryBuffer.capacity(toHold: 10, from: Int.max / 2 + 1, asking: yes) == 15)
    }

    /// The system is asked for the room for more first and, refused that,
    /// for what is needed alone: the array is then given exactly that, and
    /// the write that needed it succeeds without asking again. Refused
    /// both, it is the storage's failure with the system's error, and the
    /// bytes, the length and the array's room are as they were.
    ///
    /// The question is replaced where the buffer grows, in the step that a
    /// write calls when its bytes do not fit the array; that a write calls
    /// it, and writes nothing when it throws, is held by the tests above,
    /// which ask the system itself.
    @Test func aRefusalByTheSystemIsAStorageFailureThatChangesNothing() throws {
        var asked: [Int] = []

        // the room for more refused, what is needed granted
        var buffer = MemoryBuffer(bytes: [1, 2, 3, 4])
        let before = buffer.bytes.capacity
        let needed = before + 100
        try buffer.reserve(toHold: needed) { (bytes: Int) in
            asked.append(bytes)
            return bytes > needed ? ENOMEM : 0
        }
        #expect(asked == [max(needed + needed / 2, before * 2), needed])
        let given = buffer.bytes.capacity
        #expect(given >= needed)
        #expect(given < needed + needed / 2)
        #expect(buffer.bytes == [1, 2, 3, 4])
        try buffer.write([UInt8](repeating: 7, count: 100).span, at: UInt64(before))
        #expect(buffer.bytes.capacity == given)
        #expect(buffer.count == needed)
        #expect(Array(buffer.bytes.prefix(4)) == [1, 2, 3, 4])
        #expect(buffer.bytes.dropFirst(4).prefix(before - 4).allSatisfy { $0 == 0 })
        #expect(buffer.bytes.suffix(100).allSatisfy { $0 == 7 })

        // the room for more granted: the array is given it
        asked = []
        var roomy = MemoryBuffer(bytes: [1, 2, 3, 4])
        try roomy.reserve(toHold: needed) { (bytes: Int) in
            asked.append(bytes)
            return 0
        }
        #expect(asked == [max(needed + needed / 2, before * 2)])
        #expect(roomy.bytes.capacity >= max(needed + needed / 2, before * 2))

        // both refused, with whatever the system said
        asked = []
        var refused = MemoryBuffer(bytes: [1, 2, 3, 4])
        let capacity = refused.bytes.capacity
        #expect(throws: XitDBError.storageFailure(errno: EAGAIN)) {
            try refused.reserve(toHold: capacity + 50) { (bytes: Int) in
                asked.append(bytes)
                return EAGAIN
            }
        }
        #expect(asked.count == 2)
        #expect(refused.bytes == [1, 2, 3, 4])
        #expect(refused.count == 4)
        #expect(refused.bytes.capacity == capacity)
    }

    /// What the system is really asked: a little is granted, and more than
    /// any machine has is refused with `ENOMEM`, on every system the
    /// library runs on.
    @Test func theSystemGrantsALittleAndRefusesWhatNoMachineHas() {
        #expect(Platform.askForMemory(0) == 0)
        #expect(Platform.askForMemory(1) == 0)
        #expect(Platform.askForMemory(1 << 20) == 0)
        #expect(Platform.askForMemory(1 << 62) == ENOMEM)
        #expect(Platform.askForMemory(Int.max) == ENOMEM)
        #expect(Platform.noMemory == ENOMEM)
    }

    @Test func writingNothingDoesNothing() throws {
        let storage = MemoryStorage(bytes: [1, 2])
        try writeBytes(storage, [], at: 100)
        #expect(storage.bytes == [1, 2])
    }

    @Test func readsAreShortOnlyAtTheEnd() throws {
        let storage = MemoryStorage(bytes: [1, 2, 3, 4, 5])
        #expect(try readBytes(storage, at: 0, count: 5) == [1, 2, 3, 4, 5])
        #expect(try readBytes(storage, at: 0, count: 9) == [1, 2, 3, 4, 5])
        #expect(try readBytes(storage, at: 3, count: 1) == [4])
        #expect(try readBytes(storage, at: 4, count: 4) == [5])
        #expect(try readBytes(storage, at: 5, count: 4) == [])
        #expect(try readBytes(storage, at: .max, count: 4) == [])
        #expect(try readBytes(storage, at: 2, count: 0) == [])
    }

    @Test func aReadLeavesTheRestOfTheBufferAlone() throws {
        let storage = MemoryStorage(bytes: [1, 2])
        var buffer: [UInt8] = [7, 7, 7, 7]
        var span = buffer.mutableSpan
        #expect(try storage.read(into: &span, at: 1) == 1)
        #expect(buffer == [2, 7, 7, 7])
    }

    /// The range must lie within the buffer, as the file storages require;
    /// one that does not is a precondition failure, whatever the offset,
    /// which no test can show without a crash. At the buffer's bounds, the
    /// ranges that lie within it behave, including the empty ones and the
    /// reads at or past the storage's end that fill nothing.
    @Test func aRangeAtTheBuffersBoundsIsWithinIt() throws {
        let storage = MemoryStorage(bytes: [1, 2, 3, 4, 5])
        func read(range: Range<Int>, at offset: UInt64) throws -> (count: Int, buffer: [UInt8]) {
            var buffer: [UInt8] = [7, 7, 7, 7]
            var span = buffer.mutableSpan
            let count = try storage.read(into: &span, range: range, at: offset)
            return (count, buffer)
        }
        #expect(try read(range: 0..<4, at: 0) == (4, [1, 2, 3, 4]))
        #expect(try read(range: 0..<4, at: 2) == (3, [3, 4, 5, 7]))
        #expect(try read(range: 3..<4, at: 4) == (1, [7, 7, 7, 5]))
        #expect(try read(range: 0..<0, at: 0) == (0, [7, 7, 7, 7]))
        #expect(try read(range: 4..<4, at: 0) == (0, [7, 7, 7, 7]))
        #expect(try read(range: 3..<4, at: 5) == (0, [7, 7, 7, 7]))
        #expect(try read(range: 0..<4, at: 100) == (0, [7, 7, 7, 7]))
        #expect(try read(range: 4..<4, at: .max) == (0, [7, 7, 7, 7]))
    }

    @Test func flushAndSyncDoNothing() throws {
        let storage = MemoryStorage(bytes: [1])
        try storage.flush()
        try storage.sync(.beforeRootHeader)
        try storage.sync(.afterRootHeader)
        #expect(storage.bytes == [1])
    }
}
