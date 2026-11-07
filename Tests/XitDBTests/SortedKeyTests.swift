import Testing

@testable import XitDB

/// The keys of a sorted map: how each shape is stored and how they order,
/// checked against a plain array sorted the same way, on every storage.
@Suite struct SortedKeyTests {
    /// Keys compare as unsigned bytes, a shorter key before a longer one
    /// it is a prefix of: Swift's lexicographic order of byte arrays.
    private static func ordered(_ keys: [[UInt8]]) -> [[UInt8]] {
        keys.sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// The shapes the key layout turns on: empty; one byte; exactly eight
    /// bytes without a zero, the longest a slot holds; eight bytes with a
    /// zero byte, which must be a record; longer than the 256-byte chunk the
    /// comparison reads at a time; and two long keys that differ only after
    /// a shared prefix longer than a chunk.
    private static let shapes: [(name: String, key: [UInt8])] = [
        ("empty", []),
        ("one byte", [0x6d]),
        ("eight bytes", Array("abcdefgh".utf8)),
        ("eight bytes with a zero", [0x61, 0x62, 0x63, 0, 0x65, 0x66, 0x67, 0x68]),
        ("nine bytes", Array("abcdefghi".utf8)),
        ("longer than a chunk", [UInt8](repeating: 0x70, count: 300)),
        ("shared prefix, then 1", [UInt8](repeating: 0x70, count: 300) + [1]),
        ("shared prefix, then 2", [UInt8](repeating: 0x70, count: 300) + [2]),
        ("shared prefix, cut short", [UInt8](repeating: 0x70, count: 299)),
        ("high byte", [0xff]),
        ("zero byte", [0]),
        ("two zero bytes", [0, 0]),
    ]

    /// Every shape goes in and comes back, in order, with its own value,
    /// and is stored in its slot when it fits without a zero byte, as a
    /// record otherwise.
    @Test(arguments: StorageKind.allCases)
    func everyShapeIsStoredAndOrdered(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)
        // put in an order that is not the sorted one
        let shapes = Self.shapes.enumerated().sorted { ($0.offset * 7) % 12 < ($1.offset * 7) % 12 }
        try database.withTransaction { cursor in
            let map = try SortedMap(try HashMap(cursor).putCursor(forHash: sha1("map").bytes))
            for (index, shape) in shapes {
                try map.put(.uint(UInt64(index)), forKey: shape.key)
            }
            #expect(try map.count == 12)
        }

        let root = try HashMap(database.rootCursor.readOnly)
        let map = try SortedMap(try #require(try root.cursor(forHash: sha1("map").bytes)))
        let ordered = Self.ordered(Self.shapes.map(\.key))
        var seen: [[UInt8]] = []
        var iterator = try map.iterator()
        while let entry = try iterator.next() {
            let pair = try entry.readEntry()
            let key = try pair.key.readBytes()
            seen.append(key)
            let shape = try #require(Self.shapes.firstIndex { $0.key == key })
            #expect(try pair.value.readUInt64() == UInt64(shape))
            // a key of at most eight bytes without a zero byte is in its slot
            let fits = key.count <= 8 && !key.contains(0)
            #expect(try pair.key.slot.tag == (fits ? .shortBytes : .bytes), "\(Self.shapes[shape].name)")
        }
        #expect(seen == ordered)

        for (index, key) in ordered.enumerated() {
            #expect(try map.rank(of: key) == UInt64(index), "rank of \(key.count) bytes")
            let pair = try #require(try map.entry(at: Int64(index)))
            #expect(try pair.key.readBytes() == key)
            #expect(try #require(try map.slot(forKey: key)) == (try pair.value.slot))
            var from = try map.iterator(fromKey: key)
            let first = try #require(try from.next())
            #expect(try first.readEntry().key.readBytes() == key)
        }
    }

    /// Keys that are not there have a rank and a place to start too: the
    /// number of keys below them, in the same order.
    @Test(arguments: StorageKind.allCases)
    func absentKeysRankAmongThePresent(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)
        try database.withTransaction { cursor in
            let map = try SortedMap(try HashMap(cursor).putCursor(forHash: sha1("map").bytes))
            for shape in Self.shapes {
                try map.put(.uint(1), forKey: shape.key)
            }
        }
        let root = try HashMap(database.rootCursor.readOnly)
        let map = try SortedMap(try #require(try root.cursor(forHash: sha1("map").bytes)))
        let ordered = Self.ordered(Self.shapes.map(\.key))
        let absent: [[UInt8]] = [
            [0x61],
            Array("abcdefg".utf8),
            Array("abcdefgh\0".utf8),
            [UInt8](repeating: 0x70, count: 256),
            [UInt8](repeating: 0x70, count: 300) + [0],
            [UInt8](repeating: 0x70, count: 300) + [3],
            [0xff, 0],
            [0, 0, 0],
        ]
        for key in absent {
            #expect(try map.cursor(forKey: key) == nil)
            let below = ordered.filter { $0.lexicographicallyPrecedes(key) }.count
            #expect(try map.rank(of: key) == UInt64(below), "rank of \(key.count) bytes")
            var from = try map.iterator(fromKey: key)
            if below < ordered.count {
                let first = try #require(try from.next())
                #expect(try first.readEntry().key.readBytes() == ordered[below])
            } else {
                #expect(try from.next() == nil)
            }
        }
    }

    /// Many keys of mixed lengths, put in a scrambled order, come out in
    /// the order a plain array sorts them, from the start, from each key
    /// and from each index; removing every other one keeps the rest in
    /// order.
    @Test(arguments: StorageKind.allCases)
    func manyKeysAgreeWithASortedArray(kind: StorageKind) throws {
        var random = SeededGenerator(seed: 12345)
        var keys: Set<[UInt8]> = []
        while keys.count < 500 {
            let length = Int(random.next() % 20)
            keys.insert((0..<length).map { _ in UInt8(truncatingIfNeeded: random.next() % 4) + 0x61 })
        }
        let scrambled = keys.shuffled(using: &random)
        let ordered = Self.ordered(scrambled)

        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)
        try database.withTransaction { cursor in
            let map = try SortedMap(try HashMap(cursor).putCursor(forHash: sha1("map").bytes))
            for (index, key) in scrambled.enumerated() {
                try map.put(.uint(UInt64(index)), forKey: key)
            }
        }
        func walked(_ map: SortedMap<ReadOnly>) throws -> [[UInt8]] {
            var seen: [[UInt8]] = []
            var iterator = try map.iterator()
            while let entry = try iterator.next() {
                seen.append(try entry.readEntry().key.readBytes())
            }
            return seen
        }
        let root = try HashMap(database.rootCursor.readOnly)
        let map = try SortedMap(try #require(try root.cursor(forHash: sha1("map").bytes)))
        #expect(try map.count == 500)
        #expect(try walked(map) == ordered)
        for (index, key) in ordered.enumerated() where index % 37 == 0 {
            #expect(try map.rank(of: key) == UInt64(index))
            var from = try map.iterator(fromKey: key)
            var rest: [[UInt8]] = []
            while let entry = try from.next() {
                rest.append(try entry.readEntry().key.readBytes())
            }
            #expect(rest == Array(ordered[index...]))
            var fromIndex = try map.iterator(fromIndex: Int64(index))
            #expect(try #require(try fromIndex.next()).readEntry().key.readBytes() == key)
            #expect(try #require(try map.entry(at: Int64(index) - 500)).key.readBytes() == key)
        }

        try database.withTransaction { cursor in
            let map = try SortedMap(try HashMap(cursor).putCursor(forHash: sha1("map").bytes))
            for (index, key) in ordered.enumerated() where index % 2 == 1 {
                #expect(try map.remove(forKey: key))
            }
            #expect(try map.count == 250)
        }
        let after = try SortedMap(
            try #require(try HashMap(database.rootCursor.readOnly).cursor(forHash: sha1("map").bytes)))
        let kept = ordered.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        #expect(try walked(after) == kept)
        for (index, key) in kept.enumerated() where index % 23 == 0 {
            #expect(try after.rank(of: key) == UInt64(index))
            #expect(try #require(try after.entry(at: Int64(index))).key.readBytes() == key)
        }
        // the moment before the removes still has every key
        #expect(try walked(map) == ordered)
    }
}
