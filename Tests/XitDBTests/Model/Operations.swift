// The operations the model-based tests generate, and the generator.

@testable import XitDB

/// One operation on a moment, by path from its root.
enum ModelOperation: Equatable {
    /// Writes a scalar at the slot the path names, making the collections
    /// on the way.
    case put(path: [ModelStep], value: ModelValue)
    /// Removes the entry the path's last step names from the collection
    /// before it: a map's, a set's or a sorted collection's key.
    case remove(path: [ModelStep])
    /// Stores a key's name beside its hash in the map before the path's
    /// last step.
    case putKey(path: [ModelStep], name: [UInt8])
    /// Inserts a key into the set at the path: a hash with its name, or a
    /// sorted set's key bytes.
    case insert(path: [ModelStep], hash: [UInt8], name: [UInt8])
    /// Makes an empty collection of a kind at the path.
    case make(path: [ModelStep], kind: ModelKind)
    /// Appends to the list at the path: a value, or an empty element.
    case append(path: [ModelStep], value: ModelValue?)
    /// Cuts the array list at the path to `count` elements.
    case truncate(path: [ModelStep], count: Int)
    /// Inserts into the linked list at the path.
    case insertAt(path: [ModelStep], index: Int, value: ModelValue)
    /// Removes from the linked list at the path.
    case removeAt(path: [ModelStep], index: Int)
    /// Keeps `count` elements of the linked list at the path from `offset`.
    case slice(path: [ModelStep], offset: Int, count: Int)
    /// Appends the linked list at `other` to the one at the path, which
    /// freezes the transaction.
    case join(path: [ModelStep], other: [ModelStep])
    /// `Database.freeze()`.
    case freeze
}

/// One transaction: its operations, and whether its body throws at the
/// end, which rolls it back.
struct ModelTransaction: Equatable {
    var operations: [ModelOperation]
    var rollsBack: Bool
}

/// The fixed keys every generated map uses: sixteen names and their
/// SHA-1 hashes, so that the model never meets a collision the engine
/// would not.
enum ModelKeys {
    static let names: [[UInt8]] = (0..<16).map { Array("k\($0)".utf8) }
    static let hashes: [[UInt8]] = names.map { sha1(String(decoding: $0, as: UTF8.self)).bytes }
    static let sortedKeys: [[UInt8]] = (0..<16).map { Array("s\($0 < 10 ? "0" : "")\($0)".utf8) }

    static func index(ofHash hash: [UInt8]) -> Int? { hashes.firstIndex(of: hash) }
}

/// Makes transactions against the model's current shape, so that most
/// operations land on collections that exist and some make new ones.
struct ModelGenerator {
    var generator: SeededGenerator
    /// How deep a generated path may nest.
    let maxDepth = 3

    init(seed: UInt64) {
        generator = SeededGenerator(seed: seed)
    }

    mutating func transaction(against root: ModelValue) -> ModelTransaction {
        var working = root
        var operations: [ModelOperation] = []
        let count = Int.random(in: 1...8, using: &generator)
        for _ in 0..<count {
            let operation = self.operation(against: working)
            operations.append(operation)
            ModelApplier.apply(operation, to: &working)
        }
        return ModelTransaction(operations: operations, rollsBack: Int.random(in: 0..<10, using: &generator) == 0)
    }

