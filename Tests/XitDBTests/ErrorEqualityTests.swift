import Testing

@testable import XitDB

/// `XitDBError`'s equality, which goes by the case: every case is equal to
/// itself and to no other, and a case that carries a value is equal where
/// the values are. The library compares errors on the path of every lookup
/// that finds nothing, to turn "not found" into `nil`, and the comparison
/// once went by the cases' descriptions, which cost such a lookup seven
/// times what one that finds its key costs (the first client's review of
/// 0.5.1). The cost is held by the benchmark's `map_by_hash_missing`; what
/// is held here is that a comparison written case by case is right for
/// every case.
@Suite struct ErrorEqualityTests {
    /// An error a caller's type throws, for ``XitDBError/callerError(_:)``:
    /// one that can be compared.
    private struct Thrown: Error, Equatable, CustomStringConvertible {
        let description: String
    }

    /// One that cannot be compared, and one more that prints as it does.
    private struct Opaque: Error, CustomStringConvertible {
        let number: Int
        var description: String { "opaque" }
    }
    private struct OtherOpaque: Error, CustomStringConvertible {
        var description: String { "opaque" }
    }

    /// One whose own equality is not that of its stored values.
    private struct ByParity: Error, Equatable {
        let number: Int
        static func == (left: ByParity, right: ByParity) -> Bool { left.number % 2 == right.number % 2 }
    }

    /// One error of each case. The switch below fails to compile when a
    /// case is added to the enumeration, which is the moment to add it
    /// here too.
    static let everyCase: [XitDBError] = [
        .unexpectedTag, .keyNotFound, .indexOutOfRange, .writeNotAllowed, .cursorNotWritable, .expectedTxStart,
        .nestedTopLevelWrite, .invalidDatabase, .invalidVersion, .invalidHashSize, .truncatedDatabase,
        .invalidEnumTag, .invalidBTreeNode, .invalidBTreeNodeKind, .invalidRange, .invalidLength, .targetNotEmpty,
        .emptyLastMoment, .storageNotEmpty, .keyOffsetExceeded, .maxShiftExceeded, .maxSizeExceeded, .streamTooLong,
        .endOfStream, .unexpectedWriterPosition, .pathPartMustBeAtEnd, .notImplemented, .storageFailure(errno: 5),
        .callerError(Thrown(description: "one")), .invalidCount, .staleCursor, .immutableBytes, .byteWriterOpen,
        .snapshotOverwritten, .memoryMapNeedsLock, .subCollectionSnapshot, .structuralSlot, .poisonedTransaction,
        .noKeyHashing, .invalidUTF8, .untrustedRootHeader(lastVerified: 57), .storageClosed,
    ]

    /// Whether the list above has an error of this case: written as a
    /// switch with no default, so that a new case must be put in both.
    private static func isListed(_ error: XitDBError) -> Bool {
        switch error {
        case .unexpectedTag, .keyNotFound, .indexOutOfRange, .writeNotAllowed, .cursorNotWritable, .expectedTxStart,
            .nestedTopLevelWrite, .invalidDatabase, .invalidVersion, .invalidHashSize, .truncatedDatabase,
            .invalidEnumTag, .invalidBTreeNode, .invalidBTreeNodeKind, .invalidRange, .invalidLength, .targetNotEmpty,
            .emptyLastMoment, .storageNotEmpty, .keyOffsetExceeded, .maxShiftExceeded, .maxSizeExceeded,
            .streamTooLong, .endOfStream, .unexpectedWriterPosition, .pathPartMustBeAtEnd, .notImplemented,
            .storageFailure, .callerError, .invalidCount, .staleCursor, .immutableBytes, .byteWriterOpen,
            .snapshotOverwritten, .memoryMapNeedsLock, .subCollectionSnapshot, .structuralSlot, .poisonedTransaction,
            .noKeyHashing, .invalidUTF8, .untrustedRootHeader, .storageClosed:
            true
        }
    }

    /// Every case is equal to itself and to no other case, whichever side
    /// it is on.
    @Test func everyCaseIsEqualToItselfAndToNoOther() {
        let errors = Self.everyCase
        #expect(errors.count == 42)
        #expect(errors.allSatisfy(Self.isListed))
        for (i, left) in errors.enumerated() {
            for (j, right) in errors.enumerated() {
                #expect((left == right) == (i == j), "\(left) and \(right)")
            }
        }
    }

