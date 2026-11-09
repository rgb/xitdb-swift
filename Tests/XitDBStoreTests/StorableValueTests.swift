import Testing
import XitDBStore

/// Values as types: each conformance writes to a slot and reads itself back,
/// and a slot of another kind is refused.
@Suite("values as types")
struct StorableValueTests {
    static let hashSize = 4

    /// Writes `value` under `key` in a fresh database and reads it back as `V`.
    private func roundTrip<V: StorableValue>(_ value: V, as type: V.Type = V.self) throws -> V {
        let database = try Database(creating: MemoryStorage(), hashSize: Self.hashSize)
        try database.withTransaction { root in
            let map = try HashMap<ReadWrite>(root)
            var cursor = try map.putCursor(forHash: [1, 2, 3, 4])
            try value.write(to: &cursor)
        }
        let map = try HashMap<ReadOnly>(database.rootCursor)
        guard let cursor = try map.cursor(forHash: [1, 2, 3, 4]) else {
            Issue.record("the entry was not written")
            throw XitDBError.keyNotFound
        }
        return try V(reading: cursor)
    }

    @Test func scalars() throws {
        #expect(try roundTrip(UInt64(42)) == 42)
        #expect(try roundTrip(UInt64.max) == .max)
        #expect(try roundTrip(Int64(-5)) == -5)
        #expect(try roundTrip(Int64.min) == .min)
        #expect(try roundTrip(1.5) == 1.5)
        #expect(try roundTrip(-0.0).sign == .minus, "a double keeps its bits")
        #expect(try roundTrip(true) == true)
        #expect(try roundTrip(false) == false)
    }

    @Test func stringsAndBytes() throws {
        #expect(try roundTrip("héllo") == "héllo")
        #expect(try roundTrip("") == "")
        #expect(try roundTrip(String(repeating: "x", count: 1000)) == String(repeating: "x", count: 1000))
        #expect(try roundTrip([UInt8]([0, 1, 255])) == [0, 1, 255])
        #expect(try roundTrip([UInt8]()) == [])
    }

    @Test func optionals() throws {
        #expect(try roundTrip(Optional<UInt64>.some(7)) == 7)
        #expect(try roundTrip(Optional<UInt64>.none) == nil)
        #expect(try roundTrip(Optional<String>.some("a")) == "a")
        #expect(try roundTrip(Optional<[UInt8]>.none) == nil)
    }

    /// A `Bool` is an unsigned integer on disk, so any non-zero one reads as
    /// `true`, and a `Bool` reads back as the integer it is.
    @Test func boolIsAnUnsignedInteger() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: Self.hashSize)
        try database.withTransaction { root in
            let map = try HashMap<ReadWrite>(root)
            try map.put(.uint(9), forHash: [0, 0, 0, 1])
            var cursor = try map.putCursor(forHash: [0, 0, 0, 2])
            try true.write(to: &cursor)
        }
        let map = try HashMap<ReadOnly>(database.rootCursor)
        #expect(try Bool(reading: try #require(try map.cursor(forHash: [0, 0, 0, 1]))) == true)
        #expect(try UInt64(reading: try #require(try map.cursor(forHash: [0, 0, 0, 2]))) == 1)
    }

    @Test func anotherKindIsRefused() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: Self.hashSize)
        try database.withTransaction { root in
            let map = try HashMap<ReadWrite>(root)
            try map.put(.bytes(Array("text".utf8)), forHash: [0, 0, 0, 1])
        }
        let map = try HashMap<ReadOnly>(database.rootCursor)
        let cursor = try #require(try map.cursor(forHash: [0, 0, 0, 1]))
        #expect(throws: XitDBError.unexpectedTag) { try UInt64(reading: cursor) }
        #expect(throws: XitDBError.unexpectedTag) { try Double(reading: cursor) }
        #expect(try String(reading: cursor) == "text")
    }
}
