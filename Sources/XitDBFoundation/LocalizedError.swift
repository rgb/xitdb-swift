public import Foundation
public import XitDB

/// What `error.localizedDescription` says of the library's error, in a
/// program that links this module: the error's own line, and for a failure
/// of the storage the system's words for its number as well.
///
/// Without this module an `XitDBError` passed as `any Error` describes
/// itself to Foundation as "The operation couldn't be completed.", with the
/// type's name and a number. With it, `localizedDescription` is
/// ``errorDescription``. The text is English and is not localized: it is
/// for a log, or for a message your own words lead up to. To decide what
/// to do, look at the error's `code` and `kind`, never at its text.
///
/// A program that wrote this conformance itself takes its own out when it
/// adopts this module: a type conforms to a protocol once.
extension XitDBError: LocalizedError {
    /// The error as a person would read it: its `description`, and for
    /// `storageFailure(errno:)` the system's words for the number after
    /// it, as in "the storage failed with system error 2: No such file or
    /// directory".
    ///
    /// An error of the caller's own that is carried gives its own words
    /// for a person after the library's, where it has some: a
    /// `LocalizedError` that gives an `errorDescription`, or an error of
    /// Foundation's own, an `NSError` or one that stands for one, as
    /// `CocoaError` and `URLError` do. Any other carried error is given as
    /// the library's line gives it, since what Foundation says of such an
    /// error is its stock sentence with the type's name and a number.
    public var errorDescription: String? {
        switch self {
        case .storageFailure(let errno):
            // The C library's words for the number, copied out of its
            // buffer at once.
            "\(description): \(unsafe String(cString: strerror(errno)))"
        case .callerError(let error):
            if let words = Self.wordsForAPerson(of: error) {
                "an error of the caller's own: \(words)"
            } else {
                description
            }
        default:
            description
        }
    }

    /// A carried error's own words for a person, or `nil` if it has none
    /// of its own. Which it is, is told by the error's type and never by
    /// the text it gives: every error answers `localizedDescription`, and
    /// one with nothing to say answers with Foundation's stock sentence.
    private static func wordsForAPerson(of error: any Error) -> String? {
        if let localized = error as? any LocalizedError, let words = localized.errorDescription {
            return words
        }
        if error is any CustomNSError || type(of: error) is NSError.Type {
            return error.localizedDescription
        }
        return nil
    }
}
