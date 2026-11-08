import CryptoKit
import Foundation
import Testing
import XitDB

@Suite("Bring your own hashes") struct HashingExamples {
    @Test func aHashHasTheSizeOfTheDatabase() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let map = try HashMap<ReadWrite>(database.rootCursor)

        // The hash is the caller's. It only has to have the right size.
        try map.put(.uint(1), forHash: SHA256.hash(data: Array("alice".utf8)))

        #expect(throws: XitDBError.invalidHashSize) {
            // 20 bytes, in a database of 32.
            try map.put(.uint(1), forHash: Insecure.SHA1.hash(data: Array("alice".utf8)))
        }
    }

    @Test func aSharedHashIsASharedKey() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 1)
        let map = try HashMap<ReadWrite>(database.rootCursor)

        // A hash of one byte, the sum of the key's: "ab" and "ba" collide.
        func weakHash(_ key: String) -> [UInt8] {
            [key.utf8.reduce(0, &+)]
        }

        try map.put(.bytes(Array("first".utf8)), forHash: weakHash("ab"))
        try map.put(.bytes(Array("second".utf8)), forHash: weakHash("ba"))

        // One entry: the second put replaced the first without a word.
        let value = try map.cursor(forHash: weakHash("ab"))!.readBytes()
        #expect(value == Array("second".utf8))
    }

    @Test func detectingACollision() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 1)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        func weakHash(_ key: String) -> [UInt8] {
            [key.utf8.reduce(0, &+)]
        }

        try map.putKey(.bytes(Array("ab".utf8)), forHash: weakHash("ab"))

        // putKey writes once, so the stored key is the first one.
        try map.putKey(.bytes(Array("ba".utf8)), forHash: weakHash("ba"))
        let stored = try map.keyCursor(forHash: weakHash("ba"))!.readBytes()
        let collided = stored != Array("ba".utf8)
        #expect(collided)
    }

    @Test func aHashNeedNotBeCryptographic() throws {
        // Keys that are already unique, such as 64-bit IDs, can be their own
        // hash: the bytes in big-endian order.
        func hash(_ id: UInt64) -> [UInt8] {
            withUnsafeBytes(of: id.bigEndian) { Array($0) }
        }

        let database = try Database(creating: MemoryStorage(), hashSize: 8)
        let users = try HashMap<ReadWrite>(database.rootCursor)
        try users.put(.bytes(Array("Alice".utf8)), forHash: hash(1))
        try users.put(.bytes(Array("Bob".utf8)), forHash: hash(2))

        #expect(try users.cursor(forHash: hash(2))!.readBytes() == Array("Bob".utf8))
    }

    /// The trie goes by a hash's last bytes first, so a hash whose last bytes
    /// hardly vary makes a deep trie, and a change copies every block on the
    /// way down. The numbers the article quotes.
    @Test func theLastBytesOfAHashMatter() throws {
        func costOfOneChange(hash: (UInt64) -> [UInt8]) throws -> UInt64 {
            let database = try Database(creating: MemoryStorage(), hashSize: 8)
            let map = try HashMap<ReadWrite>(database.rootCursor)
            try database.withTransaction { cursor in
                let map = try HashMap<ReadWrite>(cursor)
                for id in 0..<1000 as Range<UInt64> {
                    try map.put(.uint(id), forHash: hash(id))
                }
            }
            let before = try database.committedSize
            try map.put(.uint(1), forHash: hash(1))
            return try database.committedSize - before
        }

        let bigEndian = try costOfOneChange { id in withUnsafeBytes(of: id.bigEndian) { Array($0) } }
        let littleEndian = try costOfOneChange { id in withUnsafeBytes(of: id.littleEndian) { Array($0) } }
        #expect(bigEndian == 492)
        #expect(littleEndian == 2364)
    }

    @Test func aKeyOfTheRightSizeIsItsOwnHash() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 5)
        let map = try HashMap<ReadWrite>(database.rootCursor)

        try map.put(.uint(1), forHash: "alice".utf8)

        #expect(try map.cursor(forHash: "alice".utf8)!.readUInt64() == 1)
        #expect(throws: XitDBError.invalidHashSize) {
            try map.put(.uint(2), forHash: "bob".utf8)
        }
    }

    @Test func aHashIsAnySequenceOfBytes() throws {
        // A digest as it is.
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put(.uint(1), forHash: SHA256.hash(data: Array("alice".utf8)))
        #expect(try map.cursor(forHash: Array(sha256("alice")))!.readUInt64() == 1)

        // An array, a slice, `Data`, and a string's `utf8` that has the right length.
        let small = try Database(creating: MemoryStorage(), hashSize: 5)
        let words = try HashMap<ReadWrite>(small.rootCursor)
        try words.put(.uint(1), forHash: "alice".utf8)
        let bytes = Array("alice".utf8)
        #expect(try words.cursor(forHash: bytes)!.readUInt64() == 1)
        #expect(try words.cursor(forHash: Array("xalice".utf8)[1...])!.readUInt64() == 1)
        #expect(try words.cursor(forHash: Data("alice".utf8))!.readUInt64() == 1)
        #expect(try words.cursor(forHash: bytes.span)!.readUInt64() == 1)
        #expect(throws: XitDBError.invalidHashSize) { try words.cursor(forHash: "bob".utf8) }
    }

    @Test func recordingTheAlgorithm() throws {
        let storage = MemoryStorage()

        let created = try Database(creating: storage, hashSize: 32, hashID: "sha2")
        #expect(created.header.hashID == "sha2")

        // Opened without a size, a database takes the one it records, and the
        // header says what the hash is.
        let database = try Database(opening: storage)
        let header = database.header
        #expect(header.hashSize == 32)
        #expect(header.hashID == "sha2")
        #expect(header.hashID.description == "sha2")

        enum HashAlgorithm { case sha1, sha256, sha512 }

        let algorithm: HashAlgorithm? =
            switch (header.hashID, header.hashSize) {
            case ("sha1", 20): .sha1
            case ("sha2", 32): .sha256
            case ("sha2", 64): .sha512
            default: nil
            }
        #expect(algorithm == .sha256)

        // Stating a size that is not the file's is refused.
        #expect(throws: XitDBError.invalidHashSize) {
            try Database(opening: storage, hashSize: 20)
        }

        // A hash ID computed at run time may turn out not to be four bytes.
        #expect(HashID(string: "sha2") == "sha2")
        #expect(HashID(string: "sha256") == nil)
    }

    @Test func aHashSizeHasLimits() throws {
        #expect(throws: XitDBError.invalidHashSize) {
            try Database(creating: MemoryStorage(), hashSize: 0)
        }
        #expect(throws: XitDBError.invalidHashSize) {
            try Database(creating: MemoryStorage(), hashSize: 70_000)
        }
    }

    @Test func spansAreTakenWithoutACopy() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        let hash = Array(sha256("alice"))

        try map.put(.uint(1), forHash: hash.span)
        #expect(try map.cursor(forHash: hash.span)!.readUInt64() == 1)
    }
}
