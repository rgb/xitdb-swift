import CryptoKit
import Testing
import XitDB

@Suite("Tutorial: Keeping a replica in step") struct KeepingAReplicaInStepTutorial {
    @Test func theWholeProgram() throws {
        func sha256(_ key: String) -> [UInt8] {
            Array(SHA256.hash(data: Array(key.utf8)))
        }

        let sourceStorage = MemoryStorage()
        let source = try Database(creating: sourceStorage, hashSize: 32, hashID: "sha2")
        let history = try ArrayList<ReadWrite>(source.rootCursor)

        func commit(_ value: UInt64, to history: ArrayList<ReadWrite>) throws {
            try history.append(.slot(try history.slot(at: -1))) { cursor in
                try HashMap<ReadWrite>(cursor).put(.uint(value), forHash: sha256("value"))
            }
        }

        try commit(1, to: history)

        let replicaStorage = MemoryStorage()
        let replica = try Database(creating: replicaStorage, hashSize: 32)

        let state = try replica.replicaState
        print(state.committedSize)  // 62: a new database, with nothing in it

        let start = try source.replicationStart(for: state)
        print(start)  // 0: it is not a copy of this file, so it gets all of it

        let end = try source.committedSize
        let bytes = try source.readCommitted(from: start, to: end)

        try replica.applyReplicated(at: start, bytes: bytes)
        print(replica.header.fileID == source.header.fileID)  // true
        print(replicaStorage.bytes == sourceStorage.bytes)  // true

        func sync(from source: Database, to replica: Database) throws -> UInt64 {
            let state = try replica.replicaState
            let start = try source.replicationStart(for: state)
            let end = try source.committedSize
            let bytes = try source.readCommitted(from: start, to: end)
            try replica.applyReplicated(at: start, bytes: bytes)
            return end - start
        }

        try commit(2, to: history)
        let sent = try sync(from: source, to: replica)
        print(sent)  // 388 bytes, not the whole file
        print(replicaStorage.bytes == sourceStorage.bytes)  // true

        print(try sync(from: source, to: replica))  // 0: it is up to date

        let readerHistory = try ArrayList<ReadOnly>(replica.rootCursor)
        let moment = try HashMap<ReadOnly>(readerHistory.cursor(at: -1)!)
        print(try moment.cursor(forHash: sha256("value"))!.readUInt64())  // 2

        try commit(3, to: history)
        let lastCommit = try replica.committedSize
        let nextStart = try source.replicationStart(for: try replica.replicaState)
        let nextEnd = try source.committedSize
        let nextBytes = try source.readCommitted(from: nextStart, to: nextEnd)

        var halfOfThem = ArrayByteSource(Array(nextBytes[..<(nextBytes.count / 2)]))
        do {
            try replica.applyReplicated(at: nextStart, from: &halfOfThem, count: nextEnd - nextStart)
        } catch {
            print(error)  // endOfStream
        }
        print(try replica.committedSize == lastCommit)  // true: it stays at its last commit

        print(try sync(from: source, to: replica) > 0)  // true: the next sync discards the rest and goes on
        print(replicaStorage.bytes == sourceStorage.bytes)  // true

        var offsets = MemoryOffsetMap()
        let compactedStorage = MemoryStorage()
        let compacted = try source.compact(into: compactedStorage, offsetMap: &offsets)

        print(try compacted.replicationStart(for: try replica.replicaState))  // 0: a new file, so a full copy
        _ = try sync(from: compacted, to: replica)
        print(replicaStorage.bytes == compactedStorage.bytes)  // true

        #expect(start == 0)
        #expect(sent == 388)
        #expect(replica.header.fileID == compacted.header.fileID)
        #expect(replicaStorage.bytes == compactedStorage.bytes)
        #expect(try ArrayList<ReadOnly>(replica.rootCursor).count == 1)
    }
}
