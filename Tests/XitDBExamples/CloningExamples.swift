import Testing
import XitDB
import XitDBHashing

@Suite("Cloning, freeze and stale handles") struct CloningExamples {
    /// A history whose first moment has a list of two fruits.
    private func historyWithFruits() throws -> (Database, ArrayList<ReadWrite>) {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let fruits = try ArrayList<ReadWrite>(moment.putCursor(forKey: "fruits"))
            try fruits.append("apple")
            try fruits.append("pear")
        }
        return (database, history)
    }

    private func count(_ key: String, in history: ArrayList<ReadWrite>) throws -> UInt64 {
        let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
        return try ArrayList<ReadOnly>(moment.cursor(forHash: sha256(key))!).count
    }

    @Test func aCloneOfCommittedData() throws {
        let (_, history) = try historyWithFruits()

        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)

            // "food" starts as a copy of "fruits", which an earlier transaction made.
            let fruits = try moment.slot(forKey: "fruits")
            try moment.put(.slot(fruits), forKey: "food")
            let food = try ArrayList<ReadWrite>(moment.putCursor(forKey: "food"))
            try food.append("rice")
        }

        #expect(try count("food", in: history) == 3)
        #expect(try count("fruits", in: history) == 2)
    }

    @Test func aCloneOfDataFromTheSameTransaction() throws {
        let (_, history) = try historyWithFruits()

        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let bigCities = try ArrayList<ReadWrite>(
                moment.putCursor(forKey: "big-cities"))
            try bigCities.append("New York, NY")
            try bigCities.append("Los Angeles, CA")

            // "cities" starts as a copy of "big-cities", which this transaction made.
            try moment.put(.slot(try bigCities.slot), forKey: "cities")
            let cities = try ArrayList<ReadWrite>(moment.putCursor(forKey: "cities"))
            try cities.append("Charleston, SC")
        }

        // Both have three: they are one list.
        #expect(try count("cities", in: history) == 3)
        #expect(try count("big-cities", in: history) == 3)
    }

    @Test func theCloneDoneRight() throws {
        let (_, history) = try historyWithFruits()

        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let bigCities = try ArrayList<ReadWrite>(
                moment.putCursor(forKey: "big-cities"))
            try bigCities.append("New York, NY")
            try bigCities.append("Los Angeles, CA")

            // 1. Copy the slot.
            try moment.put(.slot(try bigCities.slot), forKey: "cities")

            // 2. Freeze: nothing written so far in this transaction changes in place any more.
            try cursor.database.freeze()

            // 3. Take the collections again, from the cursor the body was given.
            let again = try HashMap<ReadWrite>(cursor)
            let cities = try ArrayList<ReadWrite>(again.putCursor(forKey: "cities"))
            try cities.append("Charleston, SC")
        }

        #expect(try count("cities", in: history) == 3)
        #expect(try count("big-cities", in: history) == 2)
    }

    /// The original README's note on its cloning example: freeze globally,
    /// before `putCursor` makes the cities cursor. Followed as written, the
    /// cursor is made through the map made before the freeze, which the port
    /// refuses; with the map made again from the body's cursor it gives what
    /// the original gives, four cities and two big cities. ("Where the port
    /// differs from the original")
    @Test func theOriginalsNoteOnFreezingGlobally() throws {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashing: SHA256.self)
        let history = try ArrayList<ReadWrite>(database.rootCursor)

        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let bigCities = try ArrayList<ReadWrite>(moment.putCursor(forKey: "big-cities"))
            try bigCities.append("New York, NY")
            try bigCities.append("Los Angeles, CA")

            try cursor.database.freeze()

            // As written: the map was made before the freeze. The refusal writes nothing.
            let length = try storage.length
            #expect(throws: XitDBError.staleCursor) { try moment.putCursor(forKey: "cities") }
            #expect(try storage.length == length)

            // The map again, from the cursor the body was given.
            var citiesCursor = try HashMap<ReadWrite>(cursor).putCursor(forKey: "cities")
            try citiesCursor.write(.slot(try bigCities.slot))
            let cities = try ArrayList<ReadWrite>(citiesCursor)
            try cities.append("Charleston, SC")
            try cities.append("Louisville, KY")
        }

        #expect(try count("cities", in: history) == 4)
        #expect(try count("big-cities", in: history) == 2)
    }

    @Test func whatAFreezeDoesToTheHandlesYouHold() throws {
        let (database, history) = try historyWithFruits()

        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let bigCities = try ArrayList<ReadWrite>(
                moment.putCursor(forKey: "big-cities"))
            try bigCities.append("New York, NY")
            var first = try bigCities.putCursor(at: 0)
            try database.freeze()

            // A write through anything made before the freeze is refused, before
            // it writes anything, so the transaction goes on.
            #expect(throws: XitDBError.staleCursor) { try bigCities.append("Boston, MA") }
            #expect(throws: XitDBError.staleCursor) { try moment.put(UInt64(1), forKey: "x") }
            #expect(throws: XitDBError.staleCursor) { try first.write(.uint(1)) }
            #expect(throws: XitDBError.staleCursor) { try bigCities.putCursor(at: 0) }
            // So is making a collection again from a held cursor.
            #expect(throws: XitDBError.staleCursor) { try ArrayList<ReadWrite>(bigCities.cursor) }
            #expect(throws: XitDBError.staleCursor) { try ArrayList<ReadWrite>(first) }
            // But not from the cursor of a collection made at the body's own slot.
            try HashMap<ReadWrite>(moment.cursor).put(UInt64(1), forKey: "y")
            // Reads go on, and see what the handle saw.
            #expect(try bigCities.count == 1)
            #expect(try moment.cursor(forKey: "fruits") != nil)

            // The way on: from the cursor the body was given.
            let again = try HashMap<ReadWrite>(cursor)
            try ArrayList<ReadWrite>(again.putCursor(forKey: "big-cities")).append(UInt64(2))
        }
        #expect(try count("big-cities", in: history) == 2)
        let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
        #expect(try moment.value(forKey: "y", as: UInt64.self) == 1)
        #expect(try moment.cursor(forKey: "x") == nil)
    }

    @Test func whatACopyOfCommittedDataCosts() throws {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashing: SHA256.self)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let fruits = try ArrayList<ReadWrite>(moment.putCursor(forKey: "fruits"))
            try fruits.append("apple")
            try fruits.append("pear")
        }
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            var mark = storage.bytes.count
            let fruits = try moment.slot(forKey: "fruits")
            try moment.put(.slot(fruits), forKey: "food")
            // A new entry: the hash and two slots.
            #expect(storage.bytes.count - mark == 50)
            mark = storage.bytes.count
            let food = try ArrayList<ReadWrite>(moment.putCursor(forKey: "food"))
            // The list's header and its block.
            #expect(storage.bytes.count - mark == 160)
            mark = storage.bytes.count
            try food.append("rice")
            #expect(storage.bytes.count == mark)
        }
    }

    @Test func everyWriteThroughAStaleHandleIsRefused() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        var kept: Cursor<ReadWrite>?
        try database.withTransaction { cursor in
            kept = try HashMap<ReadWrite>(cursor).putCursor(forKey: "list")
            _ = try ArrayList<ReadWrite>(kept!)
        }
        try database.withTransaction { cursor in
            // A cursor from an earlier transaction: not even an initialiser.
            #expect(throws: XitDBError.staleCursor) { try ArrayList<ReadWrite>(kept!) }

            let moment = try HashMap<ReadWrite>(cursor)
            let list = try ArrayList<ReadWrite>(moment.putCursor(forKey: "list"))
            try list.append(UInt64(1))
            var value = try moment.putCursor(forKey: "bytes")
            try cursor.database.freeze()
            // The body's own cursor goes on, through an init or a write: this
            // writeIfEmpty passes the guard and, the root being a map, writes nothing.
            try cursor.writeIfEmpty(.uint(1))
            // A byte writer through it is refused like every other cursor's write.
            #expect(throws: XitDBError.staleCursor) { try cursor.writeBytes { writer in try writer.write([1]) } }
            #expect(throws: XitDBError.staleCursor) {
                try value.writeBytes { writer in try writer.write([1, 2, 3]) }
            }

            // A stale handle reads what it pointed at, and not what is written afterwards.
            let again = try ArrayList<ReadWrite>(HashMap<ReadWrite>(cursor).putCursor(forKey: "list"))
            try again.append(UInt64(2))
            #expect(try list.count == 1)
            #expect(try again.count == 2)
        }
    }

    @Test func anInitOnAHeldCursorIsRefused() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { cursor in
            let root = try HashMap<ReadWrite>(cursor)
            let shop = try HashMap<ReadWrite>(root.putCursor(forKey: "shop"))
            let stock = try ArrayList<ReadWrite>(shop.putCursor(forKey: "stock"))
            try stock.append(UInt64(1))

            // A copy of the whole shop, and a freeze to keep it as it is.
            try root.put(.slot(try shop.slot), forKey: "yesterday")
            try cursor.database.freeze()

            #expect(throws: XitDBError.staleCursor) {
                // Refused with staleCursor: it would write the list's slot in place,
                // in a record the copy shares.
                try ArrayList<ReadWrite>(stock.cursor).append(UInt64(2))
            }

            let rootAgain = try HashMap<ReadWrite>(cursor)
            let shopAgain = try HashMap<ReadWrite>(rootAgain.putCursor(forKey: "shop"))
            try ArrayList<ReadWrite>(shopAgain.putCursor(forKey: "stock"))
                .append(UInt64(2))
        }
        // The refusal wrote nothing, and the way from the root leaves the copy alone.
        #expect(try stockCounts(in: database) == (2, 1))
    }

    /// The stock of "shop" and of "yesterday", as committed.
    private func stockCounts(in database: Database) throws -> (UInt64, UInt64) {
        let root = try HashMap<ReadOnly>(database.rootCursor)
        func stockCount(_ key: String) throws -> UInt64 {
            let shop = try HashMap<ReadOnly>(root.cursor(forHash: sha256(key))!)
            return try ArrayList<ReadOnly>(shop.cursor(forKey: "stock")!).count
        }
        return (try stockCount("shop"), try stockCount("yesterday"))
    }

    @Test func anInitOnAHeldCursorIsRefusedWhenTheCopyComesAfterTheFreeze() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { cursor in
            let root = try HashMap<ReadWrite>(cursor)
            let shop = try HashMap<ReadWrite>(root.putCursor(forKey: "shop"))
            let stock = try ArrayList<ReadWrite>(shop.putCursor(forKey: "stock"))
            try stock.append(UInt64(1))
            try cursor.database.freeze()
            // The copy shares the shop's record from before the freeze.
            try HashMap<ReadWrite>(cursor).put(.slot(try shop.slot), forKey: "yesterday")
            #expect(throws: XitDBError.staleCursor) { try ArrayList<ReadWrite>(stock.cursor) }
        }
        #expect(try stockCounts(in: database) == (1, 1))
    }

    @Test func aHeldCursorIsRefusedEvenWhereItWouldBeSafe() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { cursor in
            let root = try HashMap<ReadWrite>(cursor)
            let shop = try HashMap<ReadWrite>(root.putCursor(forKey: "shop"))
            try shop.put(UInt64(1), forKey: "open")
            try root.put(.slot(try shop.slot), forKey: "yesterday")
            try cursor.database.freeze()
            // The shop's own slot is in nothing that was copied, and still the engine cannot tell.
            #expect(throws: XitDBError.staleCursor) { try HashMap<ReadWrite>(shop.cursor) }
            let shopAgain = try HashMap<ReadWrite>(HashMap<ReadWrite>(cursor).putCursor(forKey: "shop"))
            try shopAgain.put(UInt64(0), forKey: "open")
        }
        let root = try HashMap<ReadOnly>(database.rootCursor)
        func open(_ key: String) throws -> UInt64 {
            try HashMap<ReadOnly>(root.cursor(forKey: key)!).value(forKey: "open", as: UInt64.self)!
        }
        #expect(try open("shop") == 0)
        #expect(try open("yesterday") == 1)
    }

    @Test func aJoinFreezesEveryList() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let tasks = try LinkedArrayList<ReadWrite>(moment.putCursor(forKey: "tasks"))
            let more = try LinkedArrayList<ReadWrite>(moment.putCursor(forKey: "more"))
            try tasks.append(UInt64(1))
            try more.append(UInt64(2))

            try tasks.append(contentsOf: more)
            // The list that joined is stale too. Take it again from the body's cursor.
            let joined = try LinkedArrayList<ReadWrite>(
                HashMap<ReadWrite>(cursor).putCursor(forKey: "tasks"))
            try joined.append(UInt64(3))

            // Every collection made before the join is stale, the list that joined included. Through
            // `tasks`, after the second handle above, the original loses the write at the commit.
            #expect(throws: XitDBError.staleCursor) { try tasks.append(UInt64(5)) }
            #expect(throws: XitDBError.staleCursor) { try LinkedArrayList<ReadWrite>(tasks.cursor) }
            #expect(throws: XitDBError.staleCursor) { try more.append(UInt64(4)) }
            #expect(throws: XitDBError.staleCursor) { try moment.put(UInt64(4), forKey: "x") }
            let again = try HashMap<ReadWrite>(cursor)
            let moreAgain = try LinkedArrayList<ReadWrite>(again.putCursor(forKey: "more"))
            try moreAgain.append(UInt64(4))
        }

        // What the commit holds: every write through a fresh handle, and nothing of the refused ones.
        let moment = try HashMap<ReadOnly>(database.rootCursor)
        func elements(_ key: String) throws -> [UInt64] {
            let list = try LinkedArrayList<ReadOnly>(moment.cursor(forHash: sha256(key))!)
            return try (0..<list.count).map { try list.cursor(at: $0)!.readUInt64() }
        }
        #expect(try elements("tasks") == [1, 2, 3])
        #expect(try elements("more") == [2, 4])
        #expect(try moment.cursor(forKey: "x") == nil)
    }

    @Test func aCursorFreezeProtectsOnlyFromThatCursor() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let bigCities = try ArrayList<ReadWrite>(
                moment.putCursor(forKey: "big-cities"))
            for number in 0..<300 {
                try bigCities.append(.uint(UInt64(number)))
            }

            // The original's pattern: copy the slot, freeze the cursor, make the list.
            var citiesCursor = try moment.putCursor(forKey: "cities")
            try citiesCursor.write(.slot(try bigCities.slot))
            try citiesCursor.freeze()
            let cities = try ArrayList<ReadWrite>(citiesCursor)

            // Writes through the copy leave the original alone.
            try cities.append(UInt64(300))
            #expect(try bigCities.count == 300)
            // A write through the original, deep in the list, shows through the copy.
            try bigCities.put(.uint(9999), at: 200)
            #expect(try cities.cursor(at: 200)!.readUInt64() == 9999)
        }

        // In a linked list the copy and the original disagree, which is an error.
        let linked = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        #expect(throws: XitDBError.invalidBTreeNode) {
            try linked.withTransaction { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                let original = try LinkedArrayList<ReadWrite>(moment.putCursor(forKey: "original"))
                for number in 0..<20 {
                    try original.append(.uint(UInt64(number)))
                }
                var copyCursor = try moment.putCursor(forKey: "copy")
                try copyCursor.write(.slot(try original.slot))
                try copyCursor.freeze()
                let copy = try LinkedArrayList<ReadWrite>(copyCursor)
                try original.remove(at: 0)
                try original.remove(at: 0)
                try copy.append(UInt64(100))
            }
        }

        // In a sorted set.
        let sortedSet = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        #expect(throws: XitDBError.invalidBTreeNode) {
            try sortedSet.withTransaction { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                let original = try SortedSet<ReadWrite>(moment.putCursor(forKey: "original"))
                for number in 0..<40 {
                    try original.insert(Array("key\(number)".utf8))
                }
                var copyCursor = try moment.putCursor(forKey: "copy")
                try copyCursor.write(.slot(try original.slot))
                try copyCursor.freeze()
                let copy = try SortedSet<ReadWrite>(copyCursor)
                for number in 0..<10 {
                    _ = try original.remove(forKey: Array("key\(number)".utf8))
                }
                try copy.insert(Array("zzz".utf8))
                #expect(try copy.count == 41)
                _ = try copy.entry(at: 35)
            }
        }

        // And in a sorted map.
        let sorted = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        #expect(throws: XitDBError.invalidBTreeNode) {
            try sorted.withTransaction { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                let original = try SortedMap<ReadWrite>(moment.putCursor(forKey: "original"))
                for number in 0..<40 {
                    try original.put(UInt64(number), forKey: Array("key\(number)".utf8))
                }
                var copyCursor = try moment.putCursor(forKey: "copy")
                try copyCursor.write(.slot(try original.slot))
                try copyCursor.freeze()
                let copy = try SortedMap<ReadWrite>(copyCursor)
                for number in 0..<10 {
                    _ = try original.remove(forKey: Array("key\(number)".utf8))
                }
                try copy.put(UInt64(1), forKey: Array("zzz".utf8))
                // The copy counts 41 entries, and its tree holds 31.
                #expect(try copy.count == 41)
                _ = try copy.entry(at: 35)
            }
        }
    }

    @Test func whatAFreezeCosts() throws {
        // The first write after a freeze copies its way down and the next is in place, as the article
        // says: two lists made in the same transaction, in a map at the root, and joined.
        func measure(_ size: Int) throws -> [Int] {
            let storage = MemoryStorage()
            let database = try Database(creating: storage, hashing: SHA256.self)
            var appended: [Int] = []
            try database.withTransaction { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                let tasks = try LinkedArrayList<ReadWrite>(moment.putCursor(forKey: "tasks"))
                let more = try LinkedArrayList<ReadWrite>(moment.putCursor(forKey: "more"))
                for number in 0..<size {
                    try tasks.append(.uint(UInt64(number)))
                    try more.append(.uint(UInt64(number)))
                }
                var mark = storage.bytes.count
                func step() {
                    appended.append(storage.bytes.count - mark)
                    mark = storage.bytes.count
                }
                try tasks.append(contentsOf: more)
                step()
                // The way on after the join, a step at a time: the map's block, the list's entry, its header.
                let rootAgain = try HashMap<ReadWrite>(cursor)
                step()
                let entry = try rootAgain.putCursor(forKey: "tasks")
                step()
                let joined = try LinkedArrayList<ReadWrite>(entry)
                step()
                try joined.append(UInt64(0))
                step()
                try joined.append(UInt64(1))
                step()
            }
            return appended
        }
        // The join, the map, the entry, the header, the first append and the second.
        #expect(try measure(1000) == [822, 144, 50, 16, 1114, 0])
        #expect(try measure(10000) == [274, 144, 50, 16, 1388, 0])
    }
}
