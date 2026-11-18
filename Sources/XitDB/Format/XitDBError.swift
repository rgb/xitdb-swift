/// An error thrown by XitDB.
///
/// Where the original has a name for a failure, the case has that name, so
/// that a failure means the same thing in both: ``unexpectedTag``,
/// ``keyNotFound``, ``invalidDatabase`` and every case not named in this
/// paragraph (``cursorNotWritable`` is the original's `CursorNotWriteable`).
/// The others are the port's own. ``indexOutOfRange`` is what
/// the original reports as `KeyNotFound` for a list index.
/// ``storageFailure(errno:)`` stands for the original's errors of the file
/// and the system, with the system's number. ``callerError(_:)`` carries an
/// error of the caller's own. And these are refusals and findings the
/// original does not make: ``untrustedRootHeader(lastVerified:)``,
/// ``poisonedTransaction``, ``staleCursor``, ``immutableBytes``,
/// ``byteWriterOpen``, ``structuralSlot``, ``emptyLastMoment``,
/// ``storageNotEmpty``, ``invalidCount``, ``invalidUTF8``,
/// ``noKeyHashing``, ``subCollectionSnapshot``, ``snapshotOverwritten``,
/// ``memoryMapNeedsLock`` and ``storageClosed``.
///
/// Two errors are equal when they are the same case with the same values.
/// Two ``callerError(_:)`` are equal when the errors they carry are of the
/// same type and, where that type is equatable, equal by its own `==`;
/// where it is not, being of the same type is enough, since a caller's
/// error need not be equatable and an error has to equal itself. An
/// error's ``code`` is its case without the values, and can be a
/// dictionary's key.
///
/// **A damaged file is one thing.** Damage is reported by whichever check
/// comes across it first, so the case says where the damage was met and
/// not what it is. From a read of a file that may be damaged,
/// ``endOfStream``, ``invalidCount``, ``keyOffsetExceeded``,
/// ``unexpectedTag``, ``invalidBTreeNode`` and ``invalidBTreeNodeKind`` all
/// mean that the bytes are not what a writer left, as ``invalidEnumTag``
/// and ``maxShiftExceeded`` do: catch them together, and do not tell one
/// from another. (Three of them have another meaning beside, which comes
/// from the caller's own calls: ``unexpectedTag`` is also a typed read of
/// another kind than a slot holds, ``endOfStream`` a source that ran out,
/// and ``invalidBTreeNode`` a position that a tree does not have though
/// its size says so, in a copy that was made by its slot and then written
/// beside its original: see <doc:CloningFreezeAndStaleHandles>.)
public enum XitDBError: Error, Sendable {
    /// A slot holds a kind of value that the operation cannot work with.
    ///
    /// For example, a hash map operation was applied to a slot that holds an
    /// array list. A typed read of another kind than the slot holds is one
    /// too: a `UInt64` from a signed integer, any number from bytes or from
    /// a slot set to nothing, a `String` from a number or a collection.
    case unexpectedTag

    /// The key does not exist.
    ///
    /// Reads and removes turn this into `nil` and `false`. From the library
    /// it gets out only from a write through a collection whose slot was
    /// cleared after the collection was made.
    case keyNotFound

    /// The index is not one of the list's elements.
    ///
    /// A write to an index that names no element, an insert at the end, or a
    /// cut past the end. A lookup gives `nil` instead. An iterator throws it
    /// only for an index that does not fit in an `Int64`.
    case indexOutOfRange

    /// A step that writes was used while reading.
    ///
    /// Only the package-level path API raises it; nothing public does.
    case writeNotAllowed

    /// The cursor has no position in the file, so nothing can be written
    /// through it: the key cursor of a sorted map's entry, and the root
    /// cursor for `writeBytes(formatTag:_:)`.
    case cursorNotWritable

    /// A write below the root, or a ``Database/freeze()``, with no
    /// transaction running.
    case expectedTxStart

    /// A write through the root, or a new transaction, while one is running.
    case nestedTopLevelWrite

