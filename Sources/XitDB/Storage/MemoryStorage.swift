/// A growable run of bytes with the read, write and truncate rules of a
/// storage. It is the state of a ``MemoryStorage`` and the window of a
/// ``BufferedFileStorage``, as Zig's `CoreMemory` is for its two.
struct MemoryBuffer {
    private(set) var bytes: [UInt8]

    /// The most bytes the buffer may grow to, or `nil` for no limit.
    let maxSize: UInt64?

    init(bytes: [UInt8] = [], maxSize: UInt64? = nil) {
        self.bytes = bytes
        self.maxSize = maxSize
    }

    var count: Int {
        bytes.count
    }

    /// Reads the bytes that start at `offset` into `buffer[range]`, as many
    /// as fit, and returns how many that was. Nothing is read at or beyond
    /// the end.
    func read(into buffer: inout MutableSpan<UInt8>, range: Range<Int>, at offset: UInt64) -> Int {
        guard offset < UInt64(bytes.count) else { return 0 }
        let start = Int(offset)
        let count = min(range.count, bytes.count - start)
        buffer.copyBytes(from: bytes.span, at: start, count: count, to: range.lowerBound)
        return count
    }

    /// Calls `body` with the buffer's bytes.
    func withBytes<Failure: Error>(_ body: (Span<UInt8>) throws(Failure) -> Void) throws(Failure) {
        try body(bytes.span)
    }

    /// Writes `source` at `offset`, growing the buffer if needed and filling
    /// any gap before the write with zeros. Writing nothing does nothing.
    ///
    /// - Throws: `maxSizeExceeded` if the write would grow the buffer beyond
    ///   `maxSize`, or beyond what an array can hold;
    ///   `storageFailure(errno:)`, with the system's error, if the system
    ///   refuses the memory when it is asked. Nothing is changed then.
    mutating func write(_ source: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        guard source.count > 0 else { return }
        let oldCount = bytes.count
        let (end, overflow) = offset.addingReportingOverflow(UInt64(source.count))
        // An end that cannot be an array index cannot be allocated either.
        guard !overflow, let endIndex = Int(exactly: end) else { throw .maxSizeExceeded }
        if endIndex > oldCount {
            if let maxSize, end > maxSize { throw .maxSizeExceeded }
            // An array that cannot have its memory ends the process, and
            // no Swift code can catch that. So the system is asked before
            // the array is: a size the system itself refuses is an error
            // here, with nothing changed.
            //
            // What this does not cover. The array's own allocation comes a
            // moment later, and can still be refused where the question was
            // answered yes: another thread took the memory in between, or
            // the allocator needs more than the bytes for its own
            // bookkeeping. That still ends the process. And a system may
            // say yes to memory it cannot back, and slow or end the process
            // when the bytes are written: nothing inside a process can turn
            // that into an error. Only a limit refuses such a size.
            if endIndex > bytes.capacity { try reserve(toHold: endIndex, asking: Platform.askForMemory) }
            if offset == UInt64(oldCount) {
                // The write starts at the end, as nearly every write of a
                // transaction does: append the bytes themselves.
                bytes.append(bytesOf: source)
                return
            }
            // Grows the buffer with zeros, which also fills the gap when the
            // write starts beyond the old end.
            bytes.append(contentsOf: repeatElement(0, count: endIndex - oldCount))
        }
        var target = bytes.mutableSpan
        target.copyBytes(from: source, count: source.count, to: Int(offset))
    }

    /// Gives the array room for `needed` bytes and more, asking the system
    /// first; ``write(_:at:)`` calls it when the array has to grow, and
    /// writes nothing if it throws.
    ///
    /// Kept out of that function's body, which every write of a transaction
    /// in memory runs, and without a parameter there for the question: with
    /// the growth in the body a hash map's put took 0.56% more instructions
    /// than before the system was asked, for a branch taken a logarithm of
    /// times; with it here every write of the four collections takes fewer
    /// than before (a hash map's put 0.58% fewer).
    ///
    /// - Parameter ask: The question to the system
    ///   (``Platform/askForMemory(_:)``), which a test replaces.
    /// - Throws: `storageFailure(errno:)`, with the system's error, if the
    ///   system does not give even what is needed. Nothing is changed then.
    @inline(never)
    mutating func reserve(toHold needed: Int, asking ask: (Int) -> Int32) throws(XitDBError) {
        bytes.reserveCapacity(try Self.capacity(toHold: needed, from: bytes.capacity, asking: ask))
    }

