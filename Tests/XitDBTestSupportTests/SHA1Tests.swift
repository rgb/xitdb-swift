import Testing
import XitDBTestSupport

@Suite("SHA-1")
struct SHA1Tests {
    /// The vectors of FIPS 180-4's examples and of the NIST test suite, as
    /// `(message, digest)`.
    static let vectors: [(message: String, digest: String)] = [
        ("", "da39a3ee5e6b4b0d3255bfef95601890afd80709"),
        ("abc", "a9993e364706816aba3e25717850c26c9cd0d89d"),
        ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "84983e441c3bd26ebaae4aa1f95129e5e54670f1"),
    ]

    @Test("published vectors", arguments: vectors)
    func publishedVectors(vector: (message: String, digest: String)) {
        let digest = Insecure.SHA1.hash(data: vector.message.utf8)
        #expect(digest.description == vector.digest)
        #expect(digest.bytes == bytes(fromHex: vector.digest))
    }

    @Test("one million a")
    func oneMillionA() {
        let digest = Insecure.SHA1.hash(data: [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000))
        let expected = "34aa973cd4c4daa4f61eeb2bdbad27316534016f"
        #expect(digest.description == expected)
        #expect(digest.bytes == bytes(fromHex: expected))
    }

    @Test("the digest is a sequence of its bytes")
    func sequence() {
        let digest = Insecure.SHA1.hash(data: "abc".utf8)
        #expect(Insecure.SHA1.byteCount == 20)
        #expect(Array(digest).count == Insecure.SHA1.byteCount)
        #expect(Array(digest) == digest.bytes)
        #expect(digest.bytes.count == Insecure.SHA1.byteCount)
        #expect(digest.description.count == 2 * Insecure.SHA1.byteCount)
    }

    @Test("equal digests are equal and hash alike, different inputs differ")
    func equatableAndHashable() {
        let first = Insecure.SHA1.hash(data: "abc".utf8)
        let again = Insecure.SHA1.hash(data: Array("abc".utf8))
        let other = Insecure.SHA1.hash(data: "abd".utf8)
        #expect(first == again)
        #expect(first.hashValue == again.hashValue)
        #expect(first != other)
        #expect(first.bytes != other.bytes)
        #expect(Set([first, again, other]).count == 2)
    }

    @Test("the same bytes hash the same whatever sequence carries them")
    func anySequence() {
        let message = pattern(count: 100)
        let fromArray = Insecure.SHA1.hash(data: message)
        let fromSlice = Insecure.SHA1.hash(data: message[...])
        let fromLazy = Insecure.SHA1.hash(data: message.lazy.map { $0 })
        #expect(fromArray == fromSlice)
        #expect(fromArray == fromLazy)
    }
}
