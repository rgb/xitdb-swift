/// Reads the bytes of a byte array a part at a time, for
/// ``Cursor/reader()``.
///
/// It is Zig's `Cursor.Reader`. A reader has a position in the value,
/// which every read moves forward and ``seek(to:)`` sets. It reads the
/// value its cursor held when the reader was made, like the cursor's other
/// reads.
///
/// Nothing is buffered. Each read of a long value is one read of the
/// storage, so read in parts of a useful size rather than a byte at a time.
/// A value of up to eight bytes is stored in the cursor's slot, and reading
/// it does not touch the storage.
public struct ByteReader {
    private let database: DatabaseReader

    /// Where the value's bytes start in the storage. Not used for a short
    /// value.
    private let startPosition: UInt64

    /// The bytes of a short value, which is stored in its slot.
    private let shortBytes: InlineArray<8, UInt8>?

    /// The number of bytes in the value.
    public let size: UInt64

    /// Where in the value the next read starts. It can lie beyond the end,
    /// after a ``seek(to:)``; nothing is read there.
    public private(set) var position: UInt64 = 0

    /// A reader of a value that is stored in the storage.
    init(database: DatabaseReader, startPosition: UInt64, size: UInt64) {
        self.database = database
        self.startPosition = startPosition
        self.shortBytes = nil
        self.size = size
    }

    /// A reader of a value that is stored in a slot.
    init(database: DatabaseReader, shortBytes: InlineArray<8, UInt8>, size: Int) {
        self.database = database
        self.startPosition = 0
        self.shortBytes = shortBytes
        self.size = UInt64(size)
    }

    /// Reads as many bytes as fit in `buffer` and are left in the value,
    /// from the reader's position, and moves the position past them.
    ///
    /// - Parameter buffer: Where to put the bytes. They are written from its
    ///   start, and the rest of it is left as it was.
    /// - Returns: The number of bytes read, which is zero at the end of the
    ///   value and beyond it.
    /// - Throws: ``XitDBError/endOfStream`` if the database ends before the
    ///   value does, which only a damaged file does.
    public mutating func read(into buffer: inout MutableSpan<UInt8>) throws(XitDBError) -> Int {
        guard position < size else { return 0 }
        let count = Int(min(UInt64(buffer.count), size - position))
        guard count > 0 else { return 0 }
        if let shortBytes {
            let start = Int(position)
            for index in 0..<count {
                buffer[index] = shortBytes[start + index]
            }
        } else {
            let offset = try startPosition.offset(by: position)
            let read = try database.storage.read(into: &buffer, range: 0..<count, at: offset)
            guard read == count else { throw .endOfStream }
        }
        position += UInt64(count)
        return count
    }

    /// Fills `buffer` from the reader's position, and moves the position
    /// past the bytes read.
    ///
    /// - Parameter buffer: Where to put the bytes.
    /// - Throws: ``XitDBError/endOfStream`` if fewer bytes than `buffer`
    ///   holds are left in the value. The bytes that were left have then
    ///   been read into the start of `buffer`, and the position is at the
    ///   end of the value or where a ``seek(to:)`` beyond it put it.
    public mutating func readAll(into buffer: inout MutableSpan<UInt8>) throws(XitDBError) {
        let read = try read(into: &buffer)
        if read != buffer.count { throw .endOfStream }
    }

    /// Reads everything from the reader's position to the end of the value,
    /// and moves the position there.
    ///
    /// - Parameter maxCount: The most bytes to accept, or `nil` for no
    ///   limit.
    /// - Returns: The bytes, which are none at the end of the value and
    ///   beyond it.
    /// - Throws: ``XitDBError/streamTooLong`` if more than `maxCount` bytes
    ///   are left, or ``XitDBError/endOfStream`` if the database ends before
    ///   the value does.
    public mutating func readRemaining(maxCount: Int? = nil) throws(XitDBError) -> [UInt8] {
        guard position < size else { return [] }
        let remaining = size - position
        if let maxCount, remaining > UInt64(max(maxCount, 0)) { throw .streamTooLong }
        if shortBytes == nil {
            // A size that the storage cannot hold comes from a damaged file.
            // It must not be allocated.
            let start = try startPosition.offset(by: position)
            let length = try database.storage.length
            guard start <= length, remaining <= length - start else { throw .endOfStream }
        }
        guard let count = Int(exactly: remaining) else { throw .endOfStream }
        var value = [UInt8](repeating: 0, count: count)
        var span = value.mutableSpan
        try readAll(into: &span)
        return value
    }

    /// Moves the reader's position.
    ///
    /// - Parameter offset: The position in the value of the next byte to
    ///   read. Beyond the end of the value there is nothing to read.
    public mutating func seek(to offset: UInt64) {
        position = offset
    }
}

extension Cursor {
    /// A reader of the slot's byte array, for reading it a part at a time.
    ///
    /// The reader reads the value this cursor holds now: if the slot is
    /// written afterwards, the reader does not notice. A slot set to nothing
    /// reads as no bytes, as it does with ``readBytes(maxCount:)``.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot does not hold
    ///   bytes, or ``XitDBError/endOfStream`` if the database ends where the
    ///   value's length should be.
    public func reader() throws(XitDBError) -> ByteReader {
        let slot = try resolved().slot
        switch slot.tag {
        case .none:
            return ByteReader(database: database.reader, startPosition: 0, size: 0)
        case .bytes:
            let size = try database.reader.uint64(at: slot.value)
            let start = try slot.value.offset(by: ByteArrayFormat.lengthByteCount)
            return ByteReader(database: database.reader, startPosition: start, size: size)
        case .shortBytes:
            // The value is in the slot, so it is read from there, whether
            // or not the slot has a position. Zig reads it from the slot's
            // position in the file, which fails for a slot without one and
            // gives other bytes once the slot has been overwritten.
            return ByteReader(
                database: database.reader,
                shortBytes: ByteArrayFormat.valueBytes(of: slot),
                size: ByteArrayFormat.shortByteCount(of: slot)
            )
        default:
            throw .unexpectedTag
        }
    }
}
