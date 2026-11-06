import Foundation
import Testing

@testable import XitDB

/// One test for each branch of Zig's `CoreBufferedFile.Writer.drain` and of
/// its `setLength`, with a window limit of sixteen bytes. Each test checks
/// where the bytes are (the window or the file) and that reads see them.
@Suite struct BufferedFileStorageTests {
    let directory: TemporaryDirectory
    let storage: BufferedFileStorage

    init() throws {
        directory = try TemporaryDirectory()
        storage = try BufferedFileStorage(path: directory.path(), durability: .none, bufferLimit: 16)
    }

    private func onDisk() throws -> [UInt8] {
        try directory.contents()
    }

    private func everything() throws -> [UInt8] {
        try readBytes(storage, at: 0, count: 1000)
    }

    // MARK: writes

    @Test func theFirstWriteStartsTheWindowWhereItLands() throws {
        try writeBytes(storage, [1, 2, 3], at: 0)
        #expect(storage.memoryPosition == 0)
        #expect(storage.memory.count == 3)
        #expect(storage.fileLength == 0)
        #expect(try onDisk() == [])
        #expect(try storage.length() == 3)
        #expect(try everything() == [1, 2, 3])
    }

    @Test func aWriteInsideTheWindowChangesItInPlace() throws {
        try writeBytes(storage, [1, 2, 3, 4, 5], at: 0)
        try writeBytes(storage, [8, 9], at: 1)
        #expect(storage.memoryPosition == 0)
        #expect(storage.memory.count == 5)
        #expect(try onDisk() == [])
        #expect(try everything() == [1, 8, 9, 4, 5])
    }

    @Test func aWriteAtTheEndOfTheWindowExtendsIt() throws {
        try writeBytes(storage, [1, 2, 3], at: 0)
        try writeBytes(storage, [4, 5], at: 3)
        // one that starts inside and reaches beyond the end extends it too
        try writeBytes(storage, [6, 7, 8], at: 4)
        #expect(storage.memoryPosition == 0)
        #expect(storage.memory.count == 7)
        #expect(try onDisk() == [])
        #expect(try everything() == [1, 2, 3, 4, 6, 7, 8])
    }

    @Test func aWritePastTheEndOfTheWindowFlushesAndStartsANewOne() throws {
        try writeBytes(storage, [1, 2, 3], at: 0)
        try writeBytes(storage, [7, 8], at: 6)
        #expect(try onDisk() == [1, 2, 3])
        #expect(storage.memoryPosition == 6)
        #expect(storage.memory.count == 2)
        #expect(storage.fileLength == 3)
        #expect(try storage.length() == 8)
    }

    /// The window can start beyond the end of the file. The bytes between do
    /// not exist anywhere yet. They read as the zeros they will be once the
    /// window is flushed. Zig reports the end of the stream for such a read;
    /// this is the one place where this storage deliberately differs.
    @Test func theGapBeforeAWindowBeyondTheEndReadsAsZeros() throws {
        try writeBytes(storage, [1, 2, 3], at: 0)
        try writeBytes(storage, [7, 8], at: 6)
        #expect(try onDisk() == [1, 2, 3])

        #expect(try everything() == [1, 2, 3, 0, 0, 0, 7, 8])
        #expect(try readBytes(storage, at: 3, count: 3) == [0, 0, 0])
        #expect(try readBytes(storage, at: 4, count: 1) == [0])
        #expect(try readBytes(storage, at: 2, count: 3) == [3, 0, 0])
        #expect(try readBytes(storage, at: 5, count: 2) == [0, 7])
        #expect(try readBytes(storage, at: 8, count: 2) == [])

        // the same reads give the same bytes after the flush
        try storage.flush()
        #expect(try onDisk() == [1, 2, 3, 0, 0, 0, 7, 8])
        #expect(try everything() == [1, 2, 3, 0, 0, 0, 7, 8])
        #expect(try readBytes(storage, at: 3, count: 3) == [0, 0, 0])
    }

    @Test func theGapBeforeAFirstWriteBeyondAnEmptyFileReadsAsZeros() throws {
        try writeBytes(storage, [9], at: 4)
        #expect(try onDisk() == [])
        #expect(try storage.length() == 5)
        #expect(try everything() == [0, 0, 0, 0, 9])
    }

