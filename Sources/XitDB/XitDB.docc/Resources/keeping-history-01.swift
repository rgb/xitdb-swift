import CryptoKit
import XitDB

func sha256(_ key: String) -> [UInt8] {
    Array(SHA256.hash(data: Array(key.utf8)))
}

let database = try Database(creating: MemoryStorage(), hashSize: 32, hashID: "sha2")
let history = try ArrayList<ReadWrite>(database.rootCursor)
