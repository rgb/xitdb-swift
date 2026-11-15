import Synchronization

extension UInt64 {
    /// This position moved forward by `distance`.
    ///
    /// Positions and sizes read from a file are added with this, so that a
    /// corrupt one is reported and cannot overflow.
    ///
    /// - Throws: `endOfStream` if the result is beyond any position a
    ///   storage has, which is what reading there would report.
    func offset(by distance: UInt64) throws(XitDBError) -> UInt64 {
        let (result, overflow) = addingReportingOverflow(distance)
        if overflow { throw .endOfStream }
        return result
    }
}

/// A key-value pair with the hash it is stored under. (A struct and not a
/// tuple, because a tuple of these needs its metadata looked up at run time
/// each time one is destroyed, which showed in iterating over a map.)
struct HashedPair {
    var hash: KeyHash
    var pair: KeyValuePair
}

/// What a replication from zero replaces: the database's header, shared
/// by the database and its reader, so that both stay `let` properties and
/// only this box is read through a dynamic exclusivity check.
final class DatabaseIdentity {
    var header: DatabaseHeader

    init(header: DatabaseHeader) {
        self.header = header
    }
}

/// Everything the read side of the engine needs from a database: its bytes,
/// its hash size and its file ID.
///
/// Code that only reads depends on this and not on ``Database``, so that the
/// same code can later read a snapshot of committed data from any thread.
///
/// A class and not a struct: as a struct of three fields over
/// ``BuiltInStorage`` the optimiser compiled its methods with `self` taken
/// apart into those fields, and the sorted map paid about an eighth of its
/// read time for it; a reference is passed whole. There is
/// no state to copy either way, since every field is a `let`.
///
/// **What no file can make the read side do.** Beside the checks of each
/// record's own bytes, the read side holds what it reads to four things,
/// so that no file makes a read run without end or outside the file's
/// data: no position read as data lies before where data starts
/// (``checkIsData(_:)``); the size of an array list or of a sorted map or
/// set, and a counted map's or set's count, is within what the file could
/// hold (``checkCount(_:bytesEach:)``); a walk of a hash trie enters no
/// more blocks than the file has room for; and a walk of a tree enters no
/// more nodes than its file, or the elements it gives, allow
/// (``SlotIterator/Bound``). A descent is bounded by the depth its
/// collection can have, as it was.
///
/// They do not vouch for a position answered from a tree's counts, which
/// the original does not either: no count is held against the nodes under
/// it. A copy made by its slot and frozen by its cursor, then written
/// beside its original in one transaction, has a header or a branch's
/// counts that disagree with its tree, with no byte damaged, and is read
/// as the original reads it.
final class DatabaseReader {
    /// The bytes, as the engine holds a storage. Only its reads are used
    /// here.
    let storage: BuiltInStorage
    /// The hash size, which a replication cannot change.
    let hashSize: UInt16
    private let identity: DatabaseIdentity

    /// The root header of the one commit a snapshot's database reads, which
    /// ``rootHeader()`` returns instead of reading one; `nil` for a live
    /// database, whose root header is read at every use.
    let pinnedRoot: RootHeader?

    /// For a snapshot's database, the commit's own root slot, which the
    /// pinned root is unless the snapshot is of a sub-collection.
    let pinnedCommitRoot: Slot?

    /// Where the committed data begins in the file: the header's
    /// `dataStart`, 32 or 37 by the format's version. It is looked at for
    /// every record read, so it is kept here and not read through the
    /// header's box, whose stored `var` costs a run-time check of exclusive
    /// access at each read; as an atomic it is a `let` and a plain load. A
    /// replication from zero, which can change the version, stores it
    /// again (``headerChanged()``).
    private let dataStart: Atomic<UInt64>

    /// The length the storage was last known to have, for the checks that
    /// hold a size or a number of blocks against what the file could hold.
    /// A plain file storage answers its length by a system call, so it is
    /// asked again only when something does not fit in the length known so
    /// far (``fileHolds(_:)``): a sound file costs a comparison.
    private let knownLength = Atomic<UInt64>(0)

    /// The file ID, which the trailers' checksums cover.
    var fileID: UInt64 { identity.header.fileID }

