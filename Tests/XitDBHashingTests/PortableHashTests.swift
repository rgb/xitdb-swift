import Testing
import XitDBHashing

/// The portable SHA-256 and SHA-1 against the published vectors, on every
/// platform: where CryptoKit exists they stand behind nothing public, but
/// they are what Linux computes, so they are checked here as well.
@Suite("portable SHA-256")
struct PortableSHA256Tests {
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
        let digest = PortableSHA256.hash(vector.message.utf8)
        #expect(digest.hex == vector.digest)
        #expect(digest.bytes == bytes(fromHex: vector.digest))
    }

    @Test("one million a")
    func oneMillionA() {
        let digest = PortableSHA256.hash([UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000))
        #expect(digest.hex == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test("the same bytes from an array, a slice and a lazy sequence")
    func anyInput() {
        let array = Array("the quick brown fox".utf8)
        let fromArray = PortableSHA256.hash(array)
        #expect(PortableSHA256.hash(array[...]) == fromArray)
        #expect(PortableSHA256.hash(array.lazy.map { $0 }) == fromArray)
        #expect(PortableSHA256.hash(Array("the quick brown fix".utf8)) != fromArray)
        #expect(fromArray.bytes.count == PortableSHA256.byteCount)
    }
}

@Suite("portable SHA-1")
struct PortableSHA1Tests {
    static let vectors: [(message: String, digest: String)] = [
        ("", "da39a3ee5e6b4b0d3255bfef95601890afd80709"),
        ("abc", "a9993e364706816aba3e25717850c26c9cd0d89d"),
        ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "84983e441c3bd26ebaae4aa1f95129e5e54670f1"),
    ]

    @Test("published vectors", arguments: vectors)
    func publishedVectors(vector: (message: String, digest: String)) {
        let digest = PortableSHA1.hash(vector.message.utf8)
        #expect(digest.hex == vector.digest)
        #expect(digest.bytes == bytes(fromHex: vector.digest))
    }

    @Test("one million a")
    func oneMillionA() {
        let digest = PortableSHA1.hash([UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000))
        #expect(digest.hex == "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
    }
}
