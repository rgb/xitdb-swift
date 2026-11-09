import Testing
import XitDB
import XitDBHashing

/// The public hashes through the `KeyHashing` conformance, on every
/// platform: the size, the digest as a sequence of that many bytes, and
/// the same digest whichever spelling and whichever kind of collection the
/// key comes as.
@Suite("key hashing")
struct KeyHashingTests {
    static let key = Array("alice".utf8)

    @Test func sha256IsThirtyTwoBytes() {
        #expect(SHA256.size == 32)
        let digest = SHA256.hash(Self.key)
        #expect(Array(digest).count == 32)
        #expect(Array(digest) == Array(SHA256.hash(data: Self.key)))
        #expect(Array(SHA256.hash("alice".utf8)) == Array(digest), "a collection that is not an array")
        #expect(Array(SHA256.hash(Self.key[1...])) == Array(SHA256.hash(data: Array("lice".utf8))), "a slice")
        #expect(Array(digest) == PortableSHA256.hash(Self.key).bytes, "the portable implementation agrees")
    }

    @Test func sha1IsTwentyBytes() {
        #expect(Insecure.SHA1.size == 20)
        let digest = Insecure.SHA1.hash(Self.key)
        #expect(Array(digest).count == 20)
        #expect(Array(digest) == Array(Insecure.SHA1.hash(data: Self.key)))
        #expect(Array(Insecure.SHA1.hash("alice".utf8)) == Array(digest))
        #expect(Array(digest) == PortableSHA1.hash(Self.key).bytes)
    }

    /// A hash names an entry of a map whose hash size is the hash's size,
    /// whichever of the two spellings computed it.
    @Test func aDigestNamesAnEntry() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: SHA256.size)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put(.uint(7), forHash: SHA256.hash(Self.key))
        #expect(try map.cursor(forHash: SHA256.hash(data: Self.key))?.readUInt64() == 7)
        #expect(try map.cursor(forHash: SHA256.hash(Array("bob".utf8))) == nil)
    }

    /// The digests print as CryptoKit's do, whichever type stands behind
    /// them, so a reader sees the same line on every platform.
    @Test func digestsPrintAlike() {
        let digest = SHA256.hash(data: Self.key)
        #expect(String(describing: digest) == "SHA256 digest: " + PortableSHA256.hash(Self.key).hex)
        #expect(
            String(describing: Insecure.SHA1.hash(data: Self.key)) == "SHA1 digest: " + PortableSHA1.hash(Self.key).hex)
        #expect(digest == SHA256.hash(Self.key))
        #expect(Set([digest, SHA256.hash(Self.key), SHA256.hash(data: Array("bob".utf8))]).count == 2)
    }
}
