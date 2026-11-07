import Testing

@testable import XitDB

/// The in-memory offset map: a table of its own, which must behave as the
/// dictionary it replaced.
@Suite struct OffsetMapTests {
    @Test func recordsAndFindsMappings() {
        var map = MemoryOffsetMap()
        #expect(map.get(0) == nil)
        #expect(map.get(UInt64.max) == nil)
        map.put(0, 20)
        map.put(UInt64.max, 7)
        map.put(62, 62)
        #expect(map.get(0) == 20)
        #expect(map.get(UInt64.max) == 7)
        #expect(map.get(62) == 62)
        #expect(map.get(61) == nil)
        // a mapping put again is replaced
        map.put(62, 100)
        #expect(map.get(62) == 100)
    }

    /// Many more mappings than the table starts with room for, with keys
    /// that share the low bits a smaller table would hash on, and every
    /// one found afterwards.
    @Test func growsPastItsFirstCapacity() {
        var map = MemoryOffsetMap()
        let keys = (0..<10_000).map { UInt64($0) * 4096 + 20 }
        for (index, key) in keys.enumerated() {
            map.put(key, UInt64(index))
        }
        for (index, key) in keys.enumerated() {
            #expect(map.get(key) == UInt64(index))
        }
        #expect(map.get(21) == nil)
        #expect(map.get(4096 * 10_000 + 20) == nil)
    }

    @Test func resetForgetsEverything() {
        var map = MemoryOffsetMap()
        for key in stride(from: UInt64(0), to: 5000, by: 3) {
            map.put(key, key + 1)
        }
        map.reset()
        for key in stride(from: UInt64(0), to: 5000, by: 3) {
            #expect(map.get(key) == nil)
        }
        map.put(9, 10)
        #expect(map.get(9) == 10)
        #expect(map.get(12) == nil)
    }
}
