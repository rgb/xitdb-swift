import Testing
import XitDB

#if canImport(CryptoKit)
    import CryptoKit
#else
    import XitDBTestSupport
#endif

@Suite("Tutorial: Keeping history") struct KeepingHistoryTutorial {
    @Test func theWholeProgram() throws {
        func sha256(_ key: String) -> SHA256Digest {
            SHA256.hash(data: Array(key.utf8))
        }

        let database = try Database(creating: MemoryStorage(), hashSize: 32, hashID: "sha2")
        let history = try ArrayList<ReadWrite>(database.rootCursor)

        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let prices = try HashMap<ReadWrite>(cursor)
            try prices.put(.uint(120), forHash: sha256("apples"))
            try prices.put(.uint(300), forHash: sha256("pears"))
        }

        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let prices = try HashMap<ReadWrite>(cursor)
            try prices.put(.uint(150), forHash: sha256("apples"))
        }

        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let prices = try HashMap<ReadWrite>(cursor)
            try prices.remove(forHash: sha256("pears"))
        }

        let latest = try HashMap<ReadOnly>(history.cursor(at: -1)!)
        print(try latest.cursor(forHash: sha256("apples"))!.readUInt64())  // 150
        print(try latest.cursor(forHash: sha256("pears")) == nil)  // true

        let first = try HashMap<ReadOnly>(history.cursor(at: 0)!)
        print(try first.cursor(forHash: sha256("apples"))!.readUInt64())  // 120
        print(try first.cursor(forHash: sha256("pears"))!.readUInt64())  // 300

        var moments = try history.iterator()
        while let cursor = try moments.next() {
            let prices = try HashMap<ReadOnly>(cursor)
            print(try prices.cursor(forHash: sha256("apples"))!.readUInt64())  // 120, 150, 150
        }

        try history.append(.slot(try history.slot(at: 1)))

        let undone = try HashMap<ReadOnly>(history.cursor(at: -1)!)
        print(try undone.cursor(forHash: sha256("pears"))!.readUInt64())  // 300: it is back
        print(try history.count)  // 4: and what we undid is still element 2

        let before = try database.committedSize
        try history.append(.slot(try history.slot(at: 1)))
        let cost = try database.committedSize - before
        print(cost)  // 194

        #expect(cost == 194)
        #expect(try history.count == 5)
        #expect(try latest.cursor(forHash: sha256("pears")) == nil)
        #expect(try first.cursor(forHash: sha256("pears"))!.readUInt64() == 300)
        #expect(try undone.cursor(forHash: sha256("pears"))!.readUInt64() == 300)
        let undoneMoment = try HashMap<ReadOnly>(history.cursor(at: 2)!)
        #expect(try undoneMoment.cursor(forHash: sha256("pears")) == nil)
    }
}
