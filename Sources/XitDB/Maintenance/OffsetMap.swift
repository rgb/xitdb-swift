/// Where a compaction remembers which target offset each source offset
/// went to, so that an object pointed at from several places is copied
/// once and a cycle ends: Zig's `offset_map`.
///
/// Every mapping must stay available until the compaction finishes. A
/// compaction resets the map at its start, so one map can serve many
/// compactions in turn. ``MemoryOffsetMap`` is the one to use unless the
/// database is too large for its offsets to fit in memory; then an
/// implementation can keep them anywhere, in another database for example.
///
/// The requirements throw ``XitDBError`` so that ``Database/compact(into:offsetMap:)``
/// keeps its typed error. An implementation whose own storage fails
/// reports that as ``XitDBError/storageFailure(errno:)``.
public protocol OffsetMap {
    /// Forgets every mapping.
    mutating func reset() throws(XitDBError)

    /// The target offset recorded for a source offset, or `nil` if none was.
    mutating func get(_ sourceOffset: UInt64) throws(XitDBError) -> UInt64?

    /// Records that the object at a source offset was copied to a target
    /// offset.
    mutating func put(_ sourceOffset: UInt64, _ targetOffset: UInt64) throws(XitDBError)
}

/// An offset map kept in memory, in a dictionary: Zig's
/// `std.AutoHashMap(u64, u64)`. Its operations cannot fail.
public struct MemoryOffsetMap: OffsetMap {
    private var offsets: [UInt64: UInt64] = [:]

    /// An empty map.
    public init() {}

    /// Forgets every mapping, keeping the room they took.
    public mutating func reset() {
        offsets.removeAll(keepingCapacity: true)
    }

    /// The target offset recorded for a source offset, or `nil` if none was.
    public func get(_ sourceOffset: UInt64) -> UInt64? {
        offsets[sourceOffset]
    }

    /// Records that the object at a source offset was copied to a target
    /// offset.
    public mutating func put(_ sourceOffset: UInt64, _ targetOffset: UInt64) {
        offsets[sourceOffset] = targetOffset
    }
}
