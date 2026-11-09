import Foundation
import Testing
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
        // the container boundaries: a scalar or a list where a record is
        // expected, a record or a scalar where a list is expected
        #expect(throws: DecodingError.self) { try latest["n"].value(decoding: Address.self) }
        #expect(throws: DecodingError.self) { try latest["s"].value(decoding: [Int].self) }
        #expect(throws: DecodingError.self) { try latest["partial"].value(decoding: [String].self) }
        try store.transaction { moment in
            try moment["list"].list(UInt64.self).append(1)
            try moment["nested"].set(encoding: ["inner": 1])
            try moment["plain"]["inner"].set(UInt64(1))
        }
        #expect(throws: DecodingError.self) { try store.latest["list"].value(decoding: Address.self) }
        #expect(throws: DecodingError.self) { try store.latest["list"].value(decoding: [String: Int].self) }
        #expect(throws: DecodingError.self) { try store.latest["nested"].value(decoding: [String: [Int]].self) }
        #expect(throws: DecodingError.self) { try store.latest["nested"].value(decoding: [String: Address].self) }
        // a map written by handles stores no key names: a dictionary sees no keys
        #expect(try store.latest["plain"].value(decoding: [String: Int].self) == [:])
    }

    /// Encoding replaces, as `set` does: entries the new value does not
    /// write are gone, arrays do not grow, an optional set to nil is nil,
    /// and an enum changes case.
    @Test func encodingAtAPlaceReplacesWhatWasThere() throws {
        let store = try makeStore()
        try store.transaction { moment in
            try moment["a"].set(encoding: Address(street: "Lane", number: 1))
            try moment["a"]["extra"].set("kept?")
            try moment["a"].set(encoding: Address(street: "Road", number: 2))
            #expect(try moment["a"].value(decoding: Address.self) == Address(street: "Road", number: 2))
            #expect(try !moment["a"]["extra"].exists)
            try moment["l"].set(encoding: [1, 2, 3])
            try moment["l"].set(encoding: [4])
            #expect(try moment["l"].value(decoding: [Int].self) == [4])
            try moment["o"].set(encoding: Optional(5))
            try moment["o"].set(encoding: Int?.none)
            #expect(try !moment["o"].exists)
            #expect(try moment["o"].value(decoding: Int?.self) == nil)
            try moment["e"].set(encoding: Event.renamed(from: "a", to: "b"))
            try moment["e"].set(encoding: Event.deleted)
            #expect(try moment["e"].value(decoding: Event.self) == .deleted)
            try moment["e"].set(encoding: Event.created(at: 2))
            #expect(try moment["e"].value(decoding: Event.self) == .created(at: 2))
            // a scalar over a record, and a record over a scalar
            try moment["a"].set(encoding: 7)
            #expect(try moment["a"].value(decoding: Int.self) == 7)
            try moment["a"].set(encoding: Address(street: "Way", number: 3))
            #expect(try moment["a"].value(decoding: Address.self) == Address(street: "Way", number: 3))
        }
    }

    struct Nothing: Codable, Equatable {}

    struct Empties: Codable, Equatable {
        var strings: [String]
        var numbers: [Int: Int]
        var bytes: [UInt8]
        var data: Data
        var nothing: Nothing
        var set: Set<Int>
        var events: [Event]
        var nested: [[String]]
        var optionals: [String: Int?]
    }

    /// An empty collection is written and comes back empty: the containers
    /// make their map or list when they are made, and a byte array is told
    /// from an empty array of anything else by its type.
    @Test func emptyCollectionsComeBackEmpty() throws {
        let store = try makeStore()
        let empties = Empties(
            strings: [], numbers: [:], bytes: [], data: Data(), nothing: Nothing(), set: [], events: [], nested: [[]],
            optionals: ["none": nil, "some": 1])
        try store.transaction { moment in
            try moment["e"].set(encoding: empties)
            #expect(try moment["e"].value(decoding: Empties.self) == empties)
            #expect(
                try !moment["e"]["optionals"]["none"].exists, "a nil in a dictionary is an entry with nothing in it")
            #expect(try moment["e"]["optionals"]["some"].value(Int64.self) == 1)
            #expect(try moment["e"]["strings"].exists)
            #expect(try moment["e"]["strings"].list(String.self).count == 0)
            #expect(try moment["e"]["numbers"].exists)
            #expect(try moment["e"]["bytes"].value([UInt8].self) == [])
            #expect(try moment["e"]["data"].value([UInt8].self) == [])
            #expect(try moment["e"]["nothing"].exists)
            #expect(try moment["e"]["nested"][index: 0].list(String.self).count == 0)
            try moment["top"].set(encoding: [String]())
            #expect(try moment["top"].exists)
            #expect(try moment["top"].value(decoding: [String].self) == [])
            try moment["dict"].set(encoding: [String: Int]())
            #expect(try moment["dict"].value(decoding: [String: Int].self) == [:])
            try moment["none"].set(encoding: Nothing())
            #expect(try moment["none"].value(decoding: Nothing.self) == Nothing())
        }
        #expect(try store.latest["e"].value(decoding: Empties.self) == empties)
        #expect(try store.latest["top"].value(decoding: [String].self) == [])
    }

    /// A record at the moment's root; a list or a scalar there is refused.
    @Test func encodingAtTheRoot() throws {
        let store = try makeStore()
        try store.transaction { moment in
            try moment["other"].set(UInt64(1))
            try moment.root.set(encoding: Address(street: "Lane", number: 1))
            #expect(try moment.root.value(decoding: Address.self) == Address(street: "Lane", number: 1))
            #expect(try !moment["other"].exists, "encoding at the root replaces the moment")
        }
        #expect(try store.latest.root.value(decoding: Address.self) == Address(street: "Lane", number: 1))
        #expect(throws: (any Error).self) {
            try store.transaction { moment in
                try moment.root.set(encoding: [1, 2])
            }
        }
        #expect(throws: (any Error).self) {
            try store.transaction { moment in
                try moment.root.set(encoding: 7)
            }
        }
        #expect(try store.latest.root.value(decoding: Address.self) == Address(street: "Lane", number: 1))
        // after a join in the same transaction, the root still takes a record
        try store.transaction { moment in
            try moment["la"].linkedList(UInt64.self).append(1)
            try moment["lb"].linkedList(UInt64.self).append(2)
            try moment["la"].linkedList(UInt64.self).join(moment["lb"].linkedList(UInt64.self))
            try moment.root.set(encoding: Address(street: "After", number: 4))
            #expect(try moment.root.value(decoding: Address.self) == Address(street: "After", number: 4))
            #expect(try !moment["la"].exists)
        }
        #expect(try store.latest.root.value(decoding: Address.self) == Address(street: "After", number: 4))
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
