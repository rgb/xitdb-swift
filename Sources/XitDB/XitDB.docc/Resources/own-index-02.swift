import CryptoKit
import XitDB

func sha256(_ key: String) -> SHA256Digest {
    SHA256.hash(data: Array(key.utf8))
}

struct Book {
    let id: String
    let title: String
    let year: UInt64
}

let books = [
    Book(id: "b1", title: "Moby-Dick", year: 1851),
    Book(id: "b2", title: "Emma", year: 1815),
    Book(id: "b3", title: "Middlemarch", year: 1871),
    Book(id: "b4", title: "Dracula", year: 1897),
    Book(id: "b5", title: "Persuasion", year: 1817),
]

let database = try Database(creating: MemoryStorage(), hashSize: 32, hashID: "sha2")
let history = try ArrayList<ReadWrite>(database.rootCursor)
