import Foundation
import Testing
import XitDBStore

// The examples of "Codable records", in XitDBStore's catalogue.

@Suite("Codable records") struct CodableRecordsExamples {
    private func makeStore() throws -> Store {
        try Store(try Database(creating: MemoryStorage(), hashSize: 32), hashing: SHA256.self)
    }

    struct Person: Codable, Equatable {
        var name: String
        var age: Int
        var roles: [String]
    }

    enum Shape: Codable {
        case circle(radius: Int64)
    }

    @Test func aRecordIsAMap() throws {
        let store = try makeStore()
        struct Person: Codable {
            var name: String
            var age: Int
            var roles: [String]
        }

        let alice = Person(name: "Alice", age: 25, roles: ["admin"])
        try store.transaction { moment in
            try moment["people"]["alice"].set(encoding: alice)
        }

        let read = try store.latest["people"]["alice"].value(decoding: Person.self)
        #expect(read?.name == "Alice" && read?.age == 25 && read?.roles == ["admin"])
        #expect(try store.latest["people"]["bob"].value(decoding: Person.self) == nil)

        // A field is an entry of its own, read without the rest of the record.
        let age = try store.latest["people"]["alice"]["age"].value(Int64.self)  // 25
        #expect(age == 25)
        #expect(try store.latest["people"]["alice"]["roles"].list(String.self)[0] == "admin")

        // Encoding replaces what was there, and nil leaves the place empty.
        try store.transaction { moment in
            try moment["people"]["alice"].set(encoding: Person(name: "Alice", age: 26, roles: []))
            #expect(try moment["people"]["alice"]["roles"].list(String.self).count == 0)
            #expect(try moment["people"]["alice"]["roles"].exists, "an empty array is an empty list")
            try moment["people"]["alice"].set(encoding: Person?.none)
            #expect(try !moment["people"]["alice"].exists)
            #expect(throws: XitDBError.unexpectedTag) { try moment.root.set(encoding: [1, 2]) }
        }
    }

    @Test func theStrategiesAreGivenToBothSides() throws {
        let store = try makeStore()
        struct Launch: Codable {
            var name: String
            var at: Date
        }

        let launch = Launch(name: "first", at: Date(timeIntervalSince1970: 0))
        try store.transaction { moment in
            try XitDBEncoder(dates: .deferred).encode(launch, at: moment["launch"])
        }

        let decoder = XitDBDecoder(dates: .deferred)
        let decoded = try decoder.decode(Launch.self, at: store.latest["launch"])
        #expect(decoded?.at == launch.at)
        #expect(try store.latest["launch"]["at"].value(Double.self) == -978_307_200)

        try store.transaction { moment in try moment["launch"].set(encoding: launch) }
        #expect(try store.latest["launch"]["at"].value(Double.self) == 0, "the default is seconds since 1970")
    }

    @Test func aMapWrittenByOtherMeansDecodesByTheKeysAskedFor() throws {
        let store = try makeStore()
        struct Point: Codable {
            var x: Int64
            var y: Int64
        }

        try store.transaction { moment in
            let origin = moment["origin"].map(String.self, Int64.self)
            try origin.put(0, forKey: "x")
            try origin.put(0, forKey: "y")
        }
        let origin = try store.latest["origin"].value(decoding: Point.self)
        #expect(origin?.x == 0 && origin?.y == 0)
        #expect(try store.latest["origin"].value(decoding: [String: Int64].self) == [:])
        #expect(throws: DecodingError.self) { try store.latest["origin"].value(decoding: Shape.self) }

        do {
            _ = try store.latest["origin"].value(decoding: Person.self)
        } catch DecodingError.keyNotFound(let key, _) {
            print("no entry for", key.stringValue)  // no entry for name
        }
        #expect {
            try store.latest["origin"].value(decoding: Person.self)
        } throws: { error in
            guard case DecodingError.keyNotFound(let key, _) = error else { return false }
            return key.stringValue == "name"
        }
    }

    @Test func wrongShapesAreDecodingErrors() throws {
        let store = try makeStore()
        try store.transaction { moment in
            try moment["list"].set(encoding: [UInt64(1)])
            try moment["big"].set(Int64(1000))
        }
        #expect {
            try store.latest["list"].value(decoding: Person.self)
        } throws: { error in
            guard case DecodingError.typeMismatch = error else { return false }
            return true
        }
        #expect {
            try store.latest["big"].value(decoding: Int8.self)
        } throws: { error in
            guard case DecodingError.dataCorrupted = error else { return false }
            return true
        }
    }
}
