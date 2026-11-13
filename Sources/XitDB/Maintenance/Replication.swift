// Replication: bringing a replica up to date by copying the bytes it does
// not have. Committed bytes never change except for the root header, so a
// replica that holds a prefix of the source needs only what follows it;
// one of another file, or one that has diverged, is replaced from zero.
// Zig's replicaState, replicationStart, readCommitted and applyReplicated.

/// What a replica sends its source, so that the source knows which bytes
/// to send back: see ``Database/replicationStart(for:)``.
public struct ReplicaState: Sendable, Equatable {
    /// The replica's committed size.
    public var committedSize: UInt64

    /// The checksum of the trailer that ends the replica's committed bytes.
    /// It covers the file ID and the commit's random ID, so it identifies
    /// both the file and the history that led to the commit.
    public var checksum: UInt64

    /// A state from its two values, as received over a wire.
    public init(committedSize: UInt64, checksum: UInt64) {
        self.committedSize = committedSize
        self.checksum = checksum
    }
}

/// Where ``Database/readCommitted(from:to:into:)-(_,_,Sink)`` writes the bytes it
/// reads, a chunk at a time: a growing buffer, a file, a socket.
///
/// A sink may throw any error; the call that was writing to it carries the
/// error as ``XitDBError/callerError(_:)``. ``ArrayByteSink`` collects the
/// bytes in memory.
public protocol ByteSink {
    /// Takes the next bytes.
    mutating func write(_ bytes: Span<UInt8>) throws
}

/// Where ``Database/applyReplicated(at:from:count:)`` reads the bytes it
/// writes, a chunk at a time.
///
/// A source may throw any error; the call that was reading from it carries
/// the error as ``XitDBError/callerError(_:)``. ``ArrayByteSource`` reads
/// from bytes in memory.
public protocol ByteSource {
    /// Fills `buffer` with the next bytes, as many as it has at hand, and
    /// returns how many: fewer than the buffer holds when fewer are at
    /// hand, as a socket gives them, and zero only when they have run out.
    /// A count larger than the buffer is an error of the source's, which
    /// the sync reports as ``XitDBError/endOfStream``.
    mutating func read(into buffer: inout MutableSpan<UInt8>) throws -> Int
}

/// A sink that collects the bytes in memory, in order: what a source sends
/// when the bytes are to be kept whole. For bytes read straight into an
/// array in one copy, ``Database/readCommitted(from:to:into:)-(_,_,[UInt8])``
/// takes the array itself.
public struct ArrayByteSink: ByteSink, Sendable {
    /// The bytes taken so far.
    public var bytes: [UInt8]

    /// A sink that appends to `bytes`.
    public init(_ bytes: [UInt8] = []) {
        self.bytes = bytes
    }

    /// Appends the bytes.
    public mutating func write(_ bytes: Span<UInt8>) {
        self.bytes.append(bytesOf: bytes)
    }
}

/// A source over bytes in memory, read from the start: what a replica
/// applies when the bytes arrived whole.
public struct ArrayByteSource: ByteSource, Sendable {
    private let bytes: [UInt8]
    private var position = 0

    /// A source over `bytes`.
    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Fills `buffer` with the next bytes, as many as are left.
    public mutating func read(into buffer: inout MutableSpan<UInt8>) -> Int {
        let count = min(buffer.count, bytes.count - position)
        buffer.copyBytes(from: bytes.span, at: position, count: count)
        position += count
        return count
    }
}

extension Database {
    /// This database's ``ReplicaState``: its committed size and the
    /// checksum of the trailer that ends it.
    ///
    /// A database without a first commit, which is what a sync from 0 that
    /// did not finish leaves, has a state of its own: a committed size of
    /// zero and a checksum of zero. A source answers 0 to it, so the next
    /// sync replaces the database.
    ///
    /// - Throws: What ``committedSize`` throws, for a database that has a
    ///   first commit: it must check out to have a state.
    public var replicaState: ReplicaState {
        get throws(XitDBError) {
            // a full copy that didn't finish has no first commit
            if try reader.recordedSize() == 0 { return ReplicaState(committedSize: 0, checksum: 0) }
            let committedSize = try reader.committedSize
            return ReplicaState(
                committedSize: committedSize, checksum: try reader.rootTrailer(endingAt: committedSize).checksum)
        }
    }

    /// Where to start sending committed bytes to a replica in `state`: its
    /// committed size if its bytes are a prefix of this database, or 0 if
    /// it must be replaced, because it is a replica of another file or has
    /// diverged from this one.
    ///
    /// A state is never an error: a size beyond this database's, or one
    /// where no trailer with that checksum ends, gives 0.
    ///
    /// - Throws: What ``committedSize`` throws, and the storage's errors.
    public func replicationStart(for state: ReplicaState) throws(XitDBError) -> UInt64 {
        if state.committedSize > (try reader.committedSize) { return 0 }
        let trailer: RootTrailer
        do throws(XitDBError) {
            trailer = try reader.rootTrailer(endingAt: state.committedSize)
        } catch {
            switch error {
            case .invalidDatabase, .invalidEnumTag: return 0
            default: throw error
            }
        }
        return trailer.checksum == state.checksum ? state.committedSize : 0
    }

