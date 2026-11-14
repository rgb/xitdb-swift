// The workloads that compare the forms a call comes in: a hash given as a
// `Span` or as an array; a sorted map's key given as a `Span`,
// as an array or as text; a value given as a type or as `WritableData`.
// Each set writes the same file, so what differs between its members is the
// form alone. They are the port's own: the original has one form of each.

import Foundation
import XitDB
import XitDBHashing

/// The map of `map_by_hash`, by the `Span` form of each call: the hash
/// borrowed from the array that holds it, with nothing copied.
func mapByHashSpan(_ size: Int, kinds: [StorageKind]) -> Workload {
    Workload(name: "map_by_hash_span", size: size, kinds: kinds, keyKind: .keys, keyCount: size) { database, keys in
        let hashes = keys.hashBytes
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(nil)) { cursor in
            let map = try HashMap<ReadWrite>(cursor)
            for index in hashes.indices {
                let hash = hashes[index]
                try map.put(.uint(UInt64(index)), forHash: hash.span)
            }
        }
    } read: { reading, keys in
        let hashes = keys.hashBytes
        let map = try HashMap<ReadOnly>(try lastMoment(reading))
        for index in hashes.indices {
            let hash = hashes[index]
            guard try map.cursor(forHash: hash.span)?.readUInt64() == UInt64(index) else {
                throw BenchmarkFailure(description: "key-\(index) does not read back by its hash as a span")
            }
        }
    } iterate: { reading, keys in
        try iterateMap(try lastMoment(reading), keys)
    }
}

/// The forms a sorted map's key comes in: a span, and two kinds of key
/// through the one form that takes a key.
enum SortedKeyForm: String {
    /// The bytes borrowed from the array that holds them.
    case span
    /// The array as a key, whose bytes are itself.
    case bytes
    /// A `String` as a key, whose bytes are its UTF-8, copied into an
    /// array.
    case text
}

/// The map of `sorted_insert` written and read through the public
/// collection, by one form of the key.
func sortedByForm(_ form: SortedKeyForm, _ size: Int, kinds: [StorageKind]) -> Workload {
    Workload(name: "sorted_by_\(form.rawValue)", size: size, kinds: kinds, keyKind: .texts, keyCount: size) {
        database, keys in
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(nil)) { cursor in
            let map = try SortedMap<ReadWrite>(cursor)
            switch form {
            case .span:
                let texts = keys.texts
                for index in texts.indices {
                    let key = texts[index]
                    try map.put(.uint(UInt64(index)), forKey: key.span)
                }
            case .bytes:
                let texts = keys.texts
                for index in texts.indices {
                    try map.put(.uint(UInt64(index)), forKey: texts[index])
                }
            case .text:
                let strings = keys.strings
                for index in strings.indices {
                    try map.put(.uint(UInt64(index)), forKey: strings[index])
                }
            }
        }
    } read: { reading, keys in
        let map = try SortedMap<ReadOnly>(try lastMoment(reading))
        func check(_ index: Int, _ cursor: Cursor<ReadOnly>?) throws {
            guard try cursor?.readUInt64() == UInt64(index) else {
                throw BenchmarkFailure(description: "key-\(index) does not read back by \(form.rawValue)")
            }
        }
        switch form {
        case .span:
            let texts = keys.texts
            for index in texts.indices {
                let key = texts[index]
                try check(index, try map.cursor(forKey: key.span))
            }
        case .bytes:
            let texts = keys.texts
            for index in texts.indices {
                try check(index, try map.cursor(forKey: texts[index]))
            }
        case .text:
            let strings = keys.strings
            for index in strings.indices {
                try check(index, try map.cursor(forKey: strings[index]))
            }
        }
    } iterate: { reading, keys in
        let map = try SortedMap<ReadOnly>(try lastMoment(reading))
        guard try map.count == UInt64(keys.texts.count) else {
            throw BenchmarkFailure(description: "the sorted map has \(try map.count) entries")
        }
    }
}

/// A number and a text under each key, in two hash maps of a moment, on a
/// database given SHA-1: through the typed calls, or through `WritableData`
/// and the cursor's reads. Both hash every key, twice, so what differs is
/// how the value is given and taken.
func mapValues(typed: Bool, _ size: Int, kinds: [StorageKind]) -> Workload {
    Workload(
        name: typed ? "map_typed" : "map_untyped", size: size, kinds: kinds, keyKind: .keys, keyCount: size,
        prepare: { storage, _ in
            try Database(
                creating: storage.storage, hashing: Insecure.SHA1.self, hashID: "sha1", fileID: 0x0011_2233_4455_6677)
        },
        write: { _, keys, prepared in
            let database = prepared as! Database
            let strings = keys.strings
            let values = keys.values
            let history = try ArrayList<ReadWrite>(database.rootCursor)
            try history.append(.slot(nil)) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                let numbers = try HashMap<ReadWrite>(moment.putCursor(forKey: "numbers"))
                let texts = try HashMap<ReadWrite>(moment.putCursor(forKey: "texts"))
                if typed {
                    for index in strings.indices {
                        try numbers.put(UInt64(index), forKey: strings[index])
                        try texts.put(values[index], forKey: strings[index])
                    }
                } else {
                    for index in strings.indices {
                        try numbers.put(.uint(UInt64(index)), forKey: strings[index])
                        try texts.put(.bytes(Array(values[index].utf8)), forKey: strings[index])
                    }
                }
            }
            return database
        },
        read: { reading, keys, _ in
            let strings = keys.strings
            let values = keys.values
            let moment = try HashMap<ReadOnly>(try lastMoment(reading))
            guard let numbersCursor = try moment.cursor(forKey: "numbers"),
                let textsCursor = try moment.cursor(forKey: "texts")
            else { throw BenchmarkFailure(description: "the moment has no maps") }
            let numbers = try HashMap<ReadOnly>(numbersCursor)
            let texts = try HashMap<ReadOnly>(textsCursor)
            var wrong = 0
            if typed {
                for index in strings.indices {
                    if try numbers.value(forKey: strings[index], as: UInt64.self) != UInt64(index) { wrong += 1 }
                    if try texts.value(forKey: strings[index], as: String.self) != values[index] { wrong += 1 }
                }
            } else {
                for index in strings.indices {
                    if try numbers.cursor(forKey: strings[index])?.readUInt64() != UInt64(index) { wrong += 1 }
                    let bytes = try texts.cursor(forKey: strings[index])?.readBytes()
                    if bytes.map({ String(decoding: $0, as: UTF8.self) }) != values[index] { wrong += 1 }
                }
            }
            guard wrong == 0 else { throw BenchmarkFailure(description: "\(wrong) values do not read back") }
        },
        iterate: { reading, keys, _ in
            let moment = try HashMap<ReadOnly>(try lastMoment(reading))
            var iterator = try moment.iterator()
            var maps = 0
            while try iterator.next() != nil { maps += 1 }
            guard maps == 2 else { throw BenchmarkFailure(description: "the moment has \(maps) maps") }
        })
}