    /// The data is not a valid xitdb database.
    ///
    /// The storage is empty or does not start with the magic bytes, no
    /// trailer in it verifies, which a damaged file ID in its header also
    /// causes, since every trailer's checksum covers it, or the bytes given
    /// to a sync do not end with a trailer that verifies. A file whose root
    /// header cannot be trusted
    /// while some trailer verifies is ``untrustedRootHeader(lastVerified:)``
    /// instead.
    ///
    /// It is also what a database without a first commit answers to
    /// everything but its replica state and a sync from 0. That is the
    /// database a sync from 0 failed on, and what a full copy that did not
    /// finish opens as when at least one block of its data arrived, so
    /// that the next sync can replace it.
    case invalidDatabase

    /// The file was written with a format version this implementation does
    /// not read.
    case invalidVersion

    /// A hash size that is not the database's, or that no database can
    /// have.
    ///
    /// Opening or recovering: the size stated with `hashSize:`, or the
    /// size of the hasher given with `hashing:`, is not the one the file
    /// records. It is checked once the header has been read and before
    /// anything else is, by ``Database/recover(_:hashing:ignoringRootHeader:)`` before it
    /// cuts anything. Creating: the size, or the hasher's, is 0 or more
    /// than 65535, or the storage holds what an unfinished creation of a
    /// database with another hash size left, which is left as it is. A
    /// call on a hash map or set: the hash given does not have as many
    /// bytes as the database's hash size, or the database's hasher gave a
    /// digest that has not, once there is a map to look in. A compaction
    /// or a sync from 0: the target, or the bytes coming in, are of
    /// another hash size.
    case invalidHashSize

    /// The storage of a database already open is shorter than the committed
    /// size it records, as a storage cut short under an open database is. A
    /// file cut short before it is opened is
    /// ``untrustedRootHeader(lastVerified:)`` instead.
    case truncatedDatabase

    /// A slot's tag byte is not one of the values in ``Slot/Tag``.
    case invalidEnumTag

    /// A tree node records more entries than a node can hold, or a position
    /// in a node is out of range.
    ///
    /// It is also a tree that is not one: deeper than a tree can be, or
    /// with more nodes than its collection can have, which is how a walk
    /// ends among nodes that lead to each other. A sorted map's or set's
    /// walk enters no more nodes than the file has room for; a linked
    /// array list's no more than the depth of a tree for each element it
    /// has given and for the next.
    case invalidBTreeNode

    /// A tree node is neither a leaf nor a branch.
    case invalidBTreeNodeKind

    /// A range of committed bytes is not one that can be read or applied: it
    /// is past the committed size, starts inside the root header, is a
    /// replica's start that is neither 0 nor its size, or is a sync from 0 of
    /// fewer bytes than the headers.
    case invalidRange

    /// A length is larger than the data it applies to: cutting a storage to
    /// more than its length.
    case invalidLength

    /// The target of a compaction already contains data: its root holds
    /// something. It is also what stops a database being compacted into
    /// itself.
    case targetNotEmpty

    /// The root of the database being compacted is an array list with no
    /// last element to keep: the list has no elements, or the slot of its
    /// last element is empty, whether the list is a history or any other
    /// list at the root. Compacting it would keep nothing of it, neither
    /// the list nor the elements before the empty one, so it is refused
    /// before anything is written to the target.
    ///
    /// An empty last slot is what an element appended and never written
    /// before 0.3.0, or by the original before `89da8e7`, is. One appended
    /// since then is a slot set to nothing, which is a moment like one set
    /// to nothing on purpose, and compacts.
    case emptyLastMoment

    /// The storage a database was to be created in already contains data,
    /// other than what a creation that did not finish left, which is
    /// created over.
    case storageNotEmpty

    /// A hash trie is deeper than a hash of the database's hash size
    /// allows, or a walk of one has entered more blocks than the file has
    /// room for: its blocks lead to each other, as no writer leaves them.
    case keyOffsetExceeded

    /// An array list is deeper than the format allows.
    case maxShiftExceeded