    @Test func aWriteBeforeTheWindowGoesStraightToTheFile() throws {
        try writeBytes(storage, [0, 0, 0, 0, 0, 0, 0, 0], at: 0)
        try storage.flush()
        try writeBytes(storage, [5, 6], at: 8)
        #expect(storage.memoryPosition == 8)

        // before the window and not touching it: the window stays
        try writeBytes(storage, [1, 2], at: 2)
        #expect(try onDisk() == [0, 0, 1, 2, 0, 0, 0, 0])
        #expect(storage.memoryPosition == 8)
        #expect(storage.memory.count == 2)
        #expect(storage.fileLength == 8)
        #expect(try everything() == [0, 0, 1, 2, 0, 0, 0, 0, 5, 6])
    }

    @Test func aDirectWriteThatOverlapsTheWindowFlushesItFirst() throws {
        try writeBytes(storage, [0, 0, 0, 0, 0, 0, 0, 0], at: 0)
        try storage.flush()
        try writeBytes(storage, [5, 6, 7], at: 8)

        // starts before the window and runs into it. Without the flush, a
        // later flush would put the stale 5 back over the 2.
        try writeBytes(storage, [1, 2], at: 7)
        #expect(storage.memory.count == 0)
        #expect(try onDisk() == [0, 0, 0, 0, 0, 0, 0, 1, 2, 6, 7])
        #expect(try everything() == [0, 0, 0, 0, 0, 0, 0, 1, 2, 6, 7])
        try storage.flush()
        #expect(try onDisk() == [0, 0, 0, 0, 0, 0, 0, 1, 2, 6, 7])
    }

    @Test func aWriteThatWouldGrowTheWindowPastTheLimitStartsANewOne() throws {
        let first = (1...12).map { UInt8($0) }
        try writeBytes(storage, first, at: 0)
        #expect(try onDisk() == [])

        // 12 + 5 > 16
        try writeBytes(storage, [21, 22, 23, 24, 25], at: 12)
        #expect(try onDisk() == first)
        #expect(storage.memoryPosition == 12)
        #expect(storage.memory.count == 5)
        #expect(try everything() == first + [21, 22, 23, 24, 25])
    }

    @Test func aWriteInsideTheWindowThatWouldEndPastTheLimitStartsANewOneThere() throws {
        let first = (1...10).map { UInt8($0) }
        try writeBytes(storage, first, at: 0)

        // starts at 8, inside the window, and would end at 18 > 16
        let second = (31...40).map { UInt8($0) }
        try writeBytes(storage, second, at: 8)
        #expect(try onDisk() == first)
        #expect(storage.memoryPosition == 8)
        #expect(storage.memory.count == 10)
        // the new window covers the last two bytes that were flushed
        #expect(try everything() == Array(first[..<8]) + second)
        try storage.flush()
        #expect(try onDisk() == Array(first[..<8]) + second)
    }

    @Test func aWriteLargerThanTheLimitGoesStraightToTheFile() throws {
        try writeBytes(storage, [1, 2, 3], at: 0)
        let large = (0..<40).map { UInt8($0 + 100) }
        try writeBytes(storage, large, at: 3)
        #expect(try onDisk() == [1, 2, 3] + large)
        #expect(storage.memory.count == 0)
        #expect(storage.memoryPosition == 3)
        #expect(storage.fileLength == 43)
        #expect(try storage.length() == 43)
        #expect(try everything() == [1, 2, 3] + large)

        // and so does one into an empty buffer
        try writeBytes(storage, large, at: 43)
        #expect(try onDisk() == [1, 2, 3] + large + large)
        #expect(storage.memory.count == 0)
    }

    @Test func aWriteOfExactlyTheLimitFitsTheWindow() throws {
        let exact = (1...16).map { UInt8($0) }
        try writeBytes(storage, exact, at: 0)
        #expect(try onDisk() == [])
        #expect(storage.memory.count == 16)
        try writeBytes(storage, [99], at: 16)
        #expect(try onDisk() == exact)
        #expect(storage.memoryPosition == 16)
    }

