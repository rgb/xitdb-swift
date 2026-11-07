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

    /// The numbers the article quotes: what one small change costs, and that
    /// a change that changes nothing costs the same.
    @Test func everyTransactionAppends() throws {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashSize: 32)
        #expect(try database.committedSize == 62)

        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            for number in 0..<1000 {
                try moment.put(.uint(UInt64(number)), forHash: sha256("key \(number)"))
            }
        }

        let before = try database.committedSize
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            try HashMap<ReadWrite>(cursor).put(.uint(1), forHash: sha256("key 1"))
        }
        let oneChange = try database.committedSize - before
        #expect(oneChange == 820)

        let beforeNothing = try database.committedSize
        try history.append(.slot(try history.slot(at: -1)))
        let noChange = try database.committedSize - beforeNothing
        #expect(noChange == 194)
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
