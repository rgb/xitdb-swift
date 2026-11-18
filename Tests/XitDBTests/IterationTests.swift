import Testing
import XitDBHashing

@testable import XitDB

/// What the collections offer in place of a `Sequence`, which an iterator
/// that can throw cannot be (the first client's review of 0.5.1, item 10;
/// the names are the user's of 2026-11-17): whether a collection is empty;
/// a map's or a set's entries as entries, and a list's elements read as a
/// type, each by an iterator a loop can leave; and a walk to the end by a
/// closure, whose own error comes out as itself.
///
/// Each is held on every collection that has it, by one body run on each
/// kind, against what the cursors' iterator gives, which the collections'
/// own tests hold.
@Suite struct IterationTests {
    /// An error of the tests' own.
    private struct Mine: Error, Equatable {
        let number: Int
    }

    /// The eight collections.
    enum Kind: String, CaseIterable, CustomTestStringConvertible {
        case arrayList, linkedArrayList, hashMap, hashSet, countedHashMap, countedHashSet, sortedMap, sortedSet

        var testDescription: String { rawValue }

        var isList: Bool { self == .arrayList || self == .linkedArrayList }
        var isSet: Bool { self == .hashSet || self == .countedHashSet || self == .sortedSet }
        var isSorted: Bool { self == .sortedMap || self == .sortedSet }
    }

    private func makeDatabase(_ storage: any WritableStorage = MemoryStorage()) throws -> Database {
        try Database(creating: storage, hashing: SHA256.self)
    }

    /// The key of a number: "k00", "k01" and so on, which sort as their
    /// numbers do up to "k99", and "k100" on, which do not need to.
    private static func key(_ number: Int) -> String {
        "k\(number < 10 ? "0" : "")\(number)"
    }

    /// What a collection of the kind holds for a number, as text: the
    /// number in a list, its key and the number in a map, its key in a set.
    private static func item(_ number: Int, in kind: Kind) -> String {
        if kind.isList { return "\(number)" }
        return kind.isSet ? key(number) : "\(key(number))=\(number)"
    }

    /// An entry as text, as `item(_:in:)` writes it.
    private static func text(_ entry: Entry, in kind: Kind) throws -> String {
        let key = try entry.key.read(String.self)
        return kind.isSet ? key : "\(key)=\(try entry.value.read(UInt64.self))"
    }

    /// Makes a collection of the kind under "it" in the root map, with the
    /// numbers given: a list's elements, a map's values under their keys,
    /// stored with the key, a set's members.
    private func fill(_ database: Database, _ kind: Kind, _ numbers: Range<Int>) throws {
        try database.withTransaction { root in
            let slot = try HashMap(root).putCursor(forKey: "it")
            switch kind {
            case .arrayList:
                let list = try ArrayList(slot)
                for number in numbers { try list.append(UInt64(number)) }
            case .linkedArrayList:
                let list = try LinkedArrayList(slot)
                for number in numbers { try list.append(UInt64(number)) }
            case .hashMap:
                let map = try HashMap(slot)
                for number in numbers { try map.put(UInt64(number), forKey: Self.key(number), storingKey: true) }
            case .hashSet:
                let set = try HashSet(slot)
                for number in numbers { try set.insert(Self.key(number)) }
            case .countedHashMap:
                let map = try CountedHashMap(slot)
                for number in numbers { try map.put(UInt64(number), forKey: Self.key(number), storingKey: true) }
            case .countedHashSet:
                let set = try CountedHashSet(slot)
                for number in numbers { try set.insert(Self.key(number)) }
            case .sortedMap:
                let map = try SortedMap(slot)
                for number in numbers { try map.put(UInt64(number), forKey: Self.key(number)) }
            case .sortedSet:
                let set = try SortedSet(slot)
                for number in numbers { try set.insert(Self.key(number)) }
            }
        }
    }

