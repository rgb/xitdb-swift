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

/// An offset map kept in memory: Zig's `std.AutoHashMap(u64, u64)`. Its
/// operations cannot fail.
///
/// It is an open-addressing table of its own rather than a `Dictionary`:
/// a compaction looks an offset up and records one for every block it
/// reaches, and the standard dictionary's hashing was a tenth of a
/// compaction in memory. The keys are offsets in a file, which a
/// multiplicative hash spreads well enough; the table doubles at half
/// full.
public struct MemoryOffsetMap: OffsetMap {
    /// The source offsets, and the target offsets beside them; a target
    /// offset of all ones marks an empty place, since no file is that
    /// large.
    private var keys: [UInt64]
    private var values: [UInt64]
    private var count = 0

    private static let empty = UInt64.max
    private static let initialCapacity = 1024

    /// An empty map.
    public init() {
        keys = [UInt64](repeating: 0, count: Self.initialCapacity)
        values = [UInt64](repeating: Self.empty, count: Self.initialCapacity)
    }

    /// Forgets every mapping, keeping the room they took.
    public mutating func reset() {
        for index in values.indices {
            values[index] = Self.empty
        }
        count = 0
    }

    /// The place for a key: where it is, or where it would go.
    private func place(_ key: UInt64) -> Int {
        let mask = keys.count - 1
        var index = Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> 32) & mask
        while values[index] != Self.empty && keys[index] != key {
            index = (index + 1) & mask
        }
        return index
    }

    /// The target offset recorded for a source offset, or `nil` if none was.
    public func get(_ sourceOffset: UInt64) -> UInt64? {
        let index = place(sourceOffset)
        return values[index] == Self.empty ? nil : values[index]
    }

    /// Records that the object at a source offset was copied to a target
    /// offset.
    public mutating func put(_ sourceOffset: UInt64, _ targetOffset: UInt64) {
        var index = place(sourceOffset)
        if values[index] == Self.empty {
            count += 1
            if count * 2 > keys.count {
                grow()
                index = place(sourceOffset)
            }
        }
        keys[index] = sourceOffset
        values[index] = targetOffset
    }

    /// Doubles the table and puts every mapping in its new place.
    private mutating func grow() {
        let oldKeys = keys
        let oldValues = values
        keys = [UInt64](repeating: 0, count: oldKeys.count * 2)
        values = [UInt64](repeating: Self.empty, count: oldKeys.count * 2)
        for index in oldValues.indices where oldValues[index] != Self.empty {
            let place = place(oldKeys[index])
            keys[place] = oldKeys[index]
            values[place] = oldValues[index]
        }
    }
}
