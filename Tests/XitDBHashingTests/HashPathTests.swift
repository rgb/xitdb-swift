import Testing
import XitDB
import XitDBHashing

/// The module has two ways of computing its hashes: the processor's SHA
/// instructions, which a key's hash takes on Apple silicon, and the
/// portable code, which it takes everywhere else. Both give the same bytes,
/// so no test of the public hashers can tell which was taken, and on Apple
/// silicon the portable code is code no key reaches. These tests take each
/// way a build has by its own entry and hold it to what the public hashers
/// are held to: the published vectors, the boundary vectors and the table
/// of digests.
@Suite("every way of computing the hashes")
struct HashPathTests {
    /// Which ways a build has follows from its machine: the portable code
    /// always, the processor's instructions on Apple silicon and nowhere
    /// else.
    ///
    /// The instructions are compiled only where the compiler has its module
    /// of them, so that a toolchain without it still builds the package. No
    /// digest could show that this had happened: every key would hash by
    /// the portable code, right and slower. Here it fails.
    @Test func aBuildHasTheWaysItsMachineCanTake() {
        #expect(HashPath.all.first?.description == HashPath.portable.description)
        #if arch(arm64) && canImport(Darwin)
            #expect(
                HashPath.instructions != nil,
                """
                On Apple silicon the hashes are meant to be computed with the processor's SHA instructions, \
                and this build has no such code: the compiler's module _Builtin_intrinsics.arm.neon could not \
                be imported, so InstructionHashes.swift compiled to nothing. What changed is the toolchain, \
                which no longer has the module. A user's build with it still works and gives the same hashes, \
                by the portable code, which takes two to four times as long for a short key.
                """)
            #expect(HashPath.all.count == 2)
        #else
            #expect(HashPath.instructions == nil)
            #expect(HashPath.all.count == 1)
        #endif
    }

    @Test("the published vectors", arguments: HashPath.all)
    func publishedVectors(path: HashPath) {
        for vector in SHA256Tests.vectors {
            #expect(hex(sha256(Array(vector.message.utf8), by: path)) == vector.digest, "\(vector.message)")
        }
        for vector in SHA1Tests.vectors {
            #expect(hex(sha1(Array(vector.message.utf8), by: path)) == vector.digest, "\(vector.message)")
        }
    }

    /// 15,625 blocks and no tail but the padding: the loop over a message's
    /// blocks, which the code of the instructions is inlined into.
    @Test("one million a", arguments: HashPath.all)
    func oneMillionA(path: HashPath) {
        let message = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        #expect(
            hex(sha256(message, by: path)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        #expect(hex(sha1(message, by: path)) == "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
    }

    @Test("the boundary vectors", arguments: HashPath.all)
    func boundaries(path: HashPath) {
        for vector in BoundaryVectorTests.vectors {
            let message = pattern(count: vector.length)
            #expect(hex(sha256(message, by: path)) == vector.sha256, "\(vector.length)")
            #expect(hex(sha1(message, by: path)) == vector.sha1, "\(vector.length)")
        }
    }

    /// The 3,301 lines of the table: the pattern at every length to 300 and
    /// the seeded messages, up to 64 KB.
    @Test("the table of digests", arguments: HashPath.all)
    func table(path: HashPath) throws {
        for line in try PinnedDigestTests.table() {
            let message = line.message
            #expect(sha256(message, by: path) == line.sha256, "\(line.length), seed \(String(describing: line.seed))")
            #expect(sha1(message, by: path) == line.sha1, "\(line.length), seed \(String(describing: line.seed))")
        }
    }
}
