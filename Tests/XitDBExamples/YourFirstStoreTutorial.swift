import Testing
import XitDBStore

@Suite("Tutorial: Your first store") struct YourFirstStoreTutorial {
    @Test @MainActor func theWholeProgramTwice() async throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }

        func run() async throws -> (moments: Int, earlier: Int, seen: Int) {
            let storage = try BufferedFileStorage(path: scratch.path("people.db"), access: .create)
            let database =
                try storage.length == 0
                ? Database(creating: storage, hashSize: 32, hashID: "sha2")
                : Database(opening: storage, hashSize: 32)
            let store = try Store(database, hashing: SHA256.self)

            struct Person: Codable {
                var name: String
                var age: Int
            }

            try store.transaction { moment in
                try moment["people"]["alice"].set(encoding: Person(name: "Alice", age: 25))
            }

            let alice = try store.latest["people"]["alice"].value(decoding: Person.self)!
            print(alice.name, alice.age)  // Alice 25

            try store.transaction { moment in
                try moment["people"]["alice"]["age"].set(Int64(26))
            }

            let earlier = try store.moment(at: -2)
            let then = try earlier["people"]["alice"].value(decoding: Person.self)!
            print(then.age)  // 25

            let snapshot = try store.snapshot()
            let reader = Task.detached { [snapshot] in
                let reading = SnapshotDatabase(snapshot)
                let moment = try Moment(reading: reading, hashing: SHA256.self)
                return try moment["people"]["alice"].value(decoding: Person.self)
            }

            try store.transaction { moment in
                try moment["people"]["alice"]["age"].set(Int64(27))
            }
            let seen = try await reader.value!
            print(seen.age)  // 26, whatever the writer did meanwhile

            print("moments:", try store.momentCount)  // 3, then 6 if you run it again
            return (try store.momentCount, then.age, seen.age)
        }

        // The first run creates the file, and the second opens it and adds to it.
        let first = try await run()
        #expect(first.moments == 3)
        #expect(first.earlier == 25)
        #expect(first.seen == 26)
        let second = try await run()
        #expect(second.moments == 6)
        #expect(second.seen == 26)
    }
}
