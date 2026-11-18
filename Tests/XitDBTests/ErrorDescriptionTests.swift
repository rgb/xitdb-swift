import Foundation
import Testing

@testable import XitDB

/// An error of the caller's own for ``XitDBError/callerError(_:)``, at the
/// file's level so that its name in a debug description is a plain one.
struct CarriedForDescription: Error {
    let number: Int
}

/// What an error says of itself beside its case (the first client's review
/// of 0.5.1, item 8; the names are the user's of 2026-11-17): its `code`,
/// which is the case without what it carries and is what code compares,
/// counts by and pins; whose it is, its `kind`; the name the original
/// gives it; a line a person can read, its `description`; and the case's
/// name with its values for a debugger, its `debugDescription`.
///
/// The library's switches name every case and have no default, so a new
/// case does not compile until it has a code, a kind, a line and a name.
/// What is held here is that each is the right one. The table below was
/// not written from those switches: its names are what Swift printed for
/// each case by string interpolation before the error had a description,
/// captured by a test run then, and its lines and kinds are the table the
/// user agreed.
///
/// The two descriptions are compared with their text here, and only here:
/// this is the test of the text. Nothing else in the package reads,
/// compares or pins what an error prints; a word for an error is its
/// code's raw value.
@Suite struct ErrorDescriptionTests {
    /// An error with what it has to say: the case's name with its values,
    /// its kind, and its line.
    typealias Row = (error: XitDBError, name: String, kind: XitDBError.Kind, line: String)

