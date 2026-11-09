import Foundation
import Testing
import XitDB
import XitDBHashing
import XitDBStore

/// Codable onto maps and lists: a grammar of types goes in and comes back
/// equal, and the layout is the one the documentation promises.
@Suite("Codable")
struct CodableTests {
    struct Address: Codable, Equatable {
        var street: String
        var number: Int
    }

    enum Role: String, Codable, Equatable {
        case admin, guest
    }

    enum Event: Codable, Equatable {
        case created(at: Double)
        case renamed(from: String, to: String)
        case deleted
    }

    struct Person: Codable, Equatable {
        var name: String
        var age: UInt8
        var height: Double
        var active: Bool
        var nickname: String?
        var address: Address
        var roles: [Role]
        var scores: [Int]
        var tags: [String: UInt64]
        var byID: [Int: String]
        var events: [Event]
        var raw: [UInt8]
        var pet: Address?
        var balance: Int64
        var big: UInt64
        var small: Int8
        var ratio: Float
    }

    static let sample = Person(
        name: "Ada", age: 36, height: 1.68, active: true, nickname: nil,
        address: Address(street: "Lane", number: 12), roles: [.admin, .guest], scores: [3, -1, 0],
        tags: ["x": 1, "y": 2], byID: [1: "one", -2: "minus two"],
        events: [.created(at: 1.5), .renamed(from: "a", to: "b"), .deleted],
        raw: [0, 255, 7], pet: nil, balance: -9_000_000_000, big: .max, small: -128, ratio: 0.25)

    private func makeStore() throws -> Store {
        try Store(try Database(creating: MemoryStorage(), hashSize: 32), hashing: SHA256.self)
    }

    @Test func aRecordRoundTrips() throws {
        let store = try makeStore()
        try store.transaction { moment in
            try moment["ada"].set(encoding: Self.sample)
            #expect(try moment["ada"].value(decoding: Person.self) == Self.sample)
        }
        let latest = try store.latest
        #expect(try latest["ada"].value(decoding: Person.self) == Self.sample)
        #expect(try latest["nobody"].value(decoding: Person.self) == nil)
    }

