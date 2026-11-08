import CryptoKit
import XitDB

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