    /// One error of each case.
    static let table: [Row] = [
        (
            .unexpectedTag, "unexpectedTag", .program,
            "a slot holds another kind of value than this operation works with"
        ),
        (
            .keyNotFound, "keyNotFound", .program,
            "the key is not there"
        ),
        (
            .indexOutOfRange, "indexOutOfRange", .program,
            "the index is not one of the list's elements"
        ),
        (
            .writeNotAllowed, "writeNotAllowed", .program,
            "a step that writes was used in a path that only reads"
        ),
        (
            .cursorNotWritable, "cursorNotWritable", .program,
            "the cursor has no position in the file, so nothing can be written through it"
        ),
        (
            .expectedTxStart, "expectedTxStart", .program,
            "a write below the root, or a freeze, with no transaction running"
        ),
        (
            .nestedTopLevelWrite, "nestedTopLevelWrite", .program,
            "a write through the root, or a new transaction, while a transaction is running"
        ),
        (
            .invalidDatabase, "invalidDatabase", .file,
            "the data is not a valid xitdb database"
        ),
        (
            .invalidVersion, "invalidVersion", .file,
            "the file has a format version this version of the library does not read"
        ),
        (
            .invalidHashSize, "invalidHashSize", .program,
            "the hash size is not the database's, or is one no database can have"
        ),
        (
            .truncatedDatabase, "truncatedDatabase", .file,
            "the storage is shorter than the committed size it records"
        ),
        (
            .invalidEnumTag, "invalidEnumTag", .file,
            "a slot's tag is not one this version of the library knows"
        ),
        (
            .invalidBTreeNode, "invalidBTreeNode", .file,
            "a tree node records more than it can hold, or a position in a tree is out of its range"
        ),
        (
            .invalidBTreeNodeKind, "invalidBTreeNodeKind", .file,
            "a tree node is neither a leaf nor a branch"
        ),
        (
            .invalidRange, "invalidRange", .program,
            "the range of committed bytes is not one that can be read or applied"
        ),
        (
            .invalidLength, "invalidLength", .program,
            "the length is larger than the data it applies to"
        ),
        (
            .targetNotEmpty, "targetNotEmpty", .program,
            "the target of a compaction already holds data"
        ),
        (
            .emptyLastMoment, "emptyLastMoment", .program,
            "the list at the root has no last element to keep, so there is nothing to compact"
        ),
        (
            .storageNotEmpty, "storageNotEmpty", .program,
            "the storage a database was to be created in already holds data"
        ),
        (
            .keyOffsetExceeded, "keyOffsetExceeded", .file,
            "a hash trie is deeper than the database's hash size allows"
        ),
        (
            .maxShiftExceeded, "maxShiftExceeded", .file,
            "an array list is deeper than the format allows"
        ),
        (
            .maxSizeExceeded, "maxSizeExceeded", .storage,
            "the write would grow the in-memory database beyond its size limit"
        ),
        (
            .streamTooLong, "streamTooLong", .program,
            "the byte array is larger than the limit or the buffer given for reading it"
        ),
        (
            .endOfStream, "endOfStream", .file,
            "the data ended before a complete value could be read"
        ),
        (
            .unexpectedWriterPosition, "unexpectedWriterPosition", .program,
            "the byte array being written is no longer at the end of the file, so it cannot be finished"
        ),
        (
            .pathPartMustBeAtEnd, "pathPartMustBeAtEnd", .program,
            "a step that must be the last of a path is followed by another"
        ),
        (
            .notImplemented, "notImplemented", .program,
            "the operation is not implemented"
        ),
        (
            .storageFailure(errno: 5), "storageFailure(errno: 5)", .storage,
            "the storage failed with system error 5"
        ),
        (
            .invalidCount, "invalidCount", .file,
            "a count in the file disagrees with what it counts"
        ),
        (
            .staleCursor, "staleCursor", .program,
            "the cursor is from before a freeze or from a transaction that has ended, and cannot be written through"
        ),
        (
            .immutableBytes, "immutableBytes", .program,
            "the write would change committed or frozen bytes in place"
        ),
        (
            .byteWriterOpen, "byteWriterOpen", .program,
            "a freeze or a join was called while a byte writer was writing"
        ),
        (
            .snapshotOverwritten, "snapshotOverwritten", .program,
            "the file under a snapshot was rewritten or cut below the snapshot's commit"
        ),
        (
            .memoryMapNeedsLock, "memoryMapNeedsLock", .program,
            "a file storage that can write needs the exclusive lock on its file to read through a memory map"
        ),
        (
            .subCollectionSnapshot, "subCollectionSnapshot", .program,
            "the database reads a snapshot of one collection, and this operation needs a whole commit"
        ),
        (
            .structuralSlot, "structuralSlot", .program,
            "a slot that belongs to a collection's own structure was given to write as a value"
        ),
        (
            .poisonedTransaction, "poisonedTransaction", .program,
            "an earlier operation in this transaction failed after it had written, so the transaction cannot commit"
        ),
        (
            .noKeyHashing, "noKeyHashing", .program,
            "the database was given no hasher, so a key cannot be hashed for it"
        ),
        (
            .invalidUTF8, "invalidUTF8", .program,
            "the bytes read as a string are not valid UTF-8"
        ),
        (
            .untrustedRootHeader(lastVerified: 57), "untrustedRootHeader(lastVerified: 57)", .file,
            "the root header cannot be trusted; the last commit that verifies ends at byte 57"
        ),
        (
            .storageClosed, "storageClosed", .program,
            "the file storage was closed, and nothing can be read or written through it"
        ),
        (
            .callerError(CarriedForDescription(number: 3)), "callerError(XitDBTests.CarriedForDescription(number: 3))",
            .caller,
            "an error of the caller's own: CarriedForDescription(number: 3)"
        ),
    ]

    /// The case's name without what it carries, from the table's own
    /// words.
    private static func caseName(_ row: Row) -> String {
        String(row.name.prefix { $0 != "(" })
    }

    /// The package's root, from this file's place in it.
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // MARK: The code

