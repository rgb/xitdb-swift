import Testing
import XitDB
import XitDBHashing

/// The module's SHA-256 and SHA-1 against the published vectors, on every
/// platform, through each way in: the portable code's entry, the
/// requirement a database calls, and `keyHash(of:)`, which a caller uses by
/// hand. On Apple silicon the last two are the processor's instructions.
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
        let message = Array(vector.message.utf8)
        #expect(hex(appendedSHA256(message)) == vector.digest)
        #expect(required(SHA256.self, message) == bytes(fromHex: vector.digest))
        #expect(SHA256.keyHash(of: vector.message) == bytes(fromHex: vector.digest))
    }

    @Test("one million a")
    func oneMillionA() {
        let message = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        #expect(hex(appendedSHA256(message)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        #expect(SHA256.keyHash(of: message) == appendedSHA256(message))
    }

    /// The requirement and `keyHash(of:)` against the portable code: the
    /// same bytes at every length to 300, which is past four blocks.
    @Test("every way in, at every length to 300")
    func everyWayIn() {
        for length in 0...300 {
            let message = pattern(count: length)
            let own = appendedSHA256(message)
            #expect(required(SHA256.self, message) == own, "\(length)")
            #expect(SHA256.keyHash(of: message) == own, "\(length)")
        }
    }

    /// A key is hashed as its bytes, whatever form it comes in.
    @Test("a key in any form is its bytes")
    func anyKey() {
        let text = "the quick brown fox"
        let fromText = SHA256.keyHash(of: text)
        #expect(SHA256.keyHash(of: Array(text.utf8)) == fromText)
        #expect(SHA256.keyHash(of: "a " + text).count == fromText.count)
        #expect(SHA256.keyHash(of: ("a " + text).dropFirst(2)) == fromText)
        #expect(SHA256.keyHash(of: Bytes(Array(text.utf8), formatTag: "tg")) == fromText)
        #expect(SHA256.keyHash(of: "the quick brown fix") != fromText)
        #expect(fromText.count == SHA256.size)
    }
}

@Suite("SHA-1")
struct SHA1Tests {
    static let vectors: [(message: String, digest: String)] = [
        ("", "da39a3ee5e6b4b0d3255bfef95601890afd80709"),
        ("abc", "a9993e364706816aba3e25717850c26c9cd0d89d"),
        ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "84983e441c3bd26ebaae4aa1f95129e5e54670f1"),
    ]

    @Test("published vectors", arguments: vectors)
    func publishedVectors(vector: (message: String, digest: String)) {
        let message = Array(vector.message.utf8)
        #expect(hex(appendedSHA1(message)) == vector.digest)
        #expect(required(Insecure.SHA1.self, message) == bytes(fromHex: vector.digest))
        #expect(Insecure.SHA1.keyHash(of: vector.message) == bytes(fromHex: vector.digest))
    }

    @Test("one million a")
    func oneMillionA() {
        let message = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        #expect(hex(appendedSHA1(message)) == "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
        #expect(Insecure.SHA1.keyHash(of: message) == appendedSHA1(message))
    }

    /// As for SHA-256.
    @Test("every way in, at every length to 300")
    func everyWayIn() {
        for length in 0...300 {
            let message = pattern(count: length)
            let own = appendedSHA1(message)
            #expect(required(Insecure.SHA1.self, message) == own, "\(length)")
            #expect(Insecure.SHA1.keyHash(of: message) == own, "\(length)")
        }
    }
}
