// Runs generated transactions against the model and against a database of
// each storage kind, and checks them against each other after every commit.

import Foundation
import Testing

@testable import XitDB

/// A database under the model, on one storage kind.
struct ModelDatabase {
    let kind: StorageKind
    let subject: StorageUnderTest
    let database: Database
}

/// The marker a rolling-back transaction's body throws.
struct ModelRollback: Error {}

/// An operation the engine refused: the finding names it.
struct ModelRefusal: Error {
    let operation: ModelOperation
    let error: any Error
}

/// Runs transactions and checks; `mismatches` collects what it finds, one
/// line each, so that a failure says where.
final class ModelRunner {
    private(set) var moments: [ModelValue] = []
    let databases: [ModelDatabase]
    private var snapshots: [(moment: Int, snapshot: Snapshot)] = []
    private var replica: Database?
    private(set) var transactionsRun = 0
    private(set) var mismatches: [String] = []

    static let hashSize: UInt16 = 20

    init(kinds: [StorageKind]) throws {
        var databases: [ModelDatabase] = []
        for kind in kinds {
            let subject = try StorageUnderTest(kind)
            let database = try Database(
                storage: subject.storage, hashSize: Self.hashSize, hashID: nil, fileID: 7,
                random: FixedRandom((1...4000).map { UInt64($0) }))
            databases.append(ModelDatabase(kind: kind, subject: subject, database: database))
        }
        self.databases = databases
    }

    /// Runs one transaction everywhere and checks; returns the mismatches
    /// it found, none for a transaction that agrees.
    func run(_ transaction: ModelTransaction) throws -> [String] {
        let before = mismatches.count
        let base = moments.last ?? .map(ModelMap())
        var after = base
        for database in databases {
            after = try execute(transaction, on: database, from: base)
        }
        transactionsRun += 1
        if mismatches.count > before { return Array(mismatches[before...]) }
        if !transaction.rollsBack { moments.append(after) }
        try checkAll(deep: transactionsRun % 5 == 0)
        return Array(mismatches[before...])
    }

    // MARK: Executing

    private func execute(_ transaction: ModelTransaction, on database: ModelDatabase, from base: ModelValue) throws
        -> ModelValue
    {
        // One path from the root, as the fixtures and the original's appendContext
        // shape it, so that the commits are one per transaction and a printed
        // script makes the same file.
        let history = try ArrayList<ReadOnly>(database.database.rootCursor)
        let previous = try history.count > 0 ? try history.slot(at: -1) : nil
        let path: [PathPart] = [.arrayListInit, .arrayListAppend, .write(.slot(previous)), .ctx]
        var model = base
        do {
            _ = try database.database.rootCursor.writePath(path.span) { cursor in
                for (index, operation) in transaction.operations.enumerated() {
                    do {
                        try self.execute(operation, on: cursor, database: database.database, model: model)
                    } catch {
                        self.mismatches.append(
                            "transaction \(self.transactionsRun + 1), operation \(index + 1) on \(database.kind): \(error) for \(operation)"
                        )
                        throw ModelRollback()
                    }
                    ModelApplier.apply(operation, to: &model)
                }
                if transaction.rollsBack { throw ModelRollback() }
            }
        } catch is ModelRollback {
            return base
        }
        return model
    }

