#if canImport(CryptoKit)
    import CryptoKit
    import Foundation
    import Testing
    import XitDBHashing

    /// Every way the build has of computing the hashes against CryptoKit,
    /// where it exists: the same digest for every length to 300 of the
    /// pattern, at the boundary lengths once more by name, and for three
    /// thousand seeded messages of up to 64 KB.
    @Suite("agreement with CryptoKit")
    struct CryptoKitAgreementTests {
        @Test("SHA-256 at every length to 300", arguments: HashPath.all)
        func sha256Lengths(path: HashPath) {
            for length in 0...300 {
                let message = pattern(count: length)
                #expect(sha256(message, by: path) == Array(CryptoKit.SHA256.hash(data: message)), "\(length)")
            }
        }

        @Test("SHA-1 at every length to 300", arguments: HashPath.all)
        func sha1Lengths(path: HashPath) {
            for length in 0...300 {
                let message = pattern(count: length)
                #expect(sha1(message, by: path) == Array(CryptoKit.Insecure.SHA1.hash(data: message)), "\(length)")
            }
        }

        @Test("the seeded messages, to 64 KB", arguments: HashPath.all)
        func seeded(path: HashPath) {
            for (length, seed) in seededMessages {
                let message = seededMessage(count: length, seed: seed)
                #expect(
                    sha256(message, by: path) == Array(CryptoKit.SHA256.hash(data: message)),
                    "\(length), seed \(seed)")
                #expect(
                    sha1(message, by: path) == Array(CryptoKit.Insecure.SHA1.hash(data: message)),
                    "\(length), seed \(seed)")
            }
        }

        @Test("the boundary lengths", arguments: boundaryLengths)
        func boundaries(length: Int) {
            let message = pattern(count: length)
            for path in HashPath.all {
                #expect(sha256(message, by: path) == Array(CryptoKit.SHA256.hash(data: message)), "\(path)")
                #expect(sha1(message, by: path) == Array(CryptoKit.Insecure.SHA1.hash(data: message)), "\(path)")
            }
        }
    }
#endif
