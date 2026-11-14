import Foundation
import Testing
import XitDBHashing

@testable import XitDB

/// Model-based tests of the calls that take keys and typed values: random
/// operations through `put(_:forKey:)`, `value(forKey:as:)`, the typed
/// calls of the lists and the sorted map, the sets' `insert(_:)` and a
/// record that writes itself as a map, against plain Swift collections, on
/// a database of each storage kind that was given a hasher. Every commit
/// is checked through the latest moment, earlier moments and a snapshot,
/// and the three storages are byte for byte alike. As `ModelTests`, this
/// finds what differs from the model, not from the original; that a keyed
/// call writes what its call by hash writes is `KeyedAccessTests`' proof.
@Suite("keyed and typed model-based", .serialized)
struct KeyedModelTests {
    static let seeds: [UInt64] = Array(1...16)
    static let transactionsPerSeed = 20
    static let kinds: [StorageKind] = [.memory, .file, .bufferedFile]
    static let keys = (0..<12).map { "k\($0)" }

    /// The names of a record's fields: a type whose raw value is a key.
    enum Field: String, KeyRepresentable {
        case id, name, tags, score
    }

    /// A record: a map of its fields, with a list among them and one field
    /// that is there only when it has a value.
    struct Record: StorableValue, Equatable {
        var id: Int64
        var name: String
        var tags: [String]
        var score: Double?

        init(id: Int64, name: String, tags: [String], score: Double?) {
            self.id = id
            self.name = name
            self.tags = tags
            self.score = score
        }

        init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
            let fields = try HashMap<ReadOnly>(cursor)
            guard let id = try fields.value(forKey: Field.id, as: Int64.self),
                let name = try fields.value(forKey: Field.name, as: String.self),
                let list = try fields.cursor(forKey: Field.tags)
            else { throw .keyNotFound }
            self.id = id
            self.name = name
            let stored = try ArrayList<ReadOnly>(list)
            var tags: [String] = []
            for index in 0..<(try stored.count) {
                guard let tag = try stored.value(at: index, as: String.self) else { throw .keyNotFound }
                tags.append(tag)
            }
            self.tags = tags
            score = try fields.value(forKey: Field.score, as: Double.self)
        }

