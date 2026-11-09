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

let alice = try store.latest["people"]["alice"].value(decoding: Person.self)!
print(alice.name, alice.age)  // Alice 25

try store.transaction { moment in
    try moment["people"]["alice"]["age"].set(Int64(26))
}

let earlier = try store.moment(at: -2)
let then = try earlier["people"]["alice"].value(decoding: Person.self)!
print(then.age)  // 25
