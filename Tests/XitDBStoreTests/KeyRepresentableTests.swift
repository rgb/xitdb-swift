import Testing
import XitDB
import XitDBHashing
import XitDBStore

/// Keys as bytes: the integers order as their values, the same on every
/// machine, and the other conformances are what they say.
@Suite("keys as bytes")
struct KeyRepresentableTests {
    @Test func stringsAreTheirUTF8() {
        #expect("abc".keyBytes == [0x61, 0x62, 0x63])
        #expect("é".keyBytes == [0xC3, 0xA9])
        #expect("".keyBytes.isEmpty)
        #expect("hello world".dropFirst(6).keyBytes == Array("world".utf8))
    }

    @Test func bytesAreThemselves() {
        #expect([UInt8]([1, 2, 3]).keyBytes == [1, 2, 3])
        #expect(Bytes([9, 8], formatTag: "jp").keyBytes == [9, 8])
    }

    @Test func unsignedIntegersAreBigEndian() {
        #expect(UInt8(0xAB).keyBytes == [0xAB])
        #expect(UInt16(0x0102).keyBytes == [0x01, 0x02])
        #expect(UInt32(0x0102_0304).keyBytes == [1, 2, 3, 4])
        #expect(UInt64(0x0102_0304_0506_0708).keyBytes == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(UInt(1).keyBytes == [0, 0, 0, 0, 0, 0, 0, 1], "eight bytes whatever the word size")
        #expect(UInt64.max.keyBytes == [UInt8](repeating: 0xFF, count: 8))
    }

    @Test func signedIntegersHaveTheSignBitFlipped() {
        #expect(Int64.min.keyBytes == [UInt8](repeating: 0, count: 8))
        #expect(Int64(-1).keyBytes == [0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(Int64(0).keyBytes == [0x80, 0, 0, 0, 0, 0, 0, 0])
        #expect(Int64(1).keyBytes == [0x80, 0, 0, 0, 0, 0, 0, 1])
        #expect(Int64.max.keyBytes == [UInt8](repeating: 0xFF, count: 8))
        #expect(Int8(-128).keyBytes == [0x00])
        #expect(Int8(127).keyBytes == [0xFF])
        #expect(Int16(-2).keyBytes == [0x7F, 0xFE])
        #expect(Int32(5).keyBytes == [0x80, 0, 0, 5])
        #expect(Int(-7).keyBytes == Int64(-7).keyBytes, "an Int is an Int64 as a key")
    }

    /// The bytes of a set of values, sorted as byte strings, are in the
    /// values' order: what a sorted map relies on.
    @Test func bytesOrderAsValuesDo() {
        let signed: [Int64] = [.min, -1_000_000, -2, -1, 0, 1, 2, 255, 256, 65_536, .max]
        let sortedByBytes = signed.sorted { $0.keyBytes.lexicographicallyPrecedes($1.keyBytes) }
        #expect(sortedByBytes == signed)
        let unsigned: [UInt32] = [0, 1, 255, 256, 65_535, 65_536, .max]
        #expect(unsigned.sorted { $0.keyBytes.lexicographicallyPrecedes($1.keyBytes) } == unsigned)
        let small: [Int8] = [-128, -100, -1, 0, 1, 100, 127]
        #expect(small.sorted { $0.keyBytes.lexicographicallyPrecedes($1.keyBytes) } == small)
    }

    enum Colour: String, KeyRepresentable {
        case red, green
    }

    enum Level: Int32, KeyRepresentable {
        case low = -1
        case high = 1
    }

    @Test func rawValuesGoThroughTheirRawValue() {
        #expect(Colour.red.keyBytes == "red".keyBytes)
        #expect(Level.low.keyBytes == Int32(-1).keyBytes)
        #expect(Level.high.keyBytes == [0x80, 0, 0, 1])
    }
}

/// The raw-value keys are opt-in: a type that declares the conformance
/// gets them through its raw value, and one that does not is not a key.
@Suite("raw-value keys opt in")
struct RawValueKeyTests {
    enum Declared: Int16, KeyRepresentable {
        case low = -1
        case high = 1
    }

    @Test func aDeclaredConformanceGoesThroughTheRawValue() throws {
        #expect(Declared.low.keyBytes == Int16(-1).keyBytes)
        #expect(Declared(keyBytes: Int16(1).keyBytes) == .high)
        #expect(Declared(keyBytes: Int16(2).keyBytes) == nil)
        #expect(Declared(keyBytes: [1]) == nil)
        let store = try Store(try Database(creating: MemoryStorage(), hashSize: 32), hashing: SHA256.self)
        try store.transaction { moment in
            let sorted = moment["levels"].sortedMap(Declared.self, UInt64.self)
            try sorted.put(2, forKey: .high)
            try sorted.put(1, forKey: .low)
            var entries = try sorted.entries()
            #expect(try entries.next()?.key == Declared.low, "signed raw values order as their values do")
            #expect(try entries.next()?.key == Declared.high)
        }
    }
}
