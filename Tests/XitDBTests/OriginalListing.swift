import Foundation
import Testing

@testable import XitDB

/// The listing of a database's content that the conformance repository's
/// `dump` prints through the original (its `src/dump.zig`), made here
/// through the port: every moment, in a text form that does not depend on
/// where anything is in the file. Offsets, sizes and commit IDs do not
/// appear, and collections print in the order of their hashes, keys or
/// indexes, so two readers that agree on what a file holds print the same
/// text, line for line.
///
/// It follows the original's tool step for step, by the same reads: an
/// array list's elements and a sorted map's entries by index, a hash map's
/// entries by its iterator, an entry through its key-value pair. Anything
/// that cannot be read prints as `error` and the name the original has for
/// the error, and is counted.
struct OriginalListing {
    private(set) var text = ""
    private(set) var errors = 0

    /// The slots of the collections around the one being printed: a file
    /// whose committed bytes were overwritten can make one contain itself.
    private var ancestors: [Slot] = []

    /// Where the original's tool stops without a listing: a file too short
    /// to have a database header, or one that does not start as a database.
    struct NoListing: Error, Equatable {
        let reason: String
    }

    /// The listing of the database in the file at `path`.
    ///
    /// As the original's tool does, it prints the header from the file's
    /// first twenty bytes as they are, and then opens the file read-only
    /// with the original's `Database.init`, which here is the Zig-shaped
    /// init: a file cut during its creation opens as a database without a
    /// first commit, whose root cannot be read, and is listed as that.
    ///
    /// - Throws: ``NoListing`` where the tool prints none, and what opening
    ///   the database throws; a database that opens always has a listing.
    static func listing(ofFileAt path: String) throws -> OriginalListing {
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        guard bytes.count >= 20 else { throw NoListing(reason: "too short to be a database") }
        guard Array(bytes[..<3]) == Array("xit".utf8) else { throw NoListing(reason: "not a xitdb file") }
        var listing = OriginalListing()
        let version = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        let hashSize = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        listing.text += "version: \(version)\nhash size: \(hashSize)\nhash id: "
        let hashID = Array(bytes[8..<12])
        if hashID.allSatisfy({ $0 == 0 }) {
            listing.text += "none"
        } else if hashID.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) {
            listing.text += String(decoding: hashID, as: UTF8.self)
        } else {
            listing.text += Self.hex(hashID)
        }
        listing.text += "\nfile id: \(Self.hex(bytes[12..<20]))\n"
        let storage = try FileStorage(path: path, access: .readOnly)
        let database = try Database(storage: storage, hashSize: hashSize)
        listing.printRoot(database.rootCursor.readOnly)
        return listing
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        var text = ""
        for byte in bytes {
            let digits = String(byte, radix: 16)
            text += digits.count == 1 ? "0" + digits : digits
        }
        return text
    }

    /// The name the original has for an error, as the conformance scripts
    /// expect it.
    private static func name(of error: any Error) -> String {
        guard let error = error as? XitDBError else { return "\(error)" }
        return ScriptRunner.name(of: error)
    }

    private mutating func line(_ level: Int, _ label: String, _ what: String) {
        text += String(repeating: "  ", count: level) + "\(label): \(what)\n"
    }

    private mutating func printError(_ level: Int, _ label: String, _ error: any Error) {
        errors += 1
        line(level, label, "error \(Self.name(of: error))")
    }

    /// Bytes as text in quotes when every one is printable ASCII other than
    /// a quote or a backslash, and as hex otherwise.
    private static func show(_ bytes: [UInt8]) -> String {
        if bytes.contains(where: { $0 < 0x20 || $0 > 0x7e || $0 == UInt8(ascii: "\"") || $0 == UInt8(ascii: "\\") }) {
            return "hex " + hex(bytes)
        }
        return "\"" + String(decoding: bytes, as: UTF8.self) + "\""
    }

    private mutating func printBytes(_ level: Int, _ label: String, _ tagName: String, _ cursor: Cursor<ReadOnly>) {
        let bytes: Bytes
        do {
            bytes = try cursor.readBytesWithFormatTag()
        } catch {
            return printError(level, label, error)
        }
        var what = "\(tagName) " + Self.show(bytes.value)
        if let tag = bytes.formatTag {
            what += " format tag " + Self.show([tag.bytes[0], tag.bytes[1]])
        }
        line(level, label, what)
    }

    private mutating func printEntry(_ level: Int, _ label: String, _ entry: Cursor<ReadOnly>) {
        let pair: Entry
        do {
            pair = try entry.readEntry()
        } catch {
            return printError(level, label, error)
        }
        text += String(repeating: "  ", count: level) + "\(label):\n"
        do {
            if try !pair.key.slot.isEmpty { printValue(level + 1, "key", pair.key) }
            if try !pair.value.slot.isEmpty { printValue(level + 1, "value", pair.value) }
        } catch {
            printError(level + 1, "entry", error)
        }
    }

    private mutating func printHashEntries(_ level: Int, _ cursor: Cursor<ReadOnly>) {
        var iterator: CollectionIterator
        do {
            iterator = try cursor.iterator()
        } catch {
            return printError(level, "entries", error)
        }
        while true {
            let next: Cursor<ReadOnly>?
            do {
                next = try iterator.next()
            } catch {
                return printError(level, "next entry", error)
            }
            guard let entry = next else { return }
            let pair: Entry
            do {
                pair = try entry.readEntry()
            } catch {
                printError(level, "entry", error)
                continue
            }
            printEntry(level, "entry \(Self.hex(pair.hash))", entry)
        }
    }

    private mutating func printElements(_ level: Int, _ cursor: Cursor<ReadOnly>, _ size: UInt64, linked: Bool) {
        for index in 0..<size {
            let label = "[\(index)]"
            let part: PathPart = linked ? .linkedArrayListGet(Int64(index)) : .arrayListGet(Int64(index))
            do {
                if let element = try cursor.readPath([part]) {
                    printValue(level, label, element)
                } else {
                    line(level, label, "empty")
                }
            } catch {
                printError(level, label, error)
            }
        }
    }

    private mutating func printSortedEntries(_ level: Int, _ cursor: Cursor<ReadOnly>, _ size: UInt64) {
        for index in 0..<size {
            let label = "[\(index)]"
            do {
                if let entry = try cursor.readPath([.sortedMapGetIndex(Int64(index))]) {
                    printEntry(level, label, entry)
                } else {
                    line(level, label, "empty")
                }
            } catch {
                printError(level, label, error)
            }
        }
    }

    /// The original's names for the tags.
    private static func tagName(_ tag: Slot.Tag) -> String {
        switch tag {
        case .none: "none"
        case .index: "index"
        case .arrayList: "array_list"
        case .linkedArrayList: "linked_array_list"
        case .hashMap: "hash_map"
        case .kvPair: "kv_pair"
        case .bytes: "bytes"
        case .shortBytes: "short_bytes"
        case .uint: "uint"
        case .int: "int"
        case .float: "float"
        case .hashSet: "hash_set"
        case .countedHashMap: "counted_hash_map"
        case .countedHashSet: "counted_hash_set"
        case .sortedMap: "sorted_map"
        case .sortedSet: "sorted_set"
        case .sortedKvPair: "sorted_kv_pair"
        }
    }

    private mutating func printValue(_ level: Int, _ label: String, _ cursor: Cursor<ReadOnly>) {
        let slot: Slot
        do {
            slot = try cursor.slot
        } catch {
            return printError(level, label, error)
        }
        do {
            switch slot.tag {
            case .none:
                line(level, label, slot.full ? "null" : "empty")
            case .uint:
                line(level, label, "uint \(try cursor.readUInt64())")
            case .int:
                line(level, label, "int \(try cursor.readInt64())")
            case .float:
                line(level, label, "float " + Self.hex(bigEndianBytes(try cursor.readDouble().bitPattern)))
            case .bytes, .shortBytes:
                printBytes(level, label, Self.tagName(slot.tag), cursor)
            case .arrayList, .linkedArrayList, .hashMap, .hashSet, .countedHashMap, .countedHashSet, .sortedMap,
                .sortedSet:
                if ancestors.contains(slot) {
                    line(level, label, "\(Self.tagName(slot.tag)) containing itself")
                    return
                }
                ancestors.append(slot)
                defer { ancestors.removeLast() }
                switch slot.tag {
                case .hashMap, .hashSet:
                    line(level, label, Self.tagName(slot.tag))
                    printHashEntries(level + 1, cursor)
                default:
                    let size = try cursor.count
                    line(level, label, "\(Self.tagName(slot.tag)) of \(size)")
                    switch slot.tag {
                    case .arrayList: printElements(level + 1, cursor, size, linked: false)
                    case .linkedArrayList: printElements(level + 1, cursor, size, linked: true)
                    case .sortedMap, .sortedSet: printSortedEntries(level + 1, cursor, size)
                    default: printHashEntries(level + 1, cursor)
                    }
                }
            case .index, .kvPair, .sortedKvPair:
                // these only show up if they were written where a value goes
                line(level, label, Self.tagName(slot.tag))
            }
        } catch {
            printError(level, label, error)
        }
    }

    private mutating func printRoot(_ root: Cursor<ReadOnly>) {
        let slot: Slot
        do {
            slot = try root.slot
        } catch {
            return printError(0, "root", error)
        }
        guard slot.tag == .arrayList else { return printValue(0, "root", root) }
        let size: UInt64
        do {
            size = try root.count
        } catch {
            return printError(0, "moments", error)
        }
        line(0, "moments", "\(size)")
        ancestors.append(slot)
        for index in 0..<size {
            let label = "moment \(index)"
            do {
                if let moment = try root.readPath([.arrayListGet(Int64(index))]) {
                    printValue(0, label, moment)
                } else {
                    line(0, label, "empty")
                }
            } catch {
                printError(0, label, error)
            }
        }
    }
}
