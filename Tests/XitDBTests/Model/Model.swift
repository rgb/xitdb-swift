// The model the model-based tests check the engine against: plain Swift
// collections, nested as the generated data nests, one root per committed
// moment.

/// A value as the model holds it, mirroring what a slot can hold.
indirect enum ModelValue: Equatable {
    case uint(UInt64)
    case int(Int64)
    case float(UInt64)
    case bytes([UInt8])
    /// A hash map: values by key hash; `names` the key bytes stored beside
    /// a hash, where `putKey` or a set's insert stored them.
    case map(ModelMap)
    case countedMap(ModelMap)
    case set(ModelSet)
    case countedSet(ModelSet)
    case list([ModelValue?])
    case linked([ModelValue?])
    case sortedMap([SortedEntry])
    case sortedSet([[UInt8]])

    var isCollection: Bool {
        switch self {
        case .uint, .int, .float, .bytes: false
        default: true
        }
    }
}

struct ModelMap: Equatable {
    var entries: [[UInt8]: ModelValue?] = [:]
    var names: [[UInt8]: [UInt8]] = [:]
}

struct ModelSet: Equatable {
    var hashes: Set<[UInt8]> = []
    var names: [[UInt8]: [UInt8]] = [:]
}

struct SortedEntry: Equatable {
    var key: [UInt8]
    var value: ModelValue?
}

/// One step of a path from a moment's root.
enum ModelStep: Equatable, CustomStringConvertible {
    case key([UInt8])
    case index(Int)
    case sortedKey([UInt8])

    var description: String {
        switch self {
        case .key(let hash): hex(hash.prefix(4)) + "…"
        case .index(let index): "#\(index)"
        case .sortedKey(let key): "«\(String(decoding: key, as: UTF8.self))»"
        }
    }
}

func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { byte in
        let digits = String(byte, radix: 16)
        return digits.count == 1 ? "0" + digits : digits
    }.joined()
}

/// The kinds a collection can be made as.
enum ModelKind: CaseIterable {
    case map, countedMap, set, countedSet, list, linked, sortedMap, sortedSet

    var empty: ModelValue {
        switch self {
        case .map: .map(ModelMap())
        case .countedMap: .countedMap(ModelMap())
        case .set: .set(ModelSet())
        case .countedSet: .countedSet(ModelSet())
        case .list: .list([])
        case .linked: .linked([])
        case .sortedMap: .sortedMap([])
        case .sortedSet: .sortedSet([])
        }
    }

    static func of(_ value: ModelValue) -> ModelKind? {
        switch value {
        case .map: .map
        case .countedMap: .countedMap
        case .set: .set
        case .countedSet: .countedSet
        case .list: .list
        case .linked: .linked
        case .sortedMap: .sortedMap
        case .sortedSet: .sortedSet
        default: nil
        }
    }
}

extension ModelValue {
    /// The value at a path, or nil where the path finds nothing.
    func value(at path: ArraySlice<ModelStep>) -> ModelValue? {
        guard let step = path.first else { return self }
        let rest = path.dropFirst()
        switch (self, step) {
        case (.map(let map), .key(let hash)), (.countedMap(let map), .key(let hash)):
            guard let child = map.entries[hash], let child else { return nil }
            return child.value(at: rest)
        case (.list(let elements), .index(let index)), (.linked(let elements), .index(let index)):
            guard index >= 0, index < elements.count, let child = elements[index] else { return nil }
            return child.value(at: rest)
        case (.sortedMap(let entries), .sortedKey(let key)):
            guard let entry = entries.first(where: { $0.key == key }), let child = entry.value else { return nil }
            return child.value(at: rest)
        default:
            return nil
        }
    }

    /// Replaces the value at a path with what `change` makes of it, making
    /// the maps and lists on the way as the engine's `putCursor` does;
    /// `change` gets nil where there is nothing yet and returns the new
    /// value, or nil to write nothing.
    mutating func update(at path: ArraySlice<ModelStep>, _ change: (ModelValue?) -> ModelValue?) {
        guard let step = path.first else {
            if let changed = change(self) { self = changed }
            return
        }
        let rest = path.dropFirst()
        switch step {
        case .key(let hash):
            var map: ModelMap
            var counted = false
            switch self {
            case .map(let existing): map = existing
            case .countedMap(let existing):
                map = existing
                counted = true
            default: map = ModelMap()
            }
            var child = map.entries[hash] ?? nil
            if rest.isEmpty {
                let changed = change(child)
                map.entries[hash] = .some(changed)
            } else {
                var next = child ?? ModelStep.defaultContainer(for: rest.first!)
                next.update(at: rest, change)
                child = next
                map.entries[hash] = .some(child)
            }
            self = counted ? .countedMap(map) : .map(map)
        case .index(let index):
            var elements: [ModelValue?]
            var linked = false
            switch self {
            case .list(let existing): elements = existing
            case .linked(let existing):
                elements = existing
                linked = true
            default: elements = []
            }
            guard index >= 0, index < elements.count else { return }
            if rest.isEmpty {
                elements[index] = change(elements[index])
            } else {
                var next = elements[index] ?? ModelStep.defaultContainer(for: rest.first!)
                next.update(at: rest, change)
                elements[index] = next
            }
            self = linked ? .linked(elements) : .list(elements)
        case .sortedKey(let key):
            var entries: [SortedEntry]
            if case .sortedMap(let existing) = self { entries = existing } else { entries = [] }
            let position = entries.firstIndex { $0.key >= key } ?? entries.count
            if position < entries.count, entries[position].key == key {
                if rest.isEmpty {
                    entries[position].value = change(entries[position].value)
                } else {
                    var next = entries[position].value ?? ModelStep.defaultContainer(for: rest.first!)
                    next.update(at: rest, change)
                    entries[position].value = next
                }
            } else {
                var next: ModelValue? = nil
                if rest.isEmpty {
                    next = change(nil)
                } else {
                    var made = ModelStep.defaultContainer(for: rest.first!)
                    made.update(at: rest, change)
                    next = made
                }
                entries.insert(SortedEntry(key: key, value: next), at: position)
            }
            self = .sortedMap(entries)
        }
    }
}

extension ModelStep {
    /// The collection the engine makes for a step into nothing: a hash map
    /// for a key, an array list for an index, a sorted map for a sorted key.
    static func defaultContainer(for step: ModelStep) -> ModelValue {
        switch step {
        case .key: .map(ModelMap())
        case .index: .list([])
        case .sortedKey: .sortedMap([])
        }
    }
}

extension Array where Element == UInt8 {
    static func < (left: [UInt8], right: [UInt8]) -> Bool {
        left.lexicographicallyPrecedes(right)
    }
    static func >= (left: [UInt8], right: [UInt8]) -> Bool {
        !left.lexicographicallyPrecedes(right)
    }
}
