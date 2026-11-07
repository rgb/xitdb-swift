import Testing

@testable import XitDB

/// The disk-backed offsets map of Zig's test "compaction with disk-backed
/// offsets map" (`test.zig` 2867–2965): a hash map with 8-byte hashes in a
/// database of its own, used inside one transaction that lasts for the
/// whole compaction, so that each `put` is not committed on its own. The
/// runtime hash size makes it a database like any other here.
///
/// A ``DiskOffsets`` owns the database; ``use(_:)`` opens the transaction
/// and hands the map to a body, which compacts with it. The runner keeps
/// one for a whole script, as the Zig runner does, so that a compaction
/// has to forget the last one.
final class DiskOffsets {
    let database: Database

    /// A map in an empty storage, with the 8-byte hashes a `u64` hash
    /// integer gives Zig's.
    init(storage: any WritableStorage) throws {
        database = try Database(storage: storage, hashSize: 8)
    }

    /// Runs `body` with the map inside one transaction of its database.
    func use<Result>(_ body: (inout DiskOffsetMap) throws -> Result) throws -> Result {
        var result: Result?
        try database.withTransaction { cursor in
            var map = DiskOffsetMap(map: try HashMap(cursor))
            result = try body(&map)
        }
        return try #require(result)
    }
}

/// Zig's `DiskOffsets`: `reset` empties the map by writing nothing to its
/// cursor and initializing it again; `get` reads the unsigned integer
/// under the source offset; `put` writes it.
struct DiskOffsetMap: OffsetMap {
    var map: HashMap<ReadWrite>

    /// The 8-byte hash of an offset, as Zig stores a `u64` hash.
    private static func hash(_ offset: UInt64) -> [UInt8] {
        bigEndianBytes(offset)
    }

    mutating func reset() throws(XitDBError) {
        var cursor = map.cursor
        try cursor.write(.slot(nil))
        map = try HashMap(cursor)
    }

    mutating func get(_ sourceOffset: UInt64) throws(XitDBError) -> UInt64? {
        guard let cursor = try map.getCursor(Self.hash(sourceOffset)) else { return nil }
        return try cursor.readUint()
    }

    mutating func put(_ sourceOffset: UInt64, _ targetOffset: UInt64) throws(XitDBError) {
        try map.put(Self.hash(sourceOffset), .uint(targetOffset))
    }
}