    /// Writes the committed bytes from `start` up to `end` to `sink`, a
    /// chunk at a time.
    ///
    /// `start` is usually from ``replicationStart(for:)``, and `end` cannot
    /// be past ``committedSize``. Committed bytes never change except for
    /// the root header's committed size, so from 0 a committed size that
    /// matches `end` is written in place of the file's, which makes the
    /// bytes a complete database by themselves, of the format version this
    /// database has. From anywhere else the bytes are sent as they are.
    ///
    /// - Throws: ``XitDBError/invalidRange`` if `start` is past `end`, `end`
    ///   past the committed size, or `start` inside the root header;
    ///   ``XitDBError/invalidDatabase`` if no trailer ends at `end`, which
    ///   is only checked from 0; ``XitDBError/endOfStream`` if the storage
    ///   ends before `end`; the storage's errors; and the sink's, carried as
    ///   ``XitDBError/callerError(_:)``.
    public func readCommitted<Sink: ByteSink>(from start: UInt64, to end: UInt64, into sink: inout Sink)
        throws(XitDBError)
    {
        try checkRange(from: start, to: end)
        if start == 0 {
            // the bytes must end with a trailer
            _ = try reader.rootTrailer(endingAt: end)
            let header = self.header
            try stream(from: 0, to: header.fileSizePosition, into: &sink)
            let bytes = InlineArray<8, UInt8> { (output: inout OutputSpan<UInt8>) in output.appendBigEndian(end) }
            try XitDBError.carrying { try sink.write(bytes.span) }
            try stream(from: header.dataStart, to: end, into: &sink)
        } else {
            try stream(from: start, to: end, into: &sink)
        }
    }

    /// Appends the committed bytes from `start` up to `end` to `bytes`:
    /// ``readCommitted(from:to:into:)-(_,_,Sink)`` for an array, which knows how many
    /// bytes are coming, makes room for them once, and has them read
    /// straight into it, in one copy.
    ///
    /// - Throws: What ``readCommitted(from:to:into:)-(_,_,Sink)`` throws.
    public func readCommitted(from start: UInt64, to end: UInt64, into bytes: inout [UInt8]) throws(XitDBError) {
        try checkRange(from: start, to: end)
        // the bytes must end with a trailer
        if start == 0 { _ = try reader.rootTrailer(endingAt: end) }

        let first = bytes.count
        bytes.append(contentsOf: repeatElement(0, count: Int(end - start)))
        var span = bytes.mutableSpan
        let read = try storage.read(into: &span, range: first..<(first + Int(end - start)), at: start)
        guard read == Int(end - start) else { throw .endOfStream }
        if start == 0 {
            // the committed size that matches `end`, in place of the file's
            let size = InlineArray<8, UInt8> { (output: inout OutputSpan<UInt8>) in output.appendBigEndian(end) }
            span.copyBytes(from: size.span, count: 8, to: first + Int(header.fileSizePosition))
        }
    }

    /// The checks of `readCommitted`'s range, in Zig's order: a start past
    /// the end is refused before the committed size is read, so that a
    /// replica with no database behind it reports the range and not its
    /// own state.
    ///
    /// - Throws: `invalidRange`, or what ``committedSize`` throws.
    private func checkRange(from start: UInt64, to end: UInt64) throws(XitDBError) {
        if start > end { throw .invalidRange }
        if end > (try reader.committedSize) { throw .invalidRange }
        if start > 0 && start < header.dataStart { throw .invalidRange }
    }

    /// The committed bytes from `start` up to `end`, in memory.
    ///
    /// - Throws: What ``readCommitted(from:to:into:)-(_,_,Sink)`` throws.
    public func readCommitted(from start: UInt64, to end: UInt64) throws(XitDBError) -> [UInt8] {
        var bytes: [UInt8] = []
        try readCommitted(from: start, to: end, into: &bytes)
        return bytes
    }

