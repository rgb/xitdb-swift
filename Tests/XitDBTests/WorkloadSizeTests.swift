import Testing

@testable import XitDB

/// The benchmark's three workloads at small sizes, held to the file sizes
/// the Zig implementation gives for them.
///
/// What these pin is how much one transaction appends when it comes back to
/// structures it made itself: a map with hundreds of keys and a list with
/// thousands of elements, each written in a single transaction. An engine
/// that copied an index block it had just made would read back right, pass
/// the conformance scripts, whose transactions are small, and only make
/// larger files.
///
/// The sizes are from a run of the same paths on the Zig original (a
/// scratch test against its lib.zig, Zig 0.17.1), with the benchmark's file
/// ID and hash ID. That run also gave 940,848 bytes for 10,000 map inserts,
/// the size in the benchmark's baseline, which ties it to the conformance
/// session's benchmark.
@Suite struct WorkloadSizeTests {
    private func makeDatabase(_ storage: any WritableStorage) throws -> Database {
        try Database(
            storage: storage,
            hashSize: 20,
            hashID: "sha1",
            fileID: 0x0011_2233_4455_6677,
            random: FixedRandom((1...100).map { UInt64($0) })
        )
    }

    private func key(_ index: Int) -> KeyHash {
        sha1("key-\(index)")
    }

    private func lastMoment(_ database: Database) throws -> Cursor<ReadOnly> {
        try #require(try database.rootCursor.readPath([.arrayListGet(-1)]))
    }

    @Test(arguments: [(1, 438), (17, 1478), (300, 26344), (1000, 92112)], StorageKind.allCases)
    func mapInsert(workload: (count: Int, size: UInt64), kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try makeDatabase(subject.storage)
        _ = try database.rootCursor.writePath([.arrayListInit, .arrayListAppend, .hashMapInit(), .ctx]) { cursor in
            for index in 0..<workload.count {
                _ = try cursor.writePath([.hashMapGet(.value, key(index)), .write(.uint(UInt64(index)))])
            }
        }
        #expect(try subject.storage.length == workload.size)
        #expect(try database.committedSize == workload.size)

        let moment = try lastMoment(database)
        for index in 0..<workload.count {
            #expect(try #require(try moment.readPath([.hashMapGet(.value, key(index))])).readUInt64() == UInt64(index))
        }
    }

    @Test(arguments: [(1, 416), (17, 704), (300, 3440), (5000, 48656)], StorageKind.allCases)
    func listAppend(workload: (count: Int, size: UInt64), kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try makeDatabase(subject.storage)
        _ = try database.rootCursor.writePath([.arrayListInit, .arrayListAppend, .arrayListInit, .ctx]) { cursor in
            for index in 0..<workload.count {
                _ = try cursor.writePath([.arrayListAppend, .write(.uint(UInt64(index)))])
            }
        }
        #expect(try subject.storage.length == workload.size)

        let moment = try lastMoment(database)
        #expect(try moment.count == UInt64(workload.count))
        for index in 0..<workload.count {
            #expect(try #require(try moment.readPath([.arrayListGet(Int64(index))])).readUInt64() == UInt64(index))
        }
    }

    @Test(arguments: [(1, 1068), (30, 72722)], StorageKind.allCases)
    func mapTransactions(workload: (count: Int, size: UInt64), kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try makeDatabase(subject.storage)
        for transaction in 0..<workload.count {
            let root = database.rootCursor
            let last = try root.readPathSlot([.arrayListGet(-1)])
            _ = try root.writePath([.arrayListInit, .arrayListAppend, .write(.slot(last)), .hashMapInit(), .ctx]) {
                cursor in
                for index in (transaction * 10)..<(transaction * 10 + 10) {
                    _ = try cursor.writePath([.hashMapGet(.value, key(index)), .write(.uint(UInt64(index)))])
                }
            }
        }
        #expect(try subject.storage.length == workload.size)

        let moment = try lastMoment(database)
        for index in 0..<(workload.count * 10) {
            #expect(try #require(try moment.readPath([.hashMapGet(.value, key(index))])).readUInt64() == UInt64(index))
        }
    }
}
