import Testing
import XitDB
import XitDBHashing

/// Where the system has a routine, the public hashers take the module's
/// own code up to a length and the system's routine above it. Both give
/// the same hash, so the switch cannot be seen: these tests hash the
/// lengths on both sides of each limit both ways, and through the public
/// hasher, and hold the three to one another.
@Suite("the switch to the system's routine")
struct SwitchTests {
    /// Lengths on both sides of a limit, and where blocks begin and end
    /// above it.
    static func lengths(around limit: Int) -> [Int] {
        let near = [limit - 65, limit - 64, limit - 1, limit, limit + 1, limit + 2, limit + 8, limit + 9]
        let blocks = [limit + 64, limit + 65, limit + 128, limit + 129, 2 * limit, 4 * limit + 3, 1_000, 4_096, 70_000]
        return (near + blocks).filter { $0 >= 0 }
    }

    /// The limits are where a message stops fitting a whole number of
    /// blocks with its padding, so that the last length the module's own
    /// code takes fills its last block.
    @Test func theLimitsAreTheLongestMessagesOfTheirBlocks() {
        #expect((SHA256.ownCodeLimit + 9) % 64 == 0)
        #expect((Insecure.SHA1.ownCodeLimit + 9) % 64 == 0)
        #expect(SHA256.ownCodeLimit >= 55)
        #expect(Insecure.SHA1.ownCodeLimit >= 55)
    }

    @Test func sha256OnBothSidesOfItsLimit() {
        for length in Self.lengths(around: SHA256.ownCodeLimit) {
            let message = seededMessage(count: length, seed: 7)
            let own = appendedSHA256(message)
            #expect(required(SHA256.self, message) == own, "\(length)")
            #expect(SHA256.keyHash(of: message) == own, "\(length)")
            #if canImport(CryptoKit)
                let system = [UInt8](capacity: 32) { output in SystemHashes.sha256(message.span, into: &output) }
                #expect(system == own, "\(length)")
            #endif
        }
    }

    @Test func sha1OnBothSidesOfItsLimit() {
        for length in Self.lengths(around: Insecure.SHA1.ownCodeLimit) {
            let message = seededMessage(count: length, seed: 8)
            let own = appendedSHA1(message)
            #expect(required(Insecure.SHA1.self, message) == own, "\(length)")
            #expect(Insecure.SHA1.keyHash(of: message) == own, "\(length)")
            #if canImport(CryptoKit)
                let system = [UInt8](capacity: 20) { output in SystemHashes.sha1(message.span, into: &output) }
                #expect(system == own, "\(length)")
            #endif
        }
    }

    #if canImport(CryptoKit)
        /// The system's routine by itself, on short input too, where the
        /// public hasher never takes it: every length to 300.
        @Test func theSystemsRoutineAtEveryLengthTo300() {
            for length in 0...300 {
                let message = pattern(count: length)
                let sha256 = [UInt8](capacity: 32) { output in SystemHashes.sha256(message.span, into: &output) }
                let sha1 = [UInt8](capacity: 20) { output in SystemHashes.sha1(message.span, into: &output) }
                #expect(sha256 == appendedSHA256(message), "\(length)")
                #expect(sha1 == appendedSHA1(message), "\(length)")
            }
        }
    #endif
}
