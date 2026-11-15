import Testing
import XitDB
import XitDBHashing

/// What a copy made by its slot and frozen by its cursor reads as, once it
/// and its original have both been written in the same transaction: the
/// hazard that "Cloning, freeze and stale handles" warns of, as a table.
///
/// Each table is one way of doing it, on a sorted map, a sorted set or a
/// linked array list of forty: the original's writes first and then the
/// copy's, or the copy's first; the original removing ten or adding ten.
/// The copy's own write adds one. The reads are of the copy, and give the
/// same in the transaction and after it is committed.
///
/// Two kinds of copy come of it, and neither has a byte that is damaged.
/// With the original's writes first, the copy's size disagrees with its
/// tree, which is otherwise whole: the size says 41 where the tree holds
/// 31, or 51. With the copy's write first, the copy has a root of its own
/// whose counts are of the leaves as they were, and the original then
/// changes those leaves in place: the size agrees with the root, and the
/// root counts 8 for a leaf that holds none, or 16.
///
/// Every read answers from the tree as it finds it, with no error unless a
/// position leads where the tree has nothing, which is `invalidBTreeNode`.
/// A read by key finds every key that is in a leaf. A position, a key's
/// rank and a walk go by counts and slots that may no longer agree, so a
/// position can give another entry than the walk gives at that place, a
/// walk can give an element twice, and a rank can be off, each without an
/// error. The port reads these copies as the original does, except where
/// the original ends its process: an iterator started at a position the
/// tree does not have.
@Suite("What the freeze hazard leaves") struct FreezeHazardTable {
    enum Collection: String, CaseIterable {
        case sortedMap, sortedSet, linkedArrayList
    }

    enum Order: String, CaseIterable {
        /// The original's writes, then the copy's.
        case originalFirst
        /// The copy's write, then the original's.
        case copyFirst
    }

    enum Change: String, CaseIterable {
        /// The original removes its first ten.
        case removes
        /// The original adds ten among its first ten: after each of the
        /// keys "k00" to "k09" in a sorted collection, three at the front
        /// of a list.
        case adds
    }

    /// The key of a number: "k00" to "k39", which sort as their numbers do.
    private static func key(_ number: Int) -> [UInt8] {
        Array("k\(number < 10 ? "0" : "")\(number)".utf8)
    }

    /// What a read gives, as text: its result, or the error's name.
    private static func outcome(_ read: () throws -> String) -> String {
        do {
            return try read()
        } catch {
            return "\(error)"
        }
    }

    /// What a walk gives: how many, how it ended, and each in turn.
    private static func walk(
        _ start: () throws -> CollectionIterator, _ text: (Cursor<ReadOnly>) throws -> String
    ) -> String {
        var given: [String] = []
        do {
            var iterator = try start()
            while let entry = try iterator.next() {
                given.append(try text(entry))
            }
        } catch {
            return given.isEmpty ? "\(error)" : "\(given.count) and then \(error): \(runs(given))"
        }
        return given.isEmpty ? "none and an end" : "\(given.count) and an end: \(runs(given))"
    }

    /// What a walk gave, in turn, with three or more that follow one
    /// another written as the first and the last: "k10 to k39".
    private static func runs(_ given: [String]) -> String {
        /// The number of "k12" or of "12", and whether it has the "k".
        func number(_ item: String) -> (keyed: Bool, number: Int)? {
            let keyed = item.hasPrefix("k")
            guard let number = Int(keyed ? item.dropFirst() : item[...]) else { return nil }
            return (keyed, number)
        }
        var parts: [String] = []
        var index = 0
        while index < given.count {
            var last = index
            while last + 1 < given.count, let here = number(given[last]), let next = number(given[last + 1]),
                here.keyed == next.keyed, next.number == here.number + 1
            {
                last += 1
            }
            if last - index >= 2 {
                parts.append("\(given[index]) to \(given[last])")
            } else {
                parts.append(contentsOf: given[index...last])
            }
            index = last + 1
        }
        return parts.joined(separator: " ")
    }

    /// How many entries a walk from a position gives, or the error that
    /// refuses it.
    private static func walked(_ start: () throws -> CollectionIterator) -> String {
        var given = 0
        do {
            var iterator = try start()
            while try iterator.next() != nil {
                given += 1
            }
        } catch {
            return given == 0 ? "\(error)" : "\(given) and then \(error)"
        }
        return "\(given)"
    }