    @Test func aWriteThatBringsTheWindowToExactlyTheLimitStaysInIt() throws {
        let first = (1...10).map { UInt8($0) }
        try writeBytes(storage, first, at: 0)
        // 10 + 6 = 16, the limit: still one window, nothing flushed
        try writeBytes(storage, [21, 22, 23, 24, 25, 26], at: 10)
        #expect(try onDisk() == [])
        #expect(storage.memoryPosition == 0)
        #expect(storage.memory.count == 16)

        // one byte more would not fit
        try writeBytes(storage, [31], at: 16)
        #expect(try onDisk() == first + [21, 22, 23, 24, 25, 26])
        #expect(storage.memoryPosition == 16)
        #expect(storage.memory.count == 1)
    }

    @Test func writingNothingDoesNothing() throws {
        try writeBytes(storage, [1, 2], at: 0)
        try writeBytes(storage, [], at: 50)
        #expect(storage.memoryPosition == 0)
        #expect(storage.memory.count == 2)
        #expect(try storage.length() == 2)
    }

    // MARK: reads

    @Test func aReadCrossesFromTheFileIntoTheWindowAndOutAgain() throws {
        // a file of twenty bytes with a window over bytes 5 to 9
        let file = (0..<20).map { UInt8($0) }
        try writeBytes(storage, file, at: 0)
        try storage.flush()
        try writeBytes(storage, [50, 51, 52, 53, 54], at: 5)
        #expect(try onDisk() == file)

        var expected = file
        expected.replaceSubrange(5..<10, with: [50, 51, 52, 53, 54])
        #expect(try everything() == expected)
        #expect(try readBytes(storage, at: 3, count: 4) == [3, 4, 50, 51])
        #expect(try readBytes(storage, at: 8, count: 4) == [53, 54, 10, 11])
        #expect(try readBytes(storage, at: 12, count: 100) == Array(file[12...]))
        #expect(try storage.length() == 20)
    }

    // MARK: setLength

    @Test func truncationInsideTheWindowShortensIt() throws {
        try writeBytes(storage, [1, 2, 3, 4], at: 0)
        try storage.flush()
        try writeBytes(storage, [5, 6, 7, 8], at: 4)

        try storage.setLength(6)
        #expect(storage.memoryPosition == 4)
        #expect(storage.memory.count == 2)
        #expect(storage.fileLength == nil)
        #expect(try onDisk() == [1, 2, 3, 4, 0, 0])
        #expect(try storage.length() == 6)
        #expect(try everything() == [1, 2, 3, 4, 5, 6])
        try storage.flush()
        #expect(try onDisk() == [1, 2, 3, 4, 5, 6])
    }

    @Test func truncationBeforeTheWindowDiscardsItWithoutWritingIt() throws {
        try writeBytes(storage, [1, 2, 3, 4], at: 0)
        try storage.flush()
        try writeBytes(storage, [5, 6, 7, 8], at: 4)

        try storage.setLength(2)
        #expect(storage.memory.count == 0)
        // the empty window keeps its position, now beyond the end of the file
        #expect(storage.memoryPosition == 4)
        #expect(try onDisk() == [1, 2])
        #expect(try storage.length() == 2)
        #expect(try everything() == [1, 2])

        // nothing is left to flush
        try storage.flush()
        #expect(try onDisk() == [1, 2])
    }

    @Test func truncationAtTheStartOfTheWindowDiscardsIt() throws {
        try writeBytes(storage, [1, 2, 3, 4], at: 0)
        try storage.flush()
        try writeBytes(storage, [5, 6], at: 4)
        try storage.setLength(4)
        #expect(storage.memory.count == 0)
        #expect(try onDisk() == [1, 2, 3, 4])
        #expect(try storage.length() == 4)
    }

    @Test func truncationAfterTheWindowLeavesItAndCutsTheFile() throws {
        // a file of twenty bytes with a window over bytes 5 to 9
        let file = (0..<20).map { UInt8($0) }
        try writeBytes(storage, file, at: 0)
        try storage.flush()
        try writeBytes(storage, [50, 51, 52, 53, 54], at: 5)

        try storage.setLength(15)
        #expect(storage.memoryPosition == 5)
        #expect(storage.memory.count == 5)
        #expect(try onDisk() == Array(file[..<15]))
        #expect(try storage.length() == 15)

        // exactly at the end of the window
        try storage.setLength(10)
        #expect(storage.memory.count == 5)
        #expect(try onDisk() == Array(file[..<10]))
        #expect(try everything() == [0, 1, 2, 3, 4, 50, 51, 52, 53, 54])
    }