    /// A write would grow an in-memory database beyond its size limit,
    /// which is the machine's physical memory where none was named
    /// (``MemoryStorage/defaultMaxSize``), or, when it has none, beyond
    /// what an array can hold: a write whose bytes would end past `Int.max`
    /// is reported the same way.
    case maxSizeExceeded

    /// A byte array is larger than the limit or the buffer given for reading
    /// it.
    case streamTooLong

    /// Data ended before a complete value could be read, or the storage is
    /// too short to hold its headers: 32 bytes, or 37 in a version 1 file.
    ///
    /// It is also a position in the file that no record can be at: beyond
    /// any position a storage has, or before where the data starts, in the
    /// file's own headers. A file that leads a read there is damaged.
    ///
    /// It is also a ``ByteSource`` that runs out, and a read of a whole
    /// buffer from a `ByteReader` with fewer bytes left than the buffer
    /// holds.
    case endOfStream

    /// A byte array being written is no longer at the end of the file, so it
    /// cannot be finished: it grew, or took a format tag, after something
    /// else was written behind it. Also a seek beyond any position a storage
    /// can have.
    case unexpectedWriterPosition

    /// A step that must be the last one in a path is followed by another.
    ///
    /// Only the package-level path API raises it; nothing public does.
    case pathPartMustBeAtEnd

    /// The operation is not implemented.
    ///
    /// Only the package-level path API raises it; nothing public does.
    case notImplemented

    /// The storage refused, or the system did: `ENOENT` for a missing file,
    /// `EWOULDBLOCK` for a lock that is held, `EACCES` for a file the
    /// process may not open as asked, `ENOSPC` for a full disk, `EINVAL`
    /// for a path with a NUL byte in it, `ENOMEM` for memory the system
    /// would not give an in-memory database that had to grow.
    ///
    /// - Parameter errno: The system's number for the error, also where the
    ///   storage refuses before it calls the system, as it does for the
    ///   NUL byte.
    case storageFailure(errno: Int32)

    /// An error of the caller's own, carried as it was thrown. Either a
    /// type of the caller's threw it while XitDB was calling it, a
    /// ``ByteSink``, a ``ByteSource`` or an ``OffsetMap``; or it was thrown
    /// inside ``carrying(_:)``, which is how code that declares
    /// `throws(XitDBError)` makes a call that takes a closure. Such a call
    /// carries nothing itself: an error from its closure comes out of it
    /// as itself.
    case callerError(any Error)

    /// A count recorded in the file disagrees with what it counts.
    ///
    /// For a write: a counted hash map or set whose count says it is empty
    /// holds the key being removed, or whose count cannot grow is being
    /// added to.
    ///
    /// For a read: the size of an array list or of a sorted map or set, or
    /// a counted hash map's or set's count, is more than the file has room
    /// for, at a slot for each element and a pair for each counted entry.
    /// (A linked array list's size is held to nothing: a list joined to
    /// itself holds its nodes many times over. Nor is any size or count
    /// held against the tree under it.)
    case invalidCount

    /// A cursor that cannot be used any more: for a write, one made before the
    /// last freeze of this transaction (``Database/freeze()`` or
    /// ``LinkedArrayList/append(contentsOf:)-(Slot)``) or in an earlier
    /// transaction, since a write through it would change bytes that other
    /// things refer to or that are committed; for a read, one made in a
    /// transaction that did not commit, whose bytes are gone. The way on after
    /// a freeze is the transaction's cursor, the one
    /// ``Database/withTransaction(_:)`` or a history append hands its body, or
    /// any cursor at the same slot, such as the cursor of a collection made
    /// from it: making a collection from it is allowed, and so is writing a
    /// value through it, with ``Cursor/write(_:)-(WritableData)`` or
    /// ``Cursor/writeIfEmpty(_:)``, since its slot is the engine's own record
    /// that nothing inside the transaction can copy; every cursor taken from
    /// it is fresh, and a byte writer through it is refused like any other
    /// write. Through any other cursor from before the freeze every write is
    /// refused, making a collection included:
    /// made from a held cursor, the collection would rewrite its slot in place,
    /// in a record a copy may have left behind, and lose writes silently. A
    /// write that would land below the freeze by any other route is
    /// ``immutableBytes``, refused before that write; a write the operation
    /// made before it, as a hash map's get makes a new entry's record, poisons
    /// the transaction. The article on cloning, freeze and stale handles has
    /// the whole of it.
    case staleCursor

