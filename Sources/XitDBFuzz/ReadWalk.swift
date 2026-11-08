// The read walk of the battery: everything a cursor reaches, read by every
// method a cursor and a collection offer, with lookups at the edges of what
// an index or a key can be. Every error is discarded; the walk checks only
// that the library neither traps nor hangs.

import XitDB

/// Reads what `cursor` reaches, to a depth of eight and within a budget of
/// cursors.
func walk<Access: CursorAccess>(_ cursor: Cursor<Access>, depth: Int, budget: inout Int) {
    guard depth < 8, budget > 0 else { return }
    budget -= 1
    _ = try? cursor.slot
    _ = try? cursor.count
    _ = try? cursor.readUInt64()
    _ = try? cursor.readInt64()
    _ = try? cursor.readDouble()
    _ = try? cursor.readBytes(maxCount: 1 << 20)
    _ = try? cursor.readBytes()
    _ = try? cursor.readBytesWithFormatTag()
    var buffer = [UInt8](repeating: 0, count: 64)
    var span = buffer.mutableSpan
    _ = try? cursor.readBytes(into: &span)
    if var reader = try? cursor.reader() {
        _ = try? reader.read(into: &span)
        reader.seek(to: 3)
        _ = try? reader.readAll(into: &span)
        reader.seek(to: 0)
        _ = try? reader.readRemaining(maxCount: 1 << 20)
        reader.seek(to: 0)
        _ = try? reader.readRemaining()
    }
    if let entry = try? cursor.readEntry() {
        walk(entry.key, depth: depth + 1, budget: &budget)
        walk(entry.value, depth: depth + 1, budget: &budget)
    }
    guard let tag = try? cursor.slot.tag else { return }

    // the elements an iterator gives, up to a bound, each walked while the
    // budget lasts
    func iterate(_ iterator: CollectionIterator?) {
        guard var iterator else { return }
        var visited = 0
        while visited < 5000, let element = try? iterator.next() {
            visited += 1
            if budget > 0 {
                walk(element, depth: depth + 1, budget: &budget)
            }
        }
    }

    let hashSize = Int(cursor.database.header.hashSize)
    switch tag {
    case .arrayList:
        if let list = try? ArrayList<ReadOnly>(cursor) {
            iterate(try? list.iterator())
            for index in [0, 1, 15, 16, 17, 299, -1, -2, -300, Int.max, Int.min] {
                iterate(try? list.iterator(fromIndex: index))
                if let element = try? list.cursor(at: index) {
                    walk(element, depth: depth + 1, budget: &budget)
                }
                _ = try? list.slot(at: index)
            }
        }
    case .linkedArrayList:
        if let list = try? LinkedArrayList<ReadOnly>(cursor) {
            iterate(try? list.iterator())
            for index in [0, 1, 15, 16, 17, -1, -2, Int.max, Int.min] {
                iterate(try? list.iterator(fromIndex: index))
                if let element = try? list.cursor(at: index) {
                    walk(element, depth: depth + 1, budget: &budget)
                }
            }
        }
    case .hashMap:
        if let map = try? HashMap<ReadOnly>(cursor) {
            iterate(try? map.iterator())
            for name in keyNames {
                let keyHash = hash(name, hashSize)
                if let value = try? map.cursor(forHash: keyHash) {
                    walk(value, depth: depth + 1, budget: &budget)
                }
                _ = try? map.keyCursor(forHash: keyHash)
                _ = try? map.entry(forHash: keyHash)
            }
        }
    case .hashSet:
        if let set = try? HashSet<ReadOnly>(cursor) {
            iterate(try? set.iterator())
            _ = try? set.contains(hash: hash("k1", hashSize))
        }
    case .countedHashMap:
        if let map = try? CountedHashMap<ReadOnly>(cursor) {
            iterate(try? map.iterator())
            _ = try? map.count
            _ = try? map.entry(forHash: hash("k1", hashSize))
        }
    case .countedHashSet:
        if let set = try? CountedHashSet<ReadOnly>(cursor) {
            iterate(try? set.iterator())
            _ = try? set.count
        }
    case .sortedMap:
        if let map = try? SortedMap<ReadOnly>(cursor) {
            iterate(try? map.iterator())
            for index in [0, 1, 15, 16, -1, -2, Int.max, Int.min] {
                iterate(try? map.iterator(fromIndex: index))
                _ = try? map.entry(at: index)?.key.readBytes()
            }
            for key in ["", "k", "key-5", "zzz", "key-5-long-enough-for-a-record"] {
                let bytes = Array(key.utf8)
                iterate(try? map.iterator(fromKey: bytes))
                _ = try? map.rank(of: bytes)
                _ = try? map.cursor(forKey: bytes)
                _ = try? map.entry(forKey: bytes)
            }
        }
    case .sortedSet:
        if let set = try? SortedSet<ReadOnly>(cursor) {
            iterate(try? set.iterator())
            for index in [0, 1, -1, Int.max] {
                iterate(try? set.iterator(fromIndex: index))
                _ = try? set.entry(at: index)?.key.readBytes()
            }
            for key in ["", "s", "s1-long-key-long-key", "zzz"] {
                let bytes = Array(key.utf8)
                iterate(try? set.iterator(fromKey: bytes))
                _ = try? set.rank(of: bytes)
                _ = try? set.contains(bytes)
            }
        }
    default:
        break
    }
}