    /// A case that carries a value is equal where the values are: a
    /// storage's failure by its error number, an untrusted root header by
    /// the position it names, and a caller's error by what it carries.
    @Test func aCaseWithAValueIsEqualWhereTheValuesAre() {
        #expect(XitDBError.storageFailure(errno: 5) == .storageFailure(errno: 5))
        #expect(XitDBError.storageFailure(errno: 5) != .storageFailure(errno: 28))
        #expect(XitDBError.untrustedRootHeader(lastVerified: 57) == .untrustedRootHeader(lastVerified: 57))
        #expect(XitDBError.untrustedRootHeader(lastVerified: 57) != .untrustedRootHeader(lastVerified: 58))
        #expect(XitDBError.callerError(Thrown(description: "one")) == .callerError(Thrown(description: "one")))
        #expect(XitDBError.callerError(Thrown(description: "one")) != .callerError(Thrown(description: "two")))
        // a value that another case's would equal does not make the cases equal
        #expect(XitDBError.storageFailure(errno: 57) != .untrustedRootHeader(lastVerified: 57))
        #expect(XitDBError.callerError(Thrown(description: "keyNotFound")) != .keyNotFound)
    }

    /// Two carried errors are equal when they are of the same type and,
    /// where that type is equatable, equal by its own `==`. Nothing goes
    /// by what an error prints: it went by the carried errors'
    /// descriptions once, which made two errors of different types equal
    /// when they printed the same, and two of one type unequal when a
    /// description carried something that is no part of the value.
    @Test func twoCarriedErrorsAreEqualByTheirTypeAndTheirOwnEquality() {
        // Equatable: by its own `==`, which need not be that of its stored values.
        #expect(XitDBError.callerError(Thrown(description: "one")) == .callerError(Thrown(description: "one")))
        #expect(XitDBError.callerError(Thrown(description: "one")) != .callerError(Thrown(description: "two")))
        #expect(XitDBError.callerError(ByParity(number: 2)) == .callerError(ByParity(number: 4)))
        #expect(XitDBError.callerError(ByParity(number: 2)) != .callerError(ByParity(number: 3)))

        // Not equatable: the same type is enough, so that an error equals
        // itself; its values do not tell two apart.
        let opaque = XitDBError.callerError(Opaque(number: 1))
        #expect(opaque == opaque)
        #expect(XitDBError.callerError(Opaque(number: 1)) == .callerError(Opaque(number: 2)))

        // Another type is another error, though it prints the same.
        #expect("\(Opaque(number: 1))" == "\(OtherOpaque())")
        #expect(XitDBError.callerError(Opaque(number: 1)) != .callerError(OtherOpaque()))
        #expect(XitDBError.callerError(OtherOpaque()) != .callerError(Opaque(number: 1)))
        // An equatable type against one that is not, either way round.
        #expect(XitDBError.callerError(Thrown(description: "opaque")) != .callerError(OtherOpaque()))
        #expect(XitDBError.callerError(OtherOpaque()) != .callerError(Thrown(description: "opaque")))

        // One of the library's own that a type of the caller's threw is
        // compared as the library's errors are.
        #expect(XitDBError.callerError(XitDBError.keyNotFound) == .callerError(XitDBError.keyNotFound))
        #expect(XitDBError.callerError(XitDBError.keyNotFound) != .callerError(XitDBError.indexOutOfRange))
        #expect(
            XitDBError.callerError(XitDBError.storageFailure(errno: 5))
                != .callerError(XitDBError.storageFailure(errno: 28)))
    }

    /// What the library does with the comparison: a lookup that finds
    /// nothing is `nil` and not an error, by a key in a map and by an index
    /// in a list.
    @Test func aLookupThatFindsNothingIsNil() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 20)
        try database.withTransaction { root in
            let map = try HashMap<ReadWrite>(root)
            try map.put(.uint(1), forHash: hashInt("there"))
            let list = try ArrayList<ReadWrite>(try map.putCursor(forHash: hashInt("list")))
            try list.append(.uint(7))
        }
        let map = try HashMap<ReadOnly>(database.rootCursor.readOnly)
        #expect(try map.cursor(forHash: hashInt("there")) != nil)
        #expect(try map.cursor(forHash: hashInt("not there")) == nil)
        let list = try ArrayList<ReadOnly>(try #require(try map.cursor(forHash: hashInt("list"))))
        #expect(try list.cursor(at: 0) != nil)
        #expect(try list.cursor(at: 5) == nil)
    }
}
