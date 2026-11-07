import Testing
import XitDB

@Suite("Sorting and paginating") struct SortingAndPaginatingExamples {
    struct User {
        let id: String
        let username: String
        let name: String
    }

    private func newDirectory() throws -> (Database, ArrayList<ReadWrite>) {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let history = try ArrayList<ReadWrite>(database.rootCursor)

        // Inserted in no particular order; the index puts them in order.
        let users = [
            User(id: "user000000000001", username: "dave", name: "Dave Smith"),
            User(id: "user000000000002", username: "alice", name: "Alice Jones"),
            User(id: "user000000000003", username: "carol", name: "Carol White"),
            User(id: "user000000000004", username: "dan", name: "Dan Brown"),
            User(id: "user000000000005", username: "bob", name: "Bob Lee"),
            User(id: "user000000000006", username: "eve", name: "Eve Adams"),
        ]

        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)

            // The primary store: from a user's ID to the user's fields.
            let idToUser = try HashMap<ReadWrite>(moment.putCursor(forHash: sha256("id->user")))

            // The index: from a username to the user's ID, in username order.
            let usernameToID = try SortedMap<ReadWrite>(moment.putCursor(forHash: sha256("username->id")))

            for user in users {
                let fields = try HashMap<ReadWrite>(idToUser.putCursor(forHash: sha256(user.id)))
                try fields.put(.bytes(Array(user.username.utf8)), forHash: sha256("username"))
                try fields.put(.bytes(Array(user.name.utf8)), forHash: sha256("name"))

                // Both in one transaction, so that they cannot disagree.
                try usernameToID.put(.bytes(Array(user.id.utf8)), forKey: user.username.utf8)
            }
        }
        return (database, history)
    }

    @Test func aPage() throws {
        let (_, history) = try newDirectory()

        let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
        let idToUser = try HashMap<ReadOnly>(moment.cursor(forHash: sha256("id->user"))!)
        let usernameToID = try SortedMap<ReadOnly>(moment.cursor(forHash: sha256("username->id"))!)

        // ORDER BY username LIMIT 2 OFFSET 2
        let pageSize = 2
        let offset = 2

        var names: [String] = []
        var iterator = try usernameToID.iterator(fromIndex: offset)
        while names.count < pageSize, let cursor = try iterator.next() {
            let entry = try cursor.readEntry()
            let id = String(decoding: try entry.value.readBytes(), as: UTF8.self)

            let fields = try HashMap<ReadOnly>(idToUser.cursor(forHash: sha256(id))!)
            let name = try fields.cursor(forHash: sha256("name"))!.readBytes()
            names.append(String(decoding: name, as: UTF8.self))
        }
        #expect(names == ["Carol White", "Dan Brown"])
        #expect(try usernameToID.count == 6)
    }

    /// The article says that a late page takes about as many reads as an early
    /// one: the tree goes to a position without walking over what is before it.
    @Test func whatAPageCosts() throws {
        let storage = CountingStorage()
        let database = try Database(creating: storage, hashSize: 32)
        let index = try SortedMap<ReadWrite>(database.rootCursor)
        try database.withTransaction { cursor in
            let index = try SortedMap<ReadWrite>(cursor)
            for number in 0..<10_000 as Range<UInt64> {
                let key = withUnsafeBytes(of: number.bigEndian) { Array($0) }
                try index.put(.uint(number), forKey: key)
            }
        }

        func readsForAPage(at offset: Int) throws -> Int {
            let before = storage.reads
            var iterator = try index.iterator(fromIndex: offset)
            for _ in 0..<10 {
                _ = try iterator.next()!.readEntry()
            }
            return storage.reads - before
        }

        let first = try readsForAPage(at: 0)
        let middle = try readsForAPage(at: 5_000)
        let late = try readsForAPage(at: 9_990)
        #expect(abs(first - late) <= 5)
        #expect(abs(first - middle) <= 5)
    }

    @Test func aPrefixSearch() throws {
        let (_, history) = try newDirectory()
        let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
        let usernameToID = try SortedMap<ReadOnly>(moment.cursor(forHash: sha256("username->id"))!)

        // Everyone whose username starts with "da".
        let prefix = Array("da".utf8)

        var usernames: [String] = []
        var iterator = try usernameToID.iterator(fromKey: prefix)
        while let cursor = try iterator.next() {
            let key = try cursor.readEntry().key.readBytes()
            guard key.starts(with: prefix) else { break }
            usernames.append(String(decoding: key, as: UTF8.self))
        }
        #expect(usernames == ["dan", "dave"])
    }

    @Test func positions() throws {
        let (_, history) = try newDirectory()
        let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
        let usernameToID = try SortedMap<ReadOnly>(moment.cursor(forHash: sha256("username->id"))!)

        // alice bob carol dan dave eve
        let carol = try usernameToID.rank(of: "carol".utf8)  // 2
        let notThere = try usernameToID.rank(of: "david".utf8)  // 5: it would come before eve
        let third = try usernameToID.entry(at: 2)!.key.readBytes()  // carol
        let last = try usernameToID.entry(at: -1)!.key.readBytes()  // eve
        #expect(carol == 2)
        #expect(notThere == 5)
        #expect(third == Array("carol".utf8))
        #expect(last == Array("eve".utf8))
    }

    @Test func goingBackwards() throws {
        let (_, history) = try newDirectory()
        let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
        let usernameToID = try SortedMap<ReadOnly>(moment.cursor(forHash: sha256("username->id"))!)

        // There is no reverse iterator. A position counts from either end.
        var usernames: [String] = []
        for index in 1...2 {
            let key = try usernameToID.entry(at: -index)!.key.readBytes()
            usernames.append(String(decoding: key, as: UTF8.self))
        }
        #expect(usernames == ["eve", "dave"])
    }

    @Test func keysAreOrderedAsBytes() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let words = try SortedSet<ReadWrite>(database.rootCursor)

        for word in ["apple", "Zebra", "app", "éclair", "10", "9"] {
            try words.insert(word.utf8)
        }

        var ordered: [String] = []
        var iterator = try words.iterator()
        while let cursor = try iterator.next() {
            ordered.append(String(decoding: try cursor.readEntry().key.readBytes(), as: UTF8.self))
        }
        #expect(ordered == ["10", "9", "Zebra", "app", "apple", "éclair"])
    }

    // A key that sorts by score. Big-endian makes byte order match numeric
    // order, and the user's ID keeps two equal scores apart.
    func scoreKey(score: UInt64, userID: [UInt8]) -> [UInt8] {
        withUnsafeBytes(of: score.bigEndian) { Array($0) } + userID
    }

    @Test func numbersAndTies() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let leaderboard = try SortedMap<ReadWrite>(database.rootCursor)

        try leaderboard.put(.uint(1), forKey: scoreKey(score: 300, userID: [1]))
        try leaderboard.put(.uint(2), forKey: scoreKey(score: 90, userID: [2]))
        try leaderboard.put(.uint(3), forKey: scoreKey(score: 300, userID: [3]))

        var users: [UInt64] = []
        var iterator = try leaderboard.iterator()
        while let cursor = try iterator.next() {
            users.append(try cursor.readEntry().value.readUInt64())
        }
        #expect(users == [2, 1, 3])
    }

    // A signed number sorts in order once its top bit is flipped.
    func signedKey(_ value: Int64) -> [UInt8] {
        let flipped = UInt64(bitPattern: value) ^ (1 << 63)
        return withUnsafeBytes(of: flipped.bigEndian) { Array($0) }
    }

    @Test func signedNumbers() throws {
        #expect(signedKey(-1).lexicographicallyPrecedes(signedKey(0)))
        #expect(signedKey(-100).lexicographicallyPrecedes(signedKey(-1)))
        #expect(signedKey(0).lexicographicallyPrecedes(signedKey(1)))
    }

    @Test func aSortedSet() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let usernames = try SortedSet<ReadWrite>(database.rootCursor)

        try usernames.insert("alice".utf8)
        try usernames.insert("bob".utf8)
        try usernames.insert("alice".utf8)

        #expect(try usernames.count == 2)
        #expect(try usernames.contains("bob".utf8))
        #expect(try usernames.rank(of: "bob".utf8) == 1)
        #expect(try usernames.remove(forKey: "alice".utf8))
        #expect(try usernames.count == 1)
    }

    @Test func keepingAnIndexInStep() throws {
        let (_, history) = try newDirectory()

        // A rename: the index entry moves, in the same transaction as the
        // user's field, so that no moment has one without the other.
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let idToUser = try HashMap<ReadWrite>(moment.putCursor(forHash: sha256("id->user")))
            let usernameToID = try SortedMap<ReadWrite>(moment.putCursor(forHash: sha256("username->id")))

            let fields = try HashMap<ReadWrite>(idToUser.putCursor(forHash: sha256("user000000000003")))
            try fields.put(.bytes(Array("caroline".utf8)), forHash: sha256("username"))
            try usernameToID.remove(forKey: "carol".utf8)
            try usernameToID.put(.bytes(Array("user000000000003".utf8)), forKey: "caroline".utf8)
        }

        let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
        let usernameToID = try SortedMap<ReadOnly>(moment.cursor(forHash: sha256("username->id"))!)
        #expect(try usernameToID.cursor(forKey: "carol".utf8) == nil)
        #expect(try usernameToID.cursor(forKey: "caroline".utf8) != nil)
        #expect(try usernameToID.count == 6)
    }

    @Test func theKeyOfASortedEntryHasNoHash() throws {
        let (_, history) = try newDirectory()
        let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
        let usernameToID = try SortedMap<ReadOnly>(moment.cursor(forHash: sha256("username->id"))!)
        let entry = try usernameToID.entry(forKey: "alice".utf8)!
        #expect(entry.hash == [UInt8](repeating: 0, count: 32))
    }
}
