/// A byte array being written at the end of the storage: the state of Zig's
/// `Cursor.Writer`.
///
/// The record starts with an eight-byte length, which is written as zero
/// first and filled in when the array is finished. The bytes follow. The
/// array can only grow while it is still the last thing in the storage.
struct ByteRecordWriter: ~Copyable {
    private let database: Database

    /// The number of bytes in the array so far.
    private(set) var size: UInt64 = 0

    /// The slot that will point at the record once it is finished.
    private var slot: Slot

    /// Where the array's bytes start, after the length.
    private let startPosition: UInt64

    /// Where in the array the next write goes.
    private var position: UInt64 = 0

    /// A format tag to store after the bytes, or `nil` for none.
    var formatTag: FormatTag?

    /// Starts a byte array for the slot at `pointer`.
    ///
    /// - Throws: `cursorNotWritable` for the root slot, which bytes are
    ///   written to with a `write` inside a transaction, or
    ///   `expectedTxStart` outside a transaction.
    init(database: Database, at pointer: SlotPointer) throws(XitDBError) {
        if pointer.position == RootHeader.position { throw .cursorNotWritable }
        guard database.transactionStart != nil else { throw .expectedTxStart }
        let recordPosition = try database.storage.length
        try database.write(0 as UInt64, at: recordPosition)
        let startPosition = try recordPosition.offset(by: ByteArrayFormat.lengthByteCount)
        self.database = database
        self.slot = Slot(value: recordPosition, tag: .bytes)
        self.startPosition = startPosition
    }

    /// Writes bytes at the current position and moves it past them.
    ///
    /// - Throws: `expectedTxStart` outside a transaction, or
    ///   `unexpectedWriterPosition` if the write would make the array longer
    ///   and something else has been written after it since it was started
    ///   (Zig reports both as `WriteFailed`, which is all its writer
    ///   interface can report), or if the position, after a far `seek`,
    ///   lies beyond any position a storage has (Zig traps on the sum).
    mutating func write(_ bytes: Span<UInt8>) throws(XitDBError) {
        guard bytes.count > 0 else { return }
        guard database.transactionStart != nil else { throw .expectedTxStart }
        // A position that no storage can hold is the writer's own error,
        // not the storage's and not the end of a stream: nothing is read,
        // and the storage is not asked.
        let (newPosition, overflow) = position.addingReportingOverflow(UInt64(bytes.count))
        let (writePosition, beyond) = startPosition.addingReportingOverflow(position)
        if overflow || beyond { throw .unexpectedWriterPosition }

        // Another record may now follow this byte array. Extending the array
        // would overwrite it.
        if newPosition > size {
            let end = try database.storage.length
            if end != (try startPosition.offset(by: size)) { throw .unexpectedWriterPosition }
        }

        try database.storage.write(bytes, at: writePosition)
        database.noteWrite()
        position = newPosition
        if position > size {
            size = position
        }
    }

    /// Moves the position of the next write. Writing beyond the end of the
    /// array leaves zeros in between.
    mutating func seek(to offset: UInt64) {
        position = offset
    }

    /// Completes the array: writes its format tag and its length, and points
    /// the slot at `slotPosition` to it.
    ///
    /// - Returns: The slot that now points at the array.
    /// - Throws: `expectedTxStart` outside a transaction,
    ///   `unexpectedWriterPosition` if a format tag is to be written and the
    ///   array is no longer the last thing in the storage, or
    ///   `cursorNotWritable` if the slot has no position.
    mutating func finish(slotPosition: UInt64?) throws(XitDBError) -> Slot {
        guard database.transactionStart != nil else { throw .expectedTxStart }

        if let formatTag {
            // A byte array with a format tag is marked by its slot's flag.
            slot.full = true
            let tagPosition = try database.storage.length
            if (try startPosition.offset(by: size)) != tagPosition { throw .unexpectedWriterPosition }
            try database.storage.write(formatTag.bytes.span, at: tagPosition)
            database.noteWrite()
        }

        try database.write(size, at: slot.value)

        guard let slotPosition else { throw .cursorNotWritable }
        try database.write(slot, at: slotPosition)
        return slot
    }
}
