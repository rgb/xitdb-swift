import Testing
import XitDB
import XitDBHashing

/// The two public hashers as a database takes them: their sizes, the hash
/// of a key by hand, and that a keyed call writes what the call by that
/// hash writes.
@Suite("key hashing")
struct KeyHashingTests {
    static let key = Array("alice".utf8)

    @Test func sha256IsThirtyTwoBytes() {
        #expect(SHA256.size == 32)
        let hash = SHA256.keyHash(of: Self.key)
        #expect(hash.count == 32)
        #expect(hash == SHA256.keyHash(of: "alice"), "text is its UTF-8")
        #expect(SHA256.keyHash(of: Array(Self.key[1...])) == SHA256.keyHash(of: "lice"))
        #expect(hash == required(SHA256.self, Self.key), "the requirement gives the same bytes")
        #expect(hex(hash) == "2bd806c97f0e00af1a1fc3328fa763a9269723c8db8fac4f93af71db186d6e90")
    }

    @Test func sha1IsTwentyBytes() {
        #expect(Insecure.SHA1.size == 20)
        let hash = Insecure.SHA1.keyHash(of: Self.key)
        #expect(hash.count == 20)
        #expect(hash == Insecure.SHA1.keyHash(of: "alice"))
        #expect(hash == required(Insecure.SHA1.self, Self.key))
        #expect(hex(hash) == "522b276a356bdf39013dfabea2cd43e141ecc9e8")
    }

    /// Each hasher has a second name, for a file that also imports
    /// CryptoKit, whose types have the first: the same type under it, not
    /// another, so the same size and the same hash of a key.
    @Test func theSecondNamesAreTheSameTypes() {
        #expect(SHA256KeyHashing.self == SHA256.self)
        #expect(SHA1KeyHashing.self == Insecure.SHA1.self)
        #expect(SHA256KeyHashing.size == 32)
        #expect(SHA1KeyHashing.size == 20)
        #expect(SHA256KeyHashing.keyHash(of: Self.key) == SHA256.keyHash(of: Self.key))
        #expect(SHA1KeyHashing.keyHash(of: Self.key) == Insecure.SHA1.keyHash(of: Self.key))
        #expect(hex(SHA1KeyHashing.keyHash(of: "alice")) == "522b276a356bdf39013dfabea2cd43e141ecc9e8")
        let chosen: [any KeyHashing.Type] = [SHA256KeyHashing.self, SHA1KeyHashing.self]
        #expect(chosen.map { $0.size } == [32, 20])
    }

    /// A hasher chosen at run time is called as the type is: its size and
    /// `keyHash(of:)` through `any KeyHashing.Type`.
    @Test func aHasherChosenAtRunTime() {
        for (hashing, size) in [(SHA256.self, 32), (Insecure.SHA1.self, 20)] as [(any KeyHashing.Type, Int)] {
            #expect(hashing.size == size)
            #expect(hashing.keyHash(of: "alice").count == size)
        }
        let chosen: any KeyHashing.Type = SHA256.self
        #expect(chosen.keyHash(of: "alice") == SHA256.keyHash(of: "alice"))
    }

    /// The hash by hand names the entry the keyed call wrote, on a
    /// database given the hasher and on one opened with the size alone.
    @Test func theHashByHandNamesTheKeyedEntry() throws {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashing: SHA256.self)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put(.uint(7), forKey: "alice")
        let hash = SHA256.keyHash(of: "alice")
        #expect(try map.cursor(forHash: hash)?.readUInt64() == 7)
        #expect(try map.cursor(forHash: hash.span)?.readUInt64() == 7)
        #expect(try map.cursor(forHash: SHA256.keyHash(of: "bob")) == nil)

        let bySize = try Database(opening: MemoryStorage(bytes: storage.bytes), hashSize: SHA256.size)
        let reading = try HashMap<ReadOnly>(bySize.rootCursor)
        #expect(try reading.cursor(forHash: hash)?.readUInt64() == 7)
        #expect(throws: XitDBError.noKeyHashing) { try reading.cursor(forKey: "alice") }
    }
}
