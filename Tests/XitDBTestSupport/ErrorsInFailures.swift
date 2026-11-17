public import Testing
public import XitDB

/// How a failed expectation shows an error of the library's, in this
/// package's tests: by the case's name with what the case carries,
/// `storageFailure(errno: 28)`, which is the error's debug description.
///
/// Swift Testing prints a value by its `description` where it has one, and
/// the error's description is a line for a person: "the storage failed with
/// system error 28". A test that fails wants the case. Swift Testing asks a
/// value for its test description first, so the error is given one here.
/// The library cannot give it: it does not import Testing.
///
/// The conformance is in a target of its own, which the test targets depend
/// on, so that it is declared once for whatever binary the tests are linked
/// into: the same conformance declared in two modules of one binary is a
/// fault of its own.
extension XitDBError: CustomTestStringConvertible {
    /// The error as a failed expectation shows it: the case's name with
    /// what the case carries.
    public var testDescription: String {
        debugDescription
    }
}
