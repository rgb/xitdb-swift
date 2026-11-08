import CryptoKit
import XitDB

func sha256(_ key: String) -> SHA256Digest {
    SHA256.hash(data: Array(key.utf8))
}

let storage = try BufferedFileStorage(path: "people.db", access: .create)
let database =
    try storage.length == 0
    ? Database(creating: storage, hashSize: 32, hashID: "sha2")
    : Database(opening: storage, hashSize: 32)

let history = try ArrayList<ReadWrite>(database.rootCursor)

try history.append(.slot(try history.slot(at: -1))) { cursor in
    let moment = try HashMap<ReadWrite>(cursor)
    try moment.put(.bytes(Array("Alice".utf8)), forHash: sha256("name"))
    try moment.put(.uint(25), forHash: sha256("age"))
}

let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
let name = try moment.cursor(forHash: sha256("name"))!.readBytes()
let age = try moment.cursor(forHash: sha256("age"))!.readUInt64()
print(String(decoding: name, as: UTF8.self), age)  // Alice 25
