import Testing
import XitDB
import XitDBHashing

// The examples of "Hashing", in XitDBHashing's catalogue.

@Suite("Hashing") struct HashingModuleExamples {
    @Test func aDigestIsItsBytes() throws {
        let digest = SHA256.hash(data: Array("alice".utf8))
        let bytes = Array(digest)  // 32 of them
        #expect(bytes.count == 32)
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put(.uint(1), forHash: digest)
        #expect(try map.cursor(forHash: bytes)?.readUInt64() == 1)
    }
}