    /// Writes `count` bytes from `source` at `start` and commits them.
    ///
    /// The bytes must be what ``readCommitted(from:to:into:)-(_,_,Sink)`` gave, so
    /// they end with a trailer. Otherwise than at 0, `start` must be this
    /// database's ``committedSize``: anything past the committed bytes,
    /// such as what an interrupted sync left, is discarded, the bytes are
    /// written, and the root header's committed size is set to where they
    /// end. The commit syncs as any other: the data, then the committed
    /// size, then the size's sync.
    ///
    /// At 0 this database is replaced by the bytes, which are a different
    /// database with its own header. The header is read from the source
    /// and checked before anything is changed: bytes that are no database,
    /// or one of another hash size, leave this database as it was. Then
    /// the storage is emptied, the incoming header is written with an empty
    /// root header and synced, the root header that came with the bytes is
    /// passed over, the rest is written, and the committed size is set once
    /// everything has arrived and ends with a trailer. This database's
    /// ``header`` is the incoming one from the moment the incoming header
    /// is in the storage, its format version included: a replica takes the
    /// version of what it was sent. A sync that fails before that, as on a
    /// storage opened read-only, leaves this database as it was. The bytes
    /// between the database header and the
    /// committed size, which are padding, or in a version 1 file a copy of
    /// the root slot that nothing reads, are not taken from the source: the
    /// replica has zeros there.
    ///
    /// What a failure leaves is what the original leaves. Otherwise than
    /// at 0, bytes that do not end with a trailer, or a source that ends
    /// short, leave what was written past the committed size, which the
    /// next sync or transaction discards. At 0, a failure after the storage
    /// was emptied leaves a database without a first commit: the incoming
    /// header, a committed size of zero, and what arrived. Its
    /// ``replicaState`` is a size of zero and a checksum of zero, to which
    /// the source answers 0, so the next sync replaces it; everything else
    /// throws ``XitDBError/invalidDatabase`` until then, as
    /// ``init(opening:hashSize:)`` says of such a database.
    ///
    /// - Throws: ``XitDBError/invalidRange`` for a `start` that is neither
    ///   0 nor the committed size, and at 0 for a `count` too small to hold
    ///   a database header, or the headers of the version the incoming
    ///   header names, each of which changes nothing;
    ///   ``XitDBError/endOfStream`` if the source runs out before `count`
    ///   bytes, or claims to have given more than its buffer holds;
    ///   ``XitDBError/invalidDatabase`` if the bytes do not end with a
    ///   trailer that checks, or, at 0, do not start with a database
    ///   header, which changes nothing; ``XitDBError/invalidVersion`` and
    ///   ``XitDBError/invalidHashSize`` at 0 for a database of a format
    ///   version this implementation does not read, or of another hash
    ///   size, which change nothing; the storage's errors; and the
    ///   source's, carried as ``XitDBError/callerError(_:)``.
    public func applyReplicated<Source: ByteSource>(at start: UInt64, from source: inout Source, count: UInt64)
        throws(XitDBError)
    {
        var position = start
        var remaining = count
        if start == 0 {
            // The bytes are a different database, with its own header,
            // which is read and checked before this one is touched.
            if count < DatabaseHeader.byteCount { throw .invalidRange }
            let headerBytes = try take(Int(DatabaseHeader.byteCount), from: &source)
            let incoming = try incomingHeader(headerBytes.span)
            position = incoming.dataStart
            if count < position { throw .invalidRange }
            try beginFullCopy(of: incoming, headerBytes: headerBytes.span)
            // The root header that came with the bytes isn't needed.
            _ = try take(Int(position - DatabaseHeader.byteCount), from: &source)
            remaining = count - position
        } else if start == (try reader.committedSize) {
            // discard anything past the committed bytes, such as the remains
            // of an interrupted sync
            try truncate()
        } else {
            throw .invalidRange
        }

        // One buffer for the whole sync: a chunk at most, and never more
        // than what remains, so that the source is never asked for more
        // than the count. As the end nears it is cut down in place, which
        // keeps its storage; a new one for every short read near the end
        // was allocated and zeroed again, once per byte for a source that
        // gives one at a time.
        var buffer = [UInt8](repeating: 0, count: Int(min(remaining, UInt64(Self.streamChunk))))
        while remaining > 0 {
            if remaining < UInt64(buffer.count) {
                buffer.removeLast(buffer.count - Int(remaining))
            }
            var span = buffer.mutableSpan
            let read = try XitDBError.carrying { try source.read(into: &span) }
            guard read > 0, read <= buffer.count else { throw .endOfStream }
            try storage.write(buffer.span.extracting(0..<read), at: position)
            position = try position.offset(by: UInt64(read))
            remaining -= UInt64(read)
        }

        try commitApplied(at: start, count: count)
    }

