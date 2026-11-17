import Testing
import XitDB
import XitDBHashing

// The examples of XitDBHashing's landing page.

@Suite("The hashing module") struct HashingModuleExamples {
    @Test func aDatabaseIsGivenAHasher() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self, hashID: "sha2")
        #expect(database.header.hashSize == 32)
        #expect(database.header.hashID == "sha2")
        #expect(Insecure.SHA1.size == 20)
        #expect(Insecure.SHA1.keyHash(of: "foo").count == 20)
    }

    @Test func theHashersUnderTheirSecondNames() throws {
        let hasher = SHA256KeyHashing.self
        let database = try Database(creating: MemoryStorage(), hashing: hasher)
        let old = try Database(creating: MemoryStorage(), hashing: SHA1KeyHashing.self, hashID: "sha1")
        #expect(database.header.hashSize == 32)
        #expect(old.header.hashSize == 20)
        #expect(old.header.hashID == "sha1")
        // The same types: a key hashed under either name is one hash.
        #expect(SHA256KeyHashing.keyHash(of: "alice") == SHA256.keyHash(of: "alice"))
        #expect(SHA1KeyHashing.keyHash(of: "alice") == Insecure.SHA1.keyHash(of: "alice"))
    }

    @Test func aHashByHand() throws {
        let hash = SHA256.keyHash(of: "alice")  // 32 bytes
        #expect(hash.count == 32)
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put(.uint(1), forHash: hash)
        #expect(try map.value(forKey: "alice", as: UInt64.self) == 1)
    }
}
