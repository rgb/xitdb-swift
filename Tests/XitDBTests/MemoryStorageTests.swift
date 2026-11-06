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
        try storage.setLength(0)

        try writeBytes(storage, Array("Hello".utf8), at: 0)
        #expect(storage.bytes == Array("Hello".utf8))
        try writeBytes(storage, bigEndianBytes(42), at: 5)
        #expect(storage.bytes == Array("Hello".utf8) + bigEndianBytes(42))

        #expect(try readBytes(storage, at: 0, count: 5) == Array("Hello".utf8))
        #expect(try readBytes(storage, at: 5, count: 8) == bigEndianBytes(42))

        // reading past the end reads nothing (Zig: EndOfStream)
        #expect(try readBytes(storage, at: try storage.length() + 1, count: 1) == [])

        // a write past the end fills the gap with zeros
        let size = try storage.length()
        #expect(size == 13)
        try writeBytes(storage, Array("!".utf8), at: size + 3)
        #expect(Array(storage.bytes[13...]) == [0, 0, 0, 0x21])

        try storage.setLength(0)
        try writeBytes(storage, [1, 2, 3, 4], at: 0)

        // invalid lengths must leave the contents alone
        for length in [5, UInt64.max] {
            #expect(throws: XitDBError.invalidLength) { try storage.setLength(length) }
            #expect(storage.bytes == [1, 2, 3, 4])
        }

        try storage.setLength(3)
        #expect(storage.bytes == [1, 2, 3])
        try storage.setLength(3)
        #expect(storage.bytes == [1, 2, 3])
        try storage.setLength(2)
        #expect(try storage.length() == 2)
        #expect(storage.bytes == [1, 2])
        #expect(try readBytes(storage, at: 3, count: 1) == [])
        try writeBytes(storage, [9], at: 2)
        #expect(storage.bytes == [1, 2, 9])
    }

    @Test func startsFromExistingBytesAndGivesThemBack() throws {
        let storage = MemoryStorage(bytes: [1, 2, 3])
        #expect(try storage.length() == 3)
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
        let storage = MemoryStorage()
        #expect(throws: XitDBError.maxSizeExceeded) { try writeBytes(storage, [1, 2], at: .max) }
        #expect(storage.bytes == [])
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

    @Test func flushAndSyncDoNothing() throws {
        let storage = MemoryStorage(bytes: [1])
        try storage.flush()
        try storage.sync(.beforeRootHeader)
        try storage.sync(.afterRootHeader)
        #expect(storage.bytes == [1])
    }
}
