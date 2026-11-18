import Foundation
import Testing
import XitDBFoundation
import XitDBHashing

@testable import XitDB

/// `Data` as a value and as a key (the first client's review of 0.5.1,
/// item 14; decision D66): it is the format's byte array, so it reads back
/// as `[UInt8]` and the reverse, a `Data` key is the `[UInt8]` key, a slice
/// is its own bytes wherever it starts, and a file written with `Data` is
/// byte for byte the file the same calls write with `[UInt8]`.
@Suite struct DataTests {
    /// A random source that gives the same numbers for the same seed, so
    /// that two databases written alike have the same commit IDs.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    /// A new database of version 1 as the original made it: the sixty-two
    /// bytes of the conformance fixture `inputs/v1-new.db`, hash size 20,
    /// hash ID "sha1", file ID 0x10. Nothing creates version 1 any more.
    private static let newVersionOne: [UInt8] = [
        0x78, 0x69, 0x74, 0x00, 0x00, 0x01, 0x00, 0x14, 0x73, 0x68, 0x61, 0x31, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x3e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x16, 0xad, 0x04, 0x18, 0x24, 0xe1, 0x48, 0x23,
    ]

    /// The two versions of the format.
    enum Version: UInt16, CaseIterable, CustomTestStringConvertible {
        case one = 1
        case two = 2

        var testDescription: String { "version \(rawValue)" }
    }

    /// A new database in memory, of either version, with SHA-1 as its
    /// hasher and commit IDs that are the same each time.
    private static func newDatabase(_ version: Version) throws -> (MemoryStorage, Database) {
        let random = RandomSource(Seeded(state: 42))
        let hasher = KeyHasher(Insecure.SHA1.self)
        switch version {
        case .one:
            let storage = MemoryStorage(bytes: newVersionOne)
            let database = try Database(opening: storage, hashSize: 20, random: random, hasher: hasher)
            #expect(database.header.version == 1)
            return (storage, database)
        case .two:
            let storage = MemoryStorage()
            let database = try Database(
                creating: storage, hashSize: 20, hashID: "sha1", fileID: 0x10, random: random, hasher: hasher)
            #expect(database.header.version == 2)
            return (storage, database)
        }
    }

