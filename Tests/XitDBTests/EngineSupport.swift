import CryptoKit
import Foundation
import Testing

@testable import XitDB

/// A random source that hands out given values in order, so that a test can
/// fix a database's commit IDs. It records being asked for more than it has.
final class FixedRandom: RandomNumberGenerator {
    private var values: [UInt64]
    private(set) var exhausted = false

    init(_ values: [UInt64] = []) {
        self.values = values.reversed()
    }

    /// The number of values not yet handed out.
    var remaining: Int { values.count }

    func next() -> UInt64 {
        guard let value = values.popLast() else {
            exhausted = true
            return 0
        }
        return value
    }
}

/// The SHA-1 of a string's UTF-8 bytes, as a key hash.
func sha1(_ text: String) -> KeyHash {
    KeyHash(Array(Insecure.SHA1.hash(data: Data(text.utf8))))
}

/// The bytes that a string of hex digits stands for.
func hex(_ digits: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = digits.startIndex
    while index < digits.endIndex {
        let next = digits.index(index, offsetBy: 2)
        bytes.append(UInt8(digits[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

/// The contents of a file in the copied conformance fixtures.
func fixtureFile(_ relativePath: String) throws -> [UInt8] {
    let folder = try #require(Bundle.module.url(forResource: "fixtures", withExtension: nil))
    return [UInt8](try Data(contentsOf: folder.appendingPathComponent(relativePath)))
}

/// Where two files first differ, with the bytes around it, or `nil` if they
/// are equal. For reporting a mismatch against a fixture.
func firstDifference(_ actual: [UInt8], _ expected: [UInt8]) -> String? {
    if actual == expected { return nil }
    let common = min(actual.count, expected.count)
    let offset = (0..<common).first { actual[$0] != expected[$0] } ?? common
    func show(_ bytes: [UInt8]) -> String {
        let start = max(0, offset - 8)
        let end = min(bytes.count, offset + 24)
        guard start < end else { return "(nothing)" }
        return bytes[start..<end].map { String(format: "%02x", $0) }.joined(separator: " ")
    }
    return """
        sizes \(actual.count) and \(expected.count), first difference at offset \(offset)
          actual from \(max(0, offset - 8)):   \(show(actual))
          expected from \(max(0, offset - 8)): \(show(expected))
        """
}

/// Runs `body` on a thread with a 64 MiB stack and waits for it.
func onLargeStack(_ body: @escaping @Sendable () throws -> Void) throws {
    final class Outcome: @unchecked Sendable {
        // Written by the thread before it signals, read after the wait.
        var error: (any Error)?
    }
    let outcome = Outcome()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        do { try body() } catch { outcome.error = error }
        done.signal()
    }
    thread.stackSize = 64 << 20
    thread.start()
    done.wait()
    if let error = outcome.error { throw error }
}
