import XitDBStore

let storage = try BufferedFileStorage(path: "people.db", access: .create)
let database =
    try storage.length == 0
    ? Database(creating: storage, hashSize: 32, hashID: "sha2")
    : Database(opening: storage, hashSize: 32)
let store = try Store(database, hashing: SHA256.self)

struct Person: Codable {
    var name: String
    var age: Int
}

try store.transaction { moment in
    try moment["people"]["alice"].set(encoding: Person(name: "Alice", age: 25))
}
