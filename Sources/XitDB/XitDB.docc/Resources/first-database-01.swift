import CryptoKit
import XitDB

func sha256(_ key: String) -> [UInt8] {
    Array(SHA256.hash(data: Array(key.utf8)))
}
