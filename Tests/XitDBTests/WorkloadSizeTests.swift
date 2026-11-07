import Testing

@testable import XitDB

/// The benchmark's seven workloads, held to the file sizes the Zig
/// implementation gives for them: the first three at small sizes, the four
/// others at the sizes the benchmark runs on the plain file.
///
/// What these pin is how much one transaction appends when it comes back to
/// structures it made itself: a map with hundreds of keys and a list with
/// thousands of elements, each written in a single transaction. An engine
/// that copied an index block it had just made would read back right, pass
/// the conformance scripts, whose transactions are small, and only make
/// larger files.
///
/// The small sizes are from a run of the same paths on the Zig original (a
/// scratch test against its lib.zig, Zig 0.17.1), with the benchmark's file
/// ID and hash ID. That run also gave 940,848 bytes for 10,000 map inserts,
/// the size in the benchmark's baseline, which ties it to the conformance
/// session's benchmark. The plain-file sizes of the four other workloads
/// are the ones `director/spec/benchmarks.md` records from the Zig
/// benchmark, which the Swift benchmark reproduces.
@Suite struct WorkloadSizeTests {
    private func makeDatabase(_ storage: any WritableStorage) throws -> Database {
        try Database(
            storage: storage,
            hashSize: 20,
            hashID: "sha1",
            fileID: 0x0011_2233_4455_6677,
            random: FixedRandom((1...1000).map { UInt64($0) })
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

    /// `linked_append` at the plain file's size: 10,000 appends to a linked
    /// array list in one transaction.
    @Test(arguments: StorageKind.allCases)
    func linkedAppend(kind: StorageKind) throws {
        let count = 10_000
        let subject = try StorageUnderTest(kind)
        let database = try makeDatabase(subject.storage)
        _ = try database.rootCursor.writePath([.arrayListInit, .arrayListAppend, .linkedArrayListInit, .ctx]) {
            cursor in
            for index in 0..<count {
                _ = try cursor.writePath([.linkedArrayListAppend, .write(.uint(UInt64(index)))])
            }
        }
        #expect(try subject.storage.length == 231_398)

        let list = try LinkedArrayList(try lastMoment(database))
        #expect(try list.count == UInt64(count))
        #expect(try list.cursor(at: count - 1)?.readUInt64() == UInt64(count - 1))
    }

    /// `sorted_insert` at the plain file's size: 10,000 keys `key-<i>` put
    /// into a sorted map in one transaction.
    @Test(arguments: StorageKind.allCases)
    func sortedInsert(kind: StorageKind) throws {
        let count = 10_000
        let subject = try StorageUnderTest(kind)
        let database = try makeDatabase(subject.storage)
        let keys = (0..<count).map { SortedKey(Array("key-\($0)".utf8)) }
        _ = try database.rootCursor.writePath([.arrayListInit, .arrayListAppend, .sortedMapInit(), .ctx]) { cursor in
            for index in 0..<count {
                _ = try cursor.writePath([.sortedMapGet(.value, keys[index]), .write(.uint(UInt64(index)))])
            }
        }
        #expect(try subject.storage.length == 415_656)

        let map = try SortedMap(try lastMoment(database))
        #expect(try map.count == UInt64(count))
        #expect(try map.cursor(forKey: Array("key-9999".utf8))?.readUInt64() == 9999)
    }

    /// `map_compact` at the plain file's size: the source after 200
    /// transactions of ten keys, and the target its last moment compacts to.
    @Test(arguments: StorageKind.allCases)
    func mapCompact(kind: StorageKind) throws {
        let transactions = 200
        let sourceSubject = try StorageUnderTest(kind)
        let source = try makeDatabase(sourceSubject.storage)
        try writeTransactions(transactions, into: source)
        #expect(try sourceSubject.storage.length == 696_622)

        let targetSubject = try StorageUnderTest(kind)
        var offsetMap = MemoryOffsetMap()
        let target = try source.compact(
            into: targetSubject.storage, fileID: 0x0011_2233_4455_6677, offsetMap: &offsetMap)
        #expect(try targetSubject.storage.length == 172_304)
        #expect(try target.committedSize == 172_304)
        let moment = try lastMoment(target)
        #expect(
            try #require(try moment.readPath([.hashMapGet(.value, key(transactions * 10 - 1))])).readUInt64()
                == UInt64(transactions * 10 - 1))
    }

    /// `replicate` at the plain file's size: a full sync of the source's first
    /// 200 transactions into an empty replica, then an incremental sync of
    /// its last ten.
    @Test(arguments: StorageKind.allCases)
    func replicate(kind: StorageKind) throws {
        let transactions = 200
        let sourceSubject = try StorageUnderTest(kind)
        let source = try makeDatabase(sourceSubject.storage)
        try writeTransactions(transactions, into: source)
        let sizeAfterFirst = try source.committedSize
        #expect(sizeAfterFirst == 696_622)
        try writeTransactions(10, into: source, from: transactions)

        let replicaSubject = try StorageUnderTest(kind)
        let replica = try makeDatabase(replicaSubject.storage)
        try replica.applyReplicated(at: 0, bytes: try source.readCommitted(from: 0, to: sizeAfterFirst))
        #expect(try replica.committedSize == sizeAfterFirst)
        let start = try source.replicationStart(for: try replica.replicaState)
        #expect(start == sizeAfterFirst)
        let end = try source.committedSize
        try replica.applyReplicated(at: start, bytes: try source.readCommitted(from: start, to: end))
        #expect(try replica.committedSize == 736_058)
        #expect(try replicaSubject.storage.length == 736_058)
        #expect(try sourceSubject.storage.length == 736_058)
    }

    /// `map_transactions`' write phase: `transactions` transactions of ten
    /// keys each, every one a new moment, the keys counted from `first`.
    private func writeTransactions(_ transactions: Int, into database: Database, from first: Int = 0) throws {
        for transaction in first..<(first + transactions) {
            let root = database.rootCursor
            let last = try root.readPathSlot([.arrayListGet(-1)])
            _ = try root.writePath([.arrayListInit, .arrayListAppend, .write(.slot(last)), .hashMapInit(), .ctx]) {
                cursor in
                for index in (transaction * 10)..<(transaction * 10 + 10) {
                    _ = try cursor.writePath([.hashMapGet(.value, key(index)), .write(.uint(UInt64(index)))])
                }
            }
        }
    }
}
