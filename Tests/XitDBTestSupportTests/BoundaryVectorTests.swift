import Testing
import XitDBTestSupport

/// The pattern's digests at the lengths where the padding changes shape,
/// computed once by Python's hashlib, so that the boundaries are checked on
/// every platform and not only where CryptoKit is there to agree with.
@Suite("boundary vectors")
struct BoundaryVectorTests {
    /// `(length, SHA-256, SHA-1)` of `pattern(count: length)`.
    static let vectors: [(length: Int, sha256: String, sha1: String)] = [
        (
            55, "015ff676759159aa43c1991700de32ae6b24759fdc826c853c4f4e3a132ae4a0",
            "96ebb12e794fed143881d0f2d9d824e18db36850"
        ),
        (
            56, "103752a44a57f81d6ccdc73514e40302c322c15aa6beb8630c2d19464d70c155",
            "ff4d3963ffaa1b3aa2f1b381ef93cbff0c39e2a1"
        ),
        (
            63, "d19c848a46432659b0ab332f990c571f99d8016a3606c67f58cd4872f9a20e60",
            "ab331e69321604f3b2d963c101f38b1db2e2a95b"
        ),
        (
            64, "a6600154721e29ea3bbc24d7ed863b4c5c2665d13866fda5cf1fbc2beee0e0d1",
            "223df54a0d7772faa006200bfe562105d13273e0"
        ),
        (
            65, "5480bc4d9fd90d499e02015367d4a892ccf006b62f96d25756448d6431307cec",
            "6a76e76c2bb50aa1967ab5db861f4b1b31513bc0"
        ),
        (
            119, "2cc676f10623bb2b41a9acdb0286a44353c1e8b5b582e441b9e9b363896aae9d",
            "7ef6cc3b40acae81d65889211a0eef5439786df3"
        ),
        (
            120, "b6a12ab83aa1401c53feea97ecab9f5d57c7f6a9acddb2d2677a789109eaf872",
            "e0ca83b1d70b5170bcf2a25cf23c5de3da2ee820"
        ),
    ]

    @Test("SHA-256 at the boundaries", arguments: vectors)
    func sha256(vector: (length: Int, sha256: String, sha1: String)) {
        #expect(SHA256.hash(data: pattern(count: vector.length)).description == vector.sha256)
    }

    @Test("SHA-1 at the boundaries", arguments: vectors)
    func sha1(vector: (length: Int, sha256: String, sha1: String)) {
        #expect(Insecure.SHA1.hash(data: pattern(count: vector.length)).description == vector.sha1)
    }
}
