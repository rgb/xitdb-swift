import Foundation
import Testing
import XitDBStore

@testable import XitDB

/// Model-based tests of the store: random operations through handles, keys
/// as types and Codable records, against plain Swift collections, on a
/// database of each storage kind, checked after every commit through the
/// latest moment, earlier moments and a snapshot, the three storages byte
/// for byte alike. As `ModelTests`, this finds what differs from the model,
/// not from the original.
@Suite("store model-based", .serialized)
struct StoreModelTests {
    static let seeds: [UInt64] = Array(1...16)
    static let transactionsPerSeed = 20
    static let kinds: [StorageKind] = [.memory, .file, .bufferedFile]
    static let keys = (0..<12).map { "k\($0)" }

    struct Record: Codable, Equatable {
        var id: Int
        var name: String
        var tags: [String]
        var score: Double?
    }

    struct Model: Equatable {
        var numbers: [String: UInt64] = [:]
        var names: [String] = []
        var records: [String: Record] = [:]
        var sorted: [String: Int64] = [:]
        var set: Set<String> = []
    }

    enum Operation: Equatable, CustomStringConvertible {
        case putNumber(String, UInt64)
        case removeNumber(String)
        case appendName(String)
        case truncateNames(Int)
        case setRecord(String, Record)
        case clearRecord(String)
        case putSorted(String, Int64)
        case removeSorted(String)
        case insertKey(String)
        case removeKey(String)

        var description: String {
            switch self {
            case .putNumber(let key, let value): "numbers[\(key)] = \(value)"
            case .removeNumber(let key): "remove numbers[\(key)]"
            case .appendName(let name): "names.append(\(name))"
            case .truncateNames(let count): "names.truncate(\(count))"
            case .setRecord(let key, let record): "records[\(key)] = \(record)"
            case .clearRecord(let key): "clear records[\(key)]"
            case .putSorted(let key, let value): "sorted[\(key)] = \(value)"
            case .removeSorted(let key): "remove sorted[\(key)]"
            case .insertKey(let key): "set.insert(\(key))"
            case .removeKey(let key): "set.remove(\(key))"
            }
        }
    }

    struct Transaction: Equatable {
        var operations: [Operation]
        var rollsBack: Bool
    }

    struct Generator {
        var generator: SeededGenerator

        mutating func transaction(against model: Model) -> Transaction {
            var working = model
            var operations: [Operation] = []
            for _ in 0..<Int.random(in: 1...6, using: &generator) {
                let operation = self.operation(against: working)
                operations.append(operation)
                StoreModelTests.apply(operation, to: &working)
            }
            return Transaction(operations: operations, rollsBack: Int.random(in: 0..<8, using: &generator) == 0)
        }

        mutating func operation(against model: Model) -> Operation {
            let key = StoreModelTests.keys.randomElement(using: &generator)!
            switch Int.random(in: 0..<12, using: &generator) {
            case 0: return .removeNumber(key)
            case 1: return .appendName("name \(Int.random(in: 0..<1000, using: &generator))")
            case 2 where !model.names.isEmpty:
                return .truncateNames(Int.random(in: 0..<model.names.count, using: &generator))
            case 3, 4:
                let record = Record(
                    id: Int.random(in: -1000..<1000, using: &generator),
                    name: "r\(Int.random(in: 0..<100, using: &generator))",
                    tags: (0..<Int.random(in: 0..<4, using: &generator)).map { "t\($0)" },
                    score: Bool.random(using: &generator) ? Double(Int.random(in: 0..<100, using: &generator)) / 4 : nil
                )
                return .setRecord(key, record)
            case 5: return .clearRecord(key)
            case 6, 7: return .putSorted(key, Int64.random(in: -100..<100, using: &generator))
            case 8: return .removeSorted(key)
            case 9: return .insertKey(key)
            case 10: return .removeKey(key)
            default: return .putNumber(key, UInt64.random(in: 0..<10_000, using: &generator))
            }
        }
    }

    static func apply(_ operation: Operation, to model: inout Model) {
        switch operation {
        case .putNumber(let key, let value): model.numbers[key] = value
        case .removeNumber(let key): model.numbers[key] = nil
        case .appendName(let name): model.names.append(name)
        case .truncateNames(let count): model.names = Array(model.names.prefix(count))
        case .setRecord(let key, let record): model.records[key] = record
        case .clearRecord(let key): model.records[key] = nil
        case .putSorted(let key, let value): model.sorted[key] = value
        case .removeSorted(let key): model.sorted[key] = nil
        case .insertKey(let key): model.set.insert(key)
        case .removeKey(let key): model.set.remove(key)
        }
    }

