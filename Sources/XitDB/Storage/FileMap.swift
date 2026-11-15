// Reading a file through a memory map (decision D44): the file storage's
// other way of reading, asked for when it is opened. The file is mapped in
// segments of a fixed size, each mapped once, whole, when a read first
// reaches into it, and shared by the storage and every snapshot of a
// database in it. Writes stay file writes; nothing is written through a
// mapping.
//
// What makes it sound is not in this file's types but in three rules the
// file storage keeps: only bytes known to be in the file are read through
// a mapping; the file is never cut below what a live snapshot reads; and
// the storage holds a lock on its file. A read of a mapped page that lies
// beyond the end of the file is a signal that ends the process, which no
// check here could turn into an error.

/// One segment of a file, mapped into memory for reading.
///
/// The segment owns its mapping: made when the segment is, unmapped when
/// the last reference to the segment goes. It holds the mapping's address
/// as an integer, so that it is `Sendable` with nothing unchecked, and it
/// is the one place where a pointer is made of that address.
final class MappedSegment: Sendable {
    /// Where the mapping is.
    private let address: UInt

    /// The number of bytes mapped, which may reach beyond the end of the
    /// file.
    let length: Int

    /// Maps `length` bytes of the file from `offset`.
    ///
    /// - Parameters:
    ///   - offset: A multiple of the page size.
    ///   - length: More than zero.
    ///   - map: The call that maps, which a test replaces to refuse.
    /// - Returns: `nil` if the system refuses the mapping, as it does when
    ///   the address space is used up.
    init?(
        descriptor: Int32, offset: UInt64, length: Int,
        map: (Int32, UInt64, Int) -> (address: UInt, error: Int32) = Platform.mapFile
    ) {
        let mapped = map(descriptor, offset, length)
        guard mapped.error == 0 else { return nil }
        address = mapped.address
        self.length = length
    }

    deinit {
        Platform.unmapFile(address: address, length: length)
    }

    /// Copies `count` bytes of the segment, from `offset` bytes into it, to
    /// `buffer` at `destination`.
    ///
    /// The range is checked against the segment, and a range outside it is
    /// a trap. That the bytes are in the file is the caller's to know: the
    /// segment may be longer than the file.
    ///
    /// - Precondition: The range lies within the segment, and the
    ///   destination's within `buffer`.
    func copyBytes(at offset: Int, count: Int, into buffer: inout MutableSpan<UInt8>, at destination: Int) {
        precondition(offset >= 0 && count >= 0 && count <= length - offset, "a read outside the mapped segment")
        guard count > 0 else { return }
        // Safe: the address and the length are those of a mapping that
        // lives as long as this object, which the caller holds for the
        // call; the mapping is read-only and nothing is written through
        // the pointer; the span is used for this one copy, whose range was
        // checked above, and does not leave the function.
        let mapped = unsafe Span<UInt8>(
            _unsafeBytes: UnsafeRawBufferPointer(start: UnsafeRawPointer(bitPattern: address), count: length))
        buffer.copyBytes(from: mapped, at: offset, count: count, to: destination)
    }
}

/// What every snapshot that reads a file through its memory map holds of
/// the storage, and the storage holds too: while a second reference to it
/// exists, such a snapshot is alive, and the storage refuses to cut the
/// file below what the snapshot reads.
final class MapLease: Sendable {
    init() {}
}

/// The mapped segments of a file, in order from its start: what the file
/// storage reads through, and what a snapshot takes a copy of.
///
/// A copy shares the segments. A snapshot's copy also holds the storage's
/// ``MapLease``, which is how the storage knows of it.
struct FileMapView: Sendable {
    /// The size of every segment: a power of two and a multiple of the
    /// page size.
    let segmentSize: Int

    /// The segments, each at its index times ``segmentSize`` in the file.
    /// `nil` where a segment is not mapped: not yet, or because the system
    /// refused it.
    var segments: [MappedSegment?] = []

    /// The storage's lease, in a snapshot's copy.
    var lease: MapLease?

    init(segmentSize: Int) {
        precondition(
            segmentSize > 0 && segmentSize & (segmentSize - 1) == 0 && segmentSize % Platform.pageSize == 0,
            "a segment's size is a power of two and a multiple of the page size")
        self.segmentSize = segmentSize
    }

    /// The index of the segment that holds the byte at `offset`.
    func segmentIndex(of offset: UInt64) -> Int {
        Int(offset / UInt64(segmentSize))
    }

    /// Copies the bytes of the file that start at `offset` into a part of
    /// `buffer`, as many as fit there, lie below `limit` and are in
    /// segments that are mapped, from the first byte on.
    ///
    /// - Parameter limit: The number of bytes at the start of the file
    ///   that are known to be in it. No byte at or beyond it is read.
    /// - Returns: The number of bytes copied, which is less than
    ///   `range.count` where the limit or a segment that is not mapped
    ///   comes first: the caller reads the rest by a file call.
    /// - Precondition: `range` lies within `buffer`.
    func read(into buffer: inout MutableSpan<UInt8>, range: Range<Int>, at offset: UInt64, limit: UInt64) -> Int {
        precondition(range.lowerBound >= 0 && range.upperBound <= buffer.count, "the range is out of bounds")
        guard offset < limit else { return 0 }
        let count = Int(min(UInt64(range.count), limit - offset))
        var done = 0
        while done < count {
            let position = offset + UInt64(done)
            let index = segmentIndex(of: position)
            guard index < segments.count, let segment = segments[index] else { break }
            let start = Int(position % UInt64(segmentSize))
            let step = min(count - done, segmentSize - start)
            segment.copyBytes(at: start, count: step, into: &buffer, at: range.lowerBound + done)
            done += step
        }
        return done
    }
}
