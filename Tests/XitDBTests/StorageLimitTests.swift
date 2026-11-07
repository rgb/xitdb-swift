import Foundation
import Testing

@testable import XitDB

/// No storage may trap on an offset or a length it is given, however large
/// (requirement R23). Every call here must return or throw.
@Suite struct StorageLimitTests {
    /// Offsets at which not even one byte fits below the largest offset a
    /// file can have (`Int64.max`) or an array can index (`Int.max`).
    static let beyondEverything: [UInt64] = [
        .max, .max - 1, .max - 7, .max - 8,
        1 << 63, (1 << 63) + 1, (1 << 63) - 1,
    ]

    /// Offsets that a file offset can still express, but far beyond what any
    /// volume or any memory holds.
    static let expressibleButAbsurd: [UInt64] = [(1 << 63) - 2, 1 << 62]

    static let hugeOffsets = beyondEverything + expressibleButAbsurd

    /// A storage of each kind holding four bytes. The memory storage has a
    /// size limit: without one, a write far beyond the end and below
    /// `Int.max` asks for that much memory, which no limit of ours prevents.
    private func storage(_ kind: StorageKind) throws -> (any WritableStorage, TemporaryDirectory?) {
        let storage: any WritableStorage
        var directory: TemporaryDirectory?
        switch kind {
        case .memory:
            storage = MemoryStorage(maxSize: 1 << 20)
        case .file:
            directory = try TemporaryDirectory()
            storage = try FileStorage(path: try #require(directory).path(), access: .create, durability: .none)
        case .bufferedFile:
            directory = try TemporaryDirectory()
            storage = try BufferedFileStorage(path: try #require(directory).path(), access: .create, durability: .none)
        case .bufferedFileSmallWindow:
            directory = try TemporaryDirectory()
            storage = try BufferedFileStorage(
                path: try #require(directory).path(),
                access: .create,
                durability: .none,
                bufferLimit: 200
            )
        }
        try writeBytes(storage, [1, 2, 3, 4], at: 0)
        return (storage, directory)
    }

    @Test(arguments: StorageKind.allCases)
    func aReadAtAHugeOffsetReadsNothing(kind: StorageKind) throws {
        let (storage, directory) = try storage(kind)
        for offset in Self.hugeOffsets {
            for count in [0, 1, 9, 300] {
                #expect(try readBytes(storage, at: offset, count: count) == [], "offset \(offset), count \(count)")
            }
        }
        #expect(try readBytes(storage, at: 0, count: 10) == [1, 2, 3, 4])
        _ = directory
    }

    @Test(arguments: StorageKind.allCases)
    func aWriteThatNoFileOrArrayCouldHoldThrowsAtOnce(kind: StorageKind) throws {
        let (storage, directory) = try storage(kind)
        let expected: XitDBError = kind == .memory ? .maxSizeExceeded : .storageFailure(errno: EFBIG)
        for offset in Self.beyondEverything {
            for count in [1, 8, 9, 300] {
                let bytes = [UInt8](repeating: 9, count: count)
                #expect(throws: expected, "offset \(offset), count \(count)") {
                    try writeBytes(storage, bytes, at: offset)
                }
            }
            // writing nothing is nothing, wherever
            try writeBytes(storage, [], at: offset)
        }
        #expect(try storage.length == 4)
        #expect(try readBytes(storage, at: 0, count: 10) == [1, 2, 3, 4])
        try storage.flush()
        #expect(try readBytes(storage, at: 0, count: 10) == [1, 2, 3, 4])
        _ = directory
    }

    @Test func aMemoryStorageWithALimitRejectsAnAbsurdOffset() throws {
        let (storage, _) = try storage(.memory)
        for offset in Self.expressibleButAbsurd {
            #expect(throws: XitDBError.maxSizeExceeded) { try writeBytes(storage, [9], at: offset) }
        }
        #expect(try readBytes(storage, at: 0, count: 10) == [1, 2, 3, 4])
    }

    /// Whether a volume takes a byte at an absurd but expressible offset is
    /// the system's business. Its answer must come back as a success or a
    /// storage failure. On the volume this was written on, it is "file too
    /// large".
    @Test(arguments: expressibleButAbsurd)
    func aFileWriteAtAnAbsurdOffsetIsLeftToTheSystem(offset: UInt64) throws {
        let (storage, directory) = try storage(.file)
        do {
            try writeBytes(storage, [9], at: offset)
        } catch XitDBError.storageFailure {
            // the system refused
        }
        try storage.truncate(to: 4)
        #expect(try #require(directory).contents() == [1, 2, 3, 4])
    }

    /// The buffered storage takes such a write into its window, where the
    /// system has no say yet. The window reads back, fails to flush if the
    /// system refuses it, and can be thrown away without the file.
    @Test(arguments: [StorageKind.bufferedFile, .bufferedFileSmallWindow], expressibleButAbsurd)
    func aBufferedWriteAtAnAbsurdOffsetCanBeReadAndRolledBack(kind: StorageKind, offset: UInt64) throws {
        let (storage, directory) = try storage(kind)
        try storage.flush()
        try writeBytes(storage, [9], at: offset)
        #expect(try storage.length == offset + 1)
        #expect(try readBytes(storage, at: offset, count: 5) == [9])
        // the gap before the window reads as zeros, however long it is
        #expect(try readBytes(storage, at: 2, count: 6) == [3, 4, 0, 0, 0, 0])
        #expect(try readBytes(storage, at: offset - 3, count: 5) == [0, 0, 0, 9])

        do {
            try storage.flush()
        } catch XitDBError.storageFailure {
            // the system refused
        }
        try storage.truncate(to: 4)
        #expect(try storage.length == 4)
        try storage.flush()
        #expect(try #require(directory).contents() == [1, 2, 3, 4])
    }

    @Test(arguments: StorageKind.allCases)
    func aHugeLengthIsInvalidAndChangesNothing(kind: StorageKind) throws {
        let (storage, directory) = try storage(kind)
        for length in Self.hugeOffsets + [5] {
            #expect(throws: XitDBError.invalidLength, "length \(length)") { try storage.truncate(to: length) }
        }
        #expect(try storage.length == 4)
        #expect(try readBytes(storage, at: 0, count: 10) == [1, 2, 3, 4])
        _ = directory
    }

    /// Without a size limit, a memory storage still rejects what cannot be
    /// an array index at all.
    @Test func anUnlimitedMemoryStorageRejectsWhatCannotBeIndexed() throws {
        let storage = MemoryStorage(bytes: [1, 2, 3, 4])
        let offsets: [UInt64] = [.max, .max - 1, 1 << 63, (1 << 63) - 1]
        for offset in offsets {
            #expect(throws: XitDBError.maxSizeExceeded) { try writeBytes(storage, [9, 9], at: offset) }
            #expect(try readBytes(storage, at: offset, count: 4) == [])
            #expect(throws: XitDBError.invalidLength) { try storage.truncate(to: offset) }
        }
        #expect(storage.bytes == [1, 2, 3, 4])
    }
}