    /// The capacity to reserve for an array that must hold `needed` bytes
    /// and has room for `capacity` now.
    ///
    /// A write that makes the array grow leaves room for more: the double
    /// the array would take for a small write, and half as much again for
    /// a large one, such as a replica's full sync, which would otherwise
    /// fit exactly and make the next write copy everything. No sum here
    /// can overflow: each is taken with its overflow reported, and one that
    /// overflows is left out, as it is for a write far beyond the end,
    /// whose half as much again no integer holds. Where the system refuses
    /// the room for more, what is needed is asked for alone.
    ///
    /// - Parameter ask: Asks the system for that many bytes and returns
    ///   zero, or the error it refused with.
    /// - Throws: `storageFailure(errno:)`, with the system's error, if the
    ///   system does not give even what is needed.
    static func capacity(
        toHold needed: Int, from capacity: Int, asking ask: (Int) -> Int32
    ) throws(XitDBError) -> Int {
        var roomy = needed
        let halfAgain = needed.addingReportingOverflow(needed / 2)
        if !halfAgain.overflow { roomy = max(roomy, halfAgain.partialValue) }
        let doubled = capacity.multipliedReportingOverflow(by: 2)
        if !doubled.overflow { roomy = max(roomy, doubled.partialValue) }
        if roomy > needed, ask(roomy) == 0 { return roomy }
        let refusal = ask(needed)
        guard refusal == 0 else { throw .storageFailure(errno: refusal) }
        return needed
    }

    /// Cuts the buffer down to `length` bytes, keeping its capacity.
    ///
    /// - Throws: `invalidLength` if `length` is larger than the current
    ///   length. Nothing is changed then.
    mutating func truncate(to length: UInt64) throws(XitDBError) {
        guard length <= UInt64(bytes.count) else { throw .invalidLength }
        bytes.removeLast(bytes.count - Int(length))
    }

    /// Empties the buffer, keeping its capacity.
    mutating func removeAll() {
        bytes.removeAll(keepingCapacity: true)
    }
}

/// A storage that keeps a database's bytes in memory.
///
/// The bytes of an in-memory database are a complete database file. A
/// storage can be started from bytes that came from elsewhere, and its
/// ``bytes`` can be sent elsewhere and opened there, which makes an in-memory
/// database usable as a serialization format.
///
/// A ``Snapshot`` of a database in this storage shares the array: taking
/// one is free, and the first write after it copies the array once, as the
/// first write after ``bytes`` does. A writer that keeps a snapshot alive
/// across every commit therefore copies the whole database at each one.
/// The machine has to hold the bytes twice for that write. The copy is
/// the array's own, of what the storage already holds: it is not checked
/// against ``maxSize`` and the system is not asked for it first, so a
/// machine that cannot hold both ends the process there.
///
/// Flushing and syncing do nothing.
public final class MemoryStorage: WritableStorage {
    // The engine calls a storage several times for every slot it follows,
    // and the run-time exclusivity check on this property cost more than the
    // copy it guarded: 11% of a hash map insert. The check is off for this
    // one property, which makes every use of it `unsafe` to the compiler.
    //
    // Safe: what the check catches is an access to `buffer` that begins
    // while another one, a modification, is still going on. Every access is
    // in a method below, and lasts only while that method runs `MemoryBuffer`
    // code, which takes no closure and calls nothing of the caller's. So no
    // access can begin on a thread while another is in progress there. (The
    // check says nothing about two threads; the class is not `Sendable`.)
    // The spans a caller passes in cannot overlap the buffer's memory either:
    // the buffer hands out no span, and the array that `bytes` returns is
    // copied by the first write that follows it.
    @exclusivity(unchecked) private var buffer: MemoryBuffer

    /// The limit of a storage that is made without one being named: the
    /// machine's physical memory in bytes, asked of the system once. `nil`,
    /// no limit, where the system does not say how much it has.
    ///
    /// It is a guard against a runaway position, and not a promise that
    /// the memory is there. A write far beyond the end, such as one through
    /// a ``ByteWriter`` after a far ``ByteWriter/seek(to:)``, would have the
    /// storage ask for every byte up to it, and a system can grant memory
    /// it cannot back (see ``maxSize``). No database held in memory is
    /// larger than the memory, so this limit refuses no size the machine
    /// could hold, and refuses at once, with
    /// ``XitDBError/maxSizeExceeded``, one it could not.
    ///
    /// What it does not do, and a caller could take it to:
    ///
    /// - On a phone the system ends an app well below the device's
    ///   physical memory. The limit that guards there is one the caller
    ///   sets.
    /// - It is the machine's figure, not that of a limit the process is
    ///   under: in a container held to less, it is more than the process
    ///   can have. A server in a container sets the limit to what the
    ///   container is given.
    /// - A machine with more swap than memory can hold a larger store, and
    ///   this limit refuses it: pass `nil` for the limit, which is no
    ///   limit.
    public static let defaultMaxSize: UInt64? = Platform.physicalMemory

