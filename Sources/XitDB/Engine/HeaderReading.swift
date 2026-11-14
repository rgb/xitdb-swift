extension DatabaseHeader {
    /// Reads the header of the database in a storage, without opening the
    /// database.
    ///
    /// This is for choosing how to open one. The header's ``hashSize`` and
    /// ``hashID`` say which hash the database's keys were hashed with, so a
    /// program that reads databases of more than one hash reads the header
    /// first, picks the hasher by it and opens with
    /// ``Database/init(opening:hashing:)``.
    ///
    /// The header's twenty bytes are read and nothing else, and nothing is
    /// written. The root header is not looked at, so a header that reads
    /// says nothing about whether the database opens: a storage that holds
    /// a creation that did not finish, or a damaged database, has a header
    /// that reads.
    ///
    /// - Parameter storage: Where the database's bytes are.
    /// - Throws: ``XitDBError/invalidDatabase`` if the storage is empty or
    ///   its twenty bytes do not start as a database does;
    ///   ``XitDBError/endOfStream`` if it holds bytes, but fewer than
    ///   twenty;
    ///   ``XitDBError/invalidVersion`` if the database was written in a
    ///   version of the format this implementation does not read; and
    ///   ``XitDBError/storageFailure(errno:)`` if the storage fails.
    public init(reading storage: any ReadableStorage) throws(XitDBError) {
        var buffer = InlineArray<20, UInt8>(repeating: 0)
        var span = buffer.mutableSpan
        let read = try storage.read(into: &span, at: 0)
        if read == 0 { throw .invalidDatabase }
        try self.init(decoding: buffer.span.extracting(0..<read))
    }
}
