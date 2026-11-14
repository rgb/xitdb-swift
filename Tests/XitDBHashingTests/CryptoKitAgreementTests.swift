#if canImport(CryptoKit)
    import CryptoKit
    import Foundation
    import Testing
    import XitDBHashing

    /// The portable implementations against CryptoKit, where it exists: the
    /// same digest for every length to 300 of the pattern, at the boundary
    /// lengths once more by name, and for three thousand seeded messages of
    /// up to 64 KB.
    @Suite("agreement with CryptoKit")
    struct CryptoKitAgreementTests {
        @Test("SHA-256 at every length to 300")
        func sha256Lengths() {
            for length in 0...300 {
                let message = pattern(count: length)
                #expect(PortableSHA256.hash(message).bytes == Array(CryptoKit.SHA256.hash(data: message)), "\(length)")
            }
        }

        @Test("SHA-1 at every length to 300")
        func sha1Lengths() {
            for length in 0...300 {
                let message = pattern(count: length)
                #expect(
                    PortableSHA1.hash(message).bytes == Array(CryptoKit.Insecure.SHA1.hash(data: message)), "\(length)")
            }
        }

        @Test("the seeded messages, to 64 KB")
        func seeded() {
            for (length, seed) in seededMessages {
                let message = seededMessage(count: length, seed: seed)
                #expect(
                    appendedSHA256(message) == Array(CryptoKit.SHA256.hash(data: message)), "\(length), seed \(seed)")
                #expect(
                    appendedSHA1(message) == Array(CryptoKit.Insecure.SHA1.hash(data: message)),
                    "\(length), seed \(seed)")
            }
        }

        @Test("the boundary lengths", arguments: boundaryLengths)
        func boundaries(length: Int) {
            let message = pattern(count: length)
            #expect(PortableSHA256.hash(message).bytes == Array(CryptoKit.SHA256.hash(data: message)))
            #expect(PortableSHA1.hash(message).bytes == Array(CryptoKit.Insecure.SHA1.hash(data: message)))
        }
    }
#endif
