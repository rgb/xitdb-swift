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

    @Test func aDigestIsItsBytes() throws {
        let digest = SHA256.keyHash(of: "alice")
        let bytes = Array(digest)  // 32 of them
        #expect(bytes.count == 32)
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put(.uint(1), forHash: digest)
        #expect(try map.value(forKey: "alice", as: UInt64.self) == 1)
        #expect(try map.cursor(forHash: bytes)?.readUInt64() == 1)
    }
}
