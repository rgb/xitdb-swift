import CryptoKit
import XitDB

func sha256(_ key: String) -> [UInt8] {
    Array(SHA256.hash(data: Array(key.utf8)))
}

let database = try Database(creating: MemoryStorage(), hashSize: 32, hashID: "sha2")
let history = try ArrayList<ReadWrite>(database.rootCursor)

try history.append(.slot(try history.slot(at: -1))) { cursor in
    let prices = try HashMap<ReadWrite>(cursor)
    try prices.put(.uint(120), forHash: sha256("apples"))
    try prices.put(.uint(300), forHash: sha256("pears"))
}

try history.append(.slot(try history.slot(at: -1))) { cursor in
    let prices = try HashMap<ReadWrite>(cursor)
    try prices.put(.uint(150), forHash: sha256("apples"))
}

try history.append(.slot(try history.slot(at: -1))) { cursor in
    let prices = try HashMap<ReadWrite>(cursor)
    try prices.remove(forHash: sha256("pears"))
}

let latest = try HashMap<ReadOnly>(history.cursor(at: -1)!)
print(try latest.cursor(forHash: sha256("apples"))!.readUInt64())  // 150
print(try latest.cursor(forHash: sha256("pears")) == nil)  // true

let first = try HashMap<ReadOnly>(history.cursor(at: 0)!)
print(try first.cursor(forHash: sha256("apples"))!.readUInt64())  // 120
print(try first.cursor(forHash: sha256("pears"))!.readUInt64())  // 300
