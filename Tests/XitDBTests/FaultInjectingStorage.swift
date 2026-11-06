import Foundation
import Testing

@testable import XitDB

/// A storage that passes everything through to another one, except for the
/// faults it is told to inject. For testing that a database recovers when its
/// storage fails partway through a transaction.
///
/// Writes and syncs are counted from one, in the order they are made. An
/// injected failure is `storageFailure(errno: EIO)`.
final class FaultInjectingStorage: WritableStorage {
    enum Fault: Equatable {
        /// The numbered write fails and writes nothing.
        case failWrite(Int)
        /// The numbered write writes only its first `keeping` bytes and then
        /// fails, as a write interrupted by a full disk or a crash would.
        case cutWriteShort(Int, keeping: Int)
        /// The numbered sync fails. Nothing is flushed or synced by it.
        case failSync(Int)
    }

    static let failure = XitDBError.storageFailure(errno: EIO)

    let base: any WritableStorage
    var faults: [Fault]
    private(set) var writeCount = 0
    private(set) var syncCount = 0

    init(_ base: any WritableStorage, faults: [Fault] = []) {
        self.base = base
        self.faults = faults
    }

    func read(into buffer: inout MutableSpan<UInt8>, at offset: UInt64) throws(XitDBError) -> Int {
        try base.read(into: &buffer, at: offset)
    }

    func length() throws(XitDBError) -> UInt64 {
        try base.length()
    }

    func write(_ bytes: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        writeCount += 1
        for fault in faults {
            switch fault {
            case .failWrite(writeCount):
                throw Self.failure
            case .cutWriteShort(writeCount, let keeping):
                try base.write(bytes.extracting(0..<min(keeping, bytes.count)), at: offset)
                throw Self.failure
            default:
                continue
            }
        }
        try base.write(bytes, at: offset)
    }

    func setLength(_ length: UInt64) throws(XitDBError) {
        try base.setLength(length)
    }

    func flush() throws(XitDBError) {
        try base.flush()
    }

    func sync(_ point: SyncPoint) throws(XitDBError) {
        syncCount += 1
        if faults.contains(.failSync(syncCount)) { throw Self.failure }
        try base.sync(point)
    }
}

@Suite struct FaultInjectingStorageTests {
    @Test func withoutFaultsItPassesEverythingThrough() throws {
        let memory = MemoryStorage()
        let storage = FaultInjectingStorage(memory)
        try writeBytes(storage, [1, 2, 3, 4], at: 0)
        try storage.setLength(3)
        try storage.flush()
        try storage.sync(.beforeRootHeader)
        #expect(try storage.length() == 3)
        #expect(try readBytes(storage, at: 1, count: 10) == [2, 3])
        #expect(memory.bytes == [1, 2, 3])
        #expect(storage.writeCount == 1)
        #expect(storage.syncCount == 1)
    }

    @Test func aFailedWriteWritesNothingAndLaterWritesGoThrough() throws {
        let memory = MemoryStorage()
        let storage = FaultInjectingStorage(memory, faults: [.failWrite(2)])
        try writeBytes(storage, [1, 2], at: 0)
        #expect(throws: FaultInjectingStorage.failure) { try writeBytes(storage, [3, 4], at: 2) }
        #expect(memory.bytes == [1, 2])
        try writeBytes(storage, [5, 6], at: 2)
        #expect(memory.bytes == [1, 2, 5, 6])
        #expect(storage.writeCount == 3)
    }

    @Test func aWriteCutShortLeavesItsFirstBytesBehind() throws {
        let memory = MemoryStorage()
        let storage = FaultInjectingStorage(memory, faults: [.cutWriteShort(1, keeping: 3)])
        #expect(throws: FaultInjectingStorage.failure) { try writeBytes(storage, [1, 2, 3, 4, 5], at: 0) }
        #expect(memory.bytes == [1, 2, 3])

        // keeping more than the write holds writes all of it and still fails
        storage.faults = [.cutWriteShort(2, keeping: 100)]
        #expect(throws: FaultInjectingStorage.failure) { try writeBytes(storage, [9], at: 3) }
        #expect(memory.bytes == [1, 2, 3, 9])
    }

    @Test func aFailedSyncDoesNotReachTheStorageUnderneath() throws {
        let directory = try TemporaryDirectory()
        let buffered = try BufferedFileStorage(path: directory.path(), durability: .none)
        let storage = FaultInjectingStorage(buffered, faults: [.failSync(2)])
        try writeBytes(storage, [1, 2, 3], at: 0)

        try storage.sync(.beforeRootHeader)
        #expect(try directory.contents() == [1, 2, 3])

        try writeBytes(storage, [4], at: 3)
        #expect(throws: FaultInjectingStorage.failure) { try storage.sync(.afterRootHeader) }
        // the buffered storage was never asked, so it has not flushed
        #expect(try directory.contents() == [1, 2, 3])
        #expect(storage.syncCount == 2)

        try storage.sync(.afterRootHeader)
        #expect(try directory.contents() == [1, 2, 3, 4])
    }

    @Test func itWorksOverEveryKindOfStorage() throws {
        for kind in StorageKind.allCases {
            let subject = try StorageUnderTest(kind)
            let storage = FaultInjectingStorage(subject.storage, faults: [.cutWriteShort(2, keeping: 1)])
            try writeBytes(storage, [1, 2], at: 0)
            #expect(throws: FaultInjectingStorage.failure) { try writeBytes(storage, [3, 4], at: 2) }
            // roll back to before the failed write, as a database would
            try storage.setLength(2)
            try storage.flush()
            #expect(try subject.stored() == [1, 2])
        }
    }
}
