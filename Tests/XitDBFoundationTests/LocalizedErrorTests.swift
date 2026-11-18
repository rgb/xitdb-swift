import Foundation
import Testing
import XitDB
import XitDBFoundation

/// What `localizedDescription` says of the library's error where this
/// module is linked (the first client's review of 0.5.1, item 14; decision
/// D66): the error's own line, with the system's words for a storage
/// failure's number, in place of Foundation's "The operation couldn't be
/// completed".
@Suite struct LocalizedErrorTests {
    /// An error of the tests' own that says something of itself.
    private struct Refused: LocalizedError {
        var errorDescription: String? { "the server refused the upload" }
    }

    /// The system's words for a number, as the C library gives them.
    private static func words(for number: Int32) -> String {
        String(cString: strerror(number))
    }

    /// Passed as `any Error`, as a `catch` has it, the error describes
    /// itself by its own line.
    @Test func anErrorDescribesItselfByItsOwnLine() {
        let errors: [XitDBError] = [
            .keyNotFound, .invalidDatabase, .staleCursor, .untrustedRootHeader(lastVerified: 4096), .unexpectedTag,
            .memoryMapNeedsLock, .noKeyHashing,
        ]
        for error in errors {
            let caught: any Error = error
            #expect(caught.localizedDescription == error.description)
            #expect(error.errorDescription == error.description)
            #expect(!caught.localizedDescription.contains("The operation"))
        }
    }

    /// A failure of the storage says the system's words for its number
    /// after its own line.
    @Test func aStorageFailureSaysTheSystemsWords() {
        for number in [ENOENT, EACCES, ENOSPC, EWOULDBLOCK, EBADF, EINVAL] {
            let error = XitDBError.storageFailure(errno: number)
            let caught: any Error = error
            #expect(caught.localizedDescription == "\(error.description): \(Self.words(for: number))")
            #expect(caught.localizedDescription.hasPrefix("the storage failed with system error \(number): "))
        }
        let missing: any Error = XitDBError.storageFailure(errno: ENOENT)
        #expect(missing.localizedDescription == "the storage failed with system error 2: No such file or directory")
    }

    /// A caller's own error that is carried gives its own words for a
    /// person after the library's, where it has some of its own, which its
    /// type says: a `LocalizedError` with a description, and Foundation's
    /// own errors, an `NSError` and the ones that stand for one. Any other
    /// is given as the library's line gives it, and never by Foundation's
    /// stock sentence.
    @Test func aCarriedErrorGivesItsOwnWordsWhereItHasSome() {
        let lead = "an error of the caller's own: "

        // A plain error: the library's line, with the case as Swift prints it.
        enum Plain: Error { case unreachable }
        let plain = XitDBError.callerError(Plain.unreachable)
        #expect(plain.errorDescription == plain.description)
        #expect(plain.errorDescription == lead + "unreachable")
        #expect((plain as any Error).localizedDescription == lead + "unreachable")
        let own: any Error = Plain.unreachable
        #expect(!(plain as any Error).localizedDescription.contains(own.localizedDescription))

        // A `LocalizedError` of the caller's with a description: its words.
        let refused: any Error = XitDBError.callerError(Refused())
        #expect(refused.localizedDescription == lead + "the server refused the upload")

        // A `LocalizedError` that gives no description has no words of its
        // own: the library's line.
        struct Silent: LocalizedError {}
        let silent = XitDBError.callerError(Silent())
        #expect(silent.errorDescription == silent.description)

        // Foundation's own: an `NSError`, and the two that stand for one.
        let made = NSError(domain: "example", code: 7, userInfo: [NSLocalizedDescriptionKey: "the disk is full"])
        #expect((XitDBError.callerError(made) as any Error).localizedDescription == lead + "the disk is full")
        let cocoa = CocoaError(.fileNoSuchFile)
        #expect((XitDBError.callerError(cocoa) as any Error).localizedDescription == lead + cocoa.localizedDescription)
        let url = URLError(.timedOut)
        #expect((XitDBError.callerError(url) as any Error).localizedDescription == lead + url.localizedDescription)
        // Each of the two is told by its type, which the compiler holds
        // on every system this builds on, and its words are not the
        // library's line for it.
        func standsForAnNSError(_: some CustomNSError) {}
        standsForAnNSError(cocoa)
        standsForAnNSError(url)
        #expect(XitDBError.callerError(cocoa).errorDescription != XitDBError.callerError(cocoa).description)
        #expect(XitDBError.callerError(url).errorDescription != XitDBError.callerError(url).description)
    }

    /// What a failed call gives a program that shows it to a person.
    @Test func aFailedOpenSaysWhy() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xitdb-none-\(UUID().uuidString)")
        do {
            _ = try ReadOnlyFileStorage(url: folder.appendingPathComponent("none.db"))
            Issue.record("a file that is not there was opened")
        } catch {
            #expect(error.localizedDescription == "the storage failed with system error 2: No such file or directory")
        }
    }
}
