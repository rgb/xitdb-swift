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
