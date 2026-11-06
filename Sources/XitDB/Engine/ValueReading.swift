// Reading the value a slot holds: byte arrays, key-value pairs and counts.

extension DatabaseReader {
    /// Reads the byte array a slot holds, with its format tag.
    ///
    /// An empty slot reads as no bytes.
    ///
    /// - Parameter maxSize: The most bytes to read, or `nil` for no limit.
    /// - Throws: `streamTooLong` if the value is larger than `maxSize`,
    ///   `unexpectedTag` if the slot does not hold bytes, or `endOfStream`
    ///   if the storage ends before the value does.
    func bytesObject(_ slot: Slot, maxSize: Int?) throws(XitDBError) -> Bytes {
        switch slot.tag {
        case .none:
            return Bytes([])
        case .bytes:
            let size = try uint64(at: slot.value)
            if let maxSize, size > UInt64(max(maxSize, 0)) { throw .streamTooLong }
            let start = try slot.value.offset(by: ByteArrayFormat.lengthByteCount)
            // A size that the storage cannot hold comes from a corrupt file.
            // It must not be allocated.
            let length = try storage.length()
            guard start <= length, size <= length - start, let count = Int(exactly: size) else {
                throw .endOfStream
            }
            var value = [UInt8](repeating: 0, count: count)
            var span = value.mutableSpan
            let read = try storage.read(into: &span, at: start)
            guard read == count else { throw .endOfStream }
            return Bytes(value, formatTag: try formatTag(of: slot, valueStart: start, size: size))
        case .shortBytes:
            let count = ByteArrayFormat.shortByteCount(of: slot)
            if let maxSize, count > maxSize { throw .streamTooLong }
            let bytes = ByteArrayFormat.valueBytes(of: slot)
            var value: [UInt8] = []
            value.reserveCapacity(count)
            for index in 0..<count {
                value.append(bytes[index])
            }
            return Bytes(value, formatTag: ByteArrayFormat.shortFormatTag(of: slot))
        default:
            throw .unexpectedTag
        }
    }

    /// Reads the byte array a slot holds into `buffer`.
    ///
    /// An empty slot reads as no bytes, whatever the buffer's size. Zig
    /// reports the end of the stream there unless the buffer is empty, while
    /// its allocating read gives no bytes; here both give no bytes.
    ///
    /// - Returns: The number of bytes read and the value's format tag.
    /// - Throws: `streamTooLong` if the value does not fit in `buffer`,
    ///   `unexpectedTag` if the slot does not hold bytes, or `endOfStream`
    ///   if the storage ends before the value does.
    func bytesObject(
        _ slot: Slot,
        into buffer: inout MutableSpan<UInt8>
    ) throws(XitDBError) -> (count: Int, formatTag: InlineArray<2, UInt8>?) {
        switch slot.tag {
        case .none:
            return (0, nil)
        case .bytes:
            let size = try uint64(at: slot.value)
            if size > UInt64(buffer.count) { throw .streamTooLong }
            let count = Int(size)
            let start = try slot.value.offset(by: ByteArrayFormat.lengthByteCount)
            if count == buffer.count {
                let read = try storage.read(into: &buffer, at: start)
                guard read == count else { throw .endOfStream }
            } else {
                // The value is shorter than the buffer, and a storage reads
                // as many bytes as the buffer it is given holds. So that the
                // rest of the caller's buffer is left alone, the value is
                // read through a small buffer on the stack.
                var chunk = InlineArray<512, UInt8>(repeating: 0)
                var done = 0
                while done < count {
                    var span = chunk.mutableSpan
                    let read = try storage.read(into: &span, at: try start.offset(by: UInt64(done)))
                    let taken = min(read, count - done)
                    guard taken > 0 else { throw .endOfStream }
                    buffer.copyBytes(from: chunk.span, count: taken, to: done)
                    done += taken
                }
            }
            return (count, try formatTag(of: slot, valueStart: start, size: size))
        case .shortBytes:
            let count = ByteArrayFormat.shortByteCount(of: slot)
            if count > buffer.count { throw .streamTooLong }
            let bytes = ByteArrayFormat.valueBytes(of: slot)
            for index in 0..<count {
                buffer[index] = bytes[index]
            }
            return (count, ByteArrayFormat.shortFormatTag(of: slot))
        default:
            throw .unexpectedTag
        }
    }

    /// The format tag stored after a `bytes` record's value, if the slot
    /// says there is one.
    private func formatTag(
        of slot: Slot,
        valueStart: UInt64,
        size: UInt64
    ) throws(XitDBError) -> InlineArray<2, UInt8>? {
        guard slot.full else { return nil }
        return try bytes(at: try valueStart.offset(by: size))
    }

    /// Reads the key-value pair that an entry slot stands for.
    ///
    /// An entry is either a pointer to a pair (`kvPair`, `sortedKvPair`) or,
    /// in a sorted set, a key on its own (`bytes`, `shortBytes`), whose
    /// value is empty. Only a `kvPair` has a hash; the others report zeros.
    ///
    /// - Throws: `unexpectedTag` if the slot is not an entry.
    func keyValuePair(_ entry: Slot) throws(XitDBError) -> (hash: KeyHash, pair: KeyValuePair) {
        if KeyValuePair.isKeyOnlyEntry(entry) {
            return (zeroHash(), KeyValuePair(keySlot: entry, valueSlot: Slot()))
        }
        switch entry.tag {
        case .kvPair: return try hashedPair(at: entry.value)
        case .sortedKvPair: return (zeroHash(), try sortedPair(at: entry.value))
        default: throw .unexpectedTag
        }
    }

    private func zeroHash() -> KeyHash {
        KeyHash([UInt8](repeating: 0, count: Int(hashSize)))
    }

    /// The number of elements in the collection a slot holds, or of bytes in
    /// its byte array. Only headers are read.
    ///
    /// - Throws: `unexpectedTag` for a slot that has no count: a number, or
    ///   a hash map or set that does not keep one.
    func count(_ slot: Slot) throws(XitDBError) -> UInt64 {
        switch slot.tag {
        case .none: return 0
        case .arrayList: return try arrayListHeader(at: slot.value).size
        case .linkedArrayList, .sortedMap, .sortedSet: return try bTreeHeader(at: slot.value).size
        case .bytes: return try uint64(at: slot.value)
        case .shortBytes: return UInt64(ByteArrayFormat.shortByteCount(of: slot))
        case .countedHashMap, .countedHashSet: return try uint64(at: slot.value)
        default: throw .unexpectedTag
        }
    }
}
