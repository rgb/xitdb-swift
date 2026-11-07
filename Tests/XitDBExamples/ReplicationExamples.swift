import Testing
import XitDB

@Suite("Replication") struct ReplicationExamples {
    private func newSource() throws -> (storage: MemoryStorage, database: Database, history: ArrayList<ReadWrite>) {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashSize: 32)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try commit(1, to: history)
        return (storage, database, history)
    }

    private func commit(_ value: UInt64, to history: ArrayList<ReadWrite>) throws {
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            try HashMap<ReadWrite>(cursor).put(.uint(value), forHash: sha256("value"))
        }
    }

    @Test func aSync() throws {
        let (sourceStorage, source, history) = try newSource()
        let replicaStorage = MemoryStorage()
        let replica = try Database(creating: replicaStorage, hashSize: 32)

        // On the replica: describe what it already has.
        let state = try replica.replicaState

        // On the source: decide which bytes to send, and write them.
        let start = try source.replicationStart(for: state)
        let end = try source.committedSize
        var sink = ArrayByteSink()
        try source.readCommitted(from: start, to: end, into: &sink)

        // On the replica: apply them.
        var bytes = ArrayByteSource(sink.bytes)
        try replica.applyReplicated(at: start, from: &bytes, count: end - start)

        #expect(start == 0)
        #expect(replica.header == source.header)
        #expect(replicaStorage.bytes == sourceStorage.bytes)

        // Only what is new goes next time.
        try commit(2, to: history)
        let nextState = try replica.replicaState
        let nextStart = try source.replicationStart(for: nextState)
        let nextEnd = try source.committedSize
        #expect(nextStart == state.committedSize + end - 62)
        let newBytes = try source.readCommitted(from: nextStart, to: nextEnd)
        try replica.applyReplicated(at: nextStart, bytes: newBytes)

        #expect(replicaStorage.bytes == sourceStorage.bytes)
        #expect(newBytes.count < sourceStorage.bytes.count)
    }

    @Test func overAWire() throws {
        // What goes over a connection: two integers one way, and the start,
        // the count and the bytes the other.
        let (_, source, _) = try newSource()
        let replica = try Database(creating: MemoryStorage(), hashSize: 32)

        let sent = try replica.replicaState
        let (committedSize, checksum) = (sent.committedSize, sent.checksum)

        let received = ReplicaState(committedSize: committedSize, checksum: checksum)
        let start = try source.replicationStart(for: received)
        let end = try source.committedSize
        #expect(start == 0)
        #expect(end > 0)
    }

    /// A sink over a real destination, here a file.
    @Test func streaming() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }
        let (sourceStorage, source, _) = try newSource()

        // Writes what it is given to a file, as it comes.
        struct StorageSink: ByteSink {
            let storage: FileStorage
            var position: UInt64 = 0

            mutating func write(_ bytes: Span<UInt8>) throws {
                try storage.write(bytes, at: position)
                position += UInt64(bytes.count)
            }
        }

        let file = try FileStorage(path: scratch.path("sent.bin"), access: .truncate, durability: .none)
        var sink = StorageSink(storage: file)
        try source.readCommitted(from: 0, to: try source.committedSize, into: &sink)
        #expect(try file.length == sourceStorage.length)

        // Reads what it is asked for from a file, a part at a time.
        struct StorageSource: ByteSource {
            let storage: FileStorage
            var position: UInt64 = 0

            mutating func read(into buffer: inout MutableSpan<UInt8>) throws -> Int {
                let count = try storage.read(into: &buffer, at: position)
                position += UInt64(count)
                return count
            }
        }

        let replicaStorage = MemoryStorage()
        let replica = try Database(creating: replicaStorage, hashSize: 32)
        var bytes = StorageSource(storage: file)
        try replica.applyReplicated(at: 0, from: &bytes, count: try file.length)
        #expect(replicaStorage.bytes == sourceStorage.bytes)
    }

    @Test func aFirstSyncReplacesTheReplica() throws {
        let (_, source, _) = try newSource()
        let replica = try Database(creating: MemoryStorage(), hashSize: 32)
        #expect(replica.header.fileID != source.header.fileID)

        let start = try source.replicationStart(for: try replica.replicaState)
        let bytes = try source.readCommitted(from: start, to: try source.committedSize)
        try replica.applyReplicated(at: start, bytes: bytes)

        #expect(replica.header.fileID == source.header.fileID)
    }

    @Test func aDifferentFileGetsAFullCopy() throws {
        let (_, source, history) = try newSource()
        let replica = try Database(creating: MemoryStorage(), hashSize: 32)
        let bytes = try source.readCommitted(from: 0, to: try source.committedSize)
        try replica.applyReplicated(at: 0, bytes: bytes)
        try commit(2, to: history)
        #expect(try source.replicationStart(for: try replica.replicaState) > 0)

        // The source compacted into a new file: replicas of the old one start again.
        var offsets = MemoryOffsetMap()
        let compacted = try source.compact(into: MemoryStorage(), offsetMap: &offsets)
        #expect(try compacted.replicationStart(for: try replica.replicaState) == 0)
    }

    @Test func aFullSyncOfBytesThatAreNotADatabase() throws {
        let (_, source, _) = try newSource()
        let bytes = try source.readCommitted(from: 0, to: try source.committedSize)

        // Too few to hold the headers, with the count right.
        let first = try Database(creating: MemoryStorage(), hashSize: 32)
        #expect(throws: XitDBError.endOfStream) {
            try first.applyReplicated(at: 0, bytes: Array(bytes[..<30]))
        }

        // A later version of the format.
        var newer = bytes
        newer[5] = 9
        let second = try Database(creating: MemoryStorage(), hashSize: 32)
        #expect(throws: XitDBError.invalidVersion) {
            try second.applyReplicated(at: 0, bytes: newer)
        }

        // No database at all.
        let third = try Database(creating: MemoryStorage(), hashSize: 32)
        #expect(throws: XitDBError.invalidDatabase) {
            try third.applyReplicated(at: 0, bytes: [UInt8](repeating: 0, count: 100))
        }
    }

    @Test func aSourceRestoredFromABackupThatHasSinceGoneOn() throws {
        let (sourceStorage, source, history) = try newSource()
        let backup = sourceStorage.bytes
        try commit(2, to: history)

        let replica = try Database(creating: MemoryStorage(), hashSize: 32)
        try replica.applyReplicated(at: 0, bytes: try source.readCommitted(from: 0, to: try source.committedSize))

        // The source goes back to the backup, and then commits past the replica.
        let restored = try Database(opening: MemoryStorage(bytes: backup))
        let restoredHistory = try ArrayList<ReadWrite>(restored.rootCursor)
        for value: UInt64 in 3...10 {
            try commit(value, to: restoredHistory)
        }
        #expect(try restored.committedSize > replica.committedSize)
        #expect(try restored.replicationStart(for: try replica.replicaState) == 0)
    }

    @Test func aNewDatabaseGivenTheSourcesFileID() throws {
        let storage = MemoryStorage()
        let source = try Database(creating: storage, hashSize: 32, hashID: "sha2", fileID: 7)
        try ArrayList<ReadWrite>(source.rootCursor).append(.uint(1))

        let replica = try Database(creating: MemoryStorage(), hashSize: 32, fileID: 7)
        let start = try source.replicationStart(for: try replica.replicaState)
        #expect(start == 62)

        try replica.applyReplicated(
            at: start, bytes: try source.readCommitted(from: start, to: try source.committedSize))
        #expect(try ArrayList<ReadOnly>(replica.rootCursor).count == 1)
        #expect(replica.header.hashID != source.header.hashID)
    }

    @Test func aReplicaWrittenToDirectlyIsReplaced() throws {
        let (_, source, _) = try newSource()
        let replica = try Database(creating: MemoryStorage(), hashSize: 32)
        let bytes = try source.readCommitted(from: 0, to: try source.committedSize)
        try replica.applyReplicated(at: 0, bytes: bytes)

        let list = try ArrayList<ReadWrite>(replica.rootCursor)
        try list.append(.uint(1))

        #expect(try source.replicationStart(for: try replica.replicaState) == 0)
    }

    @Test func anInterruptedSyncStaysAtItsLastCommit() throws {
        let (_, source, history) = try newSource()
        let replicaStorage = MemoryStorage()
        let replica = try Database(creating: replicaStorage, hashSize: 32)
        try replica.applyReplicated(at: 0, bytes: try source.readCommitted(from: 0, to: try source.committedSize))
        let lastCommit = try replica.committedSize

        try commit(2, to: history)
        let start = try source.replicationStart(for: try replica.replicaState)
        let end = try source.committedSize
        let bytes = try source.readCommitted(from: start, to: end)

        // A connection that drops halfway.
        var half = ArrayByteSource(Array(bytes[..<(bytes.count / 2)]))
        #expect(throws: XitDBError.endOfStream) {
            try replica.applyReplicated(at: start, from: &half, count: end - start)
        }

        // The replica is where it was, and the next sync goes as if nothing
        // had happened.
        #expect(try replica.committedSize == lastCommit)
        let retry = try source.replicationStart(for: try replica.replicaState)
        #expect(retry == start)
        try replica.applyReplicated(at: retry, bytes: bytes)
        #expect(try replica.committedSize == end)
    }

    @Test func anInterruptedFullSyncLeavesNothing() throws {
        let (_, source, _) = try newSource()
        let replica = try Database(creating: MemoryStorage(), hashSize: 32)
        let start = try source.replicationStart(for: try replica.replicaState)
        let end = try source.committedSize
        let bytes = try source.readCommitted(from: start, to: end)
        #expect(start == 0)

        var half = ArrayByteSource(Array(bytes[..<(bytes.count / 2)]))
        #expect(throws: XitDBError.endOfStream) {
            try replica.applyReplicated(at: start, from: &half, count: end - start)
        }
        // The file was emptied first, so the replica is no database until a
        // full sync succeeds.
        #expect(throws: (any Error).self) {
            try replica.committedSize
        }
        try replica.applyReplicated(at: 0, bytes: bytes)
        #expect(try replica.committedSize == end)
    }

    @Test func aFullSyncOfBytesCutShort() throws {
        let (_, source, _) = try newSource()
        let replica = try Database(creating: MemoryStorage(), hashSize: 32)
        let bytes = try source.readCommitted(from: 0, to: try source.committedSize)

        #expect(throws: XitDBError.truncatedDatabase) {
            try replica.applyReplicated(at: 0, bytes: Array(bytes[..<(bytes.count - 1)]))
        }
    }

    @Test func safeFullSync() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }
        let (_, source, _) = try newSource()
        let replica = try Database(creating: MemoryStorage(), hashSize: 32)

        let start = try source.replicationStart(for: try replica.replicaState)
        let end = try source.committedSize

        if start == 0 {
            // The whole file is coming. It goes to a new file, which takes the
            // old one's place only once it is complete.
            let storage = try BufferedFileStorage(path: scratch.path("replica.new"), access: .truncate)
            let incoming = try Database(creating: storage, hashSize: 32)
            try incoming.applyReplicated(at: 0, bytes: try source.readCommitted(from: 0, to: end))
            #expect(incoming.header.fileID == source.header.fileID)
        }
    }

    @Test func anEarlierCommitIsACompleteDatabase() throws {
        let (_, source, history) = try newSource()
        let asOfFirstCommit = try source.committedSize
        try commit(2, to: history)

        let bytes = try source.readCommitted(from: 0, to: asOfFirstCommit)
        let copy = try Database(opening: MemoryStorage(bytes: bytes))

        let moment = try HashMap<ReadOnly>(ArrayList<ReadOnly>(copy.rootCursor).cursor(at: -1)!)
        #expect(try moment.cursor(forHash: sha256("value"))!.readUInt64() == 1)
    }

    @Test func aReadOfNoTrailerIsRefused() throws {
        let (_, source, _) = try newSource()
        #expect(throws: XitDBError.invalidDatabase) {
            try source.readCommitted(from: 0, to: try source.committedSize - 1)
        }
        #expect(throws: XitDBError.invalidRange) {
            try source.readCommitted(from: 0, to: try source.committedSize + 1)
        }
        let replica = try Database(creating: MemoryStorage(), hashSize: 32)
        #expect(throws: XitDBError.invalidRange) {
            try replica.applyReplicated(at: 5, bytes: [])
        }
    }

    @Test func aSinksErrorIsCarried() throws {
        struct ConnectionLost: Error {}
        struct FailingSink: ByteSink {
            mutating func write(_ bytes: Span<UInt8>) throws { throw ConnectionLost() }
        }

        let (_, source, _) = try newSource()
        var sink = FailingSink()
        var connectionLost = false
        do {
            try source.readCommitted(from: 0, to: try source.committedSize, into: &sink)
        } catch .callerError(let carried) where carried is ConnectionLost {
            connectionLost = true
        }
        #expect(connectionLost)
    }

    @Test func theHashSizeHasToMatch() throws {
        let (_, source, _) = try newSource()
        let replica = try Database(creating: MemoryStorage(), hashSize: 20)
        let bytes = try source.readCommitted(from: 0, to: try source.committedSize)
        #expect(throws: XitDBError.invalidHashSize) {
            try replica.applyReplicated(at: 0, bytes: bytes)
        }
    }

    @Test func aReplicaCanBeAFile() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }
        let (sourceStorage, source, _) = try newSource()

        let storage = try BufferedFileStorage(path: scratch.path("replica.db"), access: .create, durability: .none)
        let replica = try Database(creating: storage, hashSize: 32)
        try replica.applyReplicated(
            at: try source.replicationStart(for: try replica.replicaState),
            bytes: try source.readCommitted(from: 0, to: try source.committedSize))

        let reader = try Database(
            opening: FileStorage(path: scratch.path("replica.db"), access: .readOnly, durability: .none))
        #expect(try reader.committedSize == sourceStorage.length)
    }
}