    @Test func truncationToTheCurrentLengthChangesNothing() throws {
        try writeBytes(storage, [1, 2, 3], at: 0)
        try storage.setLength(3)
        #expect(storage.memory.count == 3)
        #expect(try everything() == [1, 2, 3])
        #expect(try storage.length() == 3)
    }

    @Test func truncationIntoTheGapBeforeTheWindowKeepsTheGap() throws {
        try writeBytes(storage, [1, 2, 3], at: 0)
        try writeBytes(storage, [7, 8], at: 9)
        #expect(try onDisk() == [1, 2, 3])
        #expect(try storage.length() == 11)

        // the window goes, and the part of the gap that is kept becomes real
        try storage.setLength(6)
        #expect(storage.memory.count == 0)
        #expect(try storage.length() == 6)
        #expect(try onDisk() == [1, 2, 3, 0, 0, 0])
        #expect(try everything() == [1, 2, 3, 0, 0, 0])
    }

    @Test func aRollbackDoesNotWriteWhatItThrowsAway() throws {
        try writeBytes(storage, [1, 2, 3, 4, 5], at: 0)
        try storage.setLength(0)
        #expect(try onDisk() == [])
        #expect(storage.memory.count == 0)
        #expect(try storage.length() == 0)
        try storage.flush()
        #expect(try onDisk() == [])
    }

    @Test func lengtheningIsInvalidAndChangesNothing() throws {
        try writeBytes(storage, [1, 2, 3, 4], at: 0)
        try storage.flush()
        try writeBytes(storage, [5, 6], at: 4)
        for length in [7, UInt64.max] {
            #expect(throws: XitDBError.invalidLength) { try storage.setLength(length) }
            #expect(storage.memory.count == 2)
            #expect(storage.memoryPosition == 4)
            #expect(try onDisk() == [1, 2, 3, 4])
            #expect(try everything() == [1, 2, 3, 4, 5, 6])
        }
    }

    // MARK: the cached file length, flush and sync

    @Test func theFileLengthIsCachedOnlyWhileWriting() throws {
        #expect(storage.fileLength == nil)
        try writeBytes(storage, [1, 2, 3], at: 0)
        #expect(storage.fileLength == 0)
        try storage.flush()
        #expect(storage.fileLength == nil)

        // while it is not cached, a change made by someone else is seen
        let other = try FileStorage(path: directory.path(), durability: .none)
        try writeBytes(other, [4, 5], at: 3)
        #expect(try storage.length() == 5)
        #expect(try everything() == [1, 2, 3, 4, 5])
    }

    @Test func flushWritesTheWindowAndEmptiesIt() throws {
        try writeBytes(storage, [1, 2, 3], at: 0)
        try storage.flush()
        #expect(try onDisk() == [1, 2, 3])
        #expect(storage.memory.count == 0)
        #expect(try everything() == [1, 2, 3])
        // flushing again is harmless
        try storage.flush()
        #expect(try onDisk() == [1, 2, 3])
    }

    /// A storage whose file can be made to refuse writes, as a full disk
    /// would.
    private func storageOverAFileThatCanFail() throws -> (FileStorage, BufferedFileStorage) {
        let file = try FileStorage(path: directory.path("full.db"), durability: .none)
        return (file, BufferedFileStorage(file, bufferLimit: 16))
    }

    private static let diskFull = XitDBError.storageFailure(errno: ENOSPC)

    private static func refuseWrites(_ file: FileStorage) {
        file.calls.write = { (_, _, _) throws(XitDBError) in throw diskFull }
    }