    /// A write would change committed or frozen bytes in place: its position is
    /// below the transaction's frozen point, where every byte is either
    /// committed or was written before the last freeze and may be shared by a
    /// clone or another handle. The engine refuses it before it writes. A write
    /// into an old block that does not make its collection first reports this;
    /// a cursor from before the freeze reports ``staleCursor`` first. Through
    /// the public API nothing reaches it: the collections' initialisers make
    /// them first, and a freeze inside a byte writer's body is
    /// ``byteWriterOpen``.
    case immutableBytes

    /// ``Database/freeze()`` or a join was called while a byte writer's body
    /// was running, which would move the frozen point past the record the
    /// writer is filling and leave its completion nowhere to write. The freeze
    /// is refused before it moves anything; the body then ends with this error,
    /// and the transaction is poisoned as after any body that throws, since the
    /// writer had appended before the body ran. Finish byte writers before
    /// freezing.
    case byteWriterOpen

    /// The file a ``Snapshot`` reads was rewritten below the snapshot's
    /// committed size, so that its bytes are no longer the commit's, by a
    /// write or a truncation through the caller's own reference to the
    /// storage. Nothing the library does of itself rewrites a file under a
    /// snapshot: a replication from zero,
    /// ``Database/applyReplicated(at:bytes:)`` at 0, brings the new
    /// database in a new file, and a snapshot taken before reads the old
    /// one on. Every read through the snapshot reports this from then on;
    /// take a new snapshot. A snapshot of a database in memory keeps the
    /// commit's bytes and never reports it. Only a rewrite through the
    /// storage object the snapshot was taken from is seen: one through
    /// another storage on the same path, or by another process, is not.
    case snapshotOverwritten

    /// A file storage that can write was asked to read through a memory
    /// map without the exclusive lock on its file. With the map the lock
    /// says "I am the file's writer": a map is sound only for a file that
    /// nothing else shortens, and the lock is what keeps a second writer,
    /// another process of yours or a second storage on the same path, out.
    /// Ask for ``FileLock/exclusive``, or leave the map off: the file is
    /// then read by file calls, as a file in an iOS app's shared container
    /// must be, since it cannot hold a lock while the app is suspended.
    ///
    /// A ``ReadOnlyFileStorage`` needs no lock for the map: it reads
    /// through it only what is committed. It is thrown before the file is
    /// opened.
    case memoryMapNeedsLock

    /// The database reads a snapshot of one collection, made with
    /// ``Snapshot/init(_:)`` from a cursor inside a commit, and the
    /// operation needs the whole commit: compacting such a database is
    /// refused before anything is written to the target. Its replication
    /// reads serve the whole commit's bytes, the file being the unit.
    case subCollectionSnapshot

    /// A slot whose tag is `index`, `kvPair` or `sortedKvPair` was given to
    /// write as a value. Those tags are the trees' own; such a slot in a
    /// value builds a tree the engine cannot read. The slot of a cursor from
    /// a map's iterator is one: write the slot of the entry's value instead.
    case structuralSlot

    /// A write in a transaction that an earlier operation poisoned: that
    /// operation failed after it had written to the storage, so what it
    /// left cannot be undone short of the whole transaction, and the
    /// transaction can only roll back. Its commit fails with this too.
    case poisonedTransaction

