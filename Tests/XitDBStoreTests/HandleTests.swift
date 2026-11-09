import Testing
import XitDBStore

/// Handles: a path from the root, values at a place, and the place rather
/// than the thing.
@Suite("handles")
struct HandleTests {
    private func makeStore() throws -> Store {
        try Store(try Database(creating: MemoryStorage(), hashSize: 32), hashing: SHA256.self)
    }

    @Test func valuesAtAPlace() throws {
        let store = try makeStore()
        try store.transaction { moment in
            let place = moment["config"]["retries"]
            #expect(try !place.exists)
            #expect(try place.value(UInt64.self) == nil)
            try place.set(UInt64(3))
            #expect(try place.exists)
            #expect(try place.value(UInt64.self) == 3)
            try place.set("three")
            #expect(try place.value(String.self) == "three")
            #expect(throws: XitDBError.unexpectedTag) { try place.value(UInt64.self) }
            try place.clear()
            #expect(try !place.exists)
            #expect(try place.value(String.self) == nil)
            #expect(try moment["config"].exists, "the map on the way stays")
        }
        let latest = try store.latest
        #expect(try !latest["config"]["retries"].exists)
        #expect(try latest["nothing"]["here"].value(UInt64.self) == nil, "a missing map on the way is nothing")
    }

    @Test func descendingByIndex() throws {
        let store = try makeStore()
        try store.transaction { moment in
            let list = moment["items"].list(String.self)
            try list.append("a")
            try list.append("b")
            #expect(try moment["items"][index: 0].value(String.self) == "a")
            #expect(try moment["items"][index: -1].value(String.self) == "b")
            #expect(try moment["items"][index: 5].value(String.self) == nil)
            try moment["items"][index: 1].set("B")
            #expect(try list[1] == "B")
            #expect(throws: XitDBError.indexOutOfRange) { try moment["items"][index: 7].set("x") }
        }
    }

    /// A handle names the place: after the thing there is replaced, the
    /// handle sees the new thing, and a handle made before the write is
    /// never stale.
    @Test func aHandleNamesThePlace() throws {
        let store = try makeStore()
        try store.transaction { moment in
            let place = moment["list"]
            let list = place.list(UInt64.self)
            try list.append(1)
            let early = moment["list"][index: 0]
            #expect(try early.value(UInt64.self) == 1)
            try place.clear()
            #expect(try !early.exists)
            try list.append(9)
            #expect(try early.value(UInt64.self) == 9, "the place has a new list; the handle sees it")
        }
    }

    /// Writes to a handle's map through another handle to the same map are
    /// seen at once: nothing cached goes stale in a writable moment.
    @Test func twoHandlesToOnePlaceAgree() throws {
        let store = try makeStore()
        try store.transaction { moment in
            let a = moment["m"].map(String.self, UInt64.self)
            let b = moment["m"].map(String.self, UInt64.self)
            for index in 0..<200 {
                try a.put(UInt64(index), forKey: "k\(index)")
                #expect(try b["k\(index)"] == UInt64(index))
            }
            #expect(try b["k0"] == 0, "the first entry survived the splits that later puts caused")
        }
    }

    @Test func aHandleKeptPastTheTransactionIsStale() throws {
        let store = try makeStore()
        var kept: Handle?
        try store.transaction { moment in
            try moment["a"].set(UInt64(1))
            kept = moment["a"]
        }
        let handle = try #require(kept)
        #expect(throws: XitDBError.expectedTxStart) { try handle.set(UInt64(2)) }
        try store.transaction { _ in
            #expect(throws: XitDBError.staleCursor) { try handle.set(UInt64(2)) }
        }
        #expect(try store.latest["a"].value(UInt64.self) == 1)
    }

    /// In a read-only moment the handle keeps its cursor; a later commit
    /// does not change what the moment shows, and the handle still answers.
    @Test func aReadOnlyHandleKeepsItsView() throws {
        let store = try makeStore()
        try store.transaction { moment in try moment["a"].set(UInt64(1)) }
        let first = try store.latest["a"]
        #expect(try first.value(UInt64.self) == 1)
        try store.transaction { moment in try moment["a"].set(UInt64(2)) }
        #expect(try first.value(UInt64.self) == 1)
        #expect(try first.value(UInt64.self) == 1, "a second read, through the cache or not, says the same")
        #expect(try store.latest["a"].value(UInt64.self) == 2)
    }
}