    /// One operation, mostly on a collection that exists.
    mutating func operation(against root: ModelValue) -> ModelOperation {
        if Int.random(in: 0..<40, using: &generator) == 0 { return .freeze }
        let collections = Self.collections(in: root, path: [], depth: 0, maxDepth: maxDepth)
        // The nested collections get most of the operations once they exist: the root map alone is the dull case.
        let nested = collections.filter { !$0.path.isEmpty }
        let chosen = !nested.isEmpty && Int.random(in: 0..<4, using: &generator) != 0 ? nested : collections
        let (path, kind) = chosen.randomElement(using: &generator) ?? ([], .map)
        switch kind {
        case .map, .countedMap:
            let hash = ModelKeys.hashes.randomElement(using: &generator)!
            let entry = path + [.key(hash)]
            let existing = root.value(at: entry[...])
            switch Int.random(in: 0..<10, using: &generator) {
            case 0 where existing != nil:
                return .remove(path: entry)
            case 1:
                return .putKey(path: entry, name: ModelKeys.names[ModelKeys.index(ofHash: hash)!])
            case 2 where existing == nil && path.count < maxDepth, 3 where existing == nil && path.count < maxDepth,
                4 where existing == nil && path.count < maxDepth:
                // Lists and linked lists twice as often as the rest: their operations are the most varied.
                let kinds: [ModelKind] = [
                    .list, .list, .linked, .linked, .sortedMap, .sortedSet, .set, .countedSet, .countedMap, .map,
                ]
                return .make(path: entry, kind: kinds.randomElement(using: &generator)!)
            default:
                if let existing, existing.isCollection {
                    // A collection sits there: write beside it instead.
                    return .put(
                        path: path + [.key(ModelKeys.hashes.randomElement(using: &generator)!)], value: scalar())
                }
                return .put(path: entry, value: scalar())
            }
        case .set, .countedSet:
            let index = Int.random(in: 0..<ModelKeys.hashes.count, using: &generator)
            let hash = ModelKeys.hashes[index]
            if Int.random(in: 0..<4, using: &generator) == 0, case .set(let set)? = root.value(at: path[...]),
                set.hashes.contains(hash)
            {
                return .remove(path: path + [.key(hash)])
            }
            return .insert(path: path, hash: hash, name: ModelKeys.names[index])
        case .list:
            let elements = Self.elements(root.value(at: path[...]))
            switch Int.random(in: 0..<10, using: &generator) {
            case 0 where !elements.isEmpty:
                return .truncate(path: path, count: Int.random(in: 0..<elements.count, using: &generator))
            case 1 where !elements.isEmpty:
                return .put(
                    path: path + [.index(Int.random(in: 0..<elements.count, using: &generator))], value: scalar())
            case 2 where path.count < maxDepth:
                return .append(path: path, value: nil)
            default:
                return .append(path: path, value: scalar())
            }
        case .linked:
            let elements = Self.elements(root.value(at: path[...]))
            switch Int.random(in: 0..<12, using: &generator) {
            case 0 where !elements.isEmpty:
                return .removeAt(path: path, index: Int.random(in: 0..<elements.count, using: &generator))
            case 1 where !elements.isEmpty:
                // The engine inserts before an element that exists; the end is an append.
                return .insertAt(
                    path: path, index: Int.random(in: 0..<elements.count, using: &generator), value: scalar())
            case 2 where elements.count > 1:
                let offset = Int.random(in: 0..<elements.count, using: &generator)
                return .slice(
                    path: path, offset: offset, count: Int.random(in: 0...(elements.count - offset), using: &generator))
            case 3:
                let others = collections.filter { $0.kind == .linked && $0.path != path }
                if let other = others.randomElement(using: &generator) { return .join(path: path, other: other.path) }
                return .append(path: path, value: scalar())
            case 4 where !elements.isEmpty:
                return .put(
                    path: path + [.index(Int.random(in: 0..<elements.count, using: &generator))], value: scalar())
            default:
                return .append(path: path, value: scalar())
            }
        case .sortedMap:
            let key = ModelKeys.sortedKeys.randomElement(using: &generator)!
            if Int.random(in: 0..<5, using: &generator) == 0, root.value(at: (path + [.sortedKey(key)])[...]) != nil {
                return .remove(path: path + [.sortedKey(key)])
            }
            return .put(path: path + [.sortedKey(key)], value: scalar())
        case .sortedSet:
            let key = ModelKeys.sortedKeys.randomElement(using: &generator)!
            if Int.random(in: 0..<4, using: &generator) == 0, case .sortedSet(let keys)? = root.value(at: path[...]),
                keys.contains(key)
            {
                return .remove(path: path + [.sortedKey(key)])
            }
            return .insert(path: path, hash: key, name: key)
        }
    }