    private static func text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    private static let keysAsked = ["k00", "k05", "k12", "k20", "k35", "k39", "k03x", "zzz"]
    private static let positionsAsked = [0, 5, 20, 30, 31, 35, 40, 41, 50, -1, -11, -41]
    private static let keysWalkedFrom = ["k00", "k29", "k30", "k31", "k32", "k35", "k39", "zzz"]

    /// One line for several reads of a kind: what was asked, then what each gave.
    private static func line<Asked>(_ name: String, _ asked: [Asked], _ read: (Asked) throws -> String) -> String {
        "\(name) \(asked.map { "\($0)" }.joined(separator: " ")): "
            + asked.map { one in outcome { try read(one) } }.joined(separator: ", ")
    }

    private static func reads(of map: SortedMap<ReadOnly>) -> [String] {
        let key: (Cursor<ReadOnly>) throws -> String = { text(try $0.readEntry().key.readBytes(maxCount: 100)) }
        return [
            "count: " + outcome { "\(try map.count)" },
            line("by key", keysAsked) {
                try map.cursor(forKey: Array($0.utf8)).map { "\(try $0.readUInt64())" } ?? "nil"
            },
            line("rank of", keysAsked) { "\(try map.rank(of: Array($0.utf8)))" },
            line("at", positionsAsked) {
                try map.entry(at: $0).map { text(try $0.key.readBytes(maxCount: 100)) } ?? "nil"
            },
            "walk: " + walk({ try map.iterator() }, key),
            "walk from k12: " + walk({ try map.iterator(fromKey: Self.key(12)) }, key),
            "walk from 3: " + walk({ try map.iterator(fromIndex: 3) }, key),
            line("walked from", Array(29...42)) { position in walked { try map.iterator(fromIndex: position) } },
            line("walked from", [-1, -10, -11, -12, -41, -42]) { position in
                walked { try map.iterator(fromIndex: position) }
            },
            line("walked from", keysWalkedFrom) { key in walked { try map.iterator(fromKey: Array(key.utf8)) } },
        ]
    }

    private static func reads(of set: SortedSet<ReadOnly>) -> [String] {
        let key: (Cursor<ReadOnly>) throws -> String = { text(try $0.readEntry().key.readBytes(maxCount: 100)) }
        return [
            "count: " + outcome { "\(try set.count)" },
            line("contains", keysAsked) { try set.contains(Array($0.utf8)) ? "yes" : "no" },
            line("rank of", keysAsked) { "\(try set.rank(of: Array($0.utf8)))" },
            line("at", positionsAsked) {
                try set.entry(at: $0).map { text(try $0.key.readBytes(maxCount: 100)) } ?? "nil"
            },
            "walk: " + walk({ try set.iterator() }, key),
            "walk from k12: " + walk({ try set.iterator(fromKey: Self.key(12)) }, key),
            "walk from 3: " + walk({ try set.iterator(fromIndex: 3) }, key),
            line("walked from", Array(29...42)) { position in walked { try set.iterator(fromIndex: position) } },
            line("walked from", [-1, -10, -11, -12, -41, -42]) { position in
                walked { try set.iterator(fromIndex: position) }
            },
            line("walked from", keysWalkedFrom) { key in walked { try set.iterator(fromKey: Array(key.utf8)) } },
        ]
    }

    private static func reads(of list: LinkedArrayList<ReadOnly>) -> [String] {
        let number: (Cursor<ReadOnly>) throws -> String = { "\(try $0.readUInt64())" }
        return [
            "count: " + outcome { "\(try list.count)" },
            line("at", [0, 5, 20, 29, 30, 37, 39, 40, 41, 43, 44, -1]) {
                try list.cursor(at: $0).map { "\(try $0.readUInt64())" } ?? "nil"
            },
            "walk: " + walk({ try list.iterator() }, number),
            "walk from 3: " + walk({ try list.iterator(fromIndex: 3) }, number),
            line("walked from", Array(27...42)) { position in walked { try list.iterator(fromIndex: position) } },
            line("walked from", [-1, -10, -11, -12, -41, -42]) { position in
                walked { try list.iterator(fromIndex: position) }
            },
        ]
    }