    private func execute(_ operation: ModelOperation, on body: Cursor<ReadWrite>, database: Database, model: ModelValue)
        throws
    {
        switch operation {
        case .put(let path, let value):
            var slot = try slotCursor(path, from: body, model: model)
            try slot.write(Self.data(value))
        case .remove(let path):
            guard let last = path.last else { return }
            let container = try slotCursor(path.dropLast(), from: body, model: model)
            switch (ModelKind.of(model.value(at: path.dropLast()[...]) ?? .map(ModelMap())) ?? .map, last) {
            case (.map, .key(let hash)): try HashMap<ReadWrite>(container).remove(forHash: hash)
            case (.countedMap, .key(let hash)): try CountedHashMap<ReadWrite>(container).remove(forHash: hash)
            case (.set, .key(let hash)): try HashSet<ReadWrite>(container).remove(forHash: hash)
            case (.countedSet, .key(let hash)): try CountedHashSet<ReadWrite>(container).remove(forHash: hash)
            case (.sortedMap, .sortedKey(let key)): try SortedMap<ReadWrite>(container).remove(forKey: key)
            case (.sortedSet, .sortedKey(let key)): try SortedSet<ReadWrite>(container).remove(forKey: key)
            default: break
            }
        case .putKey(let path, let name):
            guard case .key(let hash)? = path.last else { return }
            let container = try slotCursor(path.dropLast(), from: body, model: model)
            if case .countedMap? = model.value(at: path.dropLast()[...]) {
                try CountedHashMap<ReadWrite>(container).putKey(.bytes(name), forHash: hash)
            } else {
                try HashMap<ReadWrite>(container).putKey(.bytes(name), forHash: hash)
            }
        case .insert(let path, let hash, let name):
            let container = try slotCursor(path, from: body, model: model)
            switch model.value(at: path[...]) {
            case .countedSet?: try CountedHashSet<ReadWrite>(container).insert(.bytes(name), forHash: hash)
            case .sortedSet?: try SortedSet<ReadWrite>(container).insert(hash)
            default: try HashSet<ReadWrite>(container).insert(.bytes(name), forHash: hash)
            }
        case .make(let path, let kind):
            let slot = try slotCursor(path, from: body, model: model)
            switch kind {
            case .map: _ = try HashMap<ReadWrite>(slot)
            case .countedMap: _ = try CountedHashMap<ReadWrite>(slot)
            case .set: _ = try HashSet<ReadWrite>(slot)
            case .countedSet: _ = try CountedHashSet<ReadWrite>(slot)
            case .list: _ = try ArrayList<ReadWrite>(slot)
            case .linked: _ = try LinkedArrayList<ReadWrite>(slot)
            case .sortedMap: _ = try SortedMap<ReadWrite>(slot)
            case .sortedSet: _ = try SortedSet<ReadWrite>(slot)
            }
        case .append(let path, let value):
            let container = try slotCursor(path, from: body, model: model)
            if case .linked? = model.value(at: path[...]) {
                let list = try LinkedArrayList<ReadWrite>(container)
                if let value { try list.append(Self.data(value)) } else { _ = try list.appendCursor() }
            } else {
                let list = try ArrayList<ReadWrite>(container)
                if let value { try list.append(Self.data(value)) } else { _ = try list.appendCursor() }
            }
        case .truncate(let path, let count):
            try ArrayList<ReadWrite>(try slotCursor(path, from: body, model: model)).truncate(to: UInt64(count))
        case .insertAt(let path, let index, let value):
            try LinkedArrayList<ReadWrite>(try slotCursor(path, from: body, model: model)).insert(
                Self.data(value), at: index)
        case .removeAt(let path, let index):
            try LinkedArrayList<ReadWrite>(try slotCursor(path, from: body, model: model)).remove(at: index)
        case .slice(let path, let offset, let count):
            try LinkedArrayList<ReadWrite>(try slotCursor(path, from: body, model: model))
                .formSlice(offset: UInt64(offset), count: UInt64(count))
        case .join(let path, let other):
            let otherList = try LinkedArrayList<ReadOnly>(try slotCursor(other, from: body, model: model).readOnly)
            try LinkedArrayList<ReadWrite>(try slotCursor(path, from: body, model: model)).append(contentsOf: otherList)
        case .freeze:
            try database.freeze()
        }
    }

    /// The writable cursor at a path from the body's cursor, making the
    /// collections on the way as the engine's puts do, each of the kind the
    /// model has there.
    private func slotCursor(_ path: some Collection<ModelStep>, from body: Cursor<ReadWrite>, model: ModelValue) throws
        -> Cursor<ReadWrite>
    {
        var cursor = body
        var node: ModelValue? = model
        for step in path {
            switch step {
            case .key(let hash):
                if case .countedMap? = node {
                    cursor = try CountedHashMap<ReadWrite>(cursor).putCursor(forHash: hash)
                } else {
                    cursor = try HashMap<ReadWrite>(cursor).putCursor(forHash: hash)
                }
            case .index(let index):
                if case .linked? = node {
                    cursor = try LinkedArrayList<ReadWrite>(cursor).putCursor(at: index)
                } else {
                    cursor = try ArrayList<ReadWrite>(cursor).putCursor(at: index)
                }
            case .sortedKey(let key):
                cursor = try SortedMap<ReadWrite>(cursor).putCursor(forKey: key)
            }
            node = node?.value(at: [step][...])
        }
        return cursor
    }