    /// A call of a hash map or set that takes a key, such as
    /// ``HashMap/put(_:forKey:storingKey:)-(WritableData,_,_)``, was made on a database
    /// that was given no hasher, or on a snapshot of one: the database was
    /// made with a hash size alone, as ``Database/init(opening:hashSize:)``
    /// makes it. A sorted map or set takes a key on any database, since it
    /// hashes nothing.
    ///
    /// Open the database with ``Database/init(opening:hashing:)``, or make
    /// the key's hash with a hasher's ``KeyHashing/keyHash(of:)`` and give
    /// it to the untyped call's `forHash:` form; the typed calls,
    /// `put(_:forKey:)` of a value and `value(forKey:as:)`, have no form by
    /// hash. It is thrown before anything else about the call is looked at.
    case noKeyHashing

    /// Bytes read as a `String` are not valid UTF-8. A typed read repairs
    /// nothing: read such bytes as `[UInt8]`, which reads any.
    case invalidUTF8

    /// The root header of a database being opened cannot be trusted: its
    /// size is past the end of the file, smaller than a database can be, or
    /// does not end at a trailer whose checksum verifies. `lastVerified` is
    /// the position after the last trailer that does verify, scanning back
    /// from the end; ``Database/recover(_:ignoringRootHeader:)`` cuts the file there.
    ///
    /// A committed size of zero in a file longer than a new database is not
    /// refused: it is a full copy that did not finish, which opens.
    case untrustedRootHeader(lastVerified: UInt64)

    /// A file storage was used after its `close()`: every read and write
    /// of it fails with this from then on, and so does every call of a
    /// database opened over it and of the cursors, collections and
    /// iterators made from that database, as soon as it comes to read or
    /// write. Nothing was read or written by the call that reports it.
    ///
    /// A ``Snapshot`` taken before the close is not the storage: it goes
    /// on reading its commit, and never reports this.
    case storageClosed
}

extension XitDBError: Equatable {
    /// Whether two errors are the same case with the same values. Two
    /// ``callerError(_:)`` are equal when the errors they carry are of
    /// the same type and, where that type is equatable, equal by its own
    /// `==`. Where the type is not equatable, the same type is enough: two
    /// errors of a type that cannot be compared are taken for equal, so
    /// make the type equatable if its values are to tell them apart.
    /// Nothing is compared by what it prints.
    ///
    /// The comparison goes by the case, and costs a few instructions. It
    /// went by the cases' descriptions once, which cost a lookup that
    /// found nothing seven times what one that found its key cost: the
    /// library compares errors to turn "not found" into `nil`.
    public static func == (left: XitDBError, right: XitDBError) -> Bool {
        switch (left, right) {
        case (.callerError(let leftError), .callerError(let rightError)):
            sameCarried(leftError, rightError)
        case (.storageFailure(let leftErrno), .storageFailure(let rightErrno)):
            leftErrno == rightErrno
        case (.untrustedRootHeader(let leftPosition), .untrustedRootHeader(let rightPosition)):
            leftPosition == rightPosition
        default:
            // Two cases without values are equal when they are the same
            // case; a case with a value is not equal to another case.
            left.caseNumber == right.caseNumber
        }
    }

    /// Whether two errors a caller's type threw are the same: of one
    /// type, and equal by that type's `==` where it has one.
    private static func sameCarried(_ left: any Error, _ right: any Error) -> Bool {
        guard type(of: left) == type(of: right) else { return false }
        guard let left = left as? any Equatable else { return true }
        return isEqual(left, right)
    }

    /// `left == right`, where `right` is of `left`'s type.
    private static func isEqual<Value: Equatable>(_ left: Value, _ right: any Error) -> Bool {
        guard let right = right as? Value else { return false }
        return left == right
    }