    /// Does the hazard one way and returns what the copy's reads give in
    /// the transaction and after the commit, each led by how the two
    /// sides' writes went.
    private func hazard(
        _ collection: Collection, _ order: Order, _ change: Change
    ) throws -> (inTransaction: [String], committed: [String]) {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        var writes: [String] = []
        var inTransaction: [String] = []
        /// Runs the two sides' writes in the order asked for, noting an
        /// error where a write runs into the difference.
        func write(original: () throws -> Void, copy: () throws -> Void) {
            func note(_ side: String, _ write: () throws -> Void) {
                writes.append(
                    side + ": "
                        + Self.outcome {
                            try write()
                            return "done"
                        })
            }
            switch order {
            case .originalFirst:
                note("the original's writes", original)
                note("the copy's write", copy)
            case .copyFirst:
                note("the copy's write", copy)
                note("the original's writes", original)
            }
        }
        try database.withTransaction { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            switch collection {
            case .sortedMap:
                let original = try SortedMap<ReadWrite>(moment.putCursor(forKey: "original"))
                for number in 0..<40 {
                    try original.put(UInt64(number), forKey: Self.key(number))
                }
                var copyCursor = try moment.putCursor(forKey: "copy")
                try copyCursor.write(.slot(try original.slot))
                try copyCursor.freeze()
                let copy = try SortedMap<ReadWrite>(copyCursor)
                write(
                    original: {
                        for number in 0..<10 {
                            switch change {
                            case .removes: _ = try original.remove(forKey: Self.key(number))
                            case .adds:
                                try original.put(UInt64(100 + number), forKey: Self.key(number) + Array("x".utf8))
                            }
                        }
                    }, copy: { try copy.put(UInt64(999), forKey: Array("zzz".utf8)) })
                inTransaction = Self.reads(of: copy.readOnly)
            case .sortedSet:
                let original = try SortedSet<ReadWrite>(moment.putCursor(forKey: "original"))
                for number in 0..<40 {
                    try original.insert(Self.key(number))
                }
                var copyCursor = try moment.putCursor(forKey: "copy")
                try copyCursor.write(.slot(try original.slot))
                try copyCursor.freeze()
                let copy = try SortedSet<ReadWrite>(copyCursor)
                write(
                    original: {
                        for number in 0..<10 {
                            switch change {
                            case .removes: _ = try original.remove(forKey: Self.key(number))
                            case .adds: try original.insert(Self.key(number) + Array("x".utf8))
                            }
                        }
                    }, copy: { try copy.insert(Array("zzz".utf8)) })
                inTransaction = Self.reads(of: copy.readOnly)
            case .linkedArrayList:
                let original = try LinkedArrayList<ReadWrite>(moment.putCursor(forKey: "original"))
                for number in 0..<40 {
                    try original.append(.uint(UInt64(number)))
                }
                var copyCursor = try moment.putCursor(forKey: "copy")
                try copyCursor.write(.slot(try original.slot))
                try copyCursor.freeze()
                let copy = try LinkedArrayList<ReadWrite>(copyCursor)
                write(
                    original: {
                        switch change {
                        case .removes:
                            for _ in 0..<10 {
                                try original.remove(at: 0)
                            }
                        case .adds:
                            for number in 0..<3 {
                                try original.insert(.uint(UInt64(100 + number)), at: 0)
                            }
                        }
                    }, copy: { try copy.append(UInt64(999)) })
                inTransaction = Self.reads(of: copy.readOnly)
            }
        }
        let root = try HashMap<ReadOnly>(database.rootCursor.readOnly)
        let copy = try #require(try root.cursor(forKey: "copy"))
        let committed: [String]
        switch collection {
        case .sortedMap: committed = Self.reads(of: try SortedMap<ReadOnly>(copy))
        case .sortedSet: committed = Self.reads(of: try SortedSet<ReadOnly>(copy))
        case .linkedArrayList: committed = Self.reads(of: try LinkedArrayList<ReadOnly>(copy))
        }
        return (writes + inTransaction, writes + committed)
    }

    @Test(arguments: Collection.allCases, Order.allCases)
    func theCopyReadsAsTheTableSays(collection: Collection, order: Order) throws {
        for change in Change.allCases {
            let name = "\(collection.rawValue) \(order.rawValue) \(change.rawValue)"
            let (inTransaction, committed) = try hazard(collection, order, change)
            #expect(inTransaction == committed, "\(name)")
            #expect(committed == Self.table[name], "\(name)")
        }
    }

