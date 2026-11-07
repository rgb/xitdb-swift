import CryptoKit
import XitDB

func sha256(_ key: String) -> [UInt8] {
    Array(SHA256.hash(data: Array(key.utf8)))
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

try history.append(.slot(try history.slot(at: -1))) { cursor in
    let moment = try HashMap<ReadWrite>(cursor)
    let byID = try HashMap<ReadWrite>(moment.putCursor(forHash: sha256("books")))
    let byTitle = try SortedMap<ReadWrite>(moment.putCursor(forHash: sha256("by title")))

    for book in books {
        let fields = try HashMap<ReadWrite>(byID.putCursor(forHash: sha256(book.id)))
        try fields.put(.bytes(Array(book.title.utf8)), forHash: sha256("title"))
        try fields.put(.uint(book.year), forHash: sha256("year"))

        try byTitle.put(.bytes(Array(book.id.utf8)), forKey: book.title.utf8)
    }
}

let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
let byID = try HashMap<ReadOnly>(moment.cursor(forHash: sha256("books"))!)
let byTitle = try SortedMap<ReadOnly>(moment.cursor(forHash: sha256("by title"))!)

func page(of index: SortedMap<ReadOnly>, offset: Int, size: Int) throws -> [String] {
    var ids: [String] = []
    var iterator = try index.iterator(fromIndex: offset)
    while ids.count < size, let cursor = try iterator.next() {
        ids.append(String(decoding: try cursor.readEntry().value.readBytes(), as: UTF8.self))
    }
    return ids
}

print(try page(of: byTitle, offset: 0, size: 2))  // ["b4", "b2"]: Dracula, Emma
print(try page(of: byTitle, offset: 2, size: 2))  // ["b3", "b1"]: Middlemarch, Moby-Dick

func title(ofBook id: String, in books: HashMap<ReadOnly>) throws -> String {
    let fields = try HashMap<ReadOnly>(books.cursor(forHash: sha256(id))!)
    return String(decoding: try fields.cursor(forHash: sha256("title"))!.readBytes(), as: UTF8.self)
}

print(try title(ofBook: "b4", in: byID))  // Dracula

let prefix = Array("M".utf8)
var matches = try byTitle.iterator(fromKey: prefix)
while let cursor = try matches.next() {
    let key = try cursor.readEntry().key.readBytes()
    guard key.starts(with: prefix) else { break }
    print(String(decoding: key, as: UTF8.self))  // Middlemarch, Moby-Dick
}

print(try byTitle.rank(of: "Emma".utf8))  // 1
print(try byTitle.count)  // 5

func yearKey(_ year: UInt64, id: String) -> [UInt8] {
    withUnsafeBytes(of: year.bigEndian) { Array($0) } + Array(id.utf8)
}

try history.append(.slot(try history.slot(at: -1))) { cursor in
    let moment = try HashMap<ReadWrite>(cursor)
    let byYear = try SortedMap<ReadWrite>(moment.putCursor(forHash: sha256("by year")))

    for book in books {
        try byYear.put(.bytes(Array(book.id.utf8)), forKey: yearKey(book.year, id: book.id))
    }
}