    static func data(_ value: ModelValue) -> WritableData {
        switch value {
        case .uint(let n): .uint(n)
        case .int(let n): .int(n)
        case .float(let bits): .double(Double(bitPattern: bits))
        case .bytes(let bytes): .bytes(bytes)
        default: .slot(nil)
        }
    }

    // MARK: Checking

    private func checkAll(deep: Bool) throws {
        // The three storages hold the same bytes.
        if databases.count > 1 {
            let first = try databases[0].subject.stored()
            for database in databases.dropFirst() where try database.subject.stored() != first {
                mismatches.append(
                    "after transaction \(transactionsRun): the \(database.kind) storage's bytes differ from the \(databases[0].kind) storage's"
                )
            }
        }
        for database in databases {
            let history = try ArrayList<ReadOnly>(database.database.rootCursor)
            guard try history.count == UInt64(moments.count) else {
                mismatches.append(
                    "after transaction \(transactionsRun): \(database.kind) has \(try history.count) moments, the model \(moments.count)"
                )
                continue
            }
            let indexes = deep ? Array(moments.indices) : (moments.isEmpty ? [] : [moments.count - 1])
            for index in indexes {
                guard let cursor = try history.cursor(at: index) else {
                    mismatches.append(
                        "after transaction \(transactionsRun): \(database.kind) moment \(index) is missing")
                    continue
                }
                check(moments[index], cursor, at: "\(database.kind) moment \(index)")
            }
        }
        guard deep, !moments.isEmpty, let first = databases.first else { return }
        // Snapshots taken earlier still read their moment; one more is taken.
        for held in snapshots {
            let reading = SnapshotDatabase(held.snapshot)
            let history = try ArrayList<ReadOnly>(reading.rootCursor)
            if let cursor = try history.cursor(at: held.moment) {
                check(moments[held.moment], cursor, at: "snapshot at moment \(held.moment)")
            } else {
                mismatches.append("the snapshot at moment \(held.moment) has no such moment")
            }
        }
        if snapshots.count < 3 {
            snapshots.append((moments.count - 1, try first.database.snapshot()))
        }
        // Compaction keeps the last moment; every database compacts, since
        // the target draws from its source's randomness and the storages
        // must stay in step.
        for database in databases {
            var offsets = MemoryOffsetMap()
            let compacted = try database.database.compact(into: MemoryStorage(), fileID: 9, offsetMap: &offsets)
            let compactedHistory = try ArrayList<ReadOnly>(compacted.rootCursor)
            if try compactedHistory.count != 1 {
                mismatches.append(
                    "after transaction \(transactionsRun): \(database.kind) compacted has \(try compactedHistory.count) moments, not 1"
                )
            } else if let cursor = try compactedHistory.cursor(at: 0) {
                check(moments[moments.count - 1], cursor, at: "\(database.kind) compacted moment")
            }
        }
        // A file reopened reads the same.
        for database in databases {
            guard let path = database.subject.path else { continue }
            let reopened = try Database(opening: FileStorage(path: path, access: .readOnly, durability: .none))
            let history = try ArrayList<ReadOnly>(reopened.rootCursor)
            if try history.count != UInt64(moments.count) {
                mismatches.append(
                    "after transaction \(transactionsRun): \(database.kind) reopened has \(try history.count) moments, the model \(moments.count)"
                )
            } else if let cursor = try history.cursor(at: moments.count - 1) {
                check(moments[moments.count - 1], cursor, at: "\(database.kind) reopened, last moment")
            }
        }
        // Recovery of a copy cut short reads the model up to the last whole commit.
        let bytes = try first.subject.stored()
        let commits = try Database.verifiedCommits(in: MemoryStorage(bytes: bytes))
        if commits.count > 2 {
            // Cut inside the last commit, so that the one before it is the last whole one.
            let cut =
                Int(commits[commits.count - 2].end)
                + (Int(commits[commits.count - 1].end) - Int(commits[commits.count - 2].end)) / 2
            let recovered = try Database.recover(MemoryStorage(bytes: Array(bytes.prefix(cut))))
            let history = try ArrayList<ReadOnly>(recovered.rootCursor)
            // The commits are the creation and one per committed transaction,
            // so the copy holds the model's moments but the last.
            let expected = moments.count - 1
            if try history.count != UInt64(expected) {
                mismatches.append(
                    "after transaction \(transactionsRun): recovery of a copy cut at \(cut) has \(try history.count) moments, not \(expected)"
                )
            } else if expected > 0, let cursor = try history.cursor(at: expected - 1) {
                check(moments[expected - 1], cursor, at: "the recovered copy's last moment")
            }
        }
        // The replica follows the first database commit by commit.
        if replica == nil { replica = try Database(creating: MemoryStorage(), hashSize: Int(Self.hashSize)) }
        if let replica {
            let start = try first.database.replicationStart(for: replica.replicaState)
            let end = try first.database.committedSize
            if start < end {
                let bytes = try first.database.readCommitted(from: start, to: end)
                try replica.applyReplicated(at: start, bytes: bytes)
            }
            let replicaHistory = try ArrayList<ReadOnly>(replica.rootCursor)
            if try replicaHistory.count != UInt64(moments.count) {
                mismatches.append(
                    "after transaction \(transactionsRun): the replica has \(try replicaHistory.count) moments, the model \(moments.count)"
                )
            } else if let cursor = try replicaHistory.cursor(at: moments.count - 1) {
                check(moments[moments.count - 1], cursor, at: "the replica's last moment")
            }
        }
    }

