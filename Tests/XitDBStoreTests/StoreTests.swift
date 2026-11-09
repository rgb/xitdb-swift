import Testing
import XitDB
import XitDBHashing
import XitDBStore

/// The store over a database: moments, transactions, the hash size check,
/// and reading through a snapshot.
@Suite("the store")
struct StoreTests {
    @Test func aStoreNeedsTheDatabasesHashSize() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        _ = try Store(database, hashing: SHA256.self)
        #expect(throws: XitDBError.hashSizeMismatch) { try Store(database, hashing: Insecure.SHA1.self) }
        #expect(throws: XitDBError.hashSizeMismatch) { try Store(database, hashing: SipHash128.self) }
        let small = try Database(creating: MemoryStorage(), hashSize: 16)
        _ = try Store(small, hashing: SipHash128.self)
    }

    @Test func aTransactionIsAMomentAppendedToTheHistory() throws {
        let store = try Store(try Database(creating: MemoryStorage(), hashSize: 32), hashing: SHA256.self)
        #expect(try store.momentCount == 0)
        #expect(throws: XitDBError.indexOutOfRange) { try store.latest }

        try store.transaction { moment in
            #expect(moment.isWritable)
            #expect(moment.index == 0)
            try moment["answer"].set(UInt64(42))
        }
        #expect(try store.momentCount == 1)
        let first = try store.latest
        #expect(!first.isWritable)
        #expect(first.index == 0)
        #expect(try first["answer"].value(UInt64.self) == 42)

        try store.transaction { moment in
            #expect(moment.index == 1)
            #expect(try moment["answer"].value(UInt64.self) == 42, "the new moment starts as a clone of the latest")
            try moment["answer"].set(UInt64(43))
        }
        #expect(try store.momentCount == 2)
        #expect(try store.latest["answer"].value(UInt64.self) == 43)
        #expect(try store.moment(at: 0)["answer"].value(UInt64.self) == 42, "the earlier moment is as it was")
        #expect(try store.moment(at: -2)["answer"].value(UInt64.self) == 42)
        #expect(throws: XitDBError.indexOutOfRange) { try store.moment(at: 2) }
        #expect(throws: XitDBError.indexOutOfRange) { try store.moment(at: -3) }
    }

    @Test func aThrowingBodyRollsTheMomentBack() throws {
        struct Stop: Error {}
        let store = try Store(try Database(creating: MemoryStorage(), hashSize: 32), hashing: SHA256.self)
        try store.transaction { moment in try moment["a"].set(UInt64(1)) }
        #expect(throws: Stop.self) {
            try store.transaction { moment in
                try moment["a"].set(UInt64(2))
                throw Stop()
            }
        }
        #expect(try store.momentCount == 1)
        #expect(try store.latest["a"].value(UInt64.self) == 1)
    }

    @Test func aReadOnlyMomentRefusesWrites() throws {
        let store = try Store(try Database(creating: MemoryStorage(), hashSize: 32), hashing: SHA256.self)
        try store.transaction { moment in try moment["a"].set(UInt64(1)) }
        let latest = try store.latest
        #expect(throws: XitDBError.expectedTxStart) { try latest["a"].set(UInt64(2)) }
        #expect(throws: XitDBError.expectedTxStart) {
            try latest["b"].map(String.self, UInt64.self).put(1, forKey: "k")
        }
        #expect(throws: XitDBError.expectedTxStart) { try latest["c"].list(UInt64.self).append(1) }
        #expect(try latest["a"].value(UInt64.self) == 1)
    }

    @Test func aMomentReadsASnapshotOnItsOwn() throws {
        let store = try Store(try Database(creating: MemoryStorage(), hashSize: 32), hashing: SHA256.self)
        try store.transaction { moment in try moment["a"].set("one") }
        let snapshot = try store.snapshot()
        try store.transaction { moment in try moment["a"].set("two") }

        let frozen = try Moment(reading: SnapshotDatabase(snapshot), hashing: SHA256.self)
        #expect(try frozen["a"].value(String.self) == "one")
        #expect(frozen.index == 0)
        let live = try Moment(reading: store.database, hashing: SHA256.self)
        #expect(try live["a"].value(String.self) == "two")
        #expect(live.index == 1)
        #expect(throws: XitDBError.hashSizeMismatch) {
            try Moment(reading: SnapshotDatabase(snapshot), hashing: Insecure.SHA1.self)
        }
    }

    @Test func anEmptyDatabaseHasNoMomentToRead() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        #expect(throws: XitDBError.indexOutOfRange) { try Moment(reading: database, hashing: SHA256.self) }
    }
}