    struct Rollback: Error {}

    /// A store on each storage kind, with the model's moments.
    final class Runner {
        struct Side {
            let kind: StorageKind
            let subject: StorageUnderTest
            let store: Store
        }

        let sides: [Side]
        private(set) var moments: [Model] = []
        private var snapshot: (moment: Int, database: SnapshotDatabase)?
        private(set) var mismatches: [String] = []
        private var run = 0

        init(kinds: [StorageKind]) throws {
            sides = try kinds.map { kind in
                let subject = try StorageUnderTest(kind)
                let database = try Database(
                    storage: subject.storage, hashSize: 32, hashID: nil, fileID: 7,
                    random: FixedRandom((1...2000).map { UInt64($0) }))
                return Side(kind: kind, subject: subject, store: try Store(database, hashing: SHA256.self))
            }
        }

        func run(_ transaction: Transaction) throws -> [String] {
            let before = mismatches.count
            var after = moments.last ?? Model()
            for side in sides {
                var working = moments.last ?? Model()
                do {
                    try side.store.transaction { moment in
                        for (index, operation) in transaction.operations.enumerated() {
                            do {
                                try Self.execute(operation, in: moment)
                            } catch {
                                mismatches.append(
                                    "transaction \(run + 1), operation \(index + 1) on \(side.kind): \(error) for \(operation)"
                                )
                                throw Rollback()
                            }
                            StoreModelTests.apply(operation, to: &working)
                        }
                        if transaction.rollsBack { throw Rollback() }
                    }
                } catch is Rollback {
                    working = moments.last ?? Model()
                }
                after = working
            }
            run += 1
            if mismatches.count > before { return Array(mismatches[before...]) }
            if !transaction.rollsBack { moments.append(after) }
            try checkAll(deep: run % 4 == 0)
            return Array(mismatches[before...])
        }

        private static func execute(_ operation: Operation, in moment: Moment) throws {
            switch operation {
            case .putNumber(let key, let value):
                try moment["numbers"].map(String.self, UInt64.self).put(value, forKey: key)
            case .removeNumber(let key): _ = try moment["numbers"].map(String.self, UInt64.self).remove(key)
            case .appendName(let name): try moment["names"].list(String.self).append(name)
            case .truncateNames(let count): try moment["names"].list(String.self).truncate(to: count)
            case .setRecord(let key, let record): try moment["records"][key].set(encoding: record)
            case .clearRecord(let key): try moment["records"][key].clear()
            case .putSorted(let key, let value):
                try moment["sorted"].sortedMap(String.self, Int64.self).put(value, forKey: key)
            case .removeSorted(let key): _ = try moment["sorted"].sortedMap(String.self, Int64.self).remove(key)
            case .insertKey(let key): try moment["set"].keySet(String.self).insert(key)
            case .removeKey(let key): _ = try moment["set"].keySet(String.self).remove(key)
            }
        }

        private func checkAll(deep: Bool) throws {
            if sides.count > 1 {
                let first = try sides[0].subject.stored()
                for side in sides.dropFirst() where try side.subject.stored() != first {
                    mismatches.append(
                        "after transaction \(run): the \(side.kind) storage's bytes differ from the \(sides[0].kind) storage's"
                    )
                }
            }
            guard !moments.isEmpty else { return }
            for side in sides {
                if try side.store.momentCount != moments.count {
                    mismatches.append(
                        "after transaction \(run): \(side.kind) has \(try side.store.momentCount) moments, the model \(moments.count)"
                    )
                    continue
                }
                let indexes = deep ? Array(moments.indices) : [moments.count - 1]
                for index in indexes {
                    try check(moments[index], try side.store.moment(at: index), at: "\(side.kind) moment \(index)")
                }
            }
            guard deep, let first = sides.first else { return }
            if let snapshot {
                try check(
                    moments[snapshot.moment], try Moment(reading: snapshot.database, hashing: SHA256.self),
                    at: "the snapshot at moment \(snapshot.moment)")
            } else {
                snapshot = (moments.count - 1, SnapshotDatabase(try first.store.snapshot()))
            }
        }