    /// Takes the one thing a collection of the kind under "it" holds out of
    /// it: the number 0.
    private func removeTheOnlyOne(_ database: Database, _ kind: Kind) throws {
        try database.withTransaction { root in
            let slot = try HashMap(root).putCursor(forKey: "it")
            switch kind {
            case .arrayList: try ArrayList(slot).truncate(to: 0)
            case .linkedArrayList: try LinkedArrayList(slot).remove(at: 0)
            case .hashMap: #expect(try HashMap(slot).remove(forKey: Self.key(0)))
            case .hashSet: #expect(try HashSet(slot).remove(forKey: Self.key(0)))
            case .countedHashMap: #expect(try CountedHashMap(slot).remove(forKey: Self.key(0)))
            case .countedHashSet: #expect(try CountedHashSet(slot).remove(forKey: Self.key(0)))
            case .sortedMap: #expect(try SortedMap(slot).remove(forKey: Self.key(0)))
            case .sortedSet: #expect(try SortedSet(slot).remove(forKey: Self.key(0)))
            }
        }
    }

    /// What a collection says of itself through each way of going through
    /// it, every item as text.
    private struct Seen: Equatable {
        var isEmpty: Bool
        /// By the cursors' iterator, the way there was before.
        var byCursors: [String] = []
        /// By the iterator that gives entries, or elements read as a type.
        var byIterator: [String] = []
        /// By the walk to the end, `forEachEntry(_:)` or `forEachElement(_:)`,
        /// and for a list by `forEachElement(as:_:)` too.
        var byWalk: [String] = []
        var byTypedWalk: [String]?
    }

    /// A list, through each way.
    private func seen(
        isEmpty: Bool, cursors: CollectionIterator, elements: ElementIterator<UInt64>,
        walk: ((Cursor<ReadOnly>) throws -> Void) throws -> Void,
        typedWalk: ((UInt64) throws -> Void) throws -> Void
    ) throws -> Seen {
        var seen = Seen(isEmpty: isEmpty)
        var cursors = cursors
        while let cursor = try cursors.next() { seen.byCursors.append("\(try cursor.read(UInt64.self))") }
        var elements = elements
        while let element = try elements.next() { seen.byIterator.append("\(element)") }
        try walk { cursor in
            let element = try cursor.read(UInt64.self)
            seen.byWalk.append("\(element)")
        }
        var typed: [String] = []
        try typedWalk { element in typed.append("\(element)") }
        seen.byTypedWalk = typed
        return seen
    }

    /// A map or a set, through each way.
    private func seen(
        _ kind: Kind, isEmpty: Bool, cursors: CollectionIterator, entries: EntryIterator,
        walk: ((Entry) throws -> Void) throws -> Void
    ) throws -> Seen {
        var seen = Seen(isEmpty: isEmpty)
        var cursors = cursors
        while let cursor = try cursors.next() {
            seen.byCursors.append(try Self.text(try cursor.readEntry(), in: kind))
        }
        var entries = entries
        while let entry = try entries.next() { seen.byIterator.append(try Self.text(entry, in: kind)) }
        try walk { entry in seen.byWalk.append(try Self.text(entry, in: kind)) }
        return seen
    }

    /// The collection of the kind at a cursor, read through each way.
    private func seen(_ kind: Kind, at slot: Cursor<ReadOnly>) throws -> Seen {
        switch kind {
        case .arrayList:
            let list = try ArrayList(slot)
            return try seen(
                isEmpty: try list.isEmpty, cursors: try list.iterator(), elements: try list.elements(as: UInt64.self),
                walk: list.forEachElement(_:), typedWalk: { try list.forEachElement(as: UInt64.self, $0) })
        case .linkedArrayList:
            let list = try LinkedArrayList(slot)
            return try seen(
                isEmpty: try list.isEmpty, cursors: try list.iterator(), elements: try list.elements(),
                walk: list.forEachElement(_:), typedWalk: { try list.forEachElement(as: UInt64.self, $0) })
        case .hashMap:
            let map = try HashMap(slot)
            return try seen(
                kind, isEmpty: try map.isEmpty, cursors: try map.iterator(), entries: try map.entries(),
                walk: map.forEachEntry)
        case .hashSet:
            let set = try HashSet(slot)
            return try seen(
                kind, isEmpty: try set.isEmpty, cursors: try set.iterator(), entries: try set.entries(),
                walk: set.forEachEntry)
        case .countedHashMap:
            let map = try CountedHashMap(slot)
            return try seen(
                kind, isEmpty: try map.isEmpty, cursors: try map.iterator(), entries: try map.entries(),
                walk: map.forEachEntry)
        case .countedHashSet:
            let set = try CountedHashSet(slot)
            return try seen(
                kind, isEmpty: try set.isEmpty, cursors: try set.iterator(), entries: try set.entries(),
                walk: set.forEachEntry)
        case .sortedMap:
            let map = try SortedMap(slot)
            return try seen(
                kind, isEmpty: try map.isEmpty, cursors: try map.iterator(), entries: try map.entries(),
                walk: map.forEachEntry)
        case .sortedSet:
            let set = try SortedSet(slot)
            return try seen(
                kind, isEmpty: try set.isEmpty, cursors: try set.iterator(), entries: try set.entries(),
                walk: set.forEachEntry)
        }
    }

