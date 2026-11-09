// Reading a file into the dump's tree: every read that fails becomes a
// node that says so, and nothing traps.

package import XitDB

/// Reads a database into a ``Dump``.
package struct Dumper {
    package let options: DumpOptions

    /// Collections already dumped, by position, with where they were seen.
    private var seen: [UInt64: String] = [:]
    /// Key names by hash, from `--keys`.
    private var names: [[UInt8]: String] = [:]
    private var hashSize = 0
    private var depthLimit: Int
    /// Nodes left before the dump stops: a damaged file can describe more
    /// than any dump should print.
    private var budget: Int
    private var budgetSpent = false

    /// The most nodes one dump makes: a million, or ten times the
    /// per-collection limit when that is raised, so that a reader who asks
    /// for a large collection gets it.
    package static func nodeBudget(limit: Int) -> Int {
        max(1_000_000, limit.multipliedReportingOverflow(by: 10).partialValue)
    }

    package init(options: DumpOptions) {
        self.options = options
        depthLimit = options.depth ?? DumpOptions.defaultDepth
        budget = Self.nodeBudget(limit: options.limit)
    }

    /// Dumps the file in a storage, read-only; a damaged file is dumped as
    /// far as its last good commit, which is said.
    package mutating func dump(_ storage: any WritableStorage) -> Dump {
        var dump = Dump()
        let fileSize: UInt64
        do {
            fileSize = try storage.length
        } catch {
            dump.notes.append("the storage's length could not be read: \(error)")
            dump.exitCode = 2
            return dump
        }
        if options.verify {
            verify(storage, fileSize: fileSize, into: &dump)
        }
        let database: Database
        do {
            database = try Database(opening: storage)
        } catch .untrustedRootHeader(let lastVerified) {
            // Recovery cuts the file back to its last good commit and mends
            // the root header: done to a copy in memory, so that the file
            // stays as it is, and what opens is what recovery would open.
            dump.notes.append(
                "the root header cannot be trusted: the last commit that verifies ends at byte \(lastVerified) of \(fileSize); what follows is what recovery would open"
            )
            dump.exitCode = 1
            guard let copy = Self.copy(storage, upTo: fileSize) else {
                dump.notes.append("the file could not be read into memory")
                dump.exitCode = 2
                return dump
            }
            do {
                database = try Database.recover(copy)
            } catch {
                dump.notes.append("recovery does not open it either: \(error)")
                dump.exitCode = 2
                return dump
            }
        } catch {
            dump.notes.append("not an xitdb file that opens: \(error)")
            dump.exitCode = 2
            return dump
        }
        read(database, fileSize: fileSize, into: &dump)
        return dump
    }

    /// Dumps a database already open.
    package mutating func dump(_ database: Database) -> Dump {
        var dump = Dump()
        read(database, fileSize: (try? database.committedSize) ?? 0, into: &dump)
        return dump
    }

    private static func copy(_ storage: any ReadableStorage, upTo end: UInt64) -> MemoryStorage? {
        guard let count = Int(exactly: end) else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        var span = bytes.mutableSpan
        guard let read = try? storage.read(into: &span, range: 0..<count, at: 0), read == count else { return nil }
        return MemoryStorage(bytes: bytes)
    }

    private mutating func read(_ database: Database, fileSize: UInt64, into dump: inout Dump) {
        hashSize = Int(database.header.hashSize)
        for name in options.keys {
            let hash = options.hash.hash(Array(name.utf8))
            if hash.count >= hashSize { names[Array(hash.prefix(hashSize))] = name }
        }
        let root = database.rootCursor.readOnly
        let hashID = database.header.hashID.rawValue
        let hashIDBytes = [
            UInt8(hashID >> 24), UInt8(hashID >> 16 & 0xFF), UInt8(hashID >> 8 & 0xFF), UInt8(hashID & 0xFF),
        ]
        let hashIDText =
            hashIDBytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) ? String(decoding: hashIDBytes, as: UTF8.self) : nil
        var header = Dump.Header(
            fileSize: fileSize, committedSize: (try? database.committedSize) ?? fileSize, hashSize: hashSize,
            hashIDText: hashIDText, hashIDHex: Self.hex(hashIDBytes),
            fileID: Self.hex(bigEndian: database.header.fileID),
            momentCount: nil)
        let history: ArrayList<ReadOnly>?
        do {
            let list = try ArrayList<ReadOnly>(root)
            header.momentCount = try list.count
            history = list
        } catch {
            history = nil
        }
        dump.header = header
        guard let history, let count = header.momentCount else {
            // The root is not a history: dump it as one moment.
            dump.notes.append("the root is not a list of moments; it is dumped as it is")
            dump.moments = [Dump.Moment(index: 0, root: node(root, path: "root", depth: 0))]
            if dump.exitCode == 0, containsDamage(dump.moments[0].root) { dump.exitCode = 1 }
            return
        }
        var indexes: [Int] = []
        if options.allMoments {
            indexes = Array(0..<Int(min(count, UInt64(Int.max))))
        } else if count > 0 {
            let wanted = options.moment ?? -1
            let index = wanted < 0 ? Int(count) + wanted : wanted
            if index < 0 || UInt64(index) >= count {
                dump.notes.append("there is no moment \(wanted): the history has \(count)")
                dump.exitCode = max(dump.exitCode, 1)
            } else {
                indexes = [index]
            }
        }
        for index in indexes {
            var cursor: Cursor<ReadOnly>?
            do {
                cursor = try history.cursor(at: index)
            } catch {
                dump.moments.append(
                    Dump.Moment(index: index, root: Node(.unreadable, text: "moment \(index): \(error)")))
                continue
            }
            guard var cursor else {
                dump.moments.append(Dump.Moment(index: index, root: Node(.empty)))
                continue
            }
            var label = "moment \(index)"
            var failed: Node?
            for step in options.path {
                switch descend(cursor, by: step) {
                case .success(let next):
                    cursor = next
                    label += "/" + Self.describe(step)
                case .failure(let error):
                    failed = Node(.unreadable, text: "no such place: \(Self.describe(step)) (\(error))")
                }
                if failed != nil { break }
            }
            let node = failed ?? node(cursor, path: label, depth: 0)
            dump.moments.append(Dump.Moment(index: index, root: node))
        }
        if budgetSpent {
            dump.notes.append(
                "the dump stopped at \(Self.nodeBudget(limit: options.limit)) nodes, what came first; --limit raises it with the collections' cap"
            )
        }
        if dump.exitCode == 0, dump.moments.contains(where: { containsDamage($0.root) }) { dump.exitCode = 1 }
    }

    // MARK: Paths

    private enum StepFailure: Error, CustomStringConvertible {
        case missing
        case kind(String)
        case read(XitDBError)
        var description: String {
            switch self {
            case .missing: "nothing there"
            case .kind(let what): what
            case .read(let error): "\(error)"
            }
        }
    }

    private func descend(_ cursor: Cursor<ReadOnly>, by step: DumpOptions.PathStep) -> Result<
        Cursor<ReadOnly>, StepFailure
    > {
        do {
            let tag = try cursor.slot.tag
            switch step {
            case .index(let index):
                let next: Cursor<ReadOnly>?
                switch tag {
                case .arrayList: next = try ArrayList<ReadOnly>(cursor).cursor(at: index)
                case .linkedArrayList: next = try LinkedArrayList<ReadOnly>(cursor).cursor(at: index)
                default: return .failure(.kind("not a list: \(tag)"))
                }
                guard let next else { return .failure(.missing) }
                return .success(next)
            case .key(let name):
                switch tag {
                case .sortedMap:
                    guard let next = try SortedMap<ReadOnly>(cursor).cursor(forKey: Array(name.utf8)) else {
                        return .failure(.missing)
                    }
                    return .success(next)
                default:
                    return descend(cursor, by: .hash(options.hash.hash(Array(name.utf8))))
                }
            case .hash(let hash):
                let next: Cursor<ReadOnly>?
                switch tag {
                case .hashMap: next = try HashMap<ReadOnly>(cursor).cursor(forHash: hash)
                case .countedHashMap: next = try CountedHashMap<ReadOnly>(cursor).cursor(forHash: hash)
                case .hashSet: next = try HashSet<ReadOnly>(cursor).cursor(forHash: hash)
                case .countedHashSet: next = try CountedHashSet<ReadOnly>(cursor).cursor(forHash: hash)
                default: return .failure(.kind("not a map: \(tag)"))
                }
                guard let next else { return .failure(.missing) }
                return .success(next)
            }
        } catch {
            return .failure(.read(error))
        }
    }

    private static func describe(_ step: DumpOptions.PathStep) -> String {
        switch step {
        case .index(let index): "#\(index)"
        case .key(let name): name
        case .hash(let hash): hex(hash)
        }
    }

    // MARK: Nodes

    /// A child still to be read, or ready.
    private struct Pending {
        var cursor: Cursor<ReadOnly>?
        var ready: Node?
        var child: Node.Child
        var path: String
    }

    /// A collection being built: its own node, its children still to do,
    /// and how it hangs from its parent.
    private final class Frame {
        var node: Node
        var pending: [Pending]
        let depth: Int
        let template: Node.Child

        init(node: Node, pending: [Pending], depth: Int, template: Node.Child) {
            self.node = node
            self.pending = pending.reversed()
            self.depth = depth
            self.template = template
        }
    }

    /// The tree under a cursor, built with a stack of its own rather than
    /// by recursion: the nesting of the data is bounded by nothing but the
    /// file, and the tool runs on whatever thread calls it.
    private mutating func node(_ cursor: Cursor<ReadOnly>, path: String, depth: Int) -> Node {
        let (root, pending) = expand(cursor, path: path, depth: depth)
        if pending.isEmpty { return root }
        var stack = [Frame(node: root, pending: pending, depth: depth, template: Node.Child(node: Node(.empty)))]
        while let frame = stack.last {
            if let next = frame.pending.popLast() {
                var child = next.child
                if let ready = next.ready {
                    child.node = ready
                    frame.node.children.append(child)
                    continue
                }
                guard let cursor = next.cursor else { continue }
                let (node, pending) = expand(cursor, path: next.path, depth: frame.depth + 1)
                if pending.isEmpty {
                    child.node = node
                    frame.node.children.append(child)
                } else {
                    stack.append(Frame(node: node, pending: pending, depth: frame.depth + 1, template: child))
                }
            } else {
                stack.removeLast()
                guard let parent = stack.last else { return frame.node }
                var child = frame.template
                child.node = frame.node
                parent.node.children.append(child)
            }
        }
        return root
    }

    /// The node for one slot, and the children a collection there has
    /// still to be read.
    private mutating func expand(_ cursor: Cursor<ReadOnly>, path: String, depth: Int) -> (Node, [Pending]) {
        if budget <= 0 {
            budgetSpent = true
            return (Node(.truncated, text: "past the dump's limit"), [])
        }
        budget -= 1
        let slot: Slot
        do {
            slot = try cursor.slot
        } catch {
            return (Node(.unreadable, text: "the slot could not be read: \(error)"), [])
        }
        if Self.pointsAtCollection(slot.tag) {
            if let before = seen[slot.value] {
                return (Node(before == path || path.hasPrefix(before + "/") ? .cycle : .shared, text: before), [])
            }
            seen[slot.value] = path
        }
        if depth > depthLimit {
            return (Node(.truncated, text: "nesting past \(depthLimit) levels; --depth raises it"), [])
        }
        do {
            switch slot.tag {
            case .none:
                return (Node(slot.full ? .nothing : .empty), [])
            case .uint:
                return (Node(.uint, text: String(try cursor.readUInt64())), [])
            case .int:
                return (Node(.int, text: String(try cursor.readInt64())), [])
            case .float:
                return (Node(.float, text: Self.float(try cursor.readDouble())), [])
            case .bytes, .shortBytes:
                return (try bytes(cursor, slot: slot), [])
            case .kvPair, .sortedKvPair:
                // A pair met as a value: shown as a map of its one entry.
                let entry = try cursor.readEntry()
                var node = Node(.map)
                node.count = 1
                return (node, [pending(for: entry, sorted: slot.tag == .sortedKvPair, path: path)])
            case .arrayList:
                let list = try ArrayList<ReadOnly>(cursor)
                return try self.list(.list, count: try list.count, slot: slot, path: path) {
                    (index) throws(XitDBError) in
                    try list.cursor(at: index)
                }
            case .linkedArrayList:
                let list = try LinkedArrayList<ReadOnly>(cursor)
                return try self.list(.linked, count: try list.count, slot: slot, path: path) {
                    (index) throws(XitDBError) in try list.cursor(at: index)
                }
            case .hashMap:
                return try entries(.map, try HashMap<ReadOnly>(cursor).iterator(), count: nil, slot: slot, path: path)
            case .hashSet:
                return try entries(.set, try HashSet<ReadOnly>(cursor).iterator(), count: nil, slot: slot, path: path)
            case .countedHashMap:
                let map = try CountedHashMap<ReadOnly>(cursor)
                return try entries(.countedMap, try map.iterator(), count: try map.count, slot: slot, path: path)
            case .countedHashSet:
                let set = try CountedHashSet<ReadOnly>(cursor)
                return try entries(.countedSet, try set.iterator(), count: try set.count, slot: slot, path: path)
            case .sortedMap:
                let map = try SortedMap<ReadOnly>(cursor)
                return try entries(.sortedMap, try map.iterator(), count: try map.count, slot: slot, path: path)
            case .sortedSet:
                let set = try SortedSet<ReadOnly>(cursor)
                return try entries(.sortedSet, try set.iterator(), count: try set.count, slot: slot, path: path)
            case .index:
                return (Node(.unreadable, text: "an index block where a value should be"), [])
            }
        } catch {
            return (Node(.unreadable, text: "\(slot.tag) could not be read: \(error)"), [])
        }
    }

    private func bytes(_ cursor: Cursor<ReadOnly>, slot: Slot) throws(XitDBError) -> Node {
        var node = Node(.bytes)
        let length = try cursor.count
        node.length = length
        let shown: [UInt8]
        if length <= 64 {
            // Whole, with its format tag if it has one.
            let bytes = try cursor.readBytesWithFormatTag()
            if let tag = bytes.formatTag { node.formatTag = "\(tag)" }
            shown = bytes.value
        } else {
            var reader = try cursor.reader()
            var buffer = [UInt8](repeating: 0, count: 64)
            var span = buffer.mutableSpan
            let read = try reader.read(into: &span)
            shown = Array(buffer.prefix(read))
        }
        if length <= 64, let text = String(validating: shown, as: UTF8.self), Self.isPrintable(text) {
            node.text = text
        } else {
            node.text = "0x" + Self.hex(shown)
        }
        if options.offsets, slot.tag == .bytes {
            node.position = slot.value
            node.size = FormatSizes.bytesLength + length + (node.formatTag == nil ? 0 : FormatSizes.bytesFormatTag)
        }
        return node
    }

    private func list(
        _ kind: Node.Kind, count: UInt64, slot: Slot, path: String,
        element: (Int) throws(XitDBError) -> Cursor<ReadOnly>?
    ) throws(XitDBError) -> (Node, [Pending]) {
        var node = Node(kind)
        node.count = count
        if options.offsets {
            node.position = slot.value
            node.size = FormatSizes.listHeader
        }
        var pending: [Pending] = []
        let shown = Int(min(count, UInt64(options.limit)))
        for index in 0..<shown {
            let child = Node.Child(index: index, node: Node(.empty))
            let childPath = path + "/#\(index)"
            do {
                if let cursor = try element(index) {
                    pending.append(Pending(cursor: cursor, ready: nil, child: child, path: childPath))
                } else {
                    pending.append(Pending(cursor: nil, ready: Node(.empty), child: child, path: childPath))
                }
            } catch {
                pending.append(
                    Pending(
                        cursor: nil, ready: Node(.unreadable, text: "element \(index) could not be read: \(error)"),
                        child: child, path: childPath))
            }
        }
        if count > UInt64(shown) {
            pending.append(
                Pending(
                    cursor: nil,
                    ready: Node(.truncated, text: "\(count - UInt64(shown)) more elements; --limit shows them"),
                    child: Node.Child(node: Node(.empty)), path: path))
        }
        return (node, pending)
    }

    private func entries(
        _ kind: Node.Kind, _ iterator: CollectionIterator, count: UInt64?, slot: Slot, path: String
    ) throws(XitDBError) -> (Node, [Pending]) {
        var node = Node(kind)
        if options.offsets {
            node.position = slot.value
            switch kind {
            case .countedMap, .countedSet: node.size = FormatSizes.count + FormatSizes.indexBlock
            case .sortedMap, .sortedSet: node.size = FormatSizes.treeHeader
            default: node.size = FormatSizes.indexBlock
            }
        }
        var iterator = iterator
        let sorted = kind == .sortedMap || kind == .sortedSet
        var pending: [Pending] = []
        var shown = 0
        func note(_ text: String) {
            pending.append(
                Pending(
                    cursor: nil, ready: Node(.unreadable, text: text), child: Node.Child(node: Node(.empty)), path: path
                ))
        }
        while true {
            let next: Cursor<ReadOnly>?
            do {
                next = try iterator.next()
            } catch {
                note("the iteration failed: \(error)")
                break
            }
            guard let next else { break }
            if shown == options.limit {
                pending.append(
                    Pending(
                        cursor: nil,
                        ready: Node(.truncated, text: "more entries past the first \(shown); --limit shows them"),
                        child: Node.Child(node: Node(.empty)), path: path))
                break
            }
            shown += 1
            let elementTag = try? next.slot.tag
            do {
                let slot = try next.slot
                if slot.tag == .none {
                    // An entry written as nothing: the iterator gives its slot.
                    pending.append(
                        Pending(
                            cursor: nil, ready: Node(slot.full ? .nothing : .empty),
                            child: Node.Child(node: Node(.empty)), path: path))
                    continue
                }
                pending.append(self.pending(for: try next.readEntry(), sorted: sorted, path: path))
            } catch {
                let what = elementTag.map { "a \($0) where an entry should be" } ?? "an entry that could not be read"
                note("\(what): \(error)")
            }
        }
        node.count = count ?? UInt64(shown)
        return (node, pending)
    }

    /// An entry's value, still to be read, with the entry's label.
    private func pending(for entry: Entry, sorted: Bool, path: String) -> Pending {
        var child = Node.Child(node: Node(.empty))
        var label: String
        if sorted {
            // A sorted collection's key is the pair's bytes.
            if let key = try? entry.key.readBytes(), let text = String(validating: key, as: UTF8.self),
                Self.isPrintable(text)
            {
                child.name = text
                label = text
            } else if let key = try? entry.key.readBytes() {
                child.keyHex = Self.hex(key)
                label = child.keyHex!
            } else {
                label = "?"
            }
        } else {
            child.hash = entry.hash
            label = Self.hex(options.fullHashes ? entry.hash : Array(entry.hash.prefix(8)))
            if let keyTag = try? entry.key.slot.tag, keyTag == .bytes || keyTag == .shortBytes,
                let key = try? entry.key.readBytes(), let text = String(validating: key, as: UTF8.self),
                Self.isPrintable(text)
            {
                child.name = text
            } else if let name = names[entry.hash] {
                child.name = name
            }
            if let name = child.name { label = name }
        }
        return Pending(cursor: entry.value, ready: nil, child: child, path: path + "/" + label)
    }

    // MARK: Verify

    private func verify(_ storage: any ReadableStorage, fileSize: UInt64, into dump: inout Dump) {
        do {
            let commits = try Database.verifiedCommits(in: storage)
            let last = commits.last?.end ?? 0
            dump.verification = Dump.Verification(
                commits: commits.map {
                    Dump.Commit(end: $0.end, commitID: Self.hex(bigEndian: $0.commitID), rootTag: "\($0.root.tag)")
                },
                fileSize: fileSize, bytesPastLastCommit: last == fileSize ? nil : fileSize - last)
            if commits.isEmpty {
                dump.notes.append("no commit verifies")
            } else if last != fileSize {
                dump.notes.append(
                    "\(fileSize - last) bytes after the last good commit, which ends at \(last), do not verify")
            }
        } catch {
            dump.notes.append("the commits could not be verified: \(error)")
        }
    }

    // MARK: Helpers

    private func containsDamage(_ node: Node) -> Bool {
        if node.kind == .unreadable { return true }
        return node.children.contains { containsDamage($0.node) }
    }

    private static func pointsAtCollection(_ tag: Slot.Tag) -> Bool {
        switch tag {
        case .arrayList, .linkedArrayList, .hashMap, .hashSet, .countedHashMap, .countedHashSet, .sortedMap, .sortedSet:
            true
        default:
            false
        }
    }

    private static func isPrintable(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F || scalar == "\t"
        }
    }

    package static func hex(_ bytes: [UInt8]) -> String {
        var text = ""
        for byte in bytes {
            let digits = String(byte, radix: 16)
            text += digits.count == 1 ? "0" + digits : digits
        }
        return text
    }

    package static func hex(bigEndian value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    /// A double as the dump prints it: whole values with ".0", the rest as
    /// Swift prints them.
    package static func float(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) + ".0" }
        return "\(value)"
    }
}