        private func check(_ model: Model, _ moment: Moment, at place: String) throws {
            func fail(_ what: String) { mismatches.append("\(place): \(what)") }
            let numbers = moment["numbers"].map(String.self, UInt64.self)
            for key in StoreModelTests.keys where try numbers[key] != model.numbers[key] {
                fail(
                    "numbers[\(key)] is \(String(describing: try numbers[key])), model \(String(describing: model.numbers[key]))"
                )
            }
            var values = try numbers.values()
            var counted = 0
            while try values.next() != nil { counted += 1 }
            if counted != model.numbers.count { fail("\(counted) numbers, model \(model.numbers.count)") }
            let names = moment["names"].list(String.self)
            if try names.count != model.names.count {
                fail("\(try names.count) names, model \(model.names.count)")
            } else {
                for (index, name) in model.names.enumerated() where try names[index] != name {
                    fail("names[\(index)] is \(String(describing: try names[index])), model \(name)")
                }
            }
            for key in StoreModelTests.keys {
                let read = try moment["records"][key].value(decoding: Record.self)
                if read != model.records[key] {
                    fail(
                        "records[\(key)] is \(String(describing: read)), model \(String(describing: model.records[key]))"
                    )
                }
            }
            let sorted = moment["sorted"].sortedMap(String.self, Int64.self)
            let expectedKeys = model.sorted.keys.sorted()
            if try sorted.count != expectedKeys.count {
                fail("\(try sorted.count) sorted entries, model \(expectedKeys.count)")
            }
            var entries = try sorted.entries()
            var index = 0
            while let entry = try entries.next() {
                guard index < expectedKeys.count else {
                    fail("more sorted entries than the model's")
                    break
                }
                if entry.key != expectedKeys[index] || entry.value != model.sorted[expectedKeys[index]] {
                    fail(
                        "sorted entry \(index) is \(entry.key): \(entry.value), model \(expectedKeys[index]): \(String(describing: model.sorted[expectedKeys[index]]))"
                    )
                }
                index += 1
            }
            let set = moment["set"].keySet(String.self)
            for key in StoreModelTests.keys where try set.contains(key) != model.set.contains(key) {
                fail("set.contains(\(key)) is \(try set.contains(key)), model \(model.set.contains(key))")
            }
        }
    }

    @Test(arguments: seeds)
    func theStoreMatchesTheModel(seed: UInt64) throws {
        try Self.run(seed: seed, transactions: Self.transactionsPerSeed)
    }

    @Test func soak() throws {
        let seconds = ProcessInfo.processInfo.environment["XITDB_MODEL_SOAK"].flatMap(Double.init) ?? 0
        let deadline = Date().addingTimeInterval(seconds)
        var seed = UInt64(Date().timeIntervalSince1970) &* 2_654_435_761 &+ 7
        var runs = 0
        repeat {
            try Self.run(seed: seed, transactions: Self.transactionsPerSeed)
            seed &+= 1
            runs += 1
        } while Date() < deadline
        if seconds > 0 {
            print("store soak: \(runs) seeds of \(Self.transactionsPerSeed) transactions, the last \(seed - 1)")
        }
    }

    static func run(seed: UInt64, transactions count: Int) throws {
        var generator = Generator(generator: SeededGenerator(seed: seed))
        let runner = try Runner(kinds: kinds)
        var transactions: [Transaction] = []
        for _ in 0..<count {
            let transaction = generator.transaction(against: runner.moments.last ?? Model())
            transactions.append(transaction)
            let found = try runner.run(transaction)
            if !found.isEmpty {
                // The shortest failing prefix, on memory alone.
                var shortest = transactions
                for length in 1...transactions.count {
                    let prefix = Array(transactions.prefix(length))
                    let runner = try Runner(kinds: [.memory])
                    if try prefix.contains(where: { try !runner.run($0).isEmpty }) {
                        shortest = prefix
                        break
                    }
                }
                let script = shortest.enumerated().map { number, transaction in
                    "transaction \(number + 1)\(transaction.rollsBack ? " (rolls back)" : ""):\n"
                        + transaction.operations.map { "  \($0)" }.joined(separator: "\n")
                }.joined(separator: "\n")
                Issue.record(
                    Comment(
                        rawValue:
                            "seed \(seed), transaction \(transactions.count): \(found.joined(separator: "; "))\nshortest failing prefix:\n\(script)"
                    ))
                return
            }
        }
    }
}
