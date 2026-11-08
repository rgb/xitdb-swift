// Opening a database whose root header cannot be trusted, and recovering
// one (decision D19, as D22 item 4 settled it): opening refuses and names
// the last commit that verifies; a separate call cuts the storage back to
// it. Nothing is dropped except by that call.

extension DatabaseReader {
    /// Checks the root header as opening a database does.
    ///
    /// The root header is trusted when its committed size is at least a new
    /// database's, within the storage, and ends at a trailer whose checksum
    /// verifies: exactly when ``rootHeader()`` reads it. Otherwise the
    /// storage is scanned for the last trailer that verifies, so that the
    /// error can name where a recovery would cut.
    ///
    /// - Throws: `untrustedRootHeader(lastVerified:)` if the root header
    ///   cannot be trusted and some trailer verifies; `invalidDatabase` if
    ///   none does, as there is no commit to recover to; `endOfStream` if
    ///   the storage ends inside the root header; `invalidEnumTag` if the
    ///   trailer the root header names verifies but its root slot's tag is
    ///   unknown.
    func verifyRootHeader() throws(XitDBError) {
        do {
            _ = try rootHeader()
        } catch .invalidDatabase, .truncatedDatabase {
            guard let lastVerified = try lastVerifiedCommitEnd() else { throw .invalidDatabase }
            throw .untrustedRootHeader(lastVerified: lastVerified)
        }
    }

    /// The position after the last trailer whose checksum verifies,
    /// scanning back from the end of the storage, or `nil` if none does.
    ///
    /// A trailer's checksum covers the file ID, the position the trailer
    /// was written at and its own seventeen bytes, so a trailer of another
    /// file, or one that has moved, does not verify, and its sixty-four bits
    /// make a chance match negligible. That is what makes the scan safe:
    /// the first trailer found from the end is the end of a commit of this
    /// file.
    ///
    /// Every position from the storage's length down to the size of a new
    /// database is tried as the end of a trailer. The storage is read in
    /// windows from the end back, each overlapping the one before by one
    /// byte less than a trailer, so that a trailer across a window's edge
    /// is seen whole in the next.
    ///
    /// - Throws: `endOfStream` if the storage ends before its length said,
    ///   or ``XitDBError/storageFailure(errno:)`` if the storage fails.
    func lastVerifiedCommitEnd() throws(XitDBError) -> UInt64? {
        let length = try storage.length
        guard length >= RootHeader.minimumFileSize else { return nil }
        let trailerSize = Int(RootTrailer.byteCount)
        let window = UInt64(Self.scanWindow)
        // The first trailer starts right after the root header.
        let lowest = RootHeader.endPosition
        // Every trailer's checksum starts with the file ID.
        var fileChecksum = CRC64XZ()
        fileChecksum.updateBigEndian(fileID)

        var buffer = [UInt8](repeating: 0, count: Self.scanWindow)
        var end = length
        while true {
            let start = max(lowest, end > window ? end - window : 0)
            let count = Int(end - start)
            var span = buffer.mutableSpan
            let read = try storage.read(into: &span, range: 0..<count, at: start)
            guard read == count else { throw .endOfStream }
            var offset = count - trailerSize
            while offset >= 0 {
                let position = start + UInt64(offset)
                var checksum = fileChecksum
                checksum.updateBigEndian(position)
                checksum.update(buffer.span, at: offset, count: 17)
                let recorded: UInt64 = buffer.span.bigEndian(at: offset + 17)
                if checksum.checksum == recorded {
                    return position + RootTrailer.byteCount
                }
                offset -= 1
            }
            if start == lowest { return nil }
            end = start + UInt64(trailerSize - 1)
        }
    }

    /// The size of the windows the scan reads: large enough that a scan
    /// over a damaged tail is a few reads, small enough to sit in a buffer.
    static let scanWindow = 64 * 1024
}

extension Database {
    /// Reads the header at the start of a storage, as opening does.
    ///
    /// - Throws: `invalidDatabase` if the storage is empty or does not
    ///   start with the magic bytes, `endOfStream` if it is too short to
    ///   hold a header, or `invalidVersion` if the version is one this
    ///   implementation does not read.
    static func readHeader(of storage: any ReadableStorage) throws(XitDBError) -> DatabaseHeader {
        var buffer = InlineArray<20, UInt8>(repeating: 0)
        var span = buffer.mutableSpan
        let read = try storage.read(into: &span, at: 0)
        if read == 0 { throw .invalidDatabase }
        return try DatabaseHeader(decoding: buffer.span.extracting(0..<read))
    }