    /// The collection under "it", read through each way.
    private func seen(_ database: Database, _ kind: Kind) throws -> Seen {
        let root = try HashMap(database.rootCursor.readOnly)
        return try seen(kind, at: try #require(try root.cursor(forKey: "it")))
    }

    // MARK: Whether a collection is empty

    /// Empty when it was made and nothing was put in it, when nothing was
    /// ever made at its slot, and again when the one thing in it is taken
    /// out; not empty with one thing in it or with many.
    @Test(arguments: Kind.allCases)
    func aCollectionIsEmptyExactlyWhenItHoldsNothing(kind: Kind) throws {
        // A slot nothing was made at: a new database's root, read as the kind.
        let untouched = try makeDatabase()
        let nothing = try seen(kind, at: untouched.rootCursor.readOnly)
        #expect(nothing.isEmpty)
        #expect(nothing.byCursors.isEmpty && nothing.byIterator.isEmpty && nothing.byWalk.isEmpty)

        let database = try makeDatabase()
        try fill(database, kind, 0..<0)
        #expect(try seen(database, kind).isEmpty)
        try fill(database, kind, 0..<1)
        #expect(try !seen(database, kind).isEmpty)
        try removeTheOnlyOne(database, kind)
        #expect(try seen(database, kind).isEmpty)
        #expect(try seen(database, kind).byCursors.isEmpty)
        try fill(database, kind, 0..<50)
        #expect(try !seen(database, kind).isEmpty)
    }

    /// A hash map and a hash set keep no count, so whether one is empty is
    /// asked of an iterator: one entry and no more, since a caller will ask
    /// in a loop. Held by the storage's reads: what it takes is what making
    /// an iterator and asking it once takes, a few reads down to the first
    /// entry, which grows with the map's depth and not with what it holds,
    /// where a walk of the whole map takes hundreds.
    @Test(arguments: [Kind.hashMap, .hashSet])
    func whetherAMapWithoutACountIsEmptyAsksForOneEntryAndNoMore(kind: Kind) throws {
        var taken: [Int: Int] = [:]
        for size in [1, 100, 5000] {
            let counting = FaultInjectingStorage(MemoryStorage())
            let database = try makeDatabase(counting)
            try fill(database, kind, 0..<size)
            let slot = try #require(try HashMap(database.rootCursor.readOnly).cursor(forKey: "it"))

            /// The reads a piece of work makes of the storage.
            func reads(_ work: () throws -> Void) throws -> Int {
                let before = counting.readCount
                try work()
                return counting.readCount - before
            }
            var empty = true
            let asking = try reads {
                empty = kind == .hashMap ? try HashMap(slot).isEmpty : try HashSet(slot).isEmpty
            }
            #expect(!empty)
            let oneEntry = try reads {
                var iterator = try slot.iterator()
                #expect(try iterator.next() != nil)
            }
            let wholeWalk = try reads {
                var iterator = try slot.iterator()
                var count = 0
                while try iterator.next() != nil { count += 1 }
                #expect(count == size)
            }
            #expect(asking == oneEntry, "\(size) entries")
            #expect(asking <= 8, "\(size) entries: \(asking) reads")
            taken[size] = asking
            if size == 5000 { #expect(wholeWalk > 300, "a walk of \(size) entries: \(wholeWalk) reads") }
        }
        // five thousand entries deep, it is a few reads more than for one entry
        #expect(try #require(taken[5000]) - #require(taken[1]) <= 4)
    }

    // MARK: Entries, and elements read as a type

    /// The new ways give what the cursors' iterator gives, each of the
    /// forty, in its order: a list's in order, a sorted map's or set's in
    /// key order, a hash map's or set's in the order it keeps.
    @Test(arguments: Kind.allCases)
    func everyWayGivesWhatTheCursorsGiveInTheirOrder(kind: Kind) throws {
        let database = try makeDatabase()
        try fill(database, kind, 0..<40)
        let seen = try seen(database, kind)
        let expected = (0..<40).map { Self.item($0, in: kind) }

        #expect(seen.byCursors.count == 40)
        #expect(Set(seen.byCursors) == Set(expected))
        if kind.isList || kind.isSorted { #expect(seen.byCursors == expected) }
        #expect(seen.byIterator == seen.byCursors)
        #expect(seen.byWalk == seen.byCursors)
        if kind.isList { #expect(seen.byTypedWalk == seen.byCursors) }
    }

    /// A list's elements read as a type have to be of the type. One of
    /// another kind ends the walk with the read's error, after the ones
    /// before it were given; and so does an element that was appended and
    /// never written, which is a slot set to nothing. The cursors' iterator
    /// gives them all.
    @Test(arguments: [Kind.arrayList, .linkedArrayList])
    func anElementOfAnotherKindEndsATypedWalk(kind: Kind) throws {
        let database = try makeDatabase()
        try database.withTransaction { root in
            let slot = try HashMap(root).putCursor(forKey: "it")
            if kind == .arrayList {
                let list = try ArrayList(slot)
                try list.append(UInt64(1))
                try list.append(UInt64(2))
                try list.append("three")
                try list.append(UInt64(4))
                _ = try list.appendCursor()
            } else {
                let list = try LinkedArrayList(slot)
                try list.append(UInt64(1))
                try list.append(UInt64(2))
                try list.append("three")
                try list.append(UInt64(4))
                _ = try list.appendCursor()
            }
        }
        let slot = try #require(try HashMap(database.rootCursor.readOnly).cursor(forKey: "it"))
        var cursors = try slot.iterator()
        var count = 0
        while try cursors.next() != nil { count += 1 }
        #expect(count == 5)

        /// The elements a typed iterator gives before it ends, and the
        /// error it ends with.
        func walk(_ elements: ElementIterator<UInt64>) -> (given: [UInt64], end: XitDBError?) {
            var elements = elements
            var given: [UInt64] = []
            do {
                while let element = try elements.next() { given.append(element) }
                return (given, nil)
            } catch {
                return (given, error)
            }
        }
        let elements: ElementIterator<UInt64> =
            kind == .arrayList
            ? try ArrayList(slot).elements(as: UInt64.self) : try LinkedArrayList(slot).elements(as: UInt64.self)
        let typed = walk(elements)
        #expect(typed.given == [1, 2])
        #expect(typed.end == .unexpectedTag)

        var given: [UInt64] = []
        #expect(throws: XitDBError.unexpectedTag) {
            if kind == .arrayList {
                try ArrayList(slot).forEachElement(as: UInt64.self) { given.append($0) }
            } else {
                try LinkedArrayList(slot).forEachElement(as: UInt64.self) { given.append($0) }
            }
        }
        #expect(given == [1, 2])

        // The element never written, by itself: read as a number it is the
        // read's error; as a cursor it is there, a slot set to nothing.
        let last = try #require(
            kind == .arrayList ? try ArrayList(slot).cursor(at: -1) : try LinkedArrayList(slot).cursor(at: -1))
        #expect(throws: XitDBError.unexpectedTag) { try last.read(UInt64.self) }
    }

    // MARK: A walk to the end by a closure

    /// A walk ends where its body throws, and the body's error comes out of
    /// the call as itself; through the adapter it comes out carried, where
    /// the library's error is declared.
    @Test(arguments: Kind.allCases)
    func aWalkEndsWhereItsBodyThrowsAndTheErrorIsTheBodysOwn(kind: Kind) throws {
        let database = try makeDatabase()
        try fill(database, kind, 0..<10)
        let slot = try #require(try HashMap(database.rootCursor.readOnly).cursor(forKey: "it"))

        /// Walks the collection, throwing at the third thing given.
        func walk(visited: inout Int, typed: Bool = false) throws {
            var count = 0
            defer { visited = count }
            func step() throws {
                count += 1
                if count == 3 { throw Mine(number: 3) }
            }
            switch kind {
            case .arrayList:
                if typed {
                    try ArrayList(slot).forEachElement(as: UInt64.self) { _ in try step() }
                } else {
                    try ArrayList(slot).forEachElement { _ in try step() }
                }
            case .linkedArrayList:
                if typed {
                    try LinkedArrayList(slot).forEachElement(as: UInt64.self) { _ in try step() }
                } else {
                    try LinkedArrayList(slot).forEachElement { _ in try step() }
                }
            case .hashMap: try HashMap(slot).forEachEntry { _ in try step() }
            case .hashSet: try HashSet(slot).forEachEntry { _ in try step() }
            case .countedHashMap: try CountedHashMap(slot).forEachEntry { _ in try step() }
            case .countedHashSet: try CountedHashSet(slot).forEachEntry { _ in try step() }
            case .sortedMap: try SortedMap(slot).forEachEntry { _ in try step() }
            case .sortedSet: try SortedSet(slot).forEachEntry { _ in try step() }
            }
        }

        var visited = 0
        #expect(throws: Mine(number: 3)) { try walk(visited: &visited) }
        #expect(visited == 3)
        if kind.isList {
            visited = 0
            #expect(throws: Mine(number: 3)) { try walk(visited: &visited, typed: true) }
            #expect(visited == 3)
        }

        /// The same walk where the library's error is declared.
        func typedWalk(visited: inout Int) throws(XitDBError) {
            var count = 0
            defer { visited = count }
            try XitDBError.carrying { try walk(visited: &count) }
        }
        visited = 0
        #expect(throws: XitDBError.callerError(Mine(number: 3))) { try typedWalk(visited: &visited) }
        #expect(visited == 3)
    }

    /// The two iterators are as stale as the cursor they were made through:
    /// made in a transaction that did not commit, each is refused, as the
    /// cursors' iterator is, and so is the question whether the collection
    /// is empty.
    @Test func theIteratorsOfATransactionThatDidNotCommitAreStale() throws {
        let database = try makeDatabase()
        var keptEntries: EntryIterator?
        var keptElements: ElementIterator<UInt64>?
        var keptMap: HashMap<ReadWrite>?
        var keptList: ArrayList<ReadWrite>?
        #expect(throws: Mine(number: 1)) {
            try database.withTransaction { root in
                let map = try HashMap(try HashMap(root).putCursor(forKey: "map"))
                try map.put(UInt64(1), forKey: "one")
                let list = try ArrayList(try HashMap(root).putCursor(forKey: "list"))
                try list.append(UInt64(1))
                keptEntries = try map.entries()
                keptElements = try list.elements(as: UInt64.self)
                keptMap = map
                keptList = list
                throw Mine(number: 1)
            }
        }
        var entries = try #require(keptEntries)
        var elements = try #require(keptElements)
        let map = try #require(keptMap)
        let list = try #require(keptList)
        #expect(throws: XitDBError.staleCursor) { try entries.next() }
        #expect(throws: XitDBError.staleCursor) { try elements.next() }
        #expect(throws: XitDBError.staleCursor) { try map.isEmpty }
        #expect(throws: XitDBError.staleCursor) { try list.isEmpty }
        #expect(throws: XitDBError.staleCursor) { try map.forEachEntry { _ in } }
        #expect(throws: XitDBError.staleCursor) { try list.forEachElement(as: UInt64.self) { _ in } }
    }
}
