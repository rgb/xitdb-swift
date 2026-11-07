import CryptoKit
import XitDB

func sha256(_ key: String) -> [UInt8] {
    Array(SHA256.hash(data: Array(key.utf8)))
}

let storage = try BufferedFileStorage(path: "people.db", access: .create)
let database =
    try storage.length == 0
    ? Database(creating: storage, hashSize: 32, hashID: "sha2")
    : Database(opening: storage, hashSize: 32)

let history = try ArrayList<ReadWrite>(database.rootCursor)