    /// The layout is the documented one: a keyed container is a map keyed by
    /// the names, an unkeyed one a list, the scalars the format's own, and a
    /// nil optional leaves no entry.
    @Test func theLayoutIsMapsAndLists() throws {
        let store = try makeStore()
        try store.transaction { moment in
            try moment["ada"].set(encoding: Self.sample)
            let ada = moment["ada"]
            #expect(try ada["name"].value(String.self) == "Ada")
            #expect(try ada["age"].value(UInt64.self) == 36, "unsigned integers are the format's uint")
            #expect(try ada["balance"].value(Int64.self) == -9_000_000_000)
            #expect(try ada["active"].value(UInt64.self) == 1, "a Bool is a uint")
            #expect(try !ada["nickname"].exists, "a nil optional leaves no entry")
            #expect(try ada["address"]["number"].value(Int64.self) == 12)
            let roles = ada["roles"].list(String.self)
            #expect(try roles.count == 2)
            #expect(try roles[0] == "admin")
            #expect(try ada["scores"].list(Int64.self)[1] == -1)
            #expect(try ada["tags"]["y"].value(UInt64.self) == 2, "a dictionary with string keys is a map")
            #expect(try ada["byID"]["-2"].value(String.self) == "minus two", "integer keys go by their names")
            #expect(try ada["events"][index: 1]["renamed"]["to"].value(String.self) == "b")
            #expect(try ada["raw"].value([UInt8].self) == [0, 255, 7], "a byte array is a byte array")
        }
        // the entries store their names, read through the faithful layer
        let moment = try HashMap<ReadOnly>(
            try #require(try ArrayList<ReadOnly>(store.database.rootCursor).cursor(at: 0)))
        let ada = try HashMap<ReadOnly>(try #require(try moment.cursor(forHash: SHA256.hash(Array("ada".utf8)))))
        let entry = try #require(try ada.entry(forHash: SHA256.hash(Array("name".utf8))))
        #expect(try entry.key.readBytes() == Array("name".utf8))
    }

    @Test func wrongShapesFailAsDecodingErrors() throws {
        let store = try makeStore()
        try store.transaction { moment in
            try moment["n"].set(UInt64(300))
            try moment["s"].set("text")
            try moment["partial"]["street"].set("Lane")
        }
        let latest = try store.latest
        #expect(throws: DecodingError.self) { try latest["n"].value(decoding: UInt8.self) }
        #expect(throws: DecodingError.self) { try latest["s"].value(decoding: Int.self) }
        #expect(throws: DecodingError.self) { try latest["partial"].value(decoding: Address.self) }
        #expect(try latest["n"].value(decoding: UInt64.self) == 300)
        #expect(try latest["n"].value(decoding: UInt16.self) == 300)
    }

    @Test func encodingOverAPlaceLeavesWhatItDoesNotWrite() throws {
        let store = try makeStore()
        try store.transaction { moment in
            try moment["a"].set(encoding: Address(street: "Lane", number: 1))
            try moment["a"]["extra"].set("kept")
            try moment["a"].set(encoding: Address(street: "Road", number: 2))
            #expect(try moment["a"].value(decoding: Address.self) == Address(street: "Road", number: 2))
            #expect(try moment["a"]["extra"].value(String.self) == "kept")
            try moment["a"].clear()
            try moment["a"].set(encoding: Address(street: "Way", number: 3))
            #expect(try !moment["a"]["extra"].exists)
        }
    }

    @Test func topLevelScalarsAndLists() throws {
        let store = try makeStore()
        try store.transaction { moment in
            try moment["count"].set(encoding: 7)
            try moment["names"].set(encoding: ["a", "b"])
            try moment["flags"].set(encoding: [true, false])
            try moment["maybe"].set(encoding: Optional<Int>.none)
            #expect(try moment["count"].value(decoding: Int.self) == 7)
            #expect(try moment["names"].value(decoding: [String].self) == ["a", "b"])
            #expect(try moment["flags"].value(decoding: [Bool].self) == [true, false])
            #expect(try !moment["maybe"].exists)
            #expect(try moment["maybe"].value(decoding: Int?.self) == nil)
        }
    }

    struct Attachment: Codable, Equatable {
        var when: Date
        var payload: Data
        var link: URL
    }

    @Test func theFoundationTypesHaveTheirOwnForms() throws {
        let store = try makeStore()
        let value = Attachment(
            when: Date(timeIntervalSince1970: 1_700_000_000.5), payload: Data([1, 2, 3]),
            link: URL(string: "https://example.com/a?b=c")!)
        try store.transaction { moment in
            try moment["a"].set(encoding: value)
            #expect(try moment["a"].value(decoding: Attachment.self) == value)
            #expect(try moment["a"]["when"].value(Double.self) == 1_700_000_000.5, "seconds since 1970")
            #expect(try moment["a"]["payload"].value([UInt8].self) == [1, 2, 3], "the bytes")
            #expect(try moment["a"]["link"].value(String.self) == "https://example.com/a?b=c", "the string")

            let deferring = XitDBEncoder(dates: .deferred, data: .deferred, urls: .deferred)
            try deferring.encode(value, at: moment["b"])
            let back = try XitDBDecoder(dates: .deferred, data: .deferred, urls: .deferred).decode(
                Attachment.self, at: moment["b"])
            #expect(back == value)
            #expect(
                try moment["b"]["when"].value(Double.self) == value.when.timeIntervalSinceReferenceDate,
                "Date's own form")
            #expect(try moment["b"]["payload"].list(UInt64.self).count == 3, "Data's own form, a list")
            #expect(throws: DecodingError.self) { try moment["b"].value(decoding: Attachment.self) }
        }
    }
}