    @Test func aFlushThatFailsKeepsTheBytesAndCanBeTriedAgain() throws {
        let (file, buffered) = try storageOverAFileThatCanFail()
        try writeBytes(buffered, [1, 2, 3], at: 0)
        try buffered.flush()
        try writeBytes(buffered, [4, 5], at: 3)

        Self.refuseWrites(file)
        #expect(throws: Self.diskFull) { try buffered.flush() }
        #expect(throws: Self.diskFull) { try buffered.sync(.beforeRootHeader) }
        #expect(buffered.memory.count == 2)
        #expect(buffered.memoryPosition == 3)
        #expect(try directory.contents("full.db") == [1, 2, 3])
        // the storage still reads as if the bytes were written
        #expect(try buffered.length() == 5)
        #expect(try readBytes(buffered, at: 0, count: 10) == [1, 2, 3, 4, 5])

        // once the file takes writes again, the same flush succeeds
        file.calls.write = Platform.writeFile
        try buffered.flush()
        #expect(buffered.memory.count == 0)
        #expect(try directory.contents("full.db") == [1, 2, 3, 4, 5])
    }

    @Test func aRollbackAfterAFailedFlushDoesNotNeedTheFile() throws {
        let (file, buffered) = try storageOverAFileThatCanFail()
        try writeBytes(buffered, [1, 2, 3], at: 0)
        try buffered.flush()
        try writeBytes(buffered, [4, 5], at: 3)

        Self.refuseWrites(file)
        #expect(throws: Self.diskFull) { try buffered.sync(.beforeRootHeader) }

        // discarding what could not be written does not write anything
        try buffered.setLength(3)
        #expect(buffered.memory.count == 0)
        #expect(try buffered.length() == 3)
        try buffered.flush()
        try buffered.sync(.afterRootHeader)
        #expect(try directory.contents("full.db") == [1, 2, 3])
    }

    @Test func aWriteThatNeedsAFlushFirstFailsAndBuffersNothing() throws {
        let (file, buffered) = try storageOverAFileThatCanFail()
        try writeBytes(buffered, [1, 2, 3], at: 0)

        Self.refuseWrites(file)
        // beyond the end of the window: the window must be flushed first
        #expect(throws: Self.diskFull) { try writeBytes(buffered, [9], at: 10) }
        #expect(buffered.memoryPosition == 0)
        #expect(buffered.memory.count == 3)
        #expect(try readBytes(buffered, at: 0, count: 20) == [1, 2, 3])

        // larger than the limit: it goes straight to the file, which refuses
        let large = [UInt8](repeating: 7, count: 40)
        #expect(throws: Self.diskFull) { try writeBytes(buffered, large, at: 3) }
        #expect(try directory.contents("full.db") == [])
    }

    @Test func afterADirectWriteFailsTheFileLengthIsAskedForAgain() throws {
        let (file, buffered) = try storageOverAFileThatCanFail()
        let large = [UInt8](repeating: 7, count: 40)
        try writeBytes(buffered, large, at: 0)
        #expect(buffered.fileLength == 40)

        // a write that fails partway may have lengthened the file
        Self.refuseWrites(file)
        #expect(throws: Self.diskFull) { try writeBytes(buffered, large, at: 40) }
        #expect(buffered.fileLength == nil)
        #expect(try buffered.length() == 40)
    }

    @Test func unflushedBytesAreLostWhenTheStorageGoesAway() throws {
        do {
            let short = try BufferedFileStorage(path: directory.path("lost.db"), durability: .none)
            try writeBytes(short, [1, 2, 3], at: 0)
            try short.flush()
            try writeBytes(short, [4, 5, 6], at: 3)
        }
        #expect(try directory.contents("lost.db") == [1, 2, 3])
    }

    @Test func theDefaultLimitIsTwoMebibytes() throws {
        #expect(BufferedFileStorage.defaultBufferLimit == 2 * 1024 * 1024)
        let standard = try BufferedFileStorage(path: directory.path("default.db"))
        #expect(standard.bufferLimit == 2 * 1024 * 1024)
        #expect(storage.bufferLimit == 16)
    }

    @Test func wrapsAnExistingFileStorage() throws {
        let file = try FileStorage(path: directory.path("wrapped.db"), durability: .none)
        try writeBytes(file, [1, 2, 3], at: 0)
        let buffered = BufferedFileStorage(file, bufferLimit: 8)
        try writeBytes(buffered, [4, 5], at: 3)
        #expect(try readBytes(buffered, at: 0, count: 10) == [1, 2, 3, 4, 5])
        #expect(try directory.contents("wrapped.db") == [1, 2, 3])
        try buffered.flush()
        #expect(try directory.contents("wrapped.db") == [1, 2, 3, 4, 5])
    }
}
