// The ways the module can compute its two hashes, each reachable by itself.

/// One of the ways this module can compute its two hashes, apart from the
/// other.
///
/// A key's hash takes one way, chosen when the module is compiled
/// (`Hashes.swift`), so on Apple silicon the portable code is code no key
/// reaches. The tests hold every way a build has to the same vectors through
/// this type, and nothing else uses it.
package struct HashPath: Sendable, CustomStringConvertible {
    /// What the way is called where a test names it.
    package let description: String

    /// Appends the SHA-256 of a message to an output: 32 bytes.
    package let sha256: @Sendable (Span<UInt8>, inout OutputSpan<UInt8>) -> Void

    /// Appends the SHA-1 of a message to an output: 20 bytes.
    package let sha1: @Sendable (Span<UInt8>, inout OutputSpan<UInt8>) -> Void

    /// The portable code, which every build has.
    package static let portable = HashPath(
        description: "the portable code",
        sha256: { message, output in PortableSHA256.hash(message, into: &output) },
        sha1: { message, output in PortableSHA1.hash(message, into: &output) })

    /// Every way this build has, the portable code first.
    ///
    /// ``instructions`` is declared with the code it names, in
    /// `InstructionHashes.swift`, so that the condition it is compiled
    /// under is written there.
    package static let all: [HashPath] = [portable] + [instructions].compactMap { $0 }
}
