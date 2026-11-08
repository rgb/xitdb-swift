// Where CryptoKit exists, every length from 0 to 299 of the test pattern,
// and the lengths around the block boundaries by name, against it. On
// Linux this file compiles to nothing and the published vectors stand alone.

#if canImport(CryptoKit)
    import CryptoKit
    import Foundation
    import Testing
    import XitDBTestSupport

    @Suite("agreement with CryptoKit")
    struct CryptoKitAgreementTests {
        @Test("SHA-256 at every length under 300")
        func sha256EveryLength() {
            let message = pattern(count: 300)
            for length in 0..<300 {
                let ours = XitDBTestSupport.SHA256.hash(data: message[..<length])
                let theirs = CryptoKit.SHA256.hash(data: Data(message[..<length]))
                #expect(Array(ours) == Array(theirs), "length \(length)")
            }
        }

        @Test("SHA-1 at every length under 300")
        func sha1EveryLength() {
            let message = pattern(count: 300)
            for length in 0..<300 {
                let ours = XitDBTestSupport.Insecure.SHA1.hash(data: message[..<length])
                let theirs = CryptoKit.Insecure.SHA1.hash(data: Data(message[..<length]))
                #expect(Array(ours) == Array(theirs), "length \(length)")
            }
        }

        @Test("SHA-256 around the block boundaries", arguments: boundaryLengths)
        func sha256Boundary(length: Int) {
            let message = pattern(count: length)
            let ours = XitDBTestSupport.SHA256.hash(data: message)
            let theirs = CryptoKit.SHA256.hash(data: Data(message))
            #expect(Array(ours) == Array(theirs))
        }

        @Test("SHA-1 around the block boundaries", arguments: boundaryLengths)
        func sha1Boundary(length: Int) {
            let message = pattern(count: length)
            let ours = XitDBTestSupport.Insecure.SHA1.hash(data: message)
            let theirs = CryptoKit.Insecure.SHA1.hash(data: Data(message))
            #expect(Array(ours) == Array(theirs))
        }
    }
#endif