    /// Bytes of several lengths: none, one, as many as a slot holds and one
    /// more, a hundred, and more than a page.
    private static let samples: [[UInt8]] = [0, 1, 8, 9, 100, 5000].map { count in
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ count) }
    }

    /// The same bytes as a `Data` that is a slice: it starts three bytes
    /// into the buffer it shares.
    private static func slice(_ bytes: [UInt8]) -> Data {
        Data([0xAA, 0xBB, 0xCC] + bytes).dropFirst(3)
    }

    // MARK: The file is the file `[UInt8]` writes

    /// The calls of the library that take a value or a key, each made with
    /// bytes in a type of the caller's choosing.
    enum Calls: String, CaseIterable, CustomTestStringConvertible {
        /// Each on a collection at the root, where every call is a
        /// transaction of its own.
        case aHashMapAtTheRoot, aCountedHashMapAtTheRoot, aSortedMapAtTheRoot
        case anArrayListAtTheRoot, aLinkedArrayListAtTheRoot
        case aHashSetAtTheRoot, aCountedHashSetAtTheRoot, aSortedSetAtTheRoot
        case aWriteThroughTheRootCursor
        /// All of them in one transaction, on collections under a map.
        case everythingInOneTransaction

        var testDescription: String { rawValue }

        func make<Bytes: StorableValue & KeyRepresentable>(
            in database: Database, _ bytes: ([UInt8]) -> Bytes
        ) throws {
            let samples = DataTests.samples
            switch self {
            case .aHashMapAtTheRoot:
                try Self.fill(try HashMap(database.rootCursor), bytes)
            case .aCountedHashMapAtTheRoot:
                try Self.fill(try CountedHashMap(database.rootCursor), bytes)
            case .aSortedMapAtTheRoot:
                try Self.fill(try SortedMap(database.rootCursor), bytes)
            case .anArrayListAtTheRoot:
                try Self.fill(try ArrayList(database.rootCursor), bytes)
            case .aLinkedArrayListAtTheRoot:
                try Self.fill(try LinkedArrayList(database.rootCursor), bytes)
            case .aHashSetAtTheRoot:
                let set = try HashSet(database.rootCursor)
                for sample in samples { try set.insert(bytes(sample)) }
            case .aCountedHashSetAtTheRoot:
                let set = try CountedHashSet(database.rootCursor)
                for sample in samples { try set.insert(bytes(sample)) }
            case .aSortedSetAtTheRoot:
                let set = try SortedSet(database.rootCursor)
                for sample in samples where !sample.isEmpty { try set.insert(bytes(sample)) }
            case .aWriteThroughTheRootCursor:
                var root = database.rootCursor
                for sample in samples { try root.write(bytes(sample)) }
            case .everythingInOneTransaction:
                try database.withTransaction { rootCursor in
                    let root = try HashMap(rootCursor)
                    try Self.fill(try HashMap(try root.putCursor(forKey: "map")), bytes)
                    try Self.fill(try CountedHashMap(try root.putCursor(forKey: "counted")), bytes)
                    try Self.fill(try SortedMap(try root.putCursor(forKey: "sorted")), bytes)
                    try Self.fill(try ArrayList(try root.putCursor(forKey: "list")), bytes)
                    try Self.fill(try LinkedArrayList(try root.putCursor(forKey: "linked")), bytes)
                    let set = try HashSet(try root.putCursor(forKey: "set"))
                    let countedSet = try CountedHashSet(try root.putCursor(forKey: "counted set"))
                    let sortedSet = try SortedSet(try root.putCursor(forKey: "sorted set"))
                    for sample in samples {
                        try set.insert(bytes(sample))
                        try countedSet.insert(bytes(sample))
                        if !sample.isEmpty { try sortedSet.insert(bytes(sample)) }
                    }
                    var written = try root.putCursor(forKey: "written")
                    for sample in samples { try written.write(bytes(sample)) }
                }
            }
        }

        /// A value under a text key, a number under a key of bytes, and a
        /// value under a key of bytes that is stored beside it.
        private static func fill<Bytes: StorableValue & KeyRepresentable>(
            _ map: HashMap<ReadWrite>, _ bytes: ([UInt8]) -> Bytes
        ) throws {
            for (index, sample) in DataTests.samples.enumerated() {
                try map.put(bytes(sample), forKey: "value \(index)")
                try map.put(UInt64(index), forKey: bytes(sample + [1]))
                try map.put(bytes(sample), forKey: bytes(sample + [2]), storingKey: true)
            }
            // A value put where one is already, of another length.
            try map.put(bytes(DataTests.samples[4]), forKey: "value 1")
        }

        private static func fill<Bytes: StorableValue & KeyRepresentable>(
            _ map: CountedHashMap<ReadWrite>, _ bytes: ([UInt8]) -> Bytes
        ) throws {
            for (index, sample) in DataTests.samples.enumerated() {
                try map.put(bytes(sample), forKey: "value \(index)")
                try map.put(UInt64(index), forKey: bytes(sample + [1]))
                try map.put(bytes(sample), forKey: bytes(sample + [2]), storingKey: true)
            }
            try map.put(bytes(DataTests.samples[4]), forKey: "value 1")
        }

        private static func fill<Bytes: StorableValue & KeyRepresentable>(
            _ map: SortedMap<ReadWrite>, _ bytes: ([UInt8]) -> Bytes
        ) throws {
            for (index, sample) in DataTests.samples.enumerated() {
                try map.put(bytes(sample), forKey: "value \(index)")
                try map.put(UInt64(index), forKey: bytes(sample + [1]))
            }
            try map.put(bytes(DataTests.samples[4]), forKey: "value 1")
        }

        private static func fill<Bytes: StorableValue & KeyRepresentable>(
            _ list: ArrayList<ReadWrite>, _ bytes: ([UInt8]) -> Bytes
        ) throws {
            for sample in DataTests.samples { try list.append(bytes(sample)) }
            try list.put(bytes(DataTests.samples[4]), at: 1)
            try list.put(bytes(DataTests.samples[1]), at: -1)
        }

        private static func fill<Bytes: StorableValue & KeyRepresentable>(
            _ list: LinkedArrayList<ReadWrite>, _ bytes: ([UInt8]) -> Bytes
        ) throws {
            for sample in DataTests.samples { try list.append(bytes(sample)) }
            try list.insert(bytes(DataTests.samples[5]), at: 2)
            try list.put(bytes(DataTests.samples[4]), at: 1)
        }
    }

    /// A file written with `Data` values and keys is byte for byte the file
    /// the same calls write with `[UInt8]`: at the root, where each call is
    /// a transaction, and inside one, on both versions of the format; and
    /// so is the file written with slices.
    @Test(arguments: Calls.allCases, Version.allCases)
    func aFileWrittenWithDataIsTheFileWrittenWithBytes(calls: Calls, version: Version) throws {
        let (arrays, withArrays) = try Self.newDatabase(version)
        try calls.make(in: withArrays) { $0 }
        let (datas, withData) = try Self.newDatabase(version)
        try calls.make(in: withData) { Data($0) }
        let (slices, withSlices) = try Self.newDatabase(version)
        try calls.make(in: withSlices) { Self.slice($0) }

        #expect(arrays.bytes.count > Self.newVersionOne.count + 5000)
        #expect(
            datas.bytes == arrays.bytes,
            "written with Data, the file differs at \(Self.firstDifference(datas.bytes, arrays.bytes))")
        #expect(
            slices.bytes == arrays.bytes,
            "written with slices, the file differs at \(Self.firstDifference(slices.bytes, arrays.bytes))")
    }

    /// Where two files first differ, for a failure's message.
    private static func firstDifference(_ left: [UInt8], _ right: [UInt8]) -> String {
        let common = min(left.count, right.count)
        let offset = (0..<common).first { left[$0] != right[$0] } ?? common
        return "\(offset) of \(left.count) and \(right.count) bytes"
    }

    // MARK: A value

    private func database() throws -> Database {
        try Database(creating: MemoryStorage(), hashing: SHA256.self)
    }

    /// What was put as `Data` reads back as `Data`, as `[UInt8]`, as
    /// ``Bytes`` without a tag and, where it is text, as a `String`; and
    /// what was put as `[UInt8]`, as text or as tagged bytes reads back as
    /// `Data`.
    @Test func dataReadsBackAsBytesAndBytesAsData() throws {
        let database = try database()
        let map = try HashMap(database.rootCursor)
        for (index, sample) in Self.samples.enumerated() {
            try map.put(Data(sample), forKey: "data \(index)")
            try map.put(sample, forKey: "bytes \(index)")
            #expect(try map.value(forKey: "data \(index)", as: Data.self) == Data(sample))
            #expect(try map.value(forKey: "data \(index)", as: [UInt8].self) == sample)
            #expect(try map.value(forKey: "data \(index)", as: Bytes.self) == Bytes(sample))
            #expect(try map.value(forKey: "bytes \(index)", as: Data.self) == Data(sample))
        }
        try map.put(Data("grüße".utf8), forKey: "text")
        #expect(try map.value(forKey: "text", as: String.self) == "grüße")
        try map.put("grüße", forKey: "string")
        #expect(try map.value(forKey: "string", as: Data.self) == Data("grüße".utf8))
        try map.put(Bytes([1, 2, 3], formatTag: "tg"), forKey: "tagged")
        #expect(try map.value(forKey: "tagged", as: Data.self) == Data([1, 2, 3]))

        // Through a cursor, a list and the typed iterator too.
        try database.withTransaction { root in
            let list = try ArrayList(try HashMap(root).putCursor(forKey: "list"))
            for sample in Self.samples { try list.append(Data(sample)) }
        }
        let list = try ArrayList(try #require(try map.cursor(forKey: "list")).readOnly)
        #expect(try list.value(at: 3, as: Data.self) == Data(Self.samples[3]))
        #expect(try #require(try list.cursor(at: 4)).read(Data.self) == Data(Self.samples[4]))
        var elements = try list.elements(as: Data.self)
        var read: [Data] = []
        while let element = try elements.next() { read.append(element) }
        #expect(read == Self.samples.map { Data($0) })
    }

    /// A slot set to nothing reads as empty data, as it reads as an empty
    /// array; a number and a collection are no data.
    @Test func whatIsNoByteArrayIsNoData() throws {
        let database = try database()
        let map = try HashMap(database.rootCursor)
        try map.put(.slot(nil), forKey: "nothing")
        try map.put(UInt64(7), forKey: "number")
        try database.withTransaction { root in
            _ = try ArrayList(try HashMap(root).putCursor(forKey: "list"))
        }
        #expect(try map.value(forKey: "nothing", as: Data.self) == Data())
        #expect(try map.value(forKey: "absent", as: Data.self) == nil)
        #expect(throws: XitDBError.unexpectedTag) { try map.value(forKey: "number", as: Data.self) }
        #expect(throws: XitDBError.unexpectedTag) { try map.value(forKey: "list", as: Data.self) }
    }

    /// A slice of a `Data`, whose first index is not zero, is written and
    /// hashed as its own bytes.
    @Test func aSliceIsItsOwnBytes() throws {
        let bytes: [UInt8] = [10, 20, 30, 40, 50]
        let slice = Self.slice(bytes)
        #expect(slice.startIndex == 3)
        #expect(slice.keyBytes == bytes)
        let inner = Data([1, 2, 3, 4, 5, 6])[2..<5]
        #expect(inner.startIndex == 2)
        #expect(inner.keyBytes == [3, 4, 5])

        let database = try database()
        let map = try HashMap(database.rootCursor)
        try map.put(slice, forKey: "value")
        #expect(try map.value(forKey: "value", as: [UInt8].self) == bytes)
        try map.put(UInt64(1), forKey: slice, storingKey: true)
        #expect(try map.value(forKey: bytes, as: UInt64.self) == 1)
        #expect(try map.entry(forKey: bytes)?.key.read([UInt8].self) == bytes)
        try map.put(inner, forKey: inner)
        #expect(try map.value(forKey: [UInt8]([3, 4, 5]), as: Data.self) == Data([3, 4, 5]))
    }

    // MARK: A key

    /// A `Data` key is the key of the `[UInt8]` of the same bytes: what was
    /// put under one is found under the other, in a hash map, a counted
    /// one, a sorted one and the three sets, and a key stored beside its
    /// value is stored as those bytes.
    @Test func aDataKeyIsTheKeyOfTheSameBytes() throws {
        let key: [UInt8] = [0, 255, 7, 7, 200]
        let other: [UInt8] = [0, 255, 7, 7, 201]
        #expect(Data(key).keyBytes == key)
        #expect(SHA256.keyHash(of: Data(key)) == SHA256.keyHash(of: key))

        let database = try database()
        try database.withTransaction { rootCursor in
            let root = try HashMap(rootCursor)

            let map = try HashMap(try root.putCursor(forKey: "map"))
            try map.put(UInt64(1), forKey: Data(key), storingKey: true)
            try map.put(UInt64(2), forKey: other)
            #expect(try map.value(forKey: key, as: UInt64.self) == 1)
            #expect(try map.value(forKey: Data(other), as: UInt64.self) == 2)
            #expect(try map.entry(forKey: key)?.key.read([UInt8].self) == key)
            #expect(try map.entry(forKey: Data(key))?.key.read(Data.self) == Data(key))
            #expect(try map.remove(forKey: Data(other)))
            #expect(try map.value(forKey: other, as: UInt64.self) == nil)

            let counted = try CountedHashMap(try root.putCursor(forKey: "counted"))
            try counted.put(UInt64(1), forKey: Data(key))
            try counted.put(UInt64(2), forKey: key)
            #expect(try counted.count == 1)
            #expect(try counted.value(forKey: Data(key), as: UInt64.self) == 2)

            let sorted = try SortedMap(try root.putCursor(forKey: "sorted"))
            try sorted.put(UInt64(2), forKey: Data(other))
            try sorted.put(UInt64(1), forKey: key)
            try sorted.put(UInt64(3), forKey: Data(key))
            #expect(try sorted.count == 2)
            #expect(try sorted.value(forKey: key, as: UInt64.self) == 3)
            var entries = try sorted.entries()
            #expect(try entries.next()?.key.read(Data.self) == Data(key))
            #expect(try entries.next()?.key.read([UInt8].self) == other)

            let set = try HashSet(try root.putCursor(forKey: "set"))
            try set.insert(Data(key))
            #expect(try set.contains(key))
            #expect(try !set.contains(Data(other)))
            let countedSet = try CountedHashSet(try root.putCursor(forKey: "counted set"))
            try countedSet.insert(Data(key))
            try countedSet.insert(key)
            #expect(try countedSet.count == 1)
            let sortedSet = try SortedSet(try root.putCursor(forKey: "sorted set"))
            try sortedSet.insert(Data(other))
            try sortedSet.insert(key)
            #expect(try sortedSet.contains(Data(key)))
            #expect(try sortedSet.count == 2)
        }
    }
}
