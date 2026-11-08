import Testing

@testable import XitDB

/// A walk that met a structure it cannot describe: an index block where a
/// value should be.
struct WalkFailure: Error, CustomStringConvertible {
    let description: String
}

/// A structural walk of everything reachable from a cursor: every
/// collection with its count and its elements in order, every entry's key
/// and value, every value, written as one string, so that two walks can be
/// compared. Two databases holding the same data walk to the same string,
/// whatever their bytes; the same bytes walk to the same string however
/// they are read. M11's model-based tests need the same walk.
///
/// The walk keeps its own stack rather than recursing: the nesting of the
/// data is bounded by nothing but the file. A slot copied into a collection
/// it belongs to makes a cycle, which XitDB allows; the walk names it
/// instead of following it.
enum StructureWalk {
    /// What is left to do, on the walk's own stack.
    private enum Step {
        /// Describe what the cursor points at.
        case value(Cursor<ReadOnly>)
        /// Append this text.
        case text(String)
        /// The collection whose position is last on the path is done.
        case leave
    }

    /// The walk from `cursor`, following every collection to its leaves.
    ///
    /// - Throws: Whatever reading throws, or a `WalkFailure` for a
    ///   structure that is not a value; damage is reported, never described.
    static func describe(_ cursor: Cursor<ReadOnly>) throws -> String {
        var output = ""
        // The positions of the collections being walked, root first.
        var path: [UInt64] = []
        var stack: [Step] = [.value(cursor)]
        while let step = stack.popLast() {
            switch step {
            case .text(let text):
                output += text
            case .leave:
                path.removeLast()
            case .value(let cursor):
                try describe(cursor, into: &output, path: &path, stack: &stack)
            }
        }
        return output
    }

    private static func describe(
        _ cursor: Cursor<ReadOnly>, into output: inout String, path: inout [UInt64], stack: inout [Step]
    ) throws {
        let slot = try cursor.slot
        if slot.tag.pointsAtCollection {
            if path.contains(slot.value) {
                output += "cycle(\(slot.value))"
                return
            }
            path.append(slot.value)
            stack.append(.leave)
        }
        switch slot.tag {
        case .none:
            output += slot.full ? "nothing" : "empty"
        case .uint:
            output += "uint(\(try cursor.readUInt64()))"
        case .int:
            output += "int(\(try cursor.readInt64()))"
        case .float:
            output += "float(\(try cursor.readDouble().bitPattern))"
        case .bytes, .shortBytes:
            let bytes = try cursor.readBytesWithFormatTag()
            output += "bytes("
            if let tag = bytes.formatTag { output += "tag \(tag.description) " }
            output += "\(bytes.value.count): \(hex(bytes.value)))"
        case .kvPair, .sortedKvPair:
            let entry = try cursor.readEntry()
            output += "entry("
            stack.append(.text(")"))
            stack.append(.value(entry.value))
            stack.append(.text(" => "))
            stack.append(.value(entry.key))
        case .arrayList:
            // By index, not by the iterator, which passes over an element
            // that was appended and never written; here it is "empty".
            let list = try ArrayList<ReadOnly>(cursor)
            let count = try list.count
            var elements: [Cursor<ReadOnly>?] = []
            for index in 0..<count {
                elements.append(try list.cursor(at: index))
            }
            push("list", elements, count: count, onto: &stack, into: &output)
        case .linkedArrayList:
            let list = try LinkedArrayList<ReadOnly>(cursor)
            let count = try list.count
            var elements: [Cursor<ReadOnly>?] = []
            for index in 0..<count {
                elements.append(try list.cursor(at: index))
            }
            push("linked", elements, count: count, onto: &stack, into: &output)
        case .hashMap:
            push("map", try all(HashMap<ReadOnly>(cursor).iterator()), count: nil, onto: &stack, into: &output)
        case .hashSet:
            push("set", try all(HashSet<ReadOnly>(cursor).iterator()), count: nil, onto: &stack, into: &output)
        case .countedHashMap:
            let map = try CountedHashMap<ReadOnly>(cursor)
            push("counted map", try all(map.iterator()), count: try map.count, onto: &stack, into: &output)
        case .countedHashSet:
            let set = try CountedHashSet<ReadOnly>(cursor)
            push("counted set", try all(set.iterator()), count: try set.count, onto: &stack, into: &output)
        case .sortedMap:
            let map = try SortedMap<ReadOnly>(cursor)
            push("sorted map", try all(map.iterator()), count: try map.count, onto: &stack, into: &output)
        case .sortedSet:
            let set = try SortedSet<ReadOnly>(cursor)
            push("sorted set", try all(set.iterator()), count: try set.count, onto: &stack, into: &output)
        case .index:
            // An index block is never a value; a slot that says so is damage.
            throw WalkFailure(description: "an index slot where a value should be")
        }
    }

    /// Every element an iterator gives.
    private static func all(_ iterator: CollectionIterator) throws -> [Cursor<ReadOnly>?] {
        var iterator = iterator
        var elements: [Cursor<ReadOnly>?] = []
        while let element = try iterator.next() {
            elements.append(element)
        }
        return elements
    }

    /// Queues a collection's opening, its elements in order with their
    /// separators, and its closing with the count, which the description
    /// shows beside the number of elements where they differ.
    private static func push(
        _ kind: String, _ elements: [Cursor<ReadOnly>?], count: UInt64?, onto stack: inout [Step],
        into output: inout String
    ) {
        output += "\(kind)["
        if let count, count != UInt64(elements.count) {
            stack.append(.text("](\(count) counted, \(elements.count) given)"))
        } else {
            stack.append(.text(count.map { "](\($0))" } ?? "]"))
        }
        // Pushed last to first, so that they pop in order.
        for (index, element) in elements.enumerated().reversed() {
            if let element {
                stack.append(.value(element))
            } else {
                stack.append(.text("empty"))
            }
            if index > 0 { stack.append(.text(", ")) }
        }
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }
}

extension Slot.Tag {
    /// Whether a slot with this tag points at a collection, whose position
    /// the walk remembers against cycles.
    fileprivate var pointsAtCollection: Bool {
        switch self {
        case .arrayList, .linkedArrayList, .hashMap, .hashSet, .countedHashMap, .countedHashSet, .sortedMap, .sortedSet:
            true
        default:
            false
        }
    }

    /// Whether a slot with this tag is read from the storage: a value kept
    /// in the slot itself is not.
    var pointsIntoStorage: Bool {
        switch self {
        case .none, .uint, .int, .float, .shortBytes: false
        default: true
        }
    }
}