    /// Checks a model value against what a cursor reads, into `mismatches`.
    private func check(_ model: ModelValue, _ cursor: Cursor<ReadOnly>, at place: String) {
        do {
            try compare(model, cursor, at: place)
        } catch {
            mismatches.append("\(place): reading failed: \(error)")
        }
    }

    private func compare(_ model: ModelValue, _ cursor: Cursor<ReadOnly>, at place: String) throws {
        func fail(_ what: String) { mismatches.append("\(place): \(what)") }
        switch model {
        case .uint(let n):
            let read = try cursor.readUInt64()
            if read != n { fail("uint \(read), model \(n)") }
        case .int(let n):
            let read = try cursor.readInt64()
            if read != n { fail("int \(read), model \(n)") }
        case .float(let bits):
            let read = try cursor.readDouble().bitPattern
            if read != bits { fail("float bits \(read), model \(bits)") }
        case .bytes(let bytes):
            let read = try cursor.readBytes()
            if read != bytes { fail("bytes \(hex(read.prefix(16))), model \(hex(bytes.prefix(16)))") }
        case .map(let map), .countedMap(let map):
            let counted: Bool
            let entries: (Int) throws -> Int
            let valueCursor: ([UInt8]) throws -> Cursor<ReadOnly>?
            let keyCursor: ([UInt8]) throws -> Cursor<ReadOnly>?
            if case .countedMap = model {
                let wrapper = try CountedHashMap<ReadOnly>(cursor)
                counted = true
                if try wrapper.count != UInt64(map.entries.count) {
                    fail("count \(try wrapper.count), model \(map.entries.count)")
                }
                entries = { _ in try Self.count(try wrapper.iterator()) }
                valueCursor = { try wrapper.cursor(forHash: $0) }
                keyCursor = { try wrapper.keyCursor(forHash: $0) }
            } else {
                let wrapper = try HashMap<ReadOnly>(cursor)
                counted = false
                entries = { _ in try Self.count(try wrapper.iterator()) }
                valueCursor = { try wrapper.cursor(forHash: $0) }
                keyCursor = { try wrapper.keyCursor(forHash: $0) }
            }
            _ = counted
            let found = try entries(0)
            if found != map.entries.count { fail("\(found) entries iterated, model \(map.entries.count)") }
            for (hash, value) in map.entries {
                let label = "\(place)/\(hex(hash.prefix(4)))"
                if let value {
                    guard let valueCursor = try valueCursor(hash) else {
                        fail("no entry for \(hex(hash.prefix(4)))")
                        continue
                    }
                    try compare(value, valueCursor, at: label)
                } else if let valueCursor = try valueCursor(hash), try valueCursor.slot.tag != .none {
                    fail("\(hex(hash.prefix(4))) holds a value where the model has none")
                }
                if let name = map.names[hash] {
                    guard let key = try keyCursor(hash) else {
                        fail("no key for \(hex(hash.prefix(4)))")
                        continue
                    }
                    if try key.readBytes() != name { fail("the key stored for \(hex(hash.prefix(4))) is not its name") }
                }
            }
        case .set(let set), .countedSet(let set):
            let contains: ([UInt8]) throws -> Bool
            let keyCursor: ([UInt8]) throws -> Cursor<ReadOnly>?
            let iterated: Int
            if case .countedSet = model {
                let wrapper = try CountedHashSet<ReadOnly>(cursor)
                if try wrapper.count != UInt64(set.hashes.count) {
                    fail("count \(try wrapper.count), model \(set.hashes.count)")
                }
                contains = { try wrapper.contains(hash: $0) }
                keyCursor = { try wrapper.cursor(forHash: $0) }
                iterated = try Self.count(try wrapper.iterator())
            } else {
                let wrapper = try HashSet<ReadOnly>(cursor)
                contains = { try wrapper.contains(hash: $0) }
                keyCursor = { try wrapper.cursor(forHash: $0) }
                iterated = try Self.count(try wrapper.iterator())
            }
            if iterated != set.hashes.count { fail("\(iterated) keys iterated, model \(set.hashes.count)") }
            for hash in set.hashes {
                if try !contains(hash) { fail("missing key \(hex(hash.prefix(4)))") }
                if let name = set.names[hash], let key = try keyCursor(hash), try key.readBytes() != name {
                    fail("the key stored for \(hex(hash.prefix(4))) is not its name")
                }
            }
        case .list(let elements), .linked(let elements):
            let count: UInt64
            let element: (Int) throws -> Cursor<ReadOnly>?
            if case .linked = model {
                let wrapper = try LinkedArrayList<ReadOnly>(cursor)
                count = try wrapper.count
                element = { try wrapper.cursor(at: $0) }
            } else {
                let wrapper = try ArrayList<ReadOnly>(cursor)
                count = try wrapper.count
                element = { try wrapper.cursor(at: $0) }
            }
            if count != UInt64(elements.count) {
                fail("count \(count), model \(elements.count)")
                return
            }
            for (index, value) in elements.enumerated() {
                let found = try element(index)
                if let value {
                    guard let found else {
                        fail("element \(index) is missing")
                        continue
                    }
                    try compare(value, found, at: "\(place)/#\(index)")
                } else if let found, try found.slot.tag != .none {
                    fail("element \(index) holds a value where the model has none")
                }
            }
        case .sortedMap(let entries):
            let wrapper = try SortedMap<ReadOnly>(cursor)
            if try wrapper.count != UInt64(entries.count) { fail("count \(try wrapper.count), model \(entries.count)") }
            var iterator = try wrapper.iterator()
            var index = 0
            while let pair = try iterator.next() {
                let entry = try pair.readEntry()
                let key = try entry.key.readBytes()
                guard index < entries.count else {
                    fail("more entries than the model's \(entries.count)")
                    break
                }
                if key != entries[index].key {
                    fail(
                        "entry \(index) has key \(String(decoding: key, as: UTF8.self)), model \(String(decoding: entries[index].key, as: UTF8.self))"
                    )
                }
                if let value = entries[index].value {
                    try compare(value, entry.value, at: "\(place)/\(String(decoding: key, as: UTF8.self))")
                }
                if try wrapper.rank(of: key) != UInt64(index) {
                    fail("rank of entry \(index) is \(try wrapper.rank(of: key))")
                }
                index += 1
            }
            if index != entries.count { fail("\(index) entries iterated, model \(entries.count)") }
        case .sortedSet(let keys):
            let wrapper = try SortedSet<ReadOnly>(cursor)
            if try wrapper.count != UInt64(keys.count) { fail("count \(try wrapper.count), model \(keys.count)") }
            var iterator = try wrapper.iterator()
            var index = 0
            while let pair = try iterator.next() {
                let key = try pair.readEntry().key.readBytes()
                guard index < keys.count else {
                    fail("more keys than the model's \(keys.count)")
                    break
                }
                if key != keys[index] {
                    fail(
                        "key \(index) is \(String(decoding: key, as: UTF8.self)), model \(String(decoding: keys[index], as: UTF8.self))"
                    )
                }
                if try !wrapper.contains(key) { fail("contains says no for key \(index)") }
                if try wrapper.rank(of: key) != UInt64(index) {
                    fail("rank of key \(index) is \(try wrapper.rank(of: key))")
                }
                index += 1
            }
            if index != keys.count { fail("\(index) keys iterated, model \(keys.count)") }
        }
    }

    private static func count(_ iterator: CollectionIterator) throws -> Int {
        var iterator = iterator
        var count = 0
        while try iterator.next() != nil { count += 1 }
        return count
    }
}
