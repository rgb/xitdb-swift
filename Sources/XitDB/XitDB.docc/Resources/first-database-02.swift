import CryptoKit
import XitDB

func sha256(_ key: String) -> SHA256Digest {
    SHA256.hash(data: Array(key.utf8))
}

let storage = try BufferedFileStorage(path: "people.db", access: .create)
