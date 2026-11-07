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
        for size in [UInt64(0), 1, 24, 25, 36, 37, 61, 62, committed - 1, committed + 1, UInt64.max - 1, UInt64.max] {
            #expect(try source.replicationStart(for: ReplicaState(committedSize: size, checksum: state.checksum)) == 0)
            #expect(try source.replicationStart(for: ReplicaState(committedSize: size, checksum: 0)) == 0)
            #expect(try source.replicationStart(for: ReplicaState(committedSize: size, checksum: .max)) == 0)
        }
        #expect(
            try source.replicationStart(for: ReplicaState(committedSize: committed, checksum: state.checksum &+ 1)) == 0
        )
        // the first commit, of the empty database, is a prefix too
        let first = try source.reader.rootTrailer(endingAt: 62)
        #expect(try source.replicationStart(for: ReplicaState(committedSize: 62, checksum: first.checksum)) == 62)
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
        #expect(try readCommitted(source, from: 37, to: committed) == Array(whole[37...]))
        #expect(try readCommitted(source, from: 62, to: 62) == [])
        for (start, end) in [
            (UInt64(1), committed), (19, committed), (20, committed), (36, committed), (0, committed + 1),
            (37, committed + 1), (committed, committed + 1), (5, 3), (committed, committed - 1),
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
        #expect(try readCommitted(source, from: 37, to: committed - 1) == Array(whole[37..<Int(committed - 1)]))
        // the bytes from 0 carry a root header for the end asked for
        let earlier = try readCommitted(source, from: 0, to: 62)
        #expect(earlier.count == 62)
        #expect(Array(earlier[0..<20]) == Array(whole[0..<20]))
        #expect(Array(earlier[37..<62]) == Array(whole[37..<62]))
        let header = try RootHeader(decoding: earlier.span, at: 20)
        #expect(header.fileSize == 62)
        #expect(header.root == (try source.reader.rootTrailer(endingAt: 62)).root)
    }

    /// Syncs that fail, and what each leaves: a source that ends short, bytes
    /// that do not end with a trailer, a trailer of another file, a start
    /// that is neither 0 nor the committed size, and a count of 0.
    @Test(arguments: StorageKind.allCases)
    func applyReplicatedThatFails(kind: StorageKind) throws {
        let (_, source) = try makeSource(kind)
        let committed = try source.committedSize
        let whole = try readCommitted(source, from: 0, to: committed)
        let tail = try readCommitted(source, from: 62, to: committed)

        let replicaSubject = try StorageUnderTest(kind)
        let replica = try makeDatabase(replicaSubject, fileID: 7)
        try replica.applyReplicated(at: 0, bytes: try readCommitted(source, from: 0, to: 62))
        #expect(try replica.committedSize == 62)
        #expect(replica.header.fileID == 6)

        // a start that is neither 0 nor the committed size changes nothing
        for start in [UInt64(1), 37, 61, 63, committed, UInt64.max] {
            #expect(throws: XitDBError.invalidRange) { try replica.applyReplicated(at: start, bytes: tail) }
        }
        #expect(try replicaSubject.storage.length == 62)

        // a count larger than the source gives: the bytes written stay past
        // the committed size, and the next sync writes over them
        var short = ArrayByteSource(Array(tail[0..<10]))
        #expect(throws: XitDBError.endOfStream) {
            try replica.applyReplicated(at: 62, from: &short, count: UInt64(tail.count))
        }
        #expect(try replica.committedSize == 62)
        #expect(try replicaSubject.storage.length == 72)

        // bytes that do not end with a trailer: the same
        #expect(throws: XitDBError.invalidDatabase) {
            try replica.applyReplicated(at: 62, bytes: Array(tail.dropLast()))
        }
        #expect(try replica.committedSize == 62)
        #expect(try replicaSubject.storage.length == 62 + UInt64(tail.count - 1))

        // a trailer whose checksum is for another file
        let (_, other) = try makeSource(kind, fileID: 9)
        let otherTail = try readCommitted(other, from: 62, to: try other.committedSize)
        #expect(throws: XitDBError.invalidDatabase) { try replica.applyReplicated(at: 62, bytes: otherTail) }
        #expect(try replica.committedSize == 62)

        // a count of 0 at the committed size does nothing, and clears what
        // the failures left
        try replica.applyReplicated(at: 62, bytes: [])
        #expect(try replica.committedSize == 62)
        #expect(try replicaSubject.storage.length == 62)

        // the right bytes, after all that
        try replica.applyReplicated(at: 62, bytes: tail)
        #expect(try replica.committedSize == committed)
        #expect(try readCommitted(replica, from: 0, to: committed) == whole)
        #expect(try replica.replicaState == (try source.replicaState))
    }

    /// The streaming sync, from a source, at 0: a source that ends short is
    /// `endOfStream` before the header is read, so the replica keeps its
    /// own, with no database behind it, as Zig's reader fails before its
    /// header is read; a source that claims more than the buffer holds is
    /// `endOfStream` too; and a whole one from a source puts it right, the
    /// same as from an array.
    @Test(arguments: StorageKind.allCases)
    func aStreamingSyncAtZeroThatEndsShort(kind: StorageKind) throws {
        let (_, source) = try makeSource(kind)
        let committed = try source.committedSize
        let whole = try readCommitted(source, from: 0, to: committed)
        let replicaSubject = try StorageUnderTest(kind)
        let replica = try makeDatabase(replicaSubject, fileID: 7)

        // forty bytes of sixty-two: the header and the root header are
        // there, but they are not read
        var short = ArrayByteSource(Array(whole[0..<40]))
        #expect(throws: XitDBError.endOfStream) { try replica.applyReplicated(at: 0, from: &short, count: 62) }
        #expect(replica.header.fileID == 7)
        #expect(try replicaSubject.storage.length == 40)
        #expect(throws: XitDBError.truncatedDatabase) { try replica.committedSize }

        var overstating = OverstatingSource()
        #expect(throws: XitDBError.endOfStream) {
            try replica.applyReplicated(at: 0, from: &overstating, count: committed)
        }
        #expect(replica.header.fileID == 7)
        #expect(try replicaSubject.storage.length == 0)

        var all = ArrayByteSource(whole)
        try replica.applyReplicated(at: 0, from: &all, count: committed)
        #expect(replica.header.fileID == 6)
        #expect(try replica.committedSize == committed)
        #expect(try readCommitted(replica, from: 0, to: committed) == whole)
        #expect(try replica.replicaState == (try source.replicaState))
    }

    /// A sync at 0 that fails leaves no database: the file was emptied
    /// first. Everything that needs the committed size raises from then on,
    /// and a sync at 0 that succeeds puts it right.
    @Test(arguments: StorageKind.allCases)
    func aFailedSyncAtZeroLeavesNoDatabase(kind: StorageKind) throws {
        let (_, source) = try makeSource(kind)
        let committed = try source.committedSize
        let whole = try readCommitted(source, from: 0, to: committed)
        let replicaSubject = try StorageUnderTest(kind)
        let replica = try makeDatabase(replicaSubject, fileID: 7)

        // the root header says more than there is. the header itself was
        // read and adopted before that was found, as Zig adopts it
        #expect(throws: XitDBError.truncatedDatabase) {
            try replica.applyReplicated(at: 0, bytes: Array(whole.dropLast()))
        }
        #expect(replica.header.fileID == 6)
        #expect(throws: XitDBError.truncatedDatabase) { try replica.committedSize }
        #expect(throws: XitDBError.truncatedDatabase) { try replica.replicaState }
        #expect(throws: XitDBError.truncatedDatabase) { try replica.replicationStart(for: try source.replicaState) }
        #expect(throws: XitDBError.truncatedDatabase) { try readCommitted(replica, from: 0, to: 62) }
        #expect(throws: XitDBError.truncatedDatabase) { try replica.applyReplicated(at: committed, bytes: []) }
        // not even the header
        #expect(throws: XitDBError.endOfStream) { try replica.applyReplicated(at: 0, bytes: Array(whole[0..<10])) }
        #expect(throws: XitDBError.endOfStream) { try replica.committedSize }
        // a start past the end is refused before the committed size is
        // read, as Zig's `or` short-circuits, so the range is reported and
        // not the state the failed sync left
        #expect(throws: XitDBError.invalidRange) { try readCommitted(replica, from: 5, to: 3) }
        #expect(throws: XitDBError.endOfStream) { try readCommitted(replica, from: 37, to: 40) }
        // a trailer that does not check
        var damaged = whole
        damaged[damaged.count - 1] ^= 0xFF
        #expect(throws: XitDBError.invalidDatabase) { try replica.applyReplicated(at: 0, bytes: damaged) }
        #expect(throws: XitDBError.invalidDatabase) { try replica.committedSize }
        // a database of another hash size is not adopted
        let otherSubject = try StorageUnderTest(kind)
        let other = try Database(
            storage: otherSubject.storage, hashSize: 8, hashID: nil, fileID: 3, random: FixedRandom([1]))
        #expect(throws: XitDBError.invalidHashSize) {
            try replica.applyReplicated(at: 0, bytes: try readCommitted(other, from: 0, to: try other.committedSize))
        }
        #expect(replica.header.fileID == 6)
        #expect(replica.header.hashSize == 20)

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
        try writeBytes(subject.storage, bigEndianBytes(committed + 1), at: RootHeader.fileSizePosition)
        #expect(throws: XitDBError.truncatedDatabase) { try source.committedSize }
        #expect(throws: XitDBError.truncatedDatabase) { try source.replicaState }
        #expect(throws: XitDBError.truncatedDatabase) {
            try source.replicationStart(for: ReplicaState(committedSize: 62, checksum: 0))
        }
        #expect(throws: XitDBError.truncatedDatabase) { try readCommitted(source, from: 0, to: 62) }
        // and one that claims less than a database can be
        try writeBytes(subject.storage, bigEndianBytes(24), at: RootHeader.fileSizePosition)
        #expect(throws: XitDBError.invalidDatabase) { try source.committedSize }
        #expect(throws: XitDBError.invalidDatabase) { try source.replicaState }
    }

    /// On the plain file at full durability, a sync at the committed size
    /// writes the bytes, syncs, writes the root header, and syncs again, in
    /// that order; a sync at 0 writes the bytes and syncs once.
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

        try replica.applyReplicated(at: 0, bytes: try readCommitted(source, from: 0, to: 62))
        #expect(events.take() == [.write(at: 0, count: 62), .sync(.full)])

        let tail = try readCommitted(source, from: 62, to: committed)
        try replica.applyReplicated(at: 62, bytes: tail)
        #expect(
            events.take() == [
                .write(at: 62, count: tail.count), .sync(.barrier), .write(at: 20, count: 17), .sync(.full),
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
