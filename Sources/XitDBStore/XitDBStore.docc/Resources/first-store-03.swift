import XitDBStore

let storage = try BufferedFileStorage(path: "people.db", access: .create)
let database =
    try storage.length == 0
    ? Database(creating: storage, hashSize: 32, hashID: "sha2")
    : Database(opening: storage, hashSize: 32)
let store = try Store(database, hashing: SHA256.self)
