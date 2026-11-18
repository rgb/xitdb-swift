/// What an error says of itself beside its case: its code, whose it is, a
/// line for a person, and its name with its values for a debugger.

extension XitDBError {
    /// Which of the error's cases an error is, without what the case
    /// carries.
    ///
    /// An error cannot be a dictionary's key or a set's member, since one
    /// of its cases carries any error at all. Its code can, which is how
    /// errors are counted by case; and a code is compared without matching
    /// a value, as in `error.code == .storageFailure`.
    ///
    /// The raw value is the case's own name as the source writes it,
    /// `"invalidEnumTag"`, the same for every error of the case. It is
    /// what code logs, counts by, sends and pins: never the error's
    /// ``XitDBError/description``, whose words may change in any version,
    /// nor its debug description. A raw value changes only if a case is
    /// renamed, which a release's notes would say. `Code(rawValue:)` is
    /// the way back from a word, and is `nil` for a word that names no
    /// case; `allCases` has every code, in the order the error declares
    /// its cases.
    ///
    /// A code names a case and is not a number. The number a system gives
    /// a failure is the value that ``XitDBError/storageFailure(errno:)``
    /// carries, had by matching the case.
    ///
    /// New codes come with new cases, which may be added in minor
    /// versions: give a `switch` over the codes a `default` and keep it.
    public enum Code: String, CaseIterable, Hashable, Sendable {
        /// The code of ``XitDBError/unexpectedTag``.
        case unexpectedTag

        /// The code of ``XitDBError/keyNotFound``.
        case keyNotFound

        /// The code of ``XitDBError/indexOutOfRange``.
        case indexOutOfRange

        /// The code of ``XitDBError/writeNotAllowed``.
        case writeNotAllowed

        /// The code of ``XitDBError/cursorNotWritable``.
        case cursorNotWritable

        /// The code of ``XitDBError/expectedTxStart``.
        case expectedTxStart

        /// The code of ``XitDBError/nestedTopLevelWrite``.
        case nestedTopLevelWrite

        /// The code of ``XitDBError/invalidDatabase``.
        case invalidDatabase

        /// The code of ``XitDBError/invalidVersion``.
        case invalidVersion

        /// The code of ``XitDBError/invalidHashSize``.
        case invalidHashSize

        /// The code of ``XitDBError/truncatedDatabase``.
        case truncatedDatabase

        /// The code of ``XitDBError/invalidEnumTag``.
        case invalidEnumTag

        /// The code of ``XitDBError/invalidBTreeNode``.
        case invalidBTreeNode

        /// The code of ``XitDBError/invalidBTreeNodeKind``.
        case invalidBTreeNodeKind

        /// The code of ``XitDBError/invalidRange``.
        case invalidRange

        /// The code of ``XitDBError/invalidLength``.
        case invalidLength

        /// The code of ``XitDBError/targetNotEmpty``.
        case targetNotEmpty

        /// The code of ``XitDBError/emptyLastMoment``.
        case emptyLastMoment

        /// The code of ``XitDBError/storageNotEmpty``.
        case storageNotEmpty

        /// The code of ``XitDBError/keyOffsetExceeded``.
        case keyOffsetExceeded

        /// The code of ``XitDBError/maxShiftExceeded``.
        case maxShiftExceeded

        /// The code of ``XitDBError/maxSizeExceeded``.
        case maxSizeExceeded

        /// The code of ``XitDBError/streamTooLong``.
        case streamTooLong

        /// The code of ``XitDBError/endOfStream``.
        case endOfStream

        /// The code of ``XitDBError/unexpectedWriterPosition``.
        case unexpectedWriterPosition

        /// The code of ``XitDBError/pathPartMustBeAtEnd``.
        case pathPartMustBeAtEnd

        /// The code of ``XitDBError/notImplemented``.
        case notImplemented

        /// The code of ``XitDBError/storageFailure(errno:)``.
        case storageFailure

        /// The code of ``XitDBError/callerError(_:)``.
        case callerError

        /// The code of ``XitDBError/invalidCount``.
        case invalidCount