        func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
            // The record takes the place of the one that was there, with
            // none of its fields left.
            try cursor.write(.slot(nil))
            let fields = try HashMap<ReadWrite>(cursor)
            try fields.put(id, forKey: Field.id)
            try fields.put(name, forKey: Field.name)
            let list = try ArrayList<ReadWrite>(fields.putCursor(forKey: Field.tags))
            for tag in tags {
                try list.append(tag)
            }
            if let score {
                try fields.put(score, forKey: Field.score)
            }
        }
    }

    struct Model: Equatable {
        var numbers: [String: UInt64] = [:]
        /// The keys of `numbers` whose names are stored in the map. A put
        /// stores no name, so this is what `putKey(_:)` was called for and
        /// no remove has taken away since; a name can be stored for a key
        /// that has no value.
        var numberNames: Set<String> = []
        var names: [String] = []
        var records: [String: Record] = [:]
        var sorted: [String: Int64] = [:]
        var set: Set<String> = []
    }

    enum Operation: Equatable, CustomStringConvertible {
        case putNumber(String, UInt64)
        case storeNumberName(String)
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
            case .storeNumberName(let key): "numbers.putKey(\(key))"
            case .removeNumber(let key): "remove numbers[\(key)]"
            case .appendName(let name): "names.append(\(name))"
            case .truncateNames(let count): "names.truncate(\(count))"
            case .setRecord(let key, let record): "records[\(key)] = \(record)"
            case .clearRecord(let key): "remove records[\(key)]"
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
                KeyedModelTests.apply(operation, to: &working)
            }
            return Transaction(operations: operations, rollsBack: Int.random(in: 0..<8, using: &generator) == 0)
        }

        mutating func operation(against model: Model) -> Operation {
            let key = KeyedModelTests.keys.randomElement(using: &generator)!
            switch Int.random(in: 0..<14, using: &generator) {
            case 0: return .removeNumber(key)
            case 1: return .appendName("name \(Int.random(in: 0..<1000, using: &generator))")
            case 2 where !model.names.isEmpty:
                return .truncateNames(Int.random(in: 0..<model.names.count, using: &generator))
            case 3, 4:
                let record = Record(
                    id: Int64.random(in: -1000..<1000, using: &generator),
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
            case 11, 12: return .storeNumberName(key)
            default: return .putNumber(key, UInt64.random(in: 0..<10_000, using: &generator))
            }
        }
    }

    static func apply(_ operation: Operation, to model: inout Model) {
        switch operation {
        case .putNumber(let key, let value): model.numbers[key] = value
        case .storeNumberName(let key): model.numberNames.insert(key)
        case .removeNumber(let key):
            // A remove takes the whole entry: the value and the name.
            model.numbers[key] = nil
            model.numberNames.remove(key)
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

    /// A database on each storage kind, each given SHA-256, with the
    /// model's moments. The root is a history: each transaction appends a
    /// moment that starts as the one before it, a map of the model's five
    /// collections under their names.
    final class Runner {
        struct Side {
            let kind: StorageKind
            let subject: StorageUnderTest
            let database: Database
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
                    storage: subject.storage, hashSize: 32, hashID: "sha2", fileID: 7,
                    random: RandomSource(FixedRandom((1...2000).map { UInt64($0) })), hasher: KeyHasher(SHA256.self))
                return Side(kind: kind, subject: subject, database: database)
            }
        }

        func run(_ transaction: Transaction) throws -> [String] {
            let before = mismatches.count
            var after = moments.last ?? Model()
            for side in sides {
                var working = moments.last ?? Model()
                do {
                    let history = try ArrayList<ReadWrite>(side.database.rootCursor)
                    try history.append(.slot(try history.slot(at: -1))) { cursor in
                        let moment = try HashMap<ReadWrite>(cursor)
                        for (index, operation) in transaction.operations.enumerated() {
                            do {
                                try Self.execute(operation, in: moment)
                            } catch {
                                mismatches.append(
                                    "transaction \(run + 1), operation \(index + 1) on \(side.kind): \(error) for \(operation)"
                                )
                                throw Rollback()
                            }
                            KeyedModelTests.apply(operation, to: &working)
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

        /// One operation, through the calls that take keys and typed
        /// values, on a moment that is being written.
        private static func execute(_ operation: Operation, in moment: HashMap<ReadWrite>) throws {
            switch operation {
            case .putNumber(let key, let value):
                try HashMap<ReadWrite>(moment.putCursor(forKey: "numbers")).put(value, forKey: key)
            case .storeNumberName(let key):
                try HashMap<ReadWrite>(moment.putCursor(forKey: "numbers")).putKey(key)
            case .removeNumber(let key):
                try HashMap<ReadWrite>(moment.putCursor(forKey: "numbers")).remove(forKey: key)
            case .appendName(let name):
                try ArrayList<ReadWrite>(moment.putCursor(forKey: "names")).append(name)
            case .truncateNames(let count):
                try ArrayList<ReadWrite>(moment.putCursor(forKey: "names")).truncate(to: UInt64(count))
            case .setRecord(let key, let record):
                try CountedHashMap<ReadWrite>(moment.putCursor(forKey: "records")).put(record, forKey: key)
            case .clearRecord(let key):
                try CountedHashMap<ReadWrite>(moment.putCursor(forKey: "records")).remove(forKey: key)
            case .putSorted(let key, let value):
                try SortedMap<ReadWrite>(moment.putCursor(forKey: "sorted")).put(value, forKey: key)
            case .removeSorted(let key):
                try SortedMap<ReadWrite>(moment.putCursor(forKey: "sorted")).remove(forKey: key)
            case .insertKey(let key):
                try CountedHashSet<ReadWrite>(moment.putCursor(forKey: "set")).insert(key)
            case .removeKey(let key):
                try CountedHashSet<ReadWrite>(moment.putCursor(forKey: "set")).remove(forKey: key)
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
                let history = try ArrayList<ReadOnly>(side.database.rootCursor)
                if try history.count != UInt64(moments.count) {
                    mismatches.append(
                        "after transaction \(run): \(side.kind) has \(try history.count) moments, the model \(moments.count)"
                    )
                    continue
                }
                let indexes = deep ? Array(moments.indices) : [moments.count - 1]
                for index in indexes {
                    guard let moment = try history.cursor(at: index) else {
                        mismatches.append("\(side.kind) has no moment \(index)")
                        continue
                    }
                    try check(moments[index], moment, at: "\(side.kind) moment \(index)")
                }
            }
            guard deep, let first = sides.first else { return }
            if let snapshot {
                // The snapshot's database was given no hasher of its own:
                // it reads by keys with the one the snapshot carries.
                let history = try ArrayList<ReadOnly>(snapshot.database.rootCursor)
                guard let moment = try history.cursor(at: -1) else {
                    mismatches.append("the snapshot at moment \(snapshot.moment) has no moment")
                    return
                }
                try check(moments[snapshot.moment], moment, at: "the snapshot at moment \(snapshot.moment)")
            } else {
                snapshot = (moments.count - 1, SnapshotDatabase(try first.database.snapshot()))
            }
        }

        /// Checks a moment against the model, through the keyed and typed
        /// reads alone.
        private func check(_ model: Model, _ momentCursor: Cursor<ReadOnly>, at place: String) throws {
            func fail(_ what: String) { mismatches.append("\(place): \(what)") }
            let moment = try HashMap<ReadOnly>(momentCursor)

            // A collection the transactions never touched has no entry.
            let numbers = try moment.cursor(forKey: "numbers").map { cursor in try HashMap<ReadOnly>(cursor) }
            for key in KeyedModelTests.keys {
                let read = try numbers?.value(forKey: key, as: UInt64.self)
                if read != model.numbers[key] {
                    fail(
                        "numbers[\(key)] is \(String(describing: read)), model \(String(describing: model.numbers[key]))"
                    )
                }
            }
            // The names: stored for the keys `putKey(_:)` was called for
            // and for no others, whether or not the key has a value.
            for key in KeyedModelTests.keys {
                let name = try numbers?.keyCursor(forKey: key)?.read(String.self)
                let expected = model.numberNames.contains(key) ? key : nil
                if name != expected {
                    fail(
                        "the name of numbers[\(key)] is \(String(describing: name)), model \(String(describing: expected))"
                    )
                }
            }
            // And by iterating, which is how a reader finds the names: an
            // entry for each key that has a value or a name, the name there
            // where it was stored and under the hash of its bytes.
            let entered = Set(model.numbers.keys).union(model.numberNames)
            if let numbers {
                var entries = try numbers.iterator()
                var counted = 0
                var named: Set<String> = []
                while let cursor = try entries.next() {
                    counted += 1
                    let entry = try cursor.readEntry()
                    guard try !entry.key.slot.isEmpty else { continue }
                    let name = try entry.key.read(String.self)
                    named.insert(name)
                    if entry.hash != SHA256.keyHash(of: name) {
                        fail("the name \(name) is stored under another hash than its own")
                    }
                }
                if counted != entered.count { fail("\(counted) entries of numbers, model \(entered.count)") }
                if named != model.numberNames {
                    fail("the names stored in numbers are \(named.sorted()), model \(model.numberNames.sorted())")
                }
            } else if !entered.isEmpty {
                fail("no numbers, model \(entered.count)")
            }

            let names = try moment.cursor(forKey: "names").map { cursor in try ArrayList<ReadOnly>(cursor) }
            let nameCount = try names?.count ?? 0
            if nameCount != UInt64(model.names.count) {
                fail("\(nameCount) names, model \(model.names.count)")
            } else if let names {
                for (index, name) in model.names.enumerated() {
                    let read = try names.value(at: index, as: String.self)
                    if read != name { fail("names[\(index)] is \(String(describing: read)), model \(name)") }
                }
                if try names.value(at: model.names.count, as: String.self) != nil {
                    fail("a name past the end")
                }
            }

            let records = try moment.cursor(forKey: "records").map { cursor in try CountedHashMap<ReadOnly>(cursor) }
            for key in KeyedModelTests.keys {
                let read = try records?.value(forKey: key, as: Record.self)
                if read != model.records[key] {
                    fail(
                        "records[\(key)] is \(String(describing: read)), model \(String(describing: model.records[key]))"
                    )
                }
            }
            if try (records?.count ?? 0) != UInt64(model.records.count) {
                fail("\(try records?.count ?? 0) records, model \(model.records.count)")
            }

            let sorted = try moment.cursor(forKey: "sorted").map { cursor in try SortedMap<ReadOnly>(cursor) }
            let expectedKeys = model.sorted.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            if try (sorted?.count ?? 0) != UInt64(expectedKeys.count) {
                fail("\(try sorted?.count ?? 0) sorted entries, model \(expectedKeys.count)")
            }
            if let sorted {
                for key in KeyedModelTests.keys {
                    let read = try sorted.value(forKey: key, as: Int64.self)
                    if read != model.sorted[key] {
                        fail(
                            "sorted[\(key)] is \(String(describing: read)), model \(String(describing: model.sorted[key]))"
                        )
                    }
                }
                var entries = try sorted.iterator()
                var index = 0
                while let cursor = try entries.next() {
                    guard index < expectedKeys.count else {
                        fail("more sorted entries than the model's")
                        break
                    }
                    let entry = try cursor.readEntry()
                    let key = try entry.key.read(String.self)
                    let value = try entry.value.read(Int64.self)
                    if key != expectedKeys[index] || value != model.sorted[expectedKeys[index]] {
                        fail(
                            "sorted entry \(index) is \(key): \(value), model \(expectedKeys[index]): \(String(describing: model.sorted[expectedKeys[index]]))"
                        )
                    }
                    index += 1
                }
            }

            let set = try moment.cursor(forKey: "set").map { cursor in try CountedHashSet<ReadOnly>(cursor) }
            for key in KeyedModelTests.keys {
                let contained = try set?.contains(key) ?? false
                if contained != model.set.contains(key) {
                    fail("set.contains(\(key)) is \(contained), model \(model.set.contains(key))")
                }
                // The member is the key's bytes.
                if contained, try set?.cursor(forKey: key)?.read(String.self) != key {
                    fail("the member \(key) of the set does not read back as itself")
                }
            }
            if try (set?.count ?? 0) != UInt64(model.set.count) {
                fail("\(try set?.count ?? 0) members, model \(model.set.count)")
            }
        }
    }

    @Test(arguments: seeds)
    func theKeyedAndTypedCallsMatchTheModel(seed: UInt64) throws {
        try Self.run(seed: seed, transactions: Self.transactionsPerSeed)
    }

    @Test func soak() throws {
        let seconds = ProcessInfo.processInfo.environment["XITDB_MODEL_SOAK"].flatMap(Double.init) ?? 0
        let deadline = Date().addingTimeInterval(seconds)
        var seed = UInt64(Date().timeIntervalSince1970) &* 2_654_435_761 &+ 11
        var runs = 0
        repeat {
            try Self.run(seed: seed, transactions: Self.transactionsPerSeed)
            seed &+= 1
            runs += 1
        } while Date() < deadline
        if seconds > 0 {
            print("keyed soak: \(runs) seeds of \(Self.transactionsPerSeed) transactions, the last \(seed - 1)")
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
