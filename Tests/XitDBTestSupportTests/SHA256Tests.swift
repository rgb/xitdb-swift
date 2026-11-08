import Testing
import XitDBTestSupport

@Suite("SHA-256")
struct SHA256Tests {
    /// The vectors of FIPS 180-4's examples and of the NIST test suite, as
    /// `(message, digest)`.
    static let vectors: [(message: String, digest: String)] = [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (
            "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        ),
    ]

    @Test("published vectors", arguments: vectors)
    func publishedVectors(vector: (message: String, digest: String)) {
        let digest = SHA256.hash(data: vector.message.utf8)
        #expect(digest.description == vector.digest)
        #expect(digest.bytes == bytes(fromHex: vector.digest))
    }

    @Test("one million a")
    func oneMillionA() {
        let digest = SHA256.hash(data: [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000))
        let expected = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        #expect(digest.description == expected)
        #expect(digest.bytes == bytes(fromHex: expected))
    }

    @Test("the digest is a sequence of its bytes")
    func sequence() {
        let digest = SHA256.hash(data: "abc".utf8)
        #expect(SHA256.byteCount == 32)
        #expect(Array(digest).count == SHA256.byteCount)
        #expect(Array(digest) == digest.bytes)
        #expect(digest.bytes.count == SHA256.byteCount)
        #expect(digest.description.count == 2 * SHA256.byteCount)
    }

    @Test("equal digests are equal and hash alike, different inputs differ")
    func equatableAndHashable() {
        let first = SHA256.hash(data: "abc".utf8)
        let again = SHA256.hash(data: Array("abc".utf8))
        let other = SHA256.hash(data: "abd".utf8)
        #expect(first == again)
        #expect(first.hashValue == again.hashValue)
        #expect(first != other)
        #expect(first.bytes != other.bytes)
        #expect(Set([first, again, other]).count == 2)
    }

    @Test("the same bytes hash the same whatever sequence carries them")
    func anySequence() {
        let message = pattern(count: 100)
        let fromArray = SHA256.hash(data: message)
        let fromSlice = SHA256.hash(data: message[...])
        let fromLazy = SHA256.hash(data: message.lazy.map { $0 })
        #expect(fromArray == fromSlice)
        #expect(fromArray == fromLazy)
    }
}