        /// The code of ``XitDBError/staleCursor``.
        case staleCursor

        /// The code of ``XitDBError/immutableBytes``.
        case immutableBytes

        /// The code of ``XitDBError/byteWriterOpen``.
        case byteWriterOpen

        /// The code of ``XitDBError/snapshotOverwritten``.
        case snapshotOverwritten

        /// The code of ``XitDBError/memoryMapNeedsLock``.
        case memoryMapNeedsLock

        /// The code of ``XitDBError/subCollectionSnapshot``.
        case subCollectionSnapshot

        /// The code of ``XitDBError/structuralSlot``.
        case structuralSlot

        /// The code of ``XitDBError/poisonedTransaction``.
        case poisonedTransaction

        /// The code of ``XitDBError/noKeyHashing``.
        case noKeyHashing

        /// The code of ``XitDBError/invalidUTF8``.
        case invalidUTF8

        /// The code of ``XitDBError/untrustedRootHeader(lastVerified:)``.
        case untrustedRootHeader

        /// The code of ``XitDBError/storageClosed``.
        case storageClosed

        /// Whose an error of this code is: the heading it has in
        /// <doc:Errors>.
        ///
        /// A code has one kind, by its commoner meaning. Five have a second
        /// meaning, which is of another kind, and the kind does not tell
        /// the two apart: ``unexpectedTag`` is ``XitDBError/Kind/program``,
        /// and is also what a read of a damaged file can give;
        /// ``invalidHashSize`` is ``XitDBError/Kind/program``, and is also
        /// a file whose header states a size the caller did not expect;
        /// ``endOfStream`` is ``XitDBError/Kind/file``, and is also a
        /// ``ByteSource`` of the caller's that ran out, or a whole buffer
        /// asked of a ``ByteReader`` with fewer bytes left;
        /// ``invalidBTreeNode`` is ``XitDBError/Kind/file``, and is also a
        /// position that a copy the freeze hazard left does not have, with
        /// no byte damaged; ``invalidCount`` is ``XitDBError/Kind/file``,
        /// and is also a write's error. Each case's own documentation says
        /// when it is thrown.
        public var kind: Kind {
            switch self {
            case .unexpectedTag, .keyNotFound, .indexOutOfRange, .writeNotAllowed, .cursorNotWritable,
                .expectedTxStart, .nestedTopLevelWrite, .invalidHashSize, .invalidRange, .invalidLength,
                .targetNotEmpty, .emptyLastMoment, .storageNotEmpty, .streamTooLong, .unexpectedWriterPosition,
                .pathPartMustBeAtEnd, .notImplemented, .staleCursor, .immutableBytes, .byteWriterOpen,
                .snapshotOverwritten, .memoryMapNeedsLock, .subCollectionSnapshot, .structuralSlot,
                .poisonedTransaction, .noKeyHashing, .invalidUTF8, .storageClosed:
                .program
            case .invalidDatabase, .invalidVersion, .truncatedDatabase, .invalidEnumTag, .invalidBTreeNode,
                .invalidBTreeNodeKind, .keyOffsetExceeded, .maxShiftExceeded, .endOfStream, .invalidCount,
                .untrustedRootHeader:
                .file
            case .maxSizeExceeded, .storageFailure:
                .storage
            case .callerError:
                .caller
            }
        }