    mutating func scalar() -> ModelValue {
        switch Int.random(in: 0..<6, using: &generator) {
        case 0: return .int(Int64.random(in: -500..<500, using: &generator))
        case 1:
            return .float(
                Double(Int.random(in: -1000..<1000, using: &generator)).bitPattern / 1
                    + UInt64(Int.random(in: 0..<4, using: &generator)))
        case 2:
            let length = Int.random(in: 0..<40, using: &generator)
            return .bytes((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
        case 3:
            return .bytes(Array("text \(Int.random(in: 0..<100, using: &generator))".utf8))
        default: return .uint(UInt64.random(in: 0..<1000, using: &generator))
        }
    }

    /// Every collection in the model with its path, the root included.
    static func collections(in value: ModelValue, path: [ModelStep], depth: Int, maxDepth: Int) -> [(
        path: [ModelStep], kind: ModelKind
    )] {
        guard let kind = ModelKind.of(value) else { return [] }
        var found = [(path, kind)]
        guard depth < maxDepth else { return found }
        switch value {
        case .map(let map), .countedMap(let map):
            for (hash, child) in map.entries.sorted(by: { $0.key < $1.key }) {
                if let child {
                    found += collections(in: child, path: path + [.key(hash)], depth: depth + 1, maxDepth: maxDepth)
                }
            }
        case .list(let elements), .linked(let elements):
            for (index, child) in elements.enumerated() {
                if let child {
                    found += collections(in: child, path: path + [.index(index)], depth: depth + 1, maxDepth: maxDepth)
                }
            }
        case .sortedMap(let entries):
            for entry in entries {
                if let child = entry.value {
                    found += collections(
                        in: child, path: path + [.sortedKey(entry.key)], depth: depth + 1, maxDepth: maxDepth)
                }
            }
        default:
            break
        }
        return found
    }

    static func elements(_ value: ModelValue?) -> [ModelValue?] {
        switch value {
        case .list(let elements)?, .linked(let elements)?: elements
        default: []
        }
    }
}

/// Applies an operation to the model.
enum ModelApplier {
    static func apply(_ operation: ModelOperation, to root: inout ModelValue) {
        switch operation {
        case .put(let path, let value):
            root.update(at: path[...]) { _ in value }
        case .remove(let path):
            guard let last = path.last else { return }
            root.update(at: path.dropLast()[...]) { container in
                guard let container else { return nil }
                switch (container, last) {
                case (.map(var map), .key(let hash)):
                    map.entries[hash] = nil
                    map.names[hash] = nil
                    return .map(map)
                case (.countedMap(var map), .key(let hash)):
                    map.entries[hash] = nil
                    map.names[hash] = nil
                    return .countedMap(map)
                case (.set(var set), .key(let hash)):
                    set.hashes.remove(hash)
                    set.names[hash] = nil
                    return .set(set)
                case (.countedSet(var set), .key(let hash)):
                    set.hashes.remove(hash)
                    set.names[hash] = nil
                    return .countedSet(set)
                case (.sortedMap(var entries), .sortedKey(let key)):
                    entries.removeAll { $0.key == key }
                    return .sortedMap(entries)
                case (.sortedSet(var keys), .sortedKey(let key)):
                    keys.removeAll { $0 == key }
                    return .sortedSet(keys)
                default:
                    return container
                }
            }
        case .putKey(let path, let name):
            guard case .key(let hash)? = path.last else { return }
            root.update(at: path.dropLast()[...]) { container in
                switch container {
                case .countedMap(var map):
                    if map.entries[hash] == nil { map.entries[hash] = .some(nil) }
                    map.names[hash] = name
                    return .countedMap(map)
                default:
                    var map: ModelMap
                    if case .map(let existing)? = container { map = existing } else { map = ModelMap() }
                    if map.entries[hash] == nil { map.entries[hash] = .some(nil) }
                    map.names[hash] = name
                    return .map(map)
                }
            }
        case .insert(let path, let hash, let name):
            root.update(at: path[...]) { container in
                switch container {
                case .countedSet(var set):
                    set.hashes.insert(hash)
                    set.names[hash] = name
                    return .countedSet(set)
                case .sortedSet(var keys):
                    if !keys.contains(hash) {
                        keys.insert(hash, at: keys.firstIndex { $0 >= hash } ?? keys.count)
                    }
                    return .sortedSet(keys)
                default:
                    var set: ModelSet
                    if case .set(let existing)? = container { set = existing } else { set = ModelSet() }
                    set.hashes.insert(hash)
                    set.names[hash] = name
                    return .set(set)
                }
            }
        case .make(let path, let kind):
            root.update(at: path[...]) { existing in existing ?? kind.empty }
        case .append(let path, let value):
            root.update(at: path[...]) { container in
                switch container {
                case .linked(var elements):
                    elements.append(value)
                    return .linked(elements)
                default:
                    var elements: [ModelValue?] = []
                    if case .list(let existing)? = container { elements = existing }
                    elements.append(value)
                    return .list(elements)
                }
            }
        case .truncate(let path, let count):
            root.update(at: path[...]) { container in
                guard case .list(let elements)? = container else { return container }
                return .list(Array(elements.prefix(count)))
            }
        case .insertAt(let path, let index, let value):
            root.update(at: path[...]) { container in
                var elements: [ModelValue?] = []
                if case .linked(let existing)? = container { elements = existing }
                guard index <= elements.count else { return container }
                elements.insert(value, at: index)
                return .linked(elements)
            }
        case .removeAt(let path, let index):
            root.update(at: path[...]) { container in
                guard case .linked(var elements)? = container, index < elements.count else { return container }
                elements.remove(at: index)
                return .linked(elements)
            }
        case .slice(let path, let offset, let count):
            root.update(at: path[...]) { container in
                guard case .linked(let elements)? = container, offset + count <= elements.count else {
                    return container
                }
                return .linked(Array(elements[offset..<(offset + count)]))
            }
        case .join(let path, let other):
            let appended = ModelGenerator.elements(root.value(at: other[...]))
            root.update(at: path[...]) { container in
                var elements: [ModelValue?] = []
                if case .linked(let existing)? = container { elements = existing }
                return .linked(elements + appended)
            }
        case .freeze:
            break
        }
    }
}