    /// What each way of doing it leaves, by the reads of the copy: what
    /// version 0.5.0 gives, taken from a run of this suite on it, and what
    /// every version since is held to. A change to the library that alters
    /// one read of such a copy fails the suite at that table, and so does
    /// a change to a line here. To take the tables again from a version,
    /// put this file into a checkout of it with this dictionary emptied
    /// and run the suite: it uses nothing 0.5.0 does not have, and each
    /// failure gives the lines of one table.
    ///
    /// Each table starts with how the two sides' writes went, in their
    /// order. Then: the copy's count; a read by each of eight keys, two of
    /// them among those the original removed, one of those it added and
    /// the one the copy added; the rank of each; what is at each of twelve
    /// positions, the negative ones from the end; the walk from the start,
    /// from a key and from a position, with a run of entries written as
    /// its ends; and how many entries a walk gives from each position
    /// around the end, where the size and the tree disagree. An error is
    /// written by its name.
    static let table: [String: [String]] = [
        "sortedMap originalFirst removes": [
            "the original's writes: done",
            "the copy's write: done",
            "count: 41",
            "by key k00 k05 k12 k20 k35 k39 k03x zzz: nil, nil, 12, 20, 35, 39, nil, 999",
            "rank of k00 k05 k12 k20 k35 k39 k03x zzz: 0, 0, 2, 10, 25, 29, 0, 30",
            "at 0 5 20 30 31 35 40 41 50 -1 -11 -41: k10, k15, k30, zzz, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, nil, nil, invalidBTreeNode, zzz, k10",
            "walk: 31 and an end: k10 to k39 zzz",
            "walk from k12: 29 and an end: k12 to k39 zzz",
            "walk from 3: 28 and an end: k13 to k39 zzz",
            "walked from 29 30 31 32 33 34 35 36 37 38 39 40 41 42: 2, 1, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, 0, 0",
            "walked from -1 -10 -11 -12 -41 -42: invalidBTreeNode, invalidBTreeNode, 1, 2, 31, 0",
            "walked from k00 k29 k30 k31 k32 k35 k39 zzz: 31, 12, 11, 10, 9, 6, 2, 1",
        ],
        "sortedMap originalFirst adds": [
            "the original's writes: done",
            "the copy's write: done",
            "count: 41",
            "by key k00 k05 k12 k20 k35 k39 k03x zzz: 0, 5, 12, 20, 35, 39, 103, 999",
            "rank of k00 k05 k12 k20 k35 k39 k03x zzz: 0, 10, 22, 30, 45, 49, 7, 50",
            "at 0 5 20 30 31 35 40 41 50 -1 -11 -41: k00, k02x, k10, k20, k21, k25, k30, nil, nil, k30, k20, k00",
            "walk: 41 and an end: k00 k00x k01 k01x k02 k02x k03 k03x k04 k04x k05 k05x k06 k06x k07 k07x k08 k08x k09 k09x k10 to k30",
            "walk from k12: 19 and an end: k12 to k30",
            "walk from 3: 38 and an end: k01x k02 k02x k03 k03x k04 k04x k05 k05x k06 k06x k07 k07x k08 k08x k09 k09x k10 to k30",
            "walked from 29 30 31 32 33 34 35 36 37 38 39 40 41 42: 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0",
            "walked from -1 -10 -11 -12 -41 -42: 1, 10, 11, 12, 41, 0",
            "walked from k00 k29 k30 k31 k32 k35 k39 zzz: 41, 2, 1, 0, 0, 0, 0, 0",
        ],
        "sortedMap copyFirst removes": [
            "the copy's write: done",
            "the original's writes: done",
            "count: 41",
            "by key k00 k05 k12 k20 k35 k39 k03x zzz: nil, nil, 12, 20, 35, 39, nil, 999",
            "rank of k00 k05 k12 k20 k35 k39 k03x zzz: 0, 0, 10, 20, 35, 39, 0, 40",
            "at 0 5 20 30 31 35 40 41 50 -1 -11 -41: invalidBTreeNode, invalidBTreeNode, k20, k30, k31, k35, zzz, nil, nil, zzz, k30, invalidBTreeNode",
            "walk: 31 and an end: k10 to k39 zzz",
            "walk from k12: 29 and an end: k12 to k39 zzz",
            "walk from 3: invalidBTreeNode",
            "walked from 29 30 31 32 33 34 35 36 37 38 39 40 41 42: 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0",
            "walked from -1 -10 -11 -12 -41 -42: 1, 10, 11, 12, invalidBTreeNode, 0",
            "walked from k00 k29 k30 k31 k32 k35 k39 zzz: 31, 12, 11, 10, 9, 6, 2, 1",
        ],
        "sortedMap copyFirst adds": [
            "the copy's write: done",
            "the original's writes: done",
            "count: 41",
            "by key k00 k05 k12 k20 k35 k39 k03x zzz: 0, 5, 12, 20, 35, 39, 103, 999",
            "rank of k00 k05 k12 k20 k35 k39 k03x zzz: 0, 10, 14, 20, 35, 39, 7, 40",
            "at 0 5 20 30 31 35 40 41 50 -1 -11 -41: k00, k02x, k20, k30, k31, k35, zzz, nil, nil, zzz, k30, k00",
            "walk: 41 and an end: k00 k00x k01 k01x k02 k02x k03 k03x k04 k04x k05 k05x k06 k06x k07 k07x k08 k08x k09 k09x k10 to k30",
            "walk from k12: 27 and an end: k12 to k38",
            "walk from 3: 38 and an end: k01x k02 k02x k03 k03x k04 k04x k05 k05x k06 k06x k07 k07x k08 k08x k09 k09x k10 to k30",
            "walked from 29 30 31 32 33 34 35 36 37 38 39 40 41 42: 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0",
            "walked from -1 -10 -11 -12 -41 -42: 1, 10, 11, 12, 41, 0",
            "walked from k00 k29 k30 k31 k32 k35 k39 zzz: 41, 12, 11, 10, 9, 6, 2, 1",
        ],
        "sortedSet originalFirst removes": [
            "the original's writes: done",
            "the copy's write: done",
            "count: 41",
            "contains k00 k05 k12 k20 k35 k39 k03x zzz: no, no, yes, yes, yes, yes, no, yes",
            "rank of k00 k05 k12 k20 k35 k39 k03x zzz: 0, 0, 2, 10, 25, 29, 0, 30",
            "at 0 5 20 30 31 35 40 41 50 -1 -11 -41: k10, k15, k30, zzz, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, nil, nil, invalidBTreeNode, zzz, k10",
            "walk: 31 and an end: k10 to k39 zzz",
            "walk from k12: 29 and an end: k12 to k39 zzz",
            "walk from 3: 28 and an end: k13 to k39 zzz",
            "walked from 29 30 31 32 33 34 35 36 37 38 39 40 41 42: 2, 1, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, 0, 0",
            "walked from -1 -10 -11 -12 -41 -42: invalidBTreeNode, invalidBTreeNode, 1, 2, 31, 0",
            "walked from k00 k29 k30 k31 k32 k35 k39 zzz: 31, 12, 11, 10, 9, 6, 2, 1",
        ],
        "sortedSet originalFirst adds": [
            "the original's writes: done",
            "the copy's write: done",
            "count: 41",
            "contains k00 k05 k12 k20 k35 k39 k03x zzz: yes, yes, yes, yes, yes, yes, yes, yes",
            "rank of k00 k05 k12 k20 k35 k39 k03x zzz: 0, 10, 22, 30, 45, 49, 7, 50",
            "at 0 5 20 30 31 35 40 41 50 -1 -11 -41: k00, k02x, k10, k20, k21, k25, k30, nil, nil, k30, k20, k00",
            "walk: 41 and an end: k00 k00x k01 k01x k02 k02x k03 k03x k04 k04x k05 k05x k06 k06x k07 k07x k08 k08x k09 k09x k10 to k30",
            "walk from k12: 19 and an end: k12 to k30",
            "walk from 3: 38 and an end: k01x k02 k02x k03 k03x k04 k04x k05 k05x k06 k06x k07 k07x k08 k08x k09 k09x k10 to k30",
            "walked from 29 30 31 32 33 34 35 36 37 38 39 40 41 42: 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0",
            "walked from -1 -10 -11 -12 -41 -42: 1, 10, 11, 12, 41, 0",
            "walked from k00 k29 k30 k31 k32 k35 k39 zzz: 41, 2, 1, 0, 0, 0, 0, 0",
        ],
        "sortedSet copyFirst removes": [
            "the copy's write: done",
            "the original's writes: done",
            "count: 41",
            "contains k00 k05 k12 k20 k35 k39 k03x zzz: no, no, yes, yes, yes, yes, no, yes",
            "rank of k00 k05 k12 k20 k35 k39 k03x zzz: 0, 0, 10, 20, 35, 39, 0, 40",
            "at 0 5 20 30 31 35 40 41 50 -1 -11 -41: invalidBTreeNode, invalidBTreeNode, k20, k30, k31, k35, zzz, nil, nil, zzz, k30, invalidBTreeNode",
            "walk: 31 and an end: k10 to k39 zzz",
            "walk from k12: 29 and an end: k12 to k39 zzz",
            "walk from 3: invalidBTreeNode",
            "walked from 29 30 31 32 33 34 35 36 37 38 39 40 41 42: 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0",
            "walked from -1 -10 -11 -12 -41 -42: 1, 10, 11, 12, invalidBTreeNode, 0",
            "walked from k00 k29 k30 k31 k32 k35 k39 zzz: 31, 12, 11, 10, 9, 6, 2, 1",
        ],
        "sortedSet copyFirst adds": [
            "the copy's write: done",
            "the original's writes: done",
            "count: 41",
            "contains k00 k05 k12 k20 k35 k39 k03x zzz: yes, yes, yes, yes, yes, yes, yes, yes",
            "rank of k00 k05 k12 k20 k35 k39 k03x zzz: 0, 10, 14, 20, 35, 39, 7, 40",
            "at 0 5 20 30 31 35 40 41 50 -1 -11 -41: k00, k02x, k20, k30, k31, k35, zzz, nil, nil, zzz, k30, k00",
            "walk: 41 and an end: k00 k00x k01 k01x k02 k02x k03 k03x k04 k04x k05 k05x k06 k06x k07 k07x k08 k08x k09 k09x k10 to k30",
            "walk from k12: 27 and an end: k12 to k38",
            "walk from 3: 38 and an end: k01x k02 k02x k03 k03x k04 k04x k05 k05x k06 k06x k07 k07x k08 k08x k09 k09x k10 to k30",
            "walked from 29 30 31 32 33 34 35 36 37 38 39 40 41 42: 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0",
            "walked from -1 -10 -11 -12 -41 -42: 1, 10, 11, 12, 41, 0",
            "walked from k00 k29 k30 k31 k32 k35 k39 zzz: 41, 12, 11, 10, 9, 6, 2, 1",
        ],
        "linkedArrayList originalFirst removes": [
            "the original's writes: done",
            "the copy's write: invalidBTreeNode",
            "count: 40",
            "at 0 5 20 29 30 37 39 40 41 43 44 -1: 10, 15, 30, 39, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, nil, nil, nil, nil, invalidBTreeNode",
            "walk: 30 and an end: 10 to 39",
            "walk from 3: 27 and an end: 13 to 39",
            "walked from 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42: 3, 2, 1, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, invalidBTreeNode, 0, 0, 0",
            "walked from -1 -10 -11 -12 -41 -42: invalidBTreeNode, invalidBTreeNode, 1, 2, 0, 0",
        ],
        "linkedArrayList originalFirst adds": [
            "the original's writes: done",
            "the copy's write: done",
            "count: 41",
            "at 0 5 20 29 30 37 39 40 41 43 44 -1: 102, 2, 17, 26, 27, 34, 36, 999, nil, nil, nil, 999",
            "walk: 41 and an end: 102 101 100 0 to 36 999",
            "walk from 3: 38 and an end: 0 to 36 999",
            "walked from 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42: 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0",
            "walked from -1 -10 -11 -12 -41 -42: 1, 10, 11, 12, 41, 0",
        ],
        "linkedArrayList copyFirst removes": [
            "the copy's write: done",
            "the original's writes: done",
            "count: 41",
            "at 0 5 20 29 30 37 39 40 41 43 44 -1: 10, 15, 20, 29, 30, 37, 39, 999, nil, nil, nil, 999",
            "walk: 41 and an end: 10 to 23 8 to 34",
            "walk from 3: 38 and an end: 13 to 23 8 to 34",
            "walked from 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42: 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0",
            "walked from -1 -10 -11 -12 -41 -42: 1, 10, 11, 12, 41, 0",
        ],
        "linkedArrayList copyFirst adds": [
            "the copy's write: done",
            "the original's writes: done",
            "count: 41",
            "at 0 5 20 29 30 37 39 40 41 43 44 -1: 102, 2, 20, 29, 30, 37, 39, 999, nil, nil, nil, 999",
            "walk: 41 and an end: 102 101 100 0 to 37",
            "walk from 3: 38 and an end: 0 to 37",
            "walked from 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42: 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0",
            "walked from -1 -10 -11 -12 -41 -42: 1, 10, 11, 12, 41, 0",
        ],
    ]
}