        /// The name the original gives this error, where it has an error
        /// of this meaning under a name of its own: `"InvalidEnumTag"` for
        /// ``invalidEnumTag``, and `"CursorNotWriteable"`, as the original
        /// spells it, for ``cursorNotWritable``. It is the word in a log
        /// of the original's, in its tools' output and in the conformance
        /// suite's scripts.
        ///
        /// It is `nil` for the eighteen codes of the port's own: where the
        /// port says something the original does not say, or says with a
        /// case of its own what the original says with another error's
        /// name or with several. What the original says in those places is
        /// not one word: see ``XitDBError`` and
        /// <doc:DifferencesFromTheOriginal>.
        public var originalName: String? {
            switch self {
            case .unexpectedTag: "UnexpectedTag"
            case .keyNotFound: "KeyNotFound"
            case .writeNotAllowed: "WriteNotAllowed"
            case .cursorNotWritable: "CursorNotWriteable"
            case .expectedTxStart: "ExpectedTxStart"
            case .nestedTopLevelWrite: "NestedTopLevelWrite"
            case .invalidDatabase: "InvalidDatabase"
            case .invalidVersion: "InvalidVersion"
            case .invalidHashSize: "InvalidHashSize"
            case .truncatedDatabase: "TruncatedDatabase"
            case .invalidEnumTag: "InvalidEnumTag"
            case .invalidBTreeNode: "InvalidBTreeNode"
            case .invalidBTreeNodeKind: "InvalidBTreeNodeKind"
            case .invalidRange: "InvalidRange"
            case .invalidLength: "InvalidLength"
            case .targetNotEmpty: "TargetNotEmpty"
            case .keyOffsetExceeded: "KeyOffsetExceeded"
            case .maxShiftExceeded: "MaxShiftExceeded"
            case .maxSizeExceeded: "MaxSizeExceeded"
            case .streamTooLong: "StreamTooLong"
            case .endOfStream: "EndOfStream"
            case .unexpectedWriterPosition: "UnexpectedWriterPosition"
            case .pathPartMustBeAtEnd: "PathPartMustBeAtEnd"
            case .notImplemented: "NotImplemented"
            case .indexOutOfRange, .emptyLastMoment, .storageNotEmpty, .storageFailure, .callerError, .invalidCount,
                .staleCursor, .immutableBytes, .byteWriterOpen, .snapshotOverwritten, .memoryMapNeedsLock,
                .subCollectionSnapshot, .structuralSlot, .poisonedTransaction, .noKeyHashing, .invalidUTF8,
                .untrustedRootHeader, .storageClosed:
                nil
            }
        }
    }

    /// The error's case without what it carries, to compare, to count by
    /// and to log: see ``Code``. It names the case; the number a system
    /// gives a failure is not the code but what
    /// ``storageFailure(errno:)`` carries.
    public var code: Code {
        switch self {
        case .unexpectedTag: .unexpectedTag
        case .keyNotFound: .keyNotFound
        case .indexOutOfRange: .indexOutOfRange
        case .writeNotAllowed: .writeNotAllowed
        case .cursorNotWritable: .cursorNotWritable
        case .expectedTxStart: .expectedTxStart
        case .nestedTopLevelWrite: .nestedTopLevelWrite
        case .invalidDatabase: .invalidDatabase
        case .invalidVersion: .invalidVersion
        case .invalidHashSize: .invalidHashSize
        case .truncatedDatabase: .truncatedDatabase
        case .invalidEnumTag: .invalidEnumTag
        case .invalidBTreeNode: .invalidBTreeNode
        case .invalidBTreeNodeKind: .invalidBTreeNodeKind
        case .invalidRange: .invalidRange
        case .invalidLength: .invalidLength
        case .targetNotEmpty: .targetNotEmpty
        case .emptyLastMoment: .emptyLastMoment
        case .storageNotEmpty: .storageNotEmpty
        case .keyOffsetExceeded: .keyOffsetExceeded
        case .maxShiftExceeded: .maxShiftExceeded
        case .maxSizeExceeded: .maxSizeExceeded
        case .streamTooLong: .streamTooLong
        case .endOfStream: .endOfStream
        case .unexpectedWriterPosition: .unexpectedWriterPosition
        case .pathPartMustBeAtEnd: .pathPartMustBeAtEnd
        case .notImplemented: .notImplemented
        case .storageFailure: .storageFailure
        case .callerError: .callerError
        case .invalidCount: .invalidCount
        case .staleCursor: .staleCursor
        case .immutableBytes: .immutableBytes
        case .byteWriterOpen: .byteWriterOpen
        case .snapshotOverwritten: .snapshotOverwritten
        case .memoryMapNeedsLock: .memoryMapNeedsLock
        case .subCollectionSnapshot: .subCollectionSnapshot
        case .structuralSlot: .structuralSlot
        case .poisonedTransaction: .poisonedTransaction
        case .noKeyHashing: .noKeyHashing
        case .invalidUTF8: .invalidUTF8
        case .untrustedRootHeader: .untrustedRootHeader
        case .storageClosed: .storageClosed
        }
    }

