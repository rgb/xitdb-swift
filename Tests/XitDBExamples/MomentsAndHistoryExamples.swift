import Testing
import XitDB

@Suite("Moments and history") struct MomentsAndHistoryExamples {
    @Test func oneMomentPerTransaction() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)

        let history = try ArrayList<ReadWrite>(database.rootCursor)

        for price: UInt64 in [10, 12, 15] {
            try history.append(.slot(try history.slot(at: -1))) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                try moment.put(.uint(price), forHash: sha256("price"))
            }
        }
        #expect(try history.count == 3)

        // Each commit is an element: the first holds 10, the last holds 15.
        let first = try HashMap<ReadOnly>(history.cursor(at: 0)!)
        let firstPrice = try first.cursor(forHash: sha256("price"))!.readUInt64()
        #expect(firstPrice == 10)

        let latest = try HashMap<ReadOnly>(history.cursor(at: -1)!)
        let latestPrice = try latest.cursor(forHash: sha256("price"))!.readUInt64()
        #expect(latestPrice == 15)

        // The whole history can be walked.
        var prices: [UInt64] = []
        var moments = try history.iterator()
        while let cursor = try moments.next() {
            let moment = try HashMap<ReadOnly>(cursor)
            prices.append(try moment.cursor(forHash: sha256("price"))!.readUInt64())
        }
        #expect(prices == [10, 12, 15])
    }

    @Test func aMomentKeepsWhatItDoesNotChange() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let history = try ArrayList<ReadWrite>(database.rootCursor)

        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            try moment.put(.bytes(Array("widget".utf8)), forHash: sha256("name"))
            try moment.put(.uint(10), forHash: sha256("price"))
        }

        // The second moment starts as the first, so it still has the name.
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            try HashMap<ReadWrite>(cursor).put(.uint(12), forHash: sha256("price"))
        }

        let second = try HashMap<ReadOnly>(history.cursor(at: 1)!)
        #expect(try second.cursor(forHash: sha256("name"))!.readBytes() == Array("widget".utf8))
        #expect(try second.cursor(forHash: sha256("price"))!.readUInt64() == 12)

        // And a moment that was given nothing to start from has no name.
        try history.append(.slot(nil)) { cursor in
            try HashMap<ReadWrite>(cursor).put(.uint(99), forHash: sha256("price"))
        }

        let third = try HashMap<ReadOnly>(history.cursor(at: 2)!)
        #expect(try third.cursor(forHash: sha256("name")) == nil)
    }

    @Test func undoingIsAppendingAnEarlierMoment() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        for price: UInt64 in [10, 12, 15] {
            try history.append(.slot(try history.slot(at: -1))) { cursor in
                try HashMap<ReadWrite>(cursor).put(.uint(price), forHash: sha256("price"))
            }
        }

        // Back to the first moment. The history keeps growing: the moment we
        // are undoing stays readable, as element 2.
        try history.append(.slot(try history.slot(at: 0)))

        #expect(try history.count == 4)
        let latest = try HashMap<ReadOnly>(history.cursor(at: -1)!)
        #expect(try latest.cursor(forHash: sha256("price"))!.readUInt64() == 10)
        let undone = try HashMap<ReadOnly>(history.cursor(at: 2)!)
        #expect(try undone.cursor(forHash: sha256("price"))!.readUInt64() == 15)
    }

    /// The numbers the article quotes: what a moment that changes nothing
    /// costs as a history grows. An append also copies the blocks on the way
    /// to the last element, and the list grows a level at 16, 256 and 4096.
    @Test func aMomentThatChangesNothing() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(nil))

        var costs: [UInt64: UInt64] = [:]
        for element: UInt64 in 1...4097 {
            let before = try database.committedSize
            try history.append(.slot(try history.slot(at: -1)))
            costs[element] = try database.committedSize - before
        }
        #expect(costs[1] == 194)
        #expect(costs[15] == 194)
        #expect(costs[16] == 482)
        #expect(costs[17] == 338)
        #expect(costs[255] == 338)
        #expect(costs[256] == 626)
        #expect(costs[257] == 482)
        #expect(costs[4095] == 482)
        #expect(costs[4096] == 770)
        #expect(costs[4097] == 626)
    }

    /// The numbers the article quotes: what changing one value in a map of
    /// 1,000 entries costs, for each of its keys, in a short history. A copy
    /// of each block on the way down, and of the entry.
    @Test func changingOneValue() throws {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashSize: 32)
        #expect(try database.committedSize == 57)

        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            for number in 0..<1000 {
                try moment.put(.uint(UInt64(number)), forHash: sha256("key \(number)"))
            }
        }
        let bytes = storage.bytes

        var costs: [UInt64: Int] = [:]
        for number in 0..<1000 {
            let copy = try Database(opening: MemoryStorage(bytes: bytes))
            let list = try ArrayList<ReadWrite>(copy.rootCursor)
            let before = try copy.committedSize
            try list.append(.slot(try list.slot(at: -1))) { cursor in
                try HashMap<ReadWrite>(cursor).put(.uint(0), forHash: sha256("key \(number)"))
            }
            costs[try copy.committedSize - before, default: 0] += 1
        }
        #expect(costs == [532: 20, 676: 749, 820: 211, 964: 20])
    }

    @Test func aBlockIsCopiedOncePerTransaction() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put(.uint(1), forHash: sha256("a"))

        func cost(ofPuts count: Int) throws -> UInt64 {
            let before = try database.committedSize
            try database.withTransaction { cursor in
                let map = try HashMap<ReadWrite>(cursor)
                for number in 0..<count {
                    try map.put(.uint(UInt64(number)), forHash: sha256("a"))
                }
            }
            return try database.committedSize - before
        }
        #expect(try cost(ofPuts: 100) == cost(ofPuts: 1))
    }

    @Test func removingLeavesTheBytes() throws {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashSize: 32)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(nil)) { cursor in
            try HashMap<ReadWrite>(cursor).put(.bytes(Array("a secret".utf8)), forHash: sha256("a"))
        }
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            try HashMap<ReadWrite>(cursor).remove(forHash: sha256("a"))
        }

        let latest = try HashMap<ReadOnly>(history.cursor(at: -1)!)
        #expect(try latest.cursor(forHash: sha256("a")) == nil)
        let earlier = try HashMap<ReadOnly>(history.cursor(at: 0)!)
        #expect(try earlier.cursor(forHash: sha256("a"))!.readBytes() == Array("a secret".utf8))
    }

    @Test func aMapAtTheRootKeepsNoHistory() throws {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashSize: 32)

        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put(.uint(10), forHash: sha256("price"))
        let afterFirst = try database.committedSize
        try map.put(.uint(12), forHash: sha256("price"))
        #expect(try database.committedSize > afterFirst)

        #expect(try map.cursor(forHash: sha256("price"))!.readUInt64() == 12)
    }
}
