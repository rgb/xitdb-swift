import Testing

@testable import XitDB

/// A sink of the tests' own, which keeps what it is given. Not `[UInt8]`,
/// which `readCommitted` has a one-copy overload for: through this sink the
/// bytes take the streaming path, a chunk at a time.
struct CollectingSink: ByteSink {
    var bytes: [UInt8] = []

    mutating func write(_ bytes: Span<UInt8>) {
        self.bytes.append(bytesOf: bytes)
    }
}

/// Replication at its edges: states and ranges with any values, syncs that
/// fail, a database that claims more than it has, all without a trap and
/// each leaving what Zig leaves; and the order of a sync's calls on the
/// plain file.
///
/// `readCommitted` has two paths, the streaming one for any sink and the
/// one-copy one for an array, and every read here goes through both, which
/// must agree.
@Suite struct ReplicationEdgeTests {
    /// Where the committed data starts in the databases made here, which
    /// are created and so are version 2: the end of the root header, and
    /// the position of the first commit's trailer.
    private static let dataStart: UInt64 = 32

    /// The size of a new database, version 2: the end of its first commit.
    private static let newSize: UInt64 = 57

    private func makeDatabase(_ subject: StorageUnderTest, fileID: UInt64 = 6) throws -> Database {
        try Database(
            storage: subject.storage, hashSize: 20, hashID: nil, fileID: fileID,
            random: FixedRandom((1...50).map { UInt64($0) }))
    }

    /// `readCommitted` through a sink, the streaming path, and through the
    /// array convenience, the one-copy path: the same bytes from both, or
    /// the same error.
    private func readCommitted(_ database: Database, from start: UInt64, to end: UInt64) throws(XitDBError)
        -> [UInt8]
    {
        var sink = CollectingSink()
        let streamed = Result { () throws(XitDBError) -> [UInt8] in
            try database.readCommitted(from: start, to: end, into: &sink)
            return sink.bytes
        }
        let array = Result { () throws(XitDBError) -> [UInt8] in try database.readCommitted(from: start, to: end) }
        switch (streamed, array) {
        case (.success(let streamedBytes), .success(let arrayBytes)):
            #expect(streamedBytes == arrayBytes)
        case (.failure(let streamedError), .failure(let arrayError)):
            #expect(streamedError == arrayError)
        default:
            Issue.record("the streaming and the array readCommitted disagree from \(start) to \(end)")
        }
        return try streamed.get()
    }

    /// A source that claims to have given more bytes than the buffer holds.
    private struct OverstatingSource: ByteSource {
        mutating func read(into buffer: inout MutableSpan<UInt8>) -> Int {
            buffer.count + 1
        }
    }

    /// A source that gives one byte per read, however large the buffer, as
    /// a slow socket might.
    private struct OneByteSource: ByteSource {
        private let bytes: [UInt8]
        private var position = 0

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func read(into buffer: inout MutableSpan<UInt8>) -> Int {
            guard position < bytes.count, buffer.count > 0 else { return 0 }
            buffer[0] = bytes[position]
            position += 1
            return 1
        }
    }

    /// What a source or a sink of the tests' own throws.
    private struct Refused: Error, CustomStringConvertible {
        var description: String { "refused by the test" }
    }

    /// A source that throws on every read.
    private struct ThrowingSource: ByteSource {
        mutating func read(into buffer: inout MutableSpan<UInt8>) throws -> Int {
            throw Refused()
        }
    }

    /// A sink that takes `accepting` writes and throws on the next.
    private struct ThrowingSink: ByteSink {
        let accepting: Int
        var taken = 0

        mutating func write(_ bytes: Span<UInt8>) throws {
            guard taken < accepting else { throw Refused() }
            taken += 1
        }
    }