    /// Whose an error is, which says what to do about it: the headings of
    /// <doc:Errors>, in code.
    public enum Kind: Sendable, Hashable {
        /// The code asked for something it should not have. A fault to
        /// mend, not a condition to handle: log it and stop the operation.
        /// Nothing was damaged by it: a refusal comes before the write, or
        /// the transaction it failed in rolled back.
        case program

        /// The bytes are not what a writer left. Stop reading this file,
        /// and do not try again. If the error is
        /// ``XitDBError/untrustedRootHeader(lastVerified:)``, the file can
        /// be recovered to the commit it names, at the price
        /// <doc:Recovery> states; otherwise take another copy, a replica
        /// or a backup.
        case file

        /// The system refused (a full disk, a lock that is held, memory it
        /// would not give) or a limit was met. The transaction rolled back
        /// and the database is as it was: mend the cause and try again.
        /// The one exception is a failure of a commit's second sync, after
        /// which the commit stands: see <doc:Errors>.
        case storage

        /// An error of the caller's own, carried: take it out of
        /// ``XitDBError/callerError(_:)`` and handle it as that error.
        case caller
    }

    /// Whose the error is, which is its code's ``Code/kind``: the heading
    /// it has in <doc:Errors>. A case has one kind, by its commoner
    /// meaning; ``Code/kind`` names the five that have a second.
    public var kind: Kind {
        code.kind
    }
}

extension XitDBError: CustomStringConvertible {
    /// The error as a person would read it: one line, in lower case and
    /// with no full stop, so that it reads on after a caller's own words,
    /// as in `"could not open the library: \(error)"`.
    ///
    /// It is what `print` and string interpolation give. The words are for
    /// people and may be changed in any version: code compares the case or
    /// its ``code``, and logs, counts by and pins the code's raw value,
    /// never these words.
    ///
    /// ``storageFailure(errno:)`` gives the system's number and not the
    /// system's words for it, which are the C library's to give.
    /// ``callerError(_:)`` gives the carried error's own description after
    /// its own.
    public var description: String {
        switch self {
        case .unexpectedTag:
            "a slot holds another kind of value than this operation works with"
        case .keyNotFound:
            "the key is not there"
        case .indexOutOfRange:
            "the index is not one of the list's elements"
        case .writeNotAllowed:
            "a step that writes was used in a path that only reads"
        case .cursorNotWritable:
            "the cursor has no position in the file, so nothing can be written through it"
        case .expectedTxStart:
            "a write below the root, or a freeze, with no transaction running"
        case .nestedTopLevelWrite:
            "a write through the root, or a new transaction, while a transaction is running"
        case .invalidDatabase:
            "the data is not a valid xitdb database"
        case .invalidVersion:
            "the file has a format version this version of the library does not read"
        case .invalidHashSize:
            "the hash size is not the database's, or is one no database can have"
        case .truncatedDatabase:
            "the storage is shorter than the committed size it records"
        case .invalidEnumTag:
            "a slot's tag is not one this version of the library knows"
        case .invalidBTreeNode:
            "a tree node records more than it can hold, or a position in a tree is out of its range"
        case .invalidBTreeNodeKind:
            "a tree node is neither a leaf nor a branch"
        case .invalidRange:
            "the range of committed bytes is not one that can be read or applied"
        case .invalidLength:
            "the length is larger than the data it applies to"
        case .targetNotEmpty:
            "the target of a compaction already holds data"
        case .emptyLastMoment:
            "the list at the root has no last element to keep, so there is nothing to compact"
        case .storageNotEmpty:
            "the storage a database was to be created in already holds data"
        case .keyOffsetExceeded:
            "a hash trie is deeper than the database's hash size allows"
        case .maxShiftExceeded:
            "an array list is deeper than the format allows"
        case .maxSizeExceeded:
            "the write would grow the in-memory database beyond its size limit"
        case .streamTooLong:
            "the byte array is larger than the limit or the buffer given for reading it"
        case .endOfStream:
            "the data ended before a complete value could be read"
        case .unexpectedWriterPosition:
            "the byte array being written is no longer at the end of the file, so it cannot be finished"
        case .pathPartMustBeAtEnd:
            "a step that must be the last of a path is followed by another"
        case .notImplemented:
            "the operation is not implemented"
        case .storageFailure(let errno):
            "the storage failed with system error \(errno)"
        case .callerError(let error):
            "an error of the caller's own: \(String(describing: error))"
        case .invalidCount:
            "a count in the file disagrees with what it counts"
        case .staleCursor:
            "the cursor is from before a freeze or from a transaction that has ended, and cannot be written through"
        case .immutableBytes:
            "the write would change committed or frozen bytes in place"
        case .byteWriterOpen:
            "a freeze or a join was called while a byte writer was writing"
        case .snapshotOverwritten:
            "the file under a snapshot was rewritten or cut below the snapshot's commit"
        case .memoryMapNeedsLock:
            "a file storage that can write needs the exclusive lock on its file to read through a memory map"
        case .subCollectionSnapshot:
            "the database reads a snapshot of one collection, and this operation needs a whole commit"
        case .structuralSlot:
            "a slot that belongs to a collection's own structure was given to write as a value"
        case .poisonedTransaction:
            "an earlier operation in this transaction failed after it had written, so the transaction cannot commit"
        case .noKeyHashing:
            "the database was given no hasher, so a key cannot be hashed for it"
        case .invalidUTF8:
            "the bytes read as a string are not valid UTF-8"
        case .untrustedRootHeader(let lastVerified):
            "the root header cannot be trusted; the last commit that verifies ends at byte \(lastVerified)"
        case .storageClosed:
            "the file storage was closed, and nothing can be read or written through it"
        }
    }
}

