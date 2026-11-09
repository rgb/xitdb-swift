import Testing
import XitDBStore

// The examples of "Hashing", in XitDBHashing's catalogue. The store
// re-exports XitDBHashing, so the hashes come with it.

@Suite("Hashing") struct HashingModuleExamples {
    @Test func aStoreTakesItsHashByItsType() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let store = try Store(database, hashing: SHA256.self)
        #expect(ObjectIdentifier(store.hashing) == ObjectIdentifier(SHA256.self))

        // A database of 32-byte hashes refuses a hash of 20 bytes.
        do {
            _ = try Store(database, hashing: Insecure.SHA1.self)
        } catch XitDBError.hashSizeMismatch {
            print("the database's hashes are of another size")
        }
        #expect(throws: XitDBError.hashSizeMismatch) { try Store(database, hashing: Insecure.SHA1.self) }
        #expect(throws: XitDBError.hashSizeMismatch) { try Moment(reading: database, hashing: SipHash128.self) }
    }

    @Test func sipHashNeedsADatabaseOfSixteenByteHashes() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 16)
        let store = try Store(database, hashing: SipHash128.self)
        try store.transaction { moment in try moment["key"].set(UInt64(1)) }
        #expect(try store.latest["key"].value(UInt64.self) == 1)
    }

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