    /// A source with two moments.
    private func makeSource(_ kind: StorageKind, fileID: UInt64 = 6) throws -> (StorageUnderTest, Database) {
        let subject = try StorageUnderTest(kind)
        let source = try makeDatabase(subject, fileID: fileID)
        for moment in 1...2 {
            try ArrayList(source.rootCursor).append(.slot(try ArrayList(source.rootCursor).slot(at: -1))) {
                cursor in
                try HashMap(cursor).put(.uint(UInt64(moment)), forHash: sha1("moment").bytes)
            }
        }
        return (subject, source)
    }

    /// A state is never an error: any size and any checksum give 0 or the
    /// size, and only a trailer at the size with that checksum gives the
    /// size.
    @Test(arguments: StorageKind.allCases)
    func anyStateHasAStart(kind: StorageKind) throws {
        let (_, source) = try makeSource(kind)
        let committed = try source.committedSize
        let state = try source.replicaState
        #expect(state.committedSize == committed)
        #expect(try source.replicationStart(for: state) == committed)
        for size in [
            UInt64(0), 1, 24, 25, Self.dataStart - 1, Self.dataStart, Self.newSize - 1, Self.newSize, committed - 1,
            committed + 1, UInt64.max - 1, UInt64.max,
        ] {
            #expect(try source.replicationStart(for: ReplicaState(committedSize: size, checksum: state.checksum)) == 0)
            #expect(try source.replicationStart(for: ReplicaState(committedSize: size, checksum: 0)) == 0)
            #expect(try source.replicationStart(for: ReplicaState(committedSize: size, checksum: .max)) == 0)
        }
        #expect(
            try source.replicationStart(for: ReplicaState(committedSize: committed, checksum: state.checksum &+ 1)) == 0
        )
        // the first commit, of the empty database, is a prefix too
        let first = try source.reader.rootTrailer(endingAt: Self.newSize)
        #expect(
            try source.replicationStart(for: ReplicaState(committedSize: Self.newSize, checksum: first.checksum))
                == Self.newSize)
    }

    /// Every edge of a range: the root header's bytes cannot be a start,
    /// the end cannot be past the committed size, and an empty range at
    /// the committed size reads nothing.
    @Test(arguments: StorageKind.allCases)
    func readCommittedAtEveryEdge(kind: StorageKind) throws {
        let (_, source) = try makeSource(kind)
        let committed = try source.committedSize
        let whole = try readCommitted(source, from: 0, to: committed)
        #expect(whole.count == Int(committed))
        #expect(try readCommitted(source, from: committed, to: committed) == [])
        #expect(try readCommitted(source, from: Self.dataStart, to: committed) == Array(whole[Int(Self.dataStart)...]))
        #expect(try readCommitted(source, from: Self.newSize, to: Self.newSize) == [])
        for (start, end) in [
            (UInt64(1), committed), (19, committed), (20, committed), (Self.dataStart - 1, committed),
            (0, committed + 1),
            (Self.dataStart, committed + 1), (committed, committed + 1), (5, 3), (committed, committed - 1),
            (UInt64.max, UInt64.max),
            (0, UInt64.max), (committed + 1, committed + 1),
        ] {
            #expect(throws: XitDBError.invalidRange) { try readCommitted(source, from: start, to: end) }
        }
        // from 0, the end must be a commit: a trailer must end there
        #expect(throws: XitDBError.invalidDatabase) { try readCommitted(source, from: 0, to: 0) }
        #expect(throws: XitDBError.invalidDatabase) { try readCommitted(source, from: 0, to: 24) }
        #expect(throws: XitDBError.invalidDatabase) { try readCommitted(source, from: 0, to: committed - 1) }
        // from elsewhere, any end within the committed bytes is read as it is
        #expect(
            try readCommitted(source, from: Self.dataStart, to: committed - 1)
                == Array(whole[Int(Self.dataStart)..<Int(committed - 1)]))
        // the bytes from 0 carry a root header for the end asked for
        let earlier = try readCommitted(source, from: 0, to: Self.newSize)
        #expect(earlier.count == Int(Self.newSize))
        #expect(Array(earlier[0..<24]) == Array(whole[0..<24]))
        #expect(Array(earlier[32..<57]) == Array(whole[32..<57]))
        // the committed size, at 24 in a version 2 file, is the end asked for
        #expect(Array(earlier[24..<32]) == bigEndianBytes(Self.newSize))
        #expect(Array(whole[24..<32]) == bigEndianBytes(committed))
    }

    /// Syncs that fail, and what each leaves: a source that ends short, bytes
    /// that do not end with a trailer, a trailer of another file, a start
    /// that is neither 0 nor the committed size, and a count of 0.
    @Test(arguments: StorageKind.allCases)
    func applyReplicatedThatFails(kind: StorageKind) throws {
        let (_, source) = try makeSource(kind)
        let committed = try source.committedSize
        let whole = try readCommitted(source, from: 0, to: committed)
        let tail = try readCommitted(source, from: Self.newSize, to: committed)

        let replicaSubject = try StorageUnderTest(kind)
        let replica = try makeDatabase(replicaSubject, fileID: 7)
        try replica.applyReplicated(at: 0, bytes: try readCommitted(source, from: 0, to: Self.newSize))
        #expect(try replica.committedSize == Self.newSize)
        #expect(replica.header.fileID == 6)

        // a start that is neither 0 nor the committed size changes nothing
        for start in [UInt64(1), Self.dataStart, Self.newSize - 1, Self.newSize + 1, committed, UInt64.max] {
            #expect(throws: XitDBError.invalidRange) { try replica.applyReplicated(at: start, bytes: tail) }
        }
        #expect(try replicaSubject.storage.length == Self.newSize)

        // a count larger than the source gives: the bytes written stay past
        // the committed size, and the next sync writes over them
        var short = ArrayByteSource(Array(tail[0..<10]))
        #expect(throws: XitDBError.endOfStream) {
            try replica.applyReplicated(at: Self.newSize, from: &short, count: UInt64(tail.count))
        }
        #expect(try replica.committedSize == Self.newSize)
        #expect(try replicaSubject.storage.length == Self.newSize + 10)

        // bytes that do not end with a trailer: the same
        #expect(throws: XitDBError.invalidDatabase) {
            try replica.applyReplicated(at: Self.newSize, bytes: Array(tail.dropLast()))
        }
        #expect(try replica.committedSize == Self.newSize)
        #expect(try replicaSubject.storage.length == Self.newSize + UInt64(tail.count - 1))

        // a trailer whose checksum is for another file
        let (_, other) = try makeSource(kind, fileID: 9)
        let otherTail = try readCommitted(other, from: Self.newSize, to: try other.committedSize)
        #expect(throws: XitDBError.invalidDatabase) { try replica.applyReplicated(at: Self.newSize, bytes: otherTail) }
        #expect(try replica.committedSize == Self.newSize)

        // a count of 0 at the committed size does nothing, and clears what
        // the failures left
        try replica.applyReplicated(at: Self.newSize, bytes: [])
        #expect(try replica.committedSize == Self.newSize)
        #expect(try replicaSubject.storage.length == Self.newSize)

        // the right bytes, after all that
        try replica.applyReplicated(at: Self.newSize, bytes: tail)
        #expect(try replica.committedSize == committed)
        #expect(try readCommitted(replica, from: 0, to: committed) == whole)
        #expect(try replica.replicaState == (try source.replicaState))
    }

    /// The streaming sync, from a source, at 0. The source's header is read
    /// and checked before the replica is touched, so a source that ends
    /// inside it, or claims more than the buffer holds, is `endOfStream`
    /// with the replica as it was. A source that ends after its header has
    /// replaced the replica by then: what is left has the source's header
    /// and no first commit. A whole one from a source puts it right, the
    /// same as from an array.
    @Test(arguments: StorageKind.allCases)
    func aStreamingSyncAtZeroThatEndsShort(kind: StorageKind) throws {
        let (_, source) = try makeSource(kind)
        let committed = try source.committedSize
        let whole = try readCommitted(source, from: 0, to: committed)
        let replicaSubject = try StorageUnderTest(kind)
        let replica = try makeDatabase(replicaSubject, fileID: 7)

        // ten bytes of fifty-seven: the source ends inside its header
        var inside = ArrayByteSource(Array(whole[0..<10]))
        #expect(throws: XitDBError.endOfStream) {
            try replica.applyReplicated(at: 0, from: &inside, count: Self.newSize)
        }
        #expect(replica.header.fileID == 7)
        #expect(try replicaSubject.storage.length == Self.newSize)
        #expect(try replica.committedSize == Self.newSize)

        var overstating = OverstatingSource()
        #expect(throws: XitDBError.endOfStream) {
            try replica.applyReplicated(at: 0, from: &overstating, count: committed)
        }
        #expect(replica.header.fileID == 7)
        #expect(try replicaSubject.storage.length == Self.newSize)
        #expect(try replica.committedSize == Self.newSize)

        // forty bytes of fifty-seven: the header came, so the replica is
        // the source's database by now, without a first commit
        var short = ArrayByteSource(Array(whole[0..<40]))
        #expect(throws: XitDBError.endOfStream) {
            try replica.applyReplicated(at: 0, from: &short, count: Self.newSize)
        }
        #expect(replica.header.fileID == 6)
        #expect(try replicaSubject.storage.length == 40)
        #expect(throws: XitDBError.invalidDatabase) { try replica.committedSize }
        #expect(try replica.replicaState == ReplicaState(committedSize: 0, checksum: 0))

        var all = ArrayByteSource(whole)
        try replica.applyReplicated(at: 0, from: &all, count: committed)
        #expect(replica.header.fileID == 6)
        #expect(try replica.committedSize == committed)
        #expect(try readCommitted(replica, from: 0, to: committed) == whole)
        #expect(try replica.replicaState == (try source.replicaState))
    }

    /// A source that gives one byte per read syncs the same bytes as one
    /// that gives them whole, at 0 and at the committed size: the loop
    /// takes a short read for what it is and asks again.
    @Test(arguments: StorageKind.allCases)
    func aSourceThatGivesOneByteAtATimeSyncs(kind: StorageKind) throws {
        let (_, source) = try makeSource(kind)
        let committed = try source.committedSize
        let whole = try readCommitted(source, from: 0, to: committed)
        let replicaSubject = try StorageUnderTest(kind)
        let faulty = FaultInjectingStorage(replicaSubject.storage)
        let replica = try Database(storage: faulty, hashSize: 20, hashID: nil, fileID: 7, random: FixedRandom([1]))

        var first = OneByteSource(try readCommitted(source, from: 0, to: Self.newSize))
        var writes = faulty.writeCount
        try replica.applyReplicated(at: 0, from: &first, count: Self.newSize)
        // the header, the empty root header, one write per byte of the data,
        // and the committed size
        #expect(faulty.writeCount - writes == 2 + Int(Self.newSize - Self.dataStart) + 1)
        #expect(try replica.committedSize == Self.newSize)
        #expect(replica.header.fileID == 6)

        var rest = OneByteSource(Array(whole[Int(Self.newSize)...]))
        writes = faulty.writeCount
        try replica.applyReplicated(at: Self.newSize, from: &rest, count: committed - Self.newSize)
        // one write per byte, and one for the root header
        #expect(UInt64(faulty.writeCount - writes) == committed - Self.newSize + 1)
        #expect(try replica.committedSize == committed)
        #expect(try readCommitted(replica, from: 0, to: committed) == whole)
        #expect(try replica.replicaState == (try source.replicaState))
    }

    /// A source or a sink of the caller's that fails: a source claiming more
    /// than its buffer holds is `endOfStream` at the committed size as at
    /// 0, before anything is written; one that throws has its error
    /// carried as `callerError`, and so does a sink, wherever in the bytes
    /// it throws. At 0 a count too small for a header is refused before
    /// the source is asked for anything, and a source that throws inside
    /// its header leaves the replica as it was.
    @Test(arguments: StorageKind.allCases)
    func aSourceOrSinkOfTheCallersThatFails(kind: StorageKind) throws {
        let (_, source) = try makeSource(kind)
        let committed = try source.committedSize
        let replicaSubject = try StorageUnderTest(kind)
        let replica = try makeDatabase(replicaSubject, fileID: 7)
        try replica.applyReplicated(at: 0, bytes: try readCommitted(source, from: 0, to: committed))

        var overstating = OverstatingSource()
        #expect(throws: XitDBError.endOfStream) {
            try replica.applyReplicated(at: committed, from: &overstating, count: 10)
        }
        #expect(try replica.committedSize == committed)
        #expect(try replicaSubject.storage.length == committed)

        var refusing = ThrowingSource()
        #expect(throws: XitDBError.callerError(Refused())) {
            try replica.applyReplicated(at: committed, from: &refusing, count: 10)
        }
        #expect(try replica.committedSize == committed)
        #expect(try replicaSubject.storage.length == committed)
        #expect(throws: XitDBError.invalidRange) {
            try replica.applyReplicated(at: 0, from: &refusing, count: 10)
        }
        #expect(throws: XitDBError.callerError(Refused())) {
            try replica.applyReplicated(at: 0, from: &refusing, count: committed)
        }
        #expect(try replicaSubject.storage.length == committed)
        #expect(try replica.committedSize == committed)

        // from 0 the sink takes the bytes before the root header, the root
        // header, and the rest; from elsewhere, the bytes as they are
        for accepting in 0...2 {
            var sink = ThrowingSink(accepting: accepting)
            #expect(throws: XitDBError.callerError(Refused())) {
                try source.readCommitted(from: 0, to: committed, into: &sink)
            }
            #expect(sink.taken == accepting)
        }
        var sink = ThrowingSink(accepting: 0)
        #expect(throws: XitDBError.callerError(Refused())) {
            try source.readCommitted(from: Self.newSize, to: committed, into: &sink)
        }
        var taking = ThrowingSink(accepting: 3)
        try source.readCommitted(from: 0, to: committed, into: &taking)
        #expect(taking.taken == 3)
    }

    /// The storage failing during a sync, at each write and each sync of
    /// one, and what each failure leaves, which is what Zig leaves. At the
    /// committed size: bytes written before the failure stay past the
    /// committed size, which the next sync discards, until the root header
    /// is written, after which the commit is made and only its last sync
    /// is missing. At 0: the replica is emptied and takes the source's
    /// header before the first write, so every failure up to the committed
    /// size's write leaves a database without a first commit, with what
    /// had arrived; after it the copy is made and only its last sync is
    /// missing.
    @Test(arguments: StorageKind.allCases)
    func aStorageThatFailsDuringASync(kind: StorageKind) throws {
        let (_, source) = try makeSource(kind)
        let committed = try source.committedSize
        let whole = try readCommitted(source, from: 0, to: committed)
        let tail = try readCommitted(source, from: Self.newSize, to: committed)
        let replicaSubject = try StorageUnderTest(kind)
        let faulty = FaultInjectingStorage(replicaSubject.storage)
        let replica = try Database(storage: faulty, hashSize: 20, hashID: nil, fileID: 7, random: FixedRandom([1]))
        try replica.applyReplicated(at: 0, bytes: try readCommitted(source, from: 0, to: Self.newSize))
        #expect(try replica.committedSize == Self.newSize)
        let failure = FaultInjectingStorage.failure

        // the bytes' write fails: nothing is written
        faulty.faults = [.failWrite(faulty.writeCount + 1)]
        #expect(throws: failure) { try replica.applyReplicated(at: Self.newSize, bytes: tail) }
        #expect(try replica.committedSize == Self.newSize)
        #expect(try faulty.length == Self.newSize)

        // the bytes' write is cut short: what it wrote stays past the
        // committed size
        faulty.faults = [.cutWriteShort(faulty.writeCount + 1, keeping: 5)]
        #expect(throws: failure) { try replica.applyReplicated(at: Self.newSize, bytes: tail) }
        #expect(try replica.committedSize == Self.newSize)
        #expect(try faulty.length == Self.newSize + 5)

        // the second write of a streaming sync fails: the first byte stays
        var slow = OneByteSource(tail)
        faulty.faults = [.failWrite(faulty.writeCount + 2)]
        #expect(throws: failure) {
            try replica.applyReplicated(at: Self.newSize, from: &slow, count: UInt64(tail.count))
        }
        #expect(try replica.committedSize == Self.newSize)
        #expect(try faulty.length == Self.newSize + 1)

        // the sync before the root header fails: the bytes stay, uncommitted
        faulty.faults = [.failSync(faulty.syncCount + 1)]
        #expect(throws: failure) { try replica.applyReplicated(at: Self.newSize, bytes: tail) }
        #expect(try replica.committedSize == Self.newSize)
        #expect(try faulty.length == committed)

        // the root header's write fails: the same
        faulty.faults = [.failWrite(faulty.writeCount + 2)]
        #expect(throws: failure) { try replica.applyReplicated(at: Self.newSize, bytes: tail) }
        #expect(try replica.committedSize == Self.newSize)
        #expect(try faulty.length == committed)

        // the sync after the root header fails: the commit is made, and the
        // error reported
        faulty.faults = [.failSync(faulty.syncCount + 2)]
        #expect(throws: failure) { try replica.applyReplicated(at: Self.newSize, bytes: tail) }
        #expect(try replica.committedSize == committed)
        #expect(try readCommitted(replica, from: 0, to: committed) == whole)
        #expect(try replica.replicaState == (try source.replicaState))

        // at 0, onto a replica of another file each time: the writes and
        // the syncs of the copy, failing in turn
        let (_, otherSource) = try makeSource(kind, fileID: 9)
        let otherWhole = try readCommitted(otherSource, from: 0, to: try otherSource.committedSize)
        typealias Fault = FaultInjectingStorage.Fault
        let steps: [(String, (FaultInjectingStorage) -> Fault, UInt64, XitDBError)] = [
            ("the header's write", { .failWrite($0.writeCount + 1) }, 0, .endOfStream),
            ("the empty root header's write", { .failWrite($0.writeCount + 2) }, 20, .endOfStream),
            ("the headers' sync", { .failSync($0.syncCount + 1) }, Self.dataStart, .invalidDatabase),
            ("the data's write", { .failWrite($0.writeCount + 3) }, Self.dataStart, .invalidDatabase),
            (
                "the data's write, cut short", { .cutWriteShort($0.writeCount + 3, keeping: 5) }, Self.dataStart + 5,
                .invalidDatabase
            ),
            ("the sync before the committed size", { .failSync($0.syncCount + 2) }, committed, .invalidDatabase),
            ("the committed size's write", { .failWrite($0.writeCount + 4) }, committed, .invalidDatabase),
        ]
        for (what, fault, length, error) in steps {
            faulty.faults = []
            try replica.applyReplicated(at: 0, bytes: otherWhole)
            try #require(replica.header.fileID == 9, "\(what)")

            faulty.faults = [fault(faulty)]
            #expect(throws: failure, "\(what)") { try replica.applyReplicated(at: 0, bytes: whole) }
            #expect(try faulty.length == length, "\(what)")
            // the replica is the source's database from the moment it is emptied
            #expect(replica.header.fileID == 6, "\(what)")
            #expect(try replica.replicaState == ReplicaState(committedSize: 0, checksum: 0), "\(what)")
            #expect(throws: error, "\(what)") { try replica.committedSize }
        }

        // the sync after the committed size fails: the copy is made, and
        // the error reported
        faulty.faults = []
        try replica.applyReplicated(at: 0, bytes: otherWhole)
        faulty.faults = [.failSync(faulty.syncCount + 3)]
        #expect(throws: failure) { try replica.applyReplicated(at: 0, bytes: whole) }
        #expect(replica.header.fileID == 6)
        #expect(try replica.committedSize == committed)
        #expect(try replica.replicaState == (try source.replicaState))

        // a sync at 0 that succeeds puts any of it right
        faulty.faults = []
        try replica.applyReplicated(at: 0, bytes: otherWhole)
        try replica.applyReplicated(at: 0, bytes: whole)
        #expect(replica.header.fileID == 6)
        #expect(try replica.committedSize == committed)
        #expect(try readCommitted(replica, from: 0, to: committed) == whole)
    }

    /// A sync at 0 that fails once the replica has been emptied leaves a
    /// database without a first commit: its state is zero and zero,
    /// everything that needs the committed size raises `invalidDatabase`
    /// from then on, and a sync at 0 that succeeds puts it right. Bytes
    /// that are no database are refused before the replica is touched.
    @Test(arguments: StorageKind.allCases)
    func aFailedSyncAtZeroLeavesNoFirstCommit(kind: StorageKind) throws {
        let (_, source) = try makeSource(kind)
        let committed = try source.committedSize
        let whole = try readCommitted(source, from: 0, to: committed)
        let replicaSubject = try StorageUnderTest(kind)
        let replica = try makeDatabase(replicaSubject, fileID: 7)

        // a byte short: no trailer ends the bytes. the header was taken
        // before that was found, as Zig takes it
        #expect(throws: XitDBError.invalidDatabase) {
            try replica.applyReplicated(at: 0, bytes: Array(whole.dropLast()))
        }
        #expect(replica.header.fileID == 6)
        #expect(try replicaSubject.storage.length == committed - 1)
        #expect(try replica.replicaState == ReplicaState(committedSize: 0, checksum: 0))
        #expect(try source.replicationStart(for: try replica.replicaState) == 0)
        #expect(throws: XitDBError.invalidDatabase) { try replica.committedSize }
        #expect(throws: XitDBError.invalidDatabase) { try replica.replicationStart(for: try source.replicaState) }
        #expect(throws: XitDBError.invalidDatabase) { try readCommitted(replica, from: 0, to: Self.newSize) }
        #expect(throws: XitDBError.invalidDatabase) { try readCommitted(replica, from: Self.dataStart, to: 40) }
        #expect(throws: XitDBError.invalidDatabase) { try replica.applyReplicated(at: committed, bytes: []) }
        // a start past the end is refused before the committed size is
        // read, as Zig's `or` short-circuits, so the range is reported and
        // not the state the failed sync left
        #expect(throws: XitDBError.invalidRange) { try readCommitted(replica, from: 5, to: 3) }
        // not even a header: refused, and what the failed sync left stays
        #expect(throws: XitDBError.invalidRange) { try replica.applyReplicated(at: 0, bytes: Array(whole[0..<10])) }
        #expect(try replicaSubject.storage.length == committed - 1)
        // a trailer that does not check
        var damaged = whole
        damaged[damaged.count - 1] ^= 0xFF
        #expect(throws: XitDBError.invalidDatabase) { try replica.applyReplicated(at: 0, bytes: damaged) }
        #expect(throws: XitDBError.invalidDatabase) { try replica.committedSize }
        #expect(try replica.replicaState == ReplicaState(committedSize: 0, checksum: 0))
        #expect(try replicaSubject.storage.length == committed)
        // a database of another hash size is not adopted, and changes nothing
        let otherSubject = try StorageUnderTest(kind)
        let other = try Database(
            storage: otherSubject.storage, hashSize: 8, hashID: nil, fileID: 3, random: FixedRandom([1]))
        #expect(throws: XitDBError.invalidHashSize) {
            try replica.applyReplicated(at: 0, bytes: try readCommitted(other, from: 0, to: try other.committedSize))
        }
        #expect(replica.header.fileID == 6)
        #expect(replica.header.hashSize == 20)
        #expect(try replicaSubject.storage.length == committed)

        // a whole one puts it right
        try replica.applyReplicated(at: 0, bytes: whole)
        #expect(try replica.committedSize == committed)
        #expect(replica.header.fileID == 6)
        #expect(try replica.replicaState == (try source.replicaState))
        #expect(
            try #require(try replica.rootCursor.readPath([.arrayListGet(-1), .hashMapGet(.value, sha1("moment"))]))
                .readUInt64() == 2)
    }

    /// A database whose root header claims more than the file has: every
    /// method raises `truncatedDatabase`, as `committedSize` does.
    @Test(arguments: StorageKind.allCases)
    func aRootHeaderThatClaimsTooMuch(kind: StorageKind) throws {
        let (subject, source) = try makeSource(kind)
        let committed = try source.committedSize
        try writeBytes(subject.storage, bigEndianBytes(committed + 1), at: source.header.fileSizePosition)
        #expect(throws: XitDBError.truncatedDatabase) { try source.committedSize }
        #expect(throws: XitDBError.truncatedDatabase) { try source.replicaState }
        #expect(throws: XitDBError.truncatedDatabase) {
            try source.replicationStart(for: ReplicaState(committedSize: Self.newSize, checksum: 0))
        }
        #expect(throws: XitDBError.truncatedDatabase) { try readCommitted(source, from: 0, to: Self.newSize) }
        // and one that claims less than a database can be
        try writeBytes(subject.storage, bigEndianBytes(24), at: source.header.fileSizePosition)
        #expect(throws: XitDBError.invalidDatabase) { try source.committedSize }
        #expect(throws: XitDBError.invalidDatabase) { try source.replicaState }
    }

    /// On the plain file at full durability, a sync at the committed size
    /// writes the bytes, syncs, writes the committed size, and syncs again,
    /// in that order. A sync at 0 writes the source's header and an empty
    /// root header and syncs them before any of the data, as the barrier
    /// that keeps the data from reaching the disk without them; then the
    /// data, a sync, the committed size, and the last sync.
    @Test func aSyncOnThePlainFileSyncsAroundTheRootHeader() throws {
        let (_, source) = try makeSource(.memory)
        let committed = try source.committedSize
        let directory = try TemporaryDirectory()
        let file = try FileStorage(path: directory.path(), access: .create, durability: .full)
        let recorder = SyncRecorder()
        let events = EventRecorder()
        file.calls.sync = { descriptor, call in
            events.events.append(.sync(call))
            return recorder.call(descriptor, call)
        }
        file.calls.write = { (descriptor: Int32, bytes: Span<UInt8>, offset: UInt64) throws(XitDBError) in
            events.events.append(.write(at: offset, count: bytes.count))
            try Platform.writeFile(descriptor, bytes, at: offset)
        }
        let replica = try Database(storage: file, hashSize: 20, hashID: nil, fileID: 7, random: FixedRandom([1]))
        _ = events.take()

        try replica.applyReplicated(at: 0, bytes: try readCommitted(source, from: 0, to: Self.newSize))
        #expect(
            events.take() == [
                .write(at: 0, count: 20), .write(at: 20, count: 12), .sync(.barrier),
                .write(at: 32, count: 25), .sync(.barrier), .write(at: 24, count: 8), .sync(.full),
            ])

        let tail = try readCommitted(source, from: Self.newSize, to: committed)
        try replica.applyReplicated(at: Self.newSize, bytes: tail)
        #expect(
            events.take() == [
                .write(at: Self.newSize, count: tail.count), .sync(.barrier), .write(at: 24, count: 8), .sync(.full),
            ])
        #expect(try replica.committedSize == committed)
    }

    /// The writes and syncs a file storage makes, in order.
    private final class EventRecorder {
        enum Event: Equatable {
            case write(at: UInt64, count: Int)
            case sync(SyncCall)
        }
        var events: [Event] = []

        func take() -> [Event] {
            defer { events = [] }
            return events
        }
    }
}