    /// A number for the error's case, whatever the case carries. The
    /// switch names every case and has no default, so that a case added to
    /// the enumeration does not compile until it has a number here.
    ///
    /// The ``code`` names the same cases, and the equality could go by it.
    /// It goes by this number because that counted fewer instructions: by
    /// the code, a lookup that finds nothing took five more.
    private var caseNumber: Int {
        switch self {
        case .unexpectedTag: 0
        case .keyNotFound: 1
        case .indexOutOfRange: 2
        case .writeNotAllowed: 3
        case .cursorNotWritable: 4
        case .expectedTxStart: 5
        case .nestedTopLevelWrite: 6
        case .invalidDatabase: 7
        case .invalidVersion: 8
        case .invalidHashSize: 9
        case .truncatedDatabase: 10
        case .invalidEnumTag: 11
        case .invalidBTreeNode: 12
        case .invalidBTreeNodeKind: 13
        case .invalidRange: 14
        case .invalidLength: 15
        case .targetNotEmpty: 16
        case .emptyLastMoment: 17
        case .storageNotEmpty: 18
        case .keyOffsetExceeded: 19
        case .maxShiftExceeded: 20
        case .maxSizeExceeded: 21
        case .streamTooLong: 22
        case .endOfStream: 23
        case .unexpectedWriterPosition: 24
        case .pathPartMustBeAtEnd: 25
        case .notImplemented: 26
        case .storageFailure: 27
        case .callerError: 28
        case .invalidCount: 29
        case .staleCursor: 30
        case .immutableBytes: 31
        case .byteWriterOpen: 32
        case .snapshotOverwritten: 33
        case .memoryMapNeedsLock: 34
        case .subCollectionSnapshot: 35
        case .structuralSlot: 36
        case .poisonedTransaction: 37
        case .noKeyHashing: 38
        case .invalidUTF8: 39
        case .untrustedRootHeader: 40
        case .storageClosed: 41
        }
    }
}

extension XitDBError {
    /// Runs `body` and throws only ``XitDBError``: an error of the library's
    /// comes out as itself, and anything else `body` throws comes out
    /// carried, as ``callerError(_:)``.
    ///
    /// It is for code that declares `throws(XitDBError)` and makes a call
    /// that takes a closure of the caller's: ``Database/withTransaction(_:)``,
    /// an append that takes a body, a cursor's `writeBytes`. Those calls
    /// throw `any Error`, because they pass on whatever the closure throws,
    /// as it was thrown, and so a typed context cannot make them bare. With
    /// this it can, and no error has to be spelled on any closure:
    ///
    /// ```swift
    /// func addVisit(to database: Database) throws(XitDBError) {
    ///     try XitDBError.carrying {
    ///         try database.withTransaction { root in
    ///             let map = try HashMap(root)
    ///             let visits = try map.value(forKey: "visits", as: UInt64.self) ?? 0
    ///             try map.put(visits + 1, forKey: "visits")
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// The calls themselves are unchanged: without this, an error of the
    /// closure's comes out of them as itself, as it does from any Swift
    /// call that takes a throwing closure. Carrying is what is asked for
    /// here, and happens here, in sight.
    ///
    /// What a caller could get wrong: an error of the caller's own that
    /// leaves through this call is no longer itself. A `catch` for its type
    /// further out never matches; match ``callerError(_:)`` and look at
    /// what it carries. A ``callerError(_:)`` thrown inside comes out as it
    /// is, once, not carried again.
    ///
    /// It costs some thirty instructions a call where nothing is thrown,
    /// and about doubles the cost of an error that is, which is some six
    /// hundred instructions to begin with.
    ///
    /// - Parameter body: Anything that throws.
    /// - Returns: What `body` returns.
    /// - Throws: The ``XitDBError`` that `body` throws, as it is; and
    ///   ``callerError(_:)`` carrying any other error that `body` throws.
    public static func carrying<Result>(_ body: () throws -> Result) throws(XitDBError) -> Result {
        do {
            return try body()
        } catch let error as XitDBError {
            throw error
        } catch {
            throw .callerError(error)
        }
    }

    /// Runs `body`, which calls a type of the caller's (a sink, a source, an
    /// offset map), and carries whatever it throws as ``callerError(_:)``,
    /// an ``XitDBError`` among them: what such a type throws is the
    /// caller's, whatever its type, and is not to be taken for an error the
    /// library met itself.
    static func carryingAll<Result>(_ body: () throws -> Result) throws(XitDBError) -> Result {
        do {
            return try body()
        } catch {
            throw .callerError(error)
        }
    }
}
