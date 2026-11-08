import Synchronization

/// Tells the snapshots of a file storage that the file was rewritten below
/// what they read, so that they refuse their reads instead of decoding
/// another database's bytes at the old offsets.
///
/// The storage trips it before the write or truncation that invalidates
/// them and then starts a new fence for the snapshots taken afterwards; a
/// snapshot checks it after every read of the file. The order matters: a
/// read that saw any byte of the new contents was made after the
/// truncation, which was made after the fence was tripped, so it finds the
/// fence tripped.
final class SnapshotFence: Sendable {
    private let overwritten = Atomic<Bool>(false)

    init() {}

    /// Marks every snapshot holding this fence as overwritten.
    func trip() {
        overwritten.store(true, ordering: .sequentiallyConsistent)
    }

    /// Whether the fence was tripped.
    var isTripped: Bool {
        overwritten.load(ordering: .sequentiallyConsistent)
    }
}

/// The read half of one commit of a storage: what a ``Snapshot`` reads
/// through, from any thread at once.
///
/// Reads stop at the commit's size and ``length`` is that size, so nothing
/// read through it reaches what the writer has appended since. The bytes
/// are in memory, an array shared copy-on-write with a ``MemoryStorage`` or
/// copied once from a storage of the caller's own, or in a file, read
/// through the descriptor the storage reads through, at offsets, which the
/// system allows from any thread.
///
/// A storage of the caller's own is never called through this: its read
/// half is the copy.
struct SnapshotStorage: ReadableStorage, Sendable {
    /// Where the bytes are.
    enum Source: Sendable {
        /// Bytes in memory, at least `committedSize` of them.
        case bytes([UInt8])
        /// A file, read through its storage's descriptor, and the fence the
        /// storage trips before it rewrites the file below the committed
        /// size.
        case file(FileDescriptor, SnapshotFence)
    }

    let source: Source

    /// The commit's size: every read stops here.
    let committedSize: UInt64

    /// A read half over bytes in memory, which hold the commit's first
    /// `committedSize` bytes and maybe more, which are never read.
    init(bytes: [UInt8], committedSize: UInt64) {
        precondition(UInt64(bytes.count) >= committedSize, "the bytes do not reach the committed size")
        source = .bytes(bytes)
        self.committedSize = committedSize
    }

    /// A read half over a file, through its storage's descriptor.
    init(file descriptor: FileDescriptor, fence: SnapshotFence, committedSize: UInt64) {
        source = .file(descriptor, fence)
        self.committedSize = committedSize
    }

    /// Reads the commit's bytes that start at `offset` into a part of
    /// `buffer`, as many as fit there and lie below the committed size.
    ///
    /// - Throws: ``XitDBError/snapshotOverwritten`` if the file was
    ///   rewritten below the committed size since the snapshot was taken,
    ///   whatever this read saw; ``XitDBError/storageFailure(errno:)`` if
    ///   reading the file fails.
    /// - Precondition: `range` lies within `buffer`.
    func read(
        into buffer: inout MutableSpan<UInt8>,
        range: Range<Int>,
        at offset: UInt64
    ) throws(XitDBError) -> Int {
        precondition(range.lowerBound >= 0 && range.upperBound <= buffer.count, "the range is out of bounds")
        guard offset < committedSize else { return 0 }
        let count = Int(min(UInt64(range.count), committedSize - offset))
        switch source {
        case .bytes(let bytes):
            buffer.copyBytes(from: bytes.span, at: Int(offset), count: count, to: range.lowerBound)
            return count
        case .file(let descriptor, let fence):
            let bounded = range.lowerBound..<(range.lowerBound + count)
            let read = try Platform.readFile(descriptor.rawValue, into: &buffer, range: bounded, at: offset)
            // After the read, so that a read which saw the new contents
            // sees the fence tripped.
            if fence.isTripped { throw .snapshotOverwritten }
            return read
        }
    }

    /// The commit's size. This never throws.
    var length: UInt64 {
        get throws(XitDBError) {
            committedSize
        }
    }
}