    /// The codes are the error's cases, one for one and in their order,
    /// each with the case's own name as its raw value: held against the
    /// declarations in the library's source, and against the table.
    @Test func theCodesAreTheCasesInTheirOrder() throws {
        let source = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Sources/XitDB/Format/XitDBError.swift"),
            encoding: .utf8)
        let start = try #require(source.range(of: "public enum XitDBError: Error, Sendable {"))
        let end = try #require(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
        let declared = source[start.upperBound..<end.lowerBound].components(separatedBy: "\n")
            .filter { $0.hasPrefix("    case ") }
            .map { String($0.dropFirst("    case ".count).prefix { $0.isLetter || $0.isNumber }) }
        #expect(declared.count == 42)
        #expect(XitDBError.Code.allCases.map(\.rawValue) == declared)
        #expect(Set(declared).count == 42)
        #expect(Self.table.count == 42)
        #expect(Set(Self.table.map(Self.caseName)) == Set(declared))
    }

    /// An error's code is its case: its raw value is the name Swift
    /// printed for the case before, and the way back from that word is
    /// the code. The table's errors have every code once, and so does the
    /// list the equality's test keeps, which a switch with no default
    /// holds to the enumeration.
    @Test func everyErrorHasTheCodeOfItsCase() {
        #expect(Self.table.count == 42)
        for row in Self.table {
            #expect(row.error.code.rawValue == Self.caseName(row))
            #expect(XitDBError.Code(rawValue: Self.caseName(row)) == row.error.code)
        }
        #expect(Set(Self.table.map(\.error.code)) == Set(XitDBError.Code.allCases))
        #expect(XitDBError.Code.allCases.count == 42)
        #expect(Set(ErrorEqualityTests.everyCase.map(\.code)) == Set(XitDBError.Code.allCases))
        #expect(ErrorEqualityTests.everyCase.count == XitDBError.Code.allCases.count)
    }

    /// The code is the same whatever the case carries, so that errors are
    /// counted by case in a dictionary, which the error itself cannot key.
    @Test func aCodeIsTheSameWhateverTheCaseCarries() {
        #expect(XitDBError.storageFailure(errno: 5).code == XitDBError.storageFailure(errno: 28).code)
        #expect(XitDBError.storageFailure(errno: 5).code == .storageFailure)
        #expect(XitDBError.untrustedRootHeader(lastVerified: 1).code == .untrustedRootHeader)
        #expect(XitDBError.callerError(CarriedForDescription(number: 1)).code == .callerError)
        #expect(XitDBError.callerError(XitDBError.keyNotFound).code == .callerError)

        var counts: [XitDBError.Code: Int] = [:]
        let met: [XitDBError] = [
            .keyNotFound, .storageFailure(errno: 5), .keyNotFound, .storageFailure(errno: 28), .invalidDatabase,
        ]
        for error in met {
            counts[error.code, default: 0] += 1
        }
        #expect(counts == [.keyNotFound: 2, .storageFailure: 2, .invalidDatabase: 1])
    }

    /// From a word back to a code: the case's own name and nothing else.
    @Test func theWayBackFromAWordIsTheCasesOwnName() {
        #expect(XitDBError.Code(rawValue: "invalidEnumTag") == .invalidEnumTag)
        #expect(XitDBError.Code(rawValue: "storageFailure") == .storageFailure)
        // Not the original's spelling, not the name with a value, not a line.
        #expect(XitDBError.Code(rawValue: "InvalidEnumTag") == nil)
        #expect(XitDBError.Code(rawValue: "storageFailure(errno: 5)") == nil)
        #expect(XitDBError.Code(rawValue: "the key is not there") == nil)
        #expect(XitDBError.Code(rawValue: "") == nil)
        for code in XitDBError.Code.allCases {
            #expect(XitDBError.Code(rawValue: code.rawValue) == code)
        }
    }

    /// Two errors that carry nothing are equal exactly when their codes
    /// are. The equality goes by a number of its own for each case, which
    /// counted fewer instructions than the code; this holds the two
    /// switches to each other.
    @Test func errorsThatCarryNothingAreEqualWhenTheirCodesAre() {
        let plain = Self.table.filter { $0.name == Self.caseName($0) }
        #expect(plain.count == 39)
        for left in plain {
            for right in plain {
                #expect((left.error == right.error) == (left.error.code == right.error.code))
            }
        }
    }

    // MARK: The kind

    @Test func everyCaseHasItsKindWhichIsItsCodes() {
        for row in Self.table {
            #expect(row.error.kind == row.kind, "\(row.error.code.rawValue)")
            #expect(row.error.code.kind == row.kind, "\(row.error.code.rawValue)")
        }
    }

    /// The four kinds, by a switch with no default, so that a fifth has to
    /// be put here.
    private static func heading(of kind: XitDBError.Kind) -> String {
        switch kind {
        case .program: "Your program"
        case .file: "The file"
        case .storage: "The storage"
        case .caller: "Your own types"
        }
    }

    /// A kind as the article's links write it.
    private static func word(for kind: XitDBError.Kind) -> String {
        switch kind {
        case .program: "program"
        case .file: "file"
        case .storage: "storage"
        case .caller: "caller"
        }
    }

    /// The Errors article groups the cases under four headings, and a kind
    /// is a heading: the cases the article lists under a heading are the
    /// cases of that heading's kind, no more and no fewer, and every case
    /// is under one. The article says each list's kind itself, in the
    /// paragraph that lists it, which is the first of its section: the
    /// four headings, and "Cases you will not see", which are the
    /// program's.
    ///
    /// The article's words are taken back to cases: a link to a member of
    /// the error in one of those paragraphs has to name a case, through
    /// `XitDBError.Code(rawValue:)`, or be the link to the kind itself. A
    /// word that names no case fails, and codes are compared.
    @Test func theKindsAreTheArticlesHeadings() throws {
        let article = Self.packageRoot.appendingPathComponent("Sources/XitDB/XitDB.docc/Articles/Errors.md")
        let text = try String(contentsOf: article, encoding: .utf8)

        // Each section's heading with its first paragraph.
        var sections: [(heading: String, paragraph: String)] = []
        for part in text.components(separatedBy: "\n### ").dropFirst() {
            let lines = part.components(separatedBy: "\n")
            let body = lines.dropFirst().drop { $0.isEmpty }
            sections.append((lines[0], body.prefix { !$0.isEmpty }.joined(separator: " ")))
        }

        /// The members of the error that a paragraph links: the codes of
        /// the cases, the kinds, and whatever names neither.
        func linked(_ paragraph: String) -> (codes: Set<XitDBError.Code>, kinds: Set<String>, unknown: [String]) {
            var codes: Set<XitDBError.Code> = []
            var kinds: Set<String> = []
            var unknown: [String] = []
            for piece in paragraph.components(separatedBy: "``XitDBError/").dropFirst() {
                let link = String(piece.prefix { $0 != "`" })
                if link.hasPrefix("Kind/") {
                    kinds.insert(String(link.dropFirst("Kind/".count)))
                } else if link == "kind" {
                    continue
                } else if let code = XitDBError.Code(rawValue: String(link.prefix { $0 != "(" })) {
                    codes.insert(code)
                } else {
                    unknown.append(link)
                }
            }
            return (codes, kinds, unknown)
        }

        var listed: [XitDBError.Kind: Set<XitDBError.Code>] = [:]
        for kind in [XitDBError.Kind.program, .file, .storage, .caller] {
            let heading = Self.heading(of: kind)
            let section = try #require(sections.first { $0.heading == heading }, "no heading \(heading)")
            let links = linked(section.paragraph)
            #expect(links.kinds == [Self.word(for: kind)], "the kind the article names under \(heading)")
            #expect(links.unknown == [], "under \(heading)")
            listed[kind] = links.codes
        }
        let unseen = try #require(sections.first { $0.heading == "Cases you will not see" })
        #expect(linked(unseen.paragraph).kinds == ["program"])
        #expect(linked(unseen.paragraph).unknown == [])
        #expect(
            linked(unseen.paragraph).codes == [
                .writeNotAllowed, .pathPartMustBeAtEnd, .notImplemented, .immutableBytes,
            ])
        #expect(listed[.program, default: []].isDisjoint(with: linked(unseen.paragraph).codes))
        listed[.program, default: []].formUnion(linked(unseen.paragraph).codes)

        // No other section says of a list that it is a kind.
        let saying = sections.filter { !linked($0.paragraph).kinds.isEmpty }.map(\.heading)
        #expect(saying == ["Your program", "The file", "The storage", "Your own types", "Cases you will not see"])

        for kind in [XitDBError.Kind.program, .file, .storage, .caller] {
            let ofTheKind = Set(XitDBError.Code.allCases.filter { $0.kind == kind })
            #expect(listed[kind] == ofTheKind, "\(Self.heading(of: kind))")
        }
        #expect(listed.values.reduce(0) { $0 + $1.count } == 42)
    }

    // MARK: The original's name

    /// The eighteen codes of the port's own, which the original has no
    /// error of that meaning for under a name of its own.
    static let thePortsOwn: Set<XitDBError.Code> = [
        .indexOutOfRange, .storageFailure, .callerError, .untrustedRootHeader, .poisonedTransaction, .staleCursor,
        .immutableBytes, .byteWriterOpen, .structuralSlot, .emptyLastMoment, .storageNotEmpty, .invalidCount,
        .invalidUTF8, .noKeyHashing, .subCollectionSnapshot, .snapshotOverwritten, .memoryMapNeedsLock,
        .storageClosed,
    ]

    /// The original's name is given for the twenty-four it has and for no
    /// other; it is the case's name with a capital, but for the one the
    /// original spells otherwise; and no two codes have the same.
    @Test func theOriginalsNameIsGivenWhereTheOriginalHasOne() {
        #expect(Self.thePortsOwn.count == 18)
        var names: [String] = []
        for code in XitDBError.Code.allCases {
            guard let name = code.originalName else {
                #expect(Self.thePortsOwn.contains(code), "\(code.rawValue) has no name of the original's")
                continue
            }
            #expect(!Self.thePortsOwn.contains(code), "\(code.rawValue) is the port's own and has \(name)")
            names.append(name)
            if code == .cursorNotWritable {
                #expect(name == "CursorNotWriteable")
            } else {
                #expect(name == code.rawValue.prefix(1).uppercased() + code.rawValue.dropFirst())
            }
        }
        #expect(names.count == 24)
        #expect(Set(names).count == 24)
    }

    /// The conformance runner's names are the suite's vocabulary, which
    /// has a word for the port's own cases too. Where the library gives
    /// the original's name, the runner's is the same word.
    @Test func theRunnersNamesAreTheOriginalsWhereTheOriginalHasOne() {
        for row in Self.table {
            guard let name = row.error.code.originalName else { continue }
            #expect(ScriptRunner.name(of: row.error) == name)
        }
    }

    // MARK: The two descriptions

    @Test func everyCaseHasItsLineAndItsName() {
        for row in Self.table {
            let code = row.error.code.rawValue
            #expect(row.error.description == row.line, "\(code)")
            #expect("\(row.error)" == row.line, "\(code)")
            #expect(String(describing: row.error) == row.line, "\(code)")
            #expect(row.error.debugDescription == row.name, "\(code)")
            #expect(String(reflecting: row.error) == row.name, "\(code)")
            // The name a debugger shows begins with the code's.
            #expect(row.error.debugDescription.hasPrefix(code), "\(code)")
        }
    }

    /// A line reads on after a caller's own words: lower case, one line,
    /// no full stop; and no two cases have the same line.
    @Test func aLineReadsOnAfterACallersOwnWords() {
        for row in Self.table {
            let line = row.error.description
            #expect(line.first?.isLowercase == true, "\(row.error.code.rawValue)")
            #expect(!line.hasSuffix("."), "\(row.error.code.rawValue)")
            #expect(!line.contains("\n"), "\(row.error.code.rawValue)")
        }
        #expect(Set(Self.table.map { $0.error.description }).count == Self.table.count)
        let opening = "could not open the library: \(XitDBError.invalidDatabase)"
        #expect(opening == "could not open the library: the data is not a valid xitdb database")
    }

    /// An error that carries a value says it, in the line and in the name.
    @Test func whatAnErrorCarriesIsInItsLineAndItsName() {
        #expect(XitDBError.storageFailure(errno: 28).description == "the storage failed with system error 28")
        #expect(XitDBError.storageFailure(errno: 28).debugDescription == "storageFailure(errno: 28)")
        let untrusted = XitDBError.untrustedRootHeader(lastVerified: 1234)
        #expect(
            untrusted.description
                == "the root header cannot be trusted; the last commit that verifies ends at byte 1234")
        #expect(untrusted.debugDescription == "untrustedRootHeader(lastVerified: 1234)")

        // A carried error is given by its own description in the line, and
        // as `String(reflecting:)` gives it in the name.
        struct Spoken: Error, CustomStringConvertible, CustomDebugStringConvertible {
            var description: String { "the connection was lost" }
            var debugDescription: String { "Spoken()" }
        }
        #expect(XitDBError.callerError(Spoken()).description == "an error of the caller's own: the connection was lost")
        #expect(XitDBError.callerError(Spoken()).debugDescription == "callerError(Spoken())")
        // One of the library's own that a type of the caller's threw.
        let carried = XitDBError.callerError(XitDBError.keyNotFound)
        #expect(carried.description == "an error of the caller's own: the key is not there")
        #expect(carried.debugDescription == "callerError(keyNotFound)")
    }
}