    /// Writes bytes held in memory at `start` and commits them:
    /// ``applyReplicated(at:from:count:)`` for an array, whose bytes go to
    /// the storage straight from it, with no copy between.
    ///
    /// - Throws: What ``applyReplicated(at:from:count:)`` throws.
    public func applyReplicated(at start: UInt64, bytes: [UInt8]) throws(XitDBError) {
        var position = start
        var first = 0
        if start == 0 {
            // The bytes are a different database, with its own header,
            // which is checked before this one is touched.
            let headerSize = Int(DatabaseHeader.byteCount)
            if bytes.count < headerSize { throw .invalidRange }
            let incoming = try incomingHeader(bytes.span.extracting(0..<headerSize))
            position = incoming.dataStart
            if UInt64(bytes.count) < position { throw .invalidRange }
            try beginFullCopy(of: incoming, headerBytes: bytes.span.extracting(0..<headerSize))
            // The root header that came with the bytes isn't needed.
            first = Int(position)
        } else if start == (try reader.committedSize) {
            // discard anything past the committed bytes, such as the remains
            // of an interrupted sync
            try truncate()
        } else {
            throw .invalidRange
        }
        if first < bytes.count {
            try storage.write(bytes.span.extracting(first..<bytes.count), at: position)
        }
        try commitApplied(at: start, count: UInt64(bytes.count))
    }

    /// The header of the database a sync from 0 brings, from its first
    /// twenty bytes, checked as opening checks one.
    ///
    /// - Throws: `invalidDatabase` for bytes that do not start a database,
    ///   `invalidVersion` for a version this implementation does not read,
    ///   `invalidHashSize` for a hash size that is not this database's.
    private func incomingHeader(_ bytes: Span<UInt8>) throws(XitDBError) -> DatabaseHeader {
        let incoming = try DatabaseHeader(decoding: bytes)
        guard incoming.hashSize == header.hashSize else { throw .invalidHashSize }
        return incoming
    }

    /// Starts a full copy: empties the storage and writes the incoming
    /// database's header, as it came, with an empty root header. From here
    /// until the copy's committed size is written the storage holds a
    /// database without a first commit, which the next sync from 0
    /// replaces if this one does not finish.
    ///
    /// This database becomes the incoming one once that header is in the
    /// storage, and not before: a copy that fails without having changed
    /// the storage, as on one opened read-only, where cutting does nothing
    /// and the first write is refused, leaves this database the one it
    /// was. (The original takes the header before it writes it, and would
    /// go on reading a sound file by another file's ID and version.)
    private func beginFullCopy(of incoming: DatabaseHeader, headerBytes: Span<UInt8>) throws(XitDBError) {
        try storage.truncate(to: 0)
        try storage.write(headerBytes, at: 0)
        become(incoming)
        try writeEmptyRootHeader()
        // Sync the headers before the data, which could otherwise reach
        // the disk without them and leave a file that can't be opened.
        try storage.sync(.beforeRootHeader)
    }

    /// Takes exactly `count` bytes from `source`, however few it gives at
    /// a time, and never asks it for more.
    ///
    /// - Throws: `endOfStream` if the source runs out first or claims to
    ///   have given more than its buffer holds, and the source's own error
    ///   carried as `callerError`.
    private func take<Source: ByteSource>(_ count: Int, from source: inout Source) throws(XitDBError) -> [UInt8] {
        var taken: [UInt8] = []
        taken.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: count)
        while taken.count < count {
            if count - taken.count < buffer.count {
                buffer.removeLast(buffer.count - (count - taken.count))
            }
            var span = buffer.mutableSpan
            let read = try XitDBError.carrying { try source.read(into: &span) }
            guard read > 0, read <= buffer.count else { throw .endOfStream }
            taken.append(contentsOf: buffer[0..<read])
        }
        return taken
    }

    /// What a sync does after `count` bytes were written from `start`: the
    /// bytes must end with a trailer, and the root header's committed size
    /// is set to where they end, with the syncs of a commit.
    private func commitApplied(at start: UInt64, count: UInt64) throws(XitDBError) {
        guard count > 0 else { return }
        _ = try reader.rootTrailer(endingAt: try start.offset(by: count))
        try storage.sync(.beforeRootHeader)
        try writeRootHeader()
        try storage.sync(.afterRootHeader)
    }

    /// The size of the chunks the streams move: large enough that a file is
    /// read or written in few calls, small enough to sit in a buffer.
    private static let streamChunk = 256 * 1024

    /// Streams the storage's bytes from `start` up to `end` into `sink`.
    ///
    /// - Throws: `endOfStream` if the storage ends first.
    private func stream<Sink: ByteSink>(from start: UInt64, to end: UInt64, into sink: inout Sink)
        throws(XitDBError)
    {
        var buffer = [UInt8](repeating: 0, count: Self.streamChunk)
        var position = start
        while position < end {
            var span = buffer.mutableSpan
            let chunk = Int(min(end - position, UInt64(Self.streamChunk)))
            let read = try storage.read(into: &span, range: 0..<chunk, at: position)
            guard read == chunk else { throw .endOfStream }
            try XitDBError.carrying { try sink.write(buffer.span.extracting(0..<chunk)) }
            position += UInt64(chunk)
        }
    }
}