    /// Recovers a database whose root header cannot be trusted, by cutting
    /// the storage back to the last commit whose trailer verifies, and
    /// opens it.
    ///
    /// This is the call for a storage that ``init(opening:hashSize:)``
    /// refused with ``XitDBError/untrustedRootHeader(lastVerified:)``: a
    /// crash, a failed write or a damaged sector has left a root header
    /// whose committed size is past the end of the storage, smaller than a
    /// database can be, or not at a trailer whose checksum verifies. The
    /// storage is scanned from its end back for the last trailer that
    /// verifies, as the error's `lastVerified` was found; the storage is
    /// cut off after that trailer; the root header is written for it, that
    /// trailer's root slot and that position as the committed size; the
    /// storage is synced, as after a commit's root header; and the database
    /// is opened. Nothing else is written, and nothing is drawn from the
    /// system's randomness: the recovered database draws its commit IDs
    /// from it as an opened one does.
    ///
    /// **A commit may be lost by this call.** Everything after the last trailer
    /// that verifies is discarded: a commit whose trailer was damaged, and
    /// whatever followed it. This is the only call that cuts a database back to
    /// an earlier commit of its own; opening a damaged database fails instead,
    /// and its bytes stay as they were until this is called. Copy the storage
    /// first if the discarded bytes might be wanted. <doc:Recovery> says what
    /// opening does with a root header it cannot trust and what recovering can
    /// lose.
    ///
    /// The scan goes by the trailers alone, not by the root header. On a
    /// storage whose root header is sound this still cuts to the last
    /// trailer that verifies: usually the one the root header names, and
    /// only the root header is rewritten; but a transaction whose trailer
    /// reached the storage and whose root header did not, as a process that
    /// died between the two leaves, lies past the committed size with a
    /// trailer that verifies, and this call commits it.
    ///
    /// - Parameter storage: Where the database's bytes are. It must be
    ///   writable; the database becomes the only writer to it.
    /// - Returns: The recovered database, open.
    /// - Throws: ``XitDBError/invalidDatabase`` if the storage is empty or
    ///   does not start with a database header, or holds no trailer that
    ///   verifies, so that there is no commit to recover to; in both the
    ///   storage is left as it was. ``XitDBError/invalidVersion`` if the
    ///   format's version is one this implementation does not read;
    ///   ``XitDBError/endOfStream`` if the storage is too short to hold a
    ///   header, or ends before its length said; ``XitDBError/invalidEnumTag``
    ///   if the trailer found has a root slot whose tag is unknown;
    ///   ``XitDBError/storageFailure(errno:)`` if the storage fails, which
    ///   a storage opened read-only does at the root header's write; and
    ///   what ``init(opening:hashSize:)`` throws, which the storage this
    ///   call has just written does not raise.
    public static func recover(_ storage: any WritableStorage) throws(XitDBError) -> Database {
        try recover(storage, random: RandomSource(SystemRandomNumberGenerator()))
    }

    /// Recovers a database with a given source of randomness for the
    /// recovered database's commit IDs. The recovery itself draws nothing.
    package static func recover(_ storage: any WritableStorage, random: any RandomNumberGenerator)
        throws(XitDBError) -> Database
    {
        try recover(storage, random: RandomSource(random))
    }

    /// Recovers a database whose recovered database draws its commit IDs
    /// from a source another database draws from.
    ///
    /// - Throws: What ``recover(_:)`` throws.
    package static func recover(_ storage: any WritableStorage, random: RandomSource) throws(XitDBError) -> Database {
        let header = try readHeader(of: storage)
        let reader = DatabaseReader(storage: storage, identity: DatabaseIdentity(header: header))
        guard let lastVerified = try reader.lastVerifiedCommitEnd() else { throw .invalidDatabase }
        let trailer = try reader.rootTrailer(endingAt: lastVerified)

        if try storage.length > lastVerified {
            try storage.truncate(to: lastVerified)
        }
        let rootHeader = RootHeader(root: trailer.root, fileSize: lastVerified)
        let rootHeaderBytes = InlineArray<17, UInt8> { (output: inout OutputSpan<UInt8>) in
            rootHeader.encode(into: &output)
        }
        try storage.write(rootHeaderBytes.span, at: RootHeader.position)
        // The data was synced by the commit that wrote it. This is the
        // commit's second sync, for the root header.
        try storage.sync(.afterRootHeader)
        return try Database(opening: storage, hashSize: nil, random: random)
    }
}