/// The same values in two lists, which hash nothing: a typed append and a
/// typed read against the append of `WritableData` and the cursor's read,
/// with only the list's own work beside them.
func listValues(typed: Bool, _ size: Int, kinds: [StorageKind]) -> Workload {
    Workload(
        name: typed ? "list_typed" : "list_untyped", size: size, kinds: kinds, keyKind: .keys, keyCount: size
    ) { database, keys in
        let values = keys.values
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(nil)) { cursor in
            let moment = try ArrayList<ReadWrite>(cursor)
            let numbers = try ArrayList<ReadWrite>(moment.appendCursor())
            let texts = try ArrayList<ReadWrite>(moment.appendCursor())
            if typed {
                for index in values.indices {
                    try numbers.append(UInt64(index))
                    try texts.append(values[index])
                }
            } else {
                for index in values.indices {
                    try numbers.append(.uint(UInt64(index)))
                    try texts.append(.bytes(Array(values[index].utf8)))
                }
            }
        }
    } read: { reading, keys in
        let values = keys.values
        let moment = try ArrayList<ReadOnly>(try lastMoment(reading))
        guard let numbersCursor = try moment.cursor(at: 0), let textsCursor = try moment.cursor(at: 1) else {
            throw BenchmarkFailure(description: "the moment has no lists")
        }
        let numbers = try ArrayList<ReadOnly>(numbersCursor)
        let texts = try ArrayList<ReadOnly>(textsCursor)
        var wrong = 0
        if typed {
            for index in values.indices {
                if try numbers.value(at: index, as: UInt64.self) != UInt64(index) { wrong += 1 }
                if try texts.value(at: index, as: String.self) != values[index] { wrong += 1 }
            }
        } else {
            for index in values.indices {
                if try numbers.cursor(at: index)?.readUInt64() != UInt64(index) { wrong += 1 }
                let bytes = try texts.cursor(at: index)?.readBytes()
                if bytes.map({ String(decoding: $0, as: UTF8.self) }) != values[index] { wrong += 1 }
            }
        }
        guard wrong == 0 else { throw BenchmarkFailure(description: "\(wrong) values do not read back") }
    } iterate: { reading, keys in
        let moment = try ArrayList<ReadOnly>(try lastMoment(reading))
        guard try moment.count == 2 else {
            throw BenchmarkFailure(description: "the moment has \(try moment.count) lists")
        }
    }
}

/// One slot written over and over through one cursor, and read back as
/// often: a number as a type, through `Cursor.write(_:)` and
/// `Cursor.read(_:)`, or as `WritableData` and through `readUInt64()`.
/// There is no collection's work beside it, so what the typed forms of a
/// cursor cost over the untyped ones is all that differs.
func cursorValues(typed: Bool, _ size: Int, kinds: [StorageKind]) -> Workload {
    Workload(
        name: typed ? "cursor_typed" : "cursor_untyped", size: size, kinds: kinds, keyKind: .none, keyCount: 0
    ) { database, _ in
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(nil)) { cursor in
            let moment = try ArrayList<ReadWrite>(cursor)
            var slot = try moment.appendCursor()
            if typed {
                for index in 0..<size {
                    try slot.write(UInt64(index))
                }
            } else {
                for index in 0..<size {
                    try slot.write(.uint(UInt64(index)))
                }
            }
        }
    } read: { reading, _ in
        let moment = try ArrayList<ReadOnly>(try lastMoment(reading))
        guard let slot = try moment.cursor(at: 0) else { throw BenchmarkFailure(description: "the moment has no slot") }
        var sum: UInt64 = 0
        if typed {
            for _ in 0..<size {
                sum &+= try slot.read(UInt64.self)
            }
        } else {
            for _ in 0..<size {
                sum &+= try slot.readUInt64()
            }
        }
        guard sum == UInt64(size) &* UInt64(size - 1) else {
            throw BenchmarkFailure(description: "the slot read back as a sum of \(sum)")
        }
    } iterate: { reading, _ in
        let moment = try ArrayList<ReadOnly>(try lastMoment(reading))
        guard try moment.count == 1 else {
            throw BenchmarkFailure(description: "the moment has \(try moment.count) slots")
        }
    }
}
