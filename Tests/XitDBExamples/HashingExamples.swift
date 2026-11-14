import Foundation
import Testing
import XitDB
import XitDBHashing

// A hasher of 20 bytes that is not SHA-1, for the test that only the size is
// checked.
private enum TwentyZeros: KeyHashing {
    static let size = 20
    static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
        output.append(repeating: 0, count: 20)
    }
}

@Suite("Hashing") struct HashingExamples {
    @Test func aDatabaseIsGivenItsHasher() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self, hashID: "sha2")
        let users = try HashMap<ReadWrite>(database.rootCursor)

        try users.put("Alice", forKey: "alice")
        let keyed = try database.readCommitted(from: 0, to: database.committedSize)

        // The same entry by its hash: the keyed put is this put.
        let hash = SHA256.keyHash(of: "alice")
        try users.put(.bytes(Array("Alice".utf8)), forHash: hash)
        #expect(try users.cursor(forHash: hash)!.read(String.self) == "Alice")
        #expect(try users.value(forKey: "alice", as: String.self) == "Alice")
        #expect(try users.keyCursor(forKey: "alice") == nil)

        // Two databases written side by side, one by key and one by hash,
        // with the same file ID and the same commit IDs, are the same file.
        let byKey = MemoryStorage()
        let byHash = MemoryStorage()
        let keyedDatabase = try Database(
            creating: byKey, hashSize: 32, hashID: "sha2", fileID: 7, random: RandomSource(Counting()),
            hasher: KeyHasher(SHA256.self))
        let hashedDatabase = try Database(
            creating: byHash, hashSize: 32, hashID: "sha2", fileID: 7, random: RandomSource(Counting()))
        try HashMap<ReadWrite>(keyedDatabase.rootCursor).put("Alice", forKey: "alice")
        try HashMap<ReadWrite>(hashedDatabase.rootCursor)
            .put(.bytes(Array("Alice".utf8)), forHash: SHA256.keyHash(of: "alice"))
        #expect(byKey.bytes == byHash.bytes)
        #expect(byKey.bytes.count == keyed.count)
    }

    /// Commit IDs 1, 2, 3, … so that two databases draw the same ones.
    private struct Counting: RandomNumberGenerator {
        var last: UInt64 = 0
        mutating func next() -> UInt64 {
            last += 1
            return last
        }
    }

    @Test func aKeyIsItsBytes() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let person = try HashMap<ReadWrite>(database.rootCursor)

        enum Field: String, KeyRepresentable {
            case name, age
        }
        try person.put(UInt64(25), forKey: Field.age)

        // The enum's case is its raw value's key, and a String's key is its
        // UTF-8, so all of these name one entry.
        #expect(try person.value(forKey: "age", as: UInt64.self) == 25)
        #expect(try person.value(forKey: Array("age".utf8), as: UInt64.self) == 25)
        #expect(try person.value(forKey: Bytes(Array("age".utf8), formatTag: "xx"), as: UInt64.self) == 25)
        #expect(try person.value(forKey: "age"[...], as: UInt64.self) == 25)
        #expect(try person.cursor(forHash: sha256("age"))!.readUInt64() == 25)
        // Nothing is normalised: the decomposed form of a name is another key.
        try person.put("composed", forKey: "\u{E9}")
        #expect(try person.value(forKey: "e\u{301}", as: String.self) == nil)
    }

    @Test func aHashSizeHasLimits() throws {
        #expect(throws: XitDBError.invalidHashSize) {
            try Database(creating: MemoryStorage(), hashSize: 0)
        }
        #expect(throws: XitDBError.invalidHashSize) {
            try Database(creating: MemoryStorage(), hashSize: 70_000)
        }
        _ = try Database(creating: MemoryStorage(), hashSize: 1)
        _ = try Database(creating: MemoryStorage(), hashSize: 65_535)
    }

    @Test func onlyTheSizeIsChecked() throws {
        let storage = MemoryStorage()
        let created = try Database(creating: storage, hashing: Insecure.SHA1.self)
        try HashMap<ReadWrite>(created.rootCursor).put("Alice", forKey: "alice")

        // The hasher gives no hash ID: without one the header holds zeros.
        #expect(created.header.hashSize == 20)
        #expect(created.header.hashID.rawValue == 0)

        // Another size is refused, before anything else is read.
        #expect(throws: XitDBError.invalidHashSize) {
            try Database(opening: storage, hashing: SHA256.self)
        }
        #expect(throws: XitDBError.invalidHashSize) {
            try Database.recover(storage, hashing: SHA256.self)
        }

        // Another hasher of the same size opens the file, and its lookups
        // miss.
        let mistaken = try Database(opening: storage, hashing: TwentyZeros.self)
        #expect(try HashMap<ReadOnly>(mistaken.rootCursor).value(forKey: "alice", as: String.self) == nil)
    }

    @Test func aDatabaseWithoutAHasher() throws {
        let storage = MemoryStorage()
        let created = try Database(creating: storage, hashing: SHA256.self)
        try HashMap<ReadWrite>(created.rootCursor).put("Alice", forKey: "alice")
        let hash = SHA256.keyHash(of: "alice")

        let plain = try Database(opening: storage)
        let map = try HashMap<ReadOnly>(plain.rootCursor)
        let alice = try map.cursor(forHash: hash)
        #expect(try alice?.read(String.self) == "Alice")

        #expect(throws: XitDBError.noKeyHashing) { try map.cursor(forKey: "alice") }
        #expect(throws: XitDBError.noKeyHashing) { try map.value(forKey: "alice", as: String.self) }
        // Before anything else about the call is looked at: on an empty root
        // a lookup by hash finds nothing, and the keyed one is refused.
        let bySize = try Database(creating: MemoryStorage(), hashSize: 32)
        let empty = try HashMap<ReadOnly>(bySize.rootCursor)
        #expect(try empty.cursor(forHash: hash) == nil)
        #expect(throws: XitDBError.noKeyHashing) { try empty.cursor(forKey: "x") }
        let writable = try HashMap<ReadWrite>(bySize.rootCursor)
        let sizeBefore = try bySize.committedSize
        #expect(throws: XitDBError.noKeyHashing) { try writable.put("x", forKey: "x") }
        #expect(try bySize.committedSize == sizeBefore)

        // A snapshot carries its database's hasher, and a compaction's target
        // takes its source's.
        let snapshot = SnapshotDatabase(try created.snapshot())
        #expect(try HashMap<ReadOnly>(snapshot.rootCursor).value(forKey: "alice", as: String.self) == "Alice")
        let source = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let history = try ArrayList<ReadWrite>(source.rootCursor)
        try history.append(.slot(nil)) { cursor in
            try HashMap<ReadWrite>(cursor).put("Alice", forKey: "alice")
        }
        var offsets = MemoryOffsetMap()
        let target = try source.compact(into: MemoryStorage(), offsetMap: &offsets)
        let moment = try HashMap<ReadOnly>(ArrayList<ReadOnly>(target.rootCursor).cursor(at: -1)!)
        #expect(try moment.value(forKey: "alice", as: String.self) == "Alice")
    }

    @Test func choosingTheHasherByTheFile() throws {
        let storage = MemoryStorage()
        let created = try Database(creating: storage, hashing: Insecure.SHA1.self, hashID: "sha1")
        try HashMap<ReadWrite>(created.rootCursor).put("Alice", forKey: "alice")

        let header = try DatabaseHeader(reading: storage)
        let hashing: (any KeyHashing.Type)? =
            switch (header.hashID, header.hashSize) {
            case ("sha1", 20): Insecure.SHA1.self
            case ("sha2", 32): SHA256.self
            default: nil
            }
        #expect(hashing != nil)

        if let hashing {
            let database = try Database(opening: storage, hashing: hashing)
            #expect(try HashMap<ReadOnly>(database.rootCursor).value(forKey: "alice", as: String.self) == "Alice")
        }

        // The header reads without the root header: a creation that did not
        // finish has a header that reads, and does not open.
        let unfinished = MemoryStorage(bytes: Array(storage.bytes[..<32]))
        #expect(try DatabaseHeader(reading: unfinished).hashID == "sha1")
        #expect(throws: XitDBError.invalidDatabase) { try Database(opening: unfinished) }
        #expect(throws: XitDBError.invalidDatabase) { try DatabaseHeader(reading: MemoryStorage()) }

        // A hash ID computed at run time may turn out not to be four bytes.
        #expect(HashID(string: "sha2") == "sha2")
        #expect(HashID(string: "sha256") == nil)
    }

    @Test func aHashHasTheSizeOfTheDatabase() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put(.uint(1), forHash: SHA256.keyHash(of: "alice"))

        #expect(throws: XitDBError.invalidHashSize) {
            // 20 bytes, in a database of 32.
            try map.put(.uint(1), forHash: Insecure.SHA1.keyHash(of: "alice"))
        }
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

        let bob = try users.cursor(forHash: hash(2))?.read(String.self)
        #expect(bob == "Bob")
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

    @Test func aHashIsAnySequenceOfBytes() throws {
        // A digest as it is.
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put(.uint(1), forHash: SHA256.keyHash(of: "alice"))
        #expect(try map.cursor(forHash: Array(sha256("alice")))!.readUInt64() == 1)

        // An array, a slice, `Data`, a span, and a string's `utf8` that has
        // the right length.
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

    @Test func aSharedHashIsASharedKey() throws {
        // A hash of one byte, the sum of the key's: "ab" and "ba" collide.
        enum ByteSum: KeyHashing {
            static var size: Int { 1 }
            static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
                var sum: UInt8 = 0
                for index in bytes.indices { sum &+= bytes[index] }
                output.append(sum)
            }
        }

        let database = try Database(creating: MemoryStorage(), hashing: ByteSum.self)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put("first", forKey: "ab")
        try map.put("second", forKey: "ba")

        // One entry: the second put replaced the first without a word.
        let value = try map.value(forKey: "ab", as: String.self)
        #expect(value == "second")
        #expect(database.header.hashSize == 1)

        try map.putKey("ab")
        try map.putKey("ba")
        let collided = try map.keyCursor(forKey: "ba")?.read(String.self) != "ba"
        #expect(collided)
        #expect(try map.keyCursor(forKey: "ba")?.read(String.self) == "ab")
    }

    @Test func spansAreTakenWithoutACopy() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        let hash = Array(sha256("alice"))

        try map.put(.uint(1), forHash: hash.span)
        #expect(try map.cursor(forHash: hash.span)!.readUInt64() == 1)
    }
}