    /// The database's header as it is now: a replication from zero
    /// replaces it, and with it the format's version, which decides where
    /// the root header's committed size and the first committed byte are.
    var header: DatabaseHeader { identity.header }

    init(
        storage: BuiltInStorage, identity: DatabaseIdentity, pinnedRoot: RootHeader? = nil,
        pinnedCommitRoot: Slot? = nil
    ) {
        self.storage = storage
        hashSize = identity.header.hashSize
        self.identity = identity
        self.pinnedRoot = pinnedRoot
        self.pinnedCommitRoot = pinnedCommitRoot
        dataStart = Atomic<UInt64>(identity.header.dataStart)
    }

    /// Takes where data starts from the header again, after a replication
    /// from zero replaced it.
    func headerChanged() {
        dataStart.store(identity.header.dataStart, ordering: .relaxed)
    }

    // MARK: What a file can hold

    /// Refuses a position that is read as data and lies before where data
    /// starts. Every position a writer stores is the length the file had
    /// when it appended what the position leads to, and the first thing
    /// appended is at the start of data: a smaller one is damage.
    ///
    /// - Throws: `endOfStream`, as for a position beyond the end: both are
    ///   places where no record can be.
    @inline(__always)
    func checkIsData(_ position: UInt64) throws(XitDBError) {
        if position < dataStart.load(ordering: .relaxed) { throw .endOfStream }
    }

    /// Whether the storage holds `needed` bytes, as far as its length says.
    /// The storage is asked for its length only when `needed` does not fit
    /// in the length known so far.
    ///
    /// - Throws: The storage's errors, when it is asked.
    func fileHolds(_ needed: UInt64) throws(XitDBError) -> Bool {
        if needed <= knownLength.load(ordering: .relaxed) { return true }
        return needed <= (try lengthNow())
    }

    /// The storage's length as it is now, asked for and kept. A snapshot's
    /// storage answers its commit's size, so that is what bounds a
    /// snapshot's database, however long the file has grown since.
    private func lengthNow() throws(XitDBError) -> UInt64 {
        let length = try storage.length
        knownLength.store(length, ordering: .relaxed)
        return length
    }

    /// Refuses a count that the file could not hold: `count` things of
    /// `bytesEach` bytes each, none of them shared, are more than the
    /// storage's length. An array list's element and a sorted collection's
    /// entry each have a slot of their own, and a counted map's entry a
    /// pair of its own, so a larger count than this is one no writer wrote.
    /// A linked array list is not held to it: a list joined to itself holds
    /// its nodes twice.
    ///
    /// - Throws: `invalidCount` for such a count, and the storage's errors.
    func checkCount(_ count: UInt64, bytesEach: UInt64) throws(XitDBError) {
        let (needed, overflow) = count.multipliedReportingOverflow(by: bytesEach)
        guard !overflow, try fileHolds(needed) else { throw .invalidCount }
    }

    /// The most pieces of `byteCount` bytes the file has room for: its
    /// length as it is now over the size of one, for a walk that enters
    /// blocks or nodes each of which is a piece of the file of its own.
    ///
    /// - Throws: The storage's errors.
    func piecesTheFileHolds(of byteCount: UInt64) throws(XitDBError) -> UInt64 {
        try lengthNow() / byteCount
    }

    // MARK: Records

    /// Reads exactly as many bytes as the result holds, at a position that
    /// came from the file.
    ///
    /// - Throws: `endOfStream` if the storage ends first, or if the
    ///   position is before where data starts.
    func bytes<let count: Int>(at position: UInt64) throws(XitDBError) -> InlineArray<count, UInt8> {
        try checkIsData(position)
        var buffer = InlineArray<count, UInt8>(repeating: 0)
        var span = buffer.mutableSpan
        let read = try storage.read(into: &span, at: position)
        guard read == count else { throw .endOfStream }
        return buffer
    }

    /// The eight bytes of the committed size in the root header, which lie
    /// before where data starts and are the one thing there that is read
    /// as a number.
    ///
    /// - Throws: `endOfStream` if the storage ends first.
    private func committedSizeField(of header: DatabaseHeader) throws(XitDBError) -> UInt64 {
        var buffer = InlineArray<8, UInt8>(repeating: 0)
        var span = buffer.mutableSpan
        let read = try storage.read(into: &span, at: header.fileSizePosition)
        guard read == 8 else { throw .endOfStream }
        return buffer.span.bigEndian(at: 0)
    }