extension XitDBError: CustomDebugStringConvertible {
    /// The case's name with what the case carries, as the source writes
    /// them: `keyNotFound`, `storageFailure(errno: 28)`,
    /// `untrustedRootHeader(lastVerified: 57)`, and for
    /// ``callerError(_:)`` the carried error as `String(reflecting:)`
    /// gives it. The name is the ``code``'s raw value.
    ///
    /// It is what `String(reflecting:)`, `debugPrint`, `dump` and a
    /// debugger give, and what string interpolation gave before the error
    /// had a ``description``. It is for a person at a debugger: code that
    /// wants the case's name takes the code's raw value.
    public var debugDescription: String {
        switch self {
        case .storageFailure(let errno): "\(code.rawValue)(errno: \(errno))"
        case .callerError(let error): "\(code.rawValue)(\(String(reflecting: error)))"
        case .untrustedRootHeader(let lastVerified): "\(code.rawValue)(lastVerified: \(lastVerified))"
        case .unexpectedTag, .keyNotFound, .indexOutOfRange, .writeNotAllowed, .cursorNotWritable, .expectedTxStart,
            .nestedTopLevelWrite, .invalidDatabase, .invalidVersion, .invalidHashSize, .truncatedDatabase,
            .invalidEnumTag, .invalidBTreeNode, .invalidBTreeNodeKind, .invalidRange, .invalidLength, .targetNotEmpty,
            .emptyLastMoment, .storageNotEmpty, .keyOffsetExceeded, .maxShiftExceeded, .maxSizeExceeded,
            .streamTooLong, .endOfStream, .unexpectedWriterPosition, .pathPartMustBeAtEnd, .notImplemented,
            .invalidCount, .staleCursor, .immutableBytes, .byteWriterOpen, .snapshotOverwritten, .memoryMapNeedsLock,
            .subCollectionSnapshot, .structuralSlot, .poisonedTransaction, .noKeyHashing, .invalidUTF8,
            .storageClosed:
            code.rawValue
        }
    }
}
