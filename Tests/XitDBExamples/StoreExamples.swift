import Testing
import XitDBStore

// The examples of "Keys, values and handles", in XitDBStore's catalogue. The
// store re-exports XitDB and XitDBHashing, so this file imports it alone, as
// the article says a store's user does.

enum Role: String {
    case admin, guest
}

extension Role: KeyRepresentable {}

@Suite("Keys, values and handles") struct StoreExamples {
    private func makeStore() throws -> Store {
        try Store(try Database(creating: MemoryStorage(), hashSize: 32), hashing: SHA256.self)
    }

    @Test func aStoreWritesAMomentAndReadsItBack() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let store = try Store(database, hashing: SHA256.self)

        try store.transaction { moment in
            try moment["name"].set("Alice")
            try moment["age"].set(UInt64(25))
        }

        let name = try store.latest["name"].value(String.self)  // "Alice"
        #expect(name == "Alice")
        #expect(try store.latest["age"].value(UInt64.self) == 25)
    }

    @Test func insideATransactionTheLatestIsTheCommitBefore() throws {
        let store = try makeStore()
        try store.transaction { moment in try moment["name"].set("Alice") }
        try store.transaction { moment in
            try moment["name"].set("Bob")
            #expect(try store.latest["name"].value(String.self) == "Alice")
            #expect(try store.momentCount == 1)
            #expect(throws: XitDBError.nestedTopLevelWrite) { try store.transaction { _ in } }
        }
        #expect(try store.momentCount == 2)
        #expect(throws: XitDBError.expectedTxStart) { try store.latest["name"].set("Carol") }
        #expect(try store.moment(at: -2)["name"].value(String.self) == "Alice")
    }

    @Test func aStoreWithAHashOfAnotherSizeIsRefused() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        #expect(throws: XitDBError.hashSizeMismatch) { try Store(database, hashing: Insecure.SHA1.self) }
    }

    @Test @MainActor func aTaskReadsASnapshotThroughAMoment() async throws {
        let store = try makeStore()
        try store.transaction { moment in
            try moment["name"].set("Alice")
        }

        // The writer hands the last commit to a reader on another task.
        let snapshot = try store.snapshot()
        let reader = Task.detached {
            let reading = SnapshotDatabase(snapshot)
            let moment = try Moment(reading: reading, hashing: SHA256.self)
            return try moment["name"].value(String.self)
        }
        try store.transaction { moment in
            try moment["name"].set("Bob")
        }
        let read = try await reader.value  // "Alice", whatever the writer did meanwhile
        #expect(read == "Alice")
        #expect(try Moment(reading: store.database, hashing: SHA256.self)["name"].value(String.self) == "Bob")
    }

    @Test func aHandleNamesAPlace() throws {
        let store = try makeStore()
        try store.transaction { moment in
            let today = moment["notes"]["today"]
            try today.set("Buy bread")

            // The map at "notes" goes, and the handle still names its place.
            try moment["notes"].clear()
            let there = try today.exists  // false
            #expect(!there)
            try today.set("Buy milk")  // and makes the map at "notes" again
        }
        #expect(try store.latest["notes"]["today"].value(String.self) == "Buy milk")
    }

    @Test func theRootPlaceIsTheMomentsMap() throws {
        let store = try makeStore()
        try store.transaction { moment in
            #expect(throws: XitDBError.unexpectedTag) { try moment.root.set("value") }
            #expect(throws: XitDBError.unexpectedTag) { try moment.root.make(.list) }
            try moment["a"].set(UInt64(1))
            try moment.root.clear()
            #expect(try !moment["a"].exists)
        }
    }

    @Test func aHandleKeptPastItsTransactionRefusesWrites() throws {
        let store = try makeStore()
        var kept: Handle?
        try store.transaction { moment in
            kept = moment["a"]
            try kept!.set(UInt64(1))
        }
        #expect(throws: XitDBError.expectedTxStart) { try kept!.set(UInt64(2)) }
        try store.transaction { _ in
            #expect(throws: XitDBError.staleCursor) { try kept!.set(UInt64(3)) }
        }
        #expect(try kept!.value(UInt64.self) == 1)
    }

    @Test func integerKeysSortAsTheirValues() throws {
        let store = try makeStore()
        try store.transaction { moment in
            let readings = moment["readings"].sortedMap(Int.self, String.self)
            try readings.put("mild", forKey: 12)
            try readings.put("cold", forKey: -5)
            try readings.put("freezing", forKey: -20)
        }

        let readings = try store.latest["readings"].sortedMap(Int.self, String.self)
        var entries = try readings.entries()
        while let entry = try entries.next() {
            print(entry.key, entry.value)  // -20 freezing, then -5 cold, then 12 mild
        }
        var again = try readings.entries()
        var seen: [String] = []
        while let entry = try again.next() { seen.append("\(entry.key) \(entry.value)") }
        #expect(seen == ["-20 freezing", "-5 cold", "12 mild"])
        #expect(Int(keyBytes: [1, 2]) == nil, "the wrong number of bytes is no Int")
        #expect(Int(-1).keyBytes.count == 8)
    }

    @Test func readsAreThrowingGettersAndWritesAreMethods() throws {
        let store = try makeStore()
        try store.transaction { moment in
            let ages = moment["ages"].map(String.self, UInt64.self)
            try ages.put(25, forKey: "alice")
        }

        let ages = try store.latest["ages"].map(String.self, UInt64.self)
        let age = try ages["alice"]  // 25
        #expect(age == 25)
        #expect(try ages["bob"] == nil)
        #expect(throws: XitDBError.unexpectedTag) { try store.latest["ages"]["alice"].value(String.self) }
    }

    @Test func aCollectionInsideACollectionIsAHandle() throws {
        let store = try makeStore()
        try store.transaction { moment in
            let alice = moment["users"]["alice"]
            try alice["email"].set("alice@example.com")
            try alice["roles"].keySet(Role.self).insert(.admin)

            // A list of lists: append() gives the handle of a new, empty element.
            let rounds = moment["rounds"].list(UInt64.self)
            let first = try rounds.append().list(UInt64.self)
            try first.append(3)
        }
        let latest = try store.latest
        #expect(try latest["users"]["alice"]["email"].value(String.self) == "alice@example.com")
        var roles = try latest["users"]["alice"]["roles"].keySet(Role.self).keys()
        #expect(try roles.next() == .admin)
        #expect(try roles.next() == nil)
        let rounds = latest["rounds"].list(UInt64.self)
        #expect(try rounds[handleAt: 0].list(UInt64.self)[0] == 3)
        #expect(throws: XitDBError.unexpectedTag) { try rounds[0] }
    }

    @Test func makeGivesACollectionThatExistsWhileEmpty() throws {
        let store = try makeStore()
        try store.transaction { moment in
            // A list that has to exist before it has elements.
            try moment["queue"].make(.list)
        }
        let made = try store.latest["queue"].exists  // true
        #expect(made)
        #expect(try store.latest["queue"].list(UInt64.self).count == 0)
        try store.transaction { moment in
            try moment["queue"].make(.list)
            #expect(throws: XitDBError.unexpectedTag) { try moment["queue"].make(.map) }
        }
    }

    @Test func aJoinLeavesTheHandlesGoingOn() throws {
        let store = try makeStore()
        try store.transaction { moment in
            let first = moment["first"].linkedList(UInt64.self)
            let second = moment["second"].linkedList(UInt64.self)
            try first.append(1)
            try second.append(2)
            try first.join(second)
            try first.append(3)
            try second.append(4)
            #expect(try first.count == 3)
            #expect(try second.count == 2)
        }
    }
}