    func slot(at position: UInt64) throws(XitDBError) -> Slot {
        let buffer: InlineArray<9, UInt8> = try bytes(at: position)
        return try Slot(decoding: buffer.span)
    }

    func uint64(at position: UInt64) throws(XitDBError) -> UInt64 {
        let buffer: InlineArray<8, UInt8> = try bytes(at: position)
        return buffer.span.bigEndian(at: 0)
    }

    func arrayListHeader(at position: UInt64) throws(XitDBError) -> ArrayListHeader {
        let buffer: InlineArray<16, UInt8> = try bytes(at: position)
        return try ArrayListHeader(decoding: buffer.span)
    }

    /// An array list's header as a read takes it, its size held against
    /// what the file could hold: every element has a slot of its own in
    /// the list's blocks. The writes read the header by
    /// ``arrayListHeader(at:)``, as they did.
    ///
    /// - Throws: `invalidCount` for a size the file has no room for, and
    ///   what reading the header throws.
    func checkedArrayListHeader(at position: UInt64) throws(XitDBError) -> ArrayListHeader {
        let header = try arrayListHeader(at: position)
        try checkCount(header.size, bytesEach: Slot.byteCount)
        return header
    }

    /// A sorted map's or set's header as a read takes it, its size held
    /// against what the file could hold: every entry has a slot of its own
    /// in a leaf, and no node is in the tree twice. A linked array list's
    /// header is not held to this, and neither are the writes, which read
    /// the header by ``bTreeHeader(at:)``.
    ///
    /// - Throws: `invalidCount` for a size the file has no room for, and
    ///   what reading the header throws.
    func checkedSortedHeader(at position: UInt64) throws(XitDBError) -> BTreeHeader {
        let header = try bTreeHeader(at: position)
        try checkCount(header.size, bytesEach: Slot.byteCount)
        return header
    }

    /// A counted hash map's or set's count as a read takes it, held
    /// against what the file could hold: every entry is a pair of its own,
    /// its hash and two slots.
    ///
    /// - Throws: `invalidCount` for a count the file has no room for, and
    ///   what reading it throws.
    func checkedHashMapCount(at position: UInt64) throws(XitDBError) -> UInt64 {
        let count = try uint64(at: position)
        try checkCount(count, bytesEach: UInt64(hashSize) + 2 * Slot.byteCount)
        return count
    }

    func bTreeHeader(at position: UInt64) throws(XitDBError) -> BTreeHeader {
        let buffer: InlineArray<16, UInt8> = try bytes(at: position)
        return try BTreeHeader(decoding: buffer.span)
    }

    /// The raw bytes of an index block, for copying it.
    func indexBlockBytes(at position: UInt64) throws(XitDBError) -> InlineArray<144, UInt8> {
        try bytes(at: position)
    }

    func indexBlock(at position: UInt64) throws(XitDBError) -> IndexBlock {
        let buffer = try indexBlockBytes(at: position)
        return try IndexBlock(decoding: buffer.span)
    }

    /// Reads the hashed key-value pair record at `position`: its hash and
    /// its two slots.
    ///
    /// The record is read in one call. For hashes of up to sixty-four bytes
    /// nothing is allocated.
    ///
    /// - Throws: `endOfStream` if the record is not all there, or
    ///   `invalidEnumTag` if one of its slots has an unknown tag.
    func hashedPair(at position: UInt64) throws(XitDBError) -> HashedPair {
        try checkIsData(position)
        let size = Int(hashSize) + 18
        if size <= 82 {
            var buffer = InlineArray<82, UInt8>(repeating: 0)
            var span = buffer.mutableSpan
            // This may read past the record into what follows it, which is
            // harmless, or come back short because the storage ends.
            let read = try storage.read(into: &span, at: position)
            guard read >= size else { throw .endOfStream }
            return try Self.decodeHashedPair(buffer.span.extracting(0..<size), hashSize: hashSize)
        }
        var buffer = [UInt8](repeating: 0, count: size)
        var span = buffer.mutableSpan
        let read = try storage.read(into: &span, at: position)
        guard read == size else { throw .endOfStream }
        return try Self.decodeHashedPair(buffer.span, hashSize: hashSize)
    }

