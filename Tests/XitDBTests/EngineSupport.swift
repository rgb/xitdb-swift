import Foundation
import Testing
import XitDBHashing

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

    /// The next value, or zero once they have run out, which is recorded as
    /// an issue: a test that draws more commit IDs than it listed has
    /// miscounted its commits, and zeros would hide that in bytes that still
    /// compare equal to each other.
    func next() -> UInt64 {
        guard let value = values.popLast() else {
            if !exhausted { Issue.record("a FixedRandom ran out of values") }
            exhausted = true
            return 0
        }
        return value
    }
}

/// The SHA-1 of a string's UTF-8 bytes, as a key hash.
func sha1(_ text: String) -> KeyHash {
    KeyHash(Insecure.SHA1.keyHash(of: text))
}

/// The UTF-8 bytes of a string: Zig's `"text"` literal as the bytes the
/// collections take.
func utf8(_ text: String) -> [UInt8] {
    Array(text.utf8)
}

/// Zig's `hashInt(text)`: the SHA-1 of the text, as the twenty bytes the
/// collections take.
func hashInt(_ text: String) -> [UInt8] {
    sha1(text).bytes
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

/// The two versions of the file format, for tests that run on a database of
/// each.
enum FormatVersion: UInt16, CaseIterable, CustomTestStringConvertible {
    case one = 1
    case two = 2

    var testDescription: String { "version \(rawValue)" }
}

/// The file ID of the databases ``newDatabase(_:in:random:)`` makes.
let newDatabaseFileID: UInt64 = 0x10

/// A new database of version 1, as the original made it at `6b93af1`: a
/// file of the conformance fixtures, sixty-two bytes, with hash size 20,
/// the hash ID "sha1" and the file ID 0x10. Nothing creates version 1 any
/// more, in the original or here, so a test that needs a version 1
/// database starts from these bytes.
func newVersionOneDatabaseBytes() throws -> [UInt8] {
    try fixtureFile("inputs/v1-new.db")
}

/// A new, empty database of hash size 20 in an empty storage, of either
/// format version: version 2 is created, and version 1 is the fixture's
/// bytes, opened. Both have the file ID 0x10 and the hash ID "sha1", so
/// that the two differ in the version alone, and neither draws from
/// `random` before its first transaction.
func newDatabase(
    _ version: FormatVersion, in storage: any WritableStorage,
    random: any RandomNumberGenerator = SystemRandomNumberGenerator()
) throws -> Database {
    switch version {
    case .one:
        let bytes = try newVersionOneDatabaseBytes()
        try storage.write(bytes.span, at: 0)
        // The bytes are a file that exists, so they are in the storage and
        // not in a buffer's window, as after the sync that ends a creation.
        try storage.flush()
        return try Database(opening: storage, hashSize: 20, random: random)
    case .two:
        return try Database(
            creating: storage, hashSize: 20, hashID: "sha1", fileID: newDatabaseFileID, random: random)
    }
}

/// The contents of a script in the copied `port-differs` folder of the
/// conformance repository.
func portDifferenceFile(_ name: String) throws -> [UInt8] {
    let folder = try #require(Bundle.module.url(forResource: "port-differs", withExtension: nil))
    return [UInt8](try Data(contentsOf: folder.appendingPathComponent(name)))
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

/// A thread could not be made, or waited for, by ``onLargeStack(stackSize:_:)``.
struct NoThreadForALargeStack: Error, CustomStringConvertible {
    /// The call that failed.
    let call: String
    /// The error number it gave.
    let code: Int32

    var description: String { "\(call) failed with error \(code): no thread with a large stack was run" }
}

/// Runs `body` on a thread with a large stack, 64 MiB unless another size
/// is given, and waits for it.
///
/// The thread is made by `pthread_create`, which says whether there is a
/// thread, with the stack's size as an attribute. Foundation's
/// `Thread.start()` says nothing when the process can make no more threads,
/// and waiting for a thread that never started does not end.
///
/// - Throws: ``NoThreadForALargeStack`` if the thread cannot be made or
///   joined, and whatever `body` throws.
func onLargeStack(stackSize: Int = 64 << 20, _ body: @escaping @Sendable () throws -> Void) throws {
    final class Run: @unchecked Sendable {
        let body: @Sendable () throws -> Void
        // Written by the thread before it ends, read after it is joined.
        var error: (any Error)?

        init(_ body: @escaping @Sendable () throws -> Void) {
            self.body = body
        }
    }
    // Room for the attributes, and not `pthread_attr_t()`: on Linux that
    // initializer belongs to a module of Dispatch's that no file can import,
    // and the compiler refuses its use.
    //
    // The rule this is one case of, for whoever writes the next test or
    // tool for Linux: in a target that imports Foundation, a C structure's
    // initializer or members can be refused there for the lack of an import
    // of whichever module the compiler takes the structure to belong to
    // that time, and importing that one moves it to another (`st_uid` was
    // refused for CoreFoundation and, with that imported, `st_dev` for
    // CDispatch). So the tests and the tools read no C structure's members
    // on Linux: they ask the library (`Platform.leads(_:to:)`), Foundation
    // (a file's attributes), a call that returns a number (`lseek` for a
    // length) or the system's own files. The library is not exposed: it
    // imports the system's module alone.
    let attributes = UnsafeMutablePointer<pthread_attr_t>.allocate(capacity: 1)
    defer { attributes.deallocate() }
    var code = pthread_attr_init(attributes)
    guard code == 0 else { throw NoThreadForALargeStack(call: "pthread_attr_init", code: code) }
    defer { _ = pthread_attr_destroy(attributes) }
    code = pthread_attr_setstacksize(attributes, stackSize)
    guard code == 0 else { throw NoThreadForALargeStack(call: "pthread_attr_setstacksize", code: code) }

    let run = Run(body)
    // One more reference, for the thread, which gives it up once it runs.
    let context = Unmanaged.passRetained(run).toOpaque()
    #if canImport(Darwin)
        var thread: pthread_t?
        code = pthread_create(
            &thread, attributes,
            { context in
                let run = Unmanaged<Run>.fromOpaque(context).takeRetainedValue()
                do { try run.body() } catch { run.error = error }
                return nil
            }, context)
    #else
        var thread: pthread_t = 0
        code = pthread_create(
            &thread, attributes,
            { context in
                guard let context else { return nil }
                let run = Unmanaged<Run>.fromOpaque(context).takeRetainedValue()
                do { try run.body() } catch { run.error = error }
                return nil
            }, context)
    #endif
    guard code == 0 else {
        // No thread took the reference made for it.
        Unmanaged<Run>.fromOpaque(context).release()
        throw NoThreadForALargeStack(call: "pthread_create", code: code)
    }
    #if canImport(Darwin)
        guard let thread else { throw NoThreadForALargeStack(call: "pthread_create", code: 0) }
    #endif
    code = pthread_join(thread, nil)
    guard code == 0 else { throw NoThreadForALargeStack(call: "pthread_join", code: code) }
    if let error = run.error { throw error }
}

/// Runs `body`, which has to end in a poisoned transaction (finding 16), and
/// checks that it does. The expectations inside `body` run as usual; one
/// `#expect(throws:)` cannot hold another, which is why this is not one.
func expectPoisoned(
    _ body: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation
) {
    let outcome = Result { try body() }
    #expect(throws: XitDBError.poisonedTransaction, sourceLocation: sourceLocation) { try outcome.get() }
}