    /// Creates a storage.
    ///
    /// - Parameters:
    ///   - bytes: The storage's initial contents: the bytes of an existing
    ///     database, or nothing for a new one.
    ///   - maxSize: The most bytes the storage may grow to, or `nil` for no
    ///     limit. Left out, it is ``defaultMaxSize``, the machine's physical
    ///     memory, which is a guard against a write far beyond the end and
    ///     not a size to plan on: ``maxSize`` says what a storage without a
    ///     limit risks. Initial contents are not checked against it.
    public init(bytes: [UInt8] = [], maxSize: UInt64? = MemoryStorage.defaultMaxSize) {
        unsafe self.buffer = MemoryBuffer(bytes: bytes, maxSize: maxSize)
    }

    /// The most bytes the storage may grow to, or `nil` for no limit.
    ///
    /// A write that would grow the storage beyond the limit throws
    /// ``XitDBError/maxSizeExceeded`` and changes nothing. A storage made
    /// without naming a limit has ``defaultMaxSize``.
    ///
    /// Without a limit, which is asked for with `nil`, a write far beyond
    /// the end makes the storage as large as it takes to reach it, and a
    /// write through a ``ByteWriter`` after a far ``ByteWriter/seek(to:)``
    /// is such a write. The system is asked for the memory before the
    /// storage grows, with a limit or without, and a size it refuses is
    /// ``XitDBError/storageFailure(errno:)`` with the system's error,
    /// `ENOMEM`, and changes nothing. A write whose bytes would end beyond
    /// what an array can hold, past `Int.max`, is refused with
    /// ``XitDBError/maxSizeExceeded``, as with a limit.
    ///
    /// **That does not make a storage without a limit safe.** A system can
    /// grant memory it cannot back, and slow the machine or end the process
    /// when the bytes are written; nothing inside a process can turn that
    /// into an error. And the storage's own allocation, a moment after the
    /// system said yes, can still be refused, which ends the process as it
    /// does for any array. Only a limit refuses a size before the system is
    /// asked. Set one of your own for a storage whose writes are not under
    /// your control: the default one refuses only what the whole machine
    /// could not hold.
    public var maxSize: UInt64? {
        unsafe buffer.maxSize
    }

    /// The storage's current contents.
    ///
    /// This is a copy as far as the caller is concerned: later writes to the
    /// storage do not change an array obtained here.
    public var bytes: [UInt8] {
        unsafe buffer.bytes
    }

    /// Reads the bytes that start at `offset` into a part of `buffer`, as
    /// many as fit there.
    ///
    /// This never throws.
    ///
    /// - Parameters:
    ///   - buffer: Where to put the bytes.
    ///   - range: The part of `buffer` to read into, which must lie within
    ///     it.
    ///   - offset: The position of the first byte to read.
    /// - Returns: The number of bytes read, which is less than `range.count`
    ///   only when the storage ends first.
    /// - Precondition: `range` lies within `buffer`, as the file storages
    ///   require too; a range that does not is a programming error, whatever
    ///   the offset.
    public func read(
        into buffer: inout MutableSpan<UInt8>,
        range: Range<Int>,
        at offset: UInt64
    ) throws(XitDBError) -> Int {
        precondition(range.lowerBound >= 0 && range.upperBound <= buffer.count, "the range is out of bounds")
        return unsafe self.buffer.read(into: &buffer, range: range, at: offset)
    }

    /// The number of bytes in the storage. This never throws.
    public var length: UInt64 {
        get throws(XitDBError) {
            UInt64(unsafe buffer.count)
        }
    }

    /// Writes `bytes` at `offset`, growing the storage if they reach beyond
    /// its end and filling any gap before them with zeros.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to write.
    ///   - offset: The position of the first byte written.
    /// - Throws: ``XitDBError/maxSizeExceeded`` if the write would grow the
    ///   storage beyond ``maxSize``, or, with or without a limit, if the
    ///   bytes would end beyond what an array can hold, past `Int.max`;
    ///   ``XitDBError/storageFailure(errno:)``, with the system's error,
    ///   if the storage has to grow and the system refuses the memory when
    ///   it is asked. Nothing is changed then. What ``maxSize`` says of a
    ///   storage without a limit holds here: a size the system grants and
    ///   cannot back is no error.
    public func write(_ bytes: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        try unsafe buffer.write(bytes, at: offset)
    }

    /// Cuts the storage down to `length` bytes.
    ///
    /// - Parameter length: The new length in bytes.
    /// - Throws: ``XitDBError/invalidLength`` if `length` is larger than the
    ///   current length. A memory storage does not grow this way, and nothing
    ///   is changed.
    public func truncate(to length: UInt64) throws(XitDBError) {
        try unsafe buffer.truncate(to: length)
    }

    /// Does nothing: there is nothing underneath a memory storage to flush
    /// to.
    public func flush() throws(XitDBError) {}

    /// Does nothing: a memory storage is not durable.
    ///
    /// - Parameter point: Which of a commit's two syncs this is.
    public func sync(_ point: SyncPoint) throws(XitDBError) {}
}

@available(*, unavailable, message: "a memory storage is used from one thread at a time")
extension MemoryStorage: Sendable {}