    private static func decodeHashedPair(_ record: Span<UInt8>, hashSize: UInt16) throws(XitDBError) -> HashedPair {
        let pair = try KeyValuePair(decodingHashed: record, hashSize: hashSize)
        return HashedPair(hash: KeyHash(record.extracting(0..<Int(hashSize))), pair: pair)
    }

    func sortedPair(at position: UInt64) throws(XitDBError) -> KeyValuePair {
        let buffer: InlineArray<18, UInt8> = try bytes(at: position)
        return try KeyValuePair(decodingSorted: buffer.span)
    }

    // MARK: The root

    /// The committed size from the root header, and the root slot from the
    /// trailer that ends there.
    ///
    /// Only the size is read from the root header, at the position the
    /// file's format version gives it. The copy of the root slot that a
    /// version 1 file keeps before it is never looked at: nothing updates
    /// it. A snapshot's reader has its commit pinned and reads nothing
    /// here.
    ///
    /// - Throws: `invalidDatabase` if the size is too small to hold a
    ///   database or the trailer's checksum does not match,
    ///   `truncatedDatabase` if the storage is shorter than the size, or
    ///   `endOfStream` if the storage ends inside the root header.
    func rootHeader() throws(XitDBError) -> RootHeader {
        if let pinnedRoot { return pinnedRoot }
        let header = identity.header
        let fileSize = try committedSizeField(of: header)
        if fileSize < header.minimumFileSize { throw .invalidDatabase }
        if try storage.length < fileSize { throw .truncatedDatabase }
        // The committed bytes must end with a trailer.
        return RootHeader(root: try rootTrailer(endingAt: fileSize).root, fileSize: fileSize)
    }

    /// The root header's committed size as it is, with nothing checked:
    /// zero until the first commit, or a full copy, has finished, and zero
    /// too for a storage that ends before the size. Zig's `readFileSize`.
    /// A database whose size is zero has no first commit.
    func recordedSize() throws(XitDBError) -> UInt64 {
        if let pinnedRoot { return pinnedRoot.fileSize }
        let header = identity.header
        if try storage.length < header.dataStart { return 0 }
        return try committedSizeField(of: header)
    }

    /// Whether the storage holds a full copy that did not finish: a
    /// database without a first commit that is longer than a new one. (One
    /// no longer than a new database is a creation that did not finish.)
    func holdsUnfinishedCopy() throws(XitDBError) -> Bool {
        guard try storage.length > identity.header.minimumFileSize else { return false }
        return try recordedSize() == 0
    }

    /// The number of bytes that belong to committed transactions.
    var committedSize: UInt64 {
        get throws(XitDBError) {
            try rootHeader().fileSize
        }
    }

    /// The most recently committed root slot.
    func rootSlot() throws(XitDBError) -> Slot {
        try rootHeader().root
    }

    /// The trailer that ends at `end`.
    ///
    /// `end` is a size, the file's own or one a caller asks about, and not
    /// a position that data led to: the bytes are read wherever it puts
    /// them, and a size too small to have a trailer before it is told by
    /// the checksum, as it was, and not by ``checkIsData(_:)``.
    func rootTrailer(endingAt end: UInt64) throws(XitDBError) -> RootTrailer {
        if end < RootTrailer.byteCount { throw .invalidDatabase }
        let position = end - RootTrailer.byteCount
        var buffer = InlineArray<25, UInt8>(repeating: 0)
        var span = buffer.mutableSpan
        let read = try storage.read(into: &span, at: position)
        guard read == 25 else { throw .endOfStream }
        return try RootTrailer(decoding: buffer.span, fileID: fileID, position: position)
    }

    /// The slot pointer a root cursor stands for right now: the root slot in
    /// the newest trailer. A trailer never changes, so everything read
    /// through the result comes from one commit.
    func resolvedRoot() throws(XitDBError) -> SlotPointer {
        let header = try rootHeader()
        return SlotPointer(position: header.fileSize - RootTrailer.byteCount, slot: header.root)
    }
}
