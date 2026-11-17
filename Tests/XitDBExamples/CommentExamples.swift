// The code of the fenced blocks in the libraries' documentation comments.
//
// This file is the package's. DocumentedCodeTests holds every fenced `swift`
// block in a `///` comment of Sources/XitDB and Sources/XitDBHashing to code
// in this target, line for line, as it holds the articles' blocks to theirs.
// The rule: a fenced block written or changed in a library comment needs its
// code here, in the same commit, compiled and run, with `#expect` lines that
// pin what it does. A block that becomes word for word an article's block is
// covered by that article's test, and its copy leaves this file.
//
// Each block is here as its comment has it. A type a block declares is
// private to this file, so that an article may declare one of the same name;
// the check ignores the `private`.

import Testing
import XitDB
import XitDBHashing

// StorableValue's comment: a record of your own.
private struct Person {
    var name: String
    var age: UInt64
}

extension Person: StorableValue {
    init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        let fields = try HashMap<ReadOnly>(cursor)
        guard let name = try fields.value(forKey: "name", as: String.self),
            let age = try fields.value(forKey: "age", as: UInt64.self)
        else { throw .keyNotFound }
        self.init(name: name, age: age)
    }

    func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.slot(nil))
        let fields = try HashMap<ReadWrite>(cursor)
        try fields.put(name, forKey: "name")
        try fields.put(age, forKey: "age")
    }
}

// KeyHashing's comment: a hasher of your own.
private enum ByteSum: KeyHashing {
    static let size = 1

    static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
        var sum: UInt8 = 0
        for index in bytes.indices { sum &+= bytes[index] }
        output.append(sum)
    }
}

@Suite("The libraries' comments") struct CommentExamples {
    /// `StorableValue`: the record goes into a list and comes back, as a map
    /// of its two fields, and takes the place of what was in its slot.
    @Test func aRecordOfYourOwn() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let people = try ArrayList<ReadWrite>(moment.putCursor(forKey: "people"))

            try people.append(Person(name: "Alice", age: 25))
            let first = try people.value(at: 0, as: Person.self)
            #expect(first?.name == "Alice")
            #expect(first?.age == 25)

            let fields = try HashMap<ReadOnly>(people.cursor(at: 0)!)
            #expect(try fields.value(forKey: "age", as: UInt64.self) == 25)
            #expect(try fields.keyCursor(forKey: "name") == nil)

            try people.put(UInt64(7), at: 0)
            try people.put(Person(name: "Bob", age: 42), at: 0)
            #expect(try people.value(at: 0, as: Person.self)?.name == "Bob")
        }
    }

    /// `KeyRepresentable`: an enum of field names is a key, the key its raw
    /// value is.
    @Test func anEnumOfFieldNames() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let person = try HashMap<ReadWrite>(database.rootCursor)

        enum Field: String, KeyRepresentable {
            case name, age
        }
        try person.put(.uint(25), forKey: Field.age)

        #expect(try person.value(forKey: "age", as: UInt64.self) == 25)
        #expect(try person.value(forKey: Field.age, as: UInt64.self) == 25)
        #expect(try person.cursor(forKey: Field.name) == nil)
    }

    /// `Database.init(opening:hashing:)`: the hasher chosen by the header's
    /// hash size, while the program runs.
    @Test func aHasherChosenByTheHeader() throws {
        for (hashing, size) in [(Insecure.SHA1.self, 20), (SHA256.self, 32)] as [(any KeyHashing.Type, UInt16)] {
            let storage = MemoryStorage()
            let created = try Database(creating: storage, hashing: hashing)
            try HashMap<ReadWrite>(created.rootCursor).put("Alice", forKey: "alice")

            let header = try DatabaseHeader(reading: storage)
            let hashing: any KeyHashing.Type = header.hashSize == 20 ? Insecure.SHA1.self : SHA256.self
            let database = try Database(opening: storage, hashing: hashing)
            #expect(header.hashSize == size)
            #expect(try HashMap<ReadOnly>(database.rootCursor).value(forKey: "alice", as: String.self) == "Alice")
        }
    }

    /// `KeyHashing`: the hasher that adds the bytes up is a hasher. A
    /// database made with it has its size, and two keys with one sum are
    /// one key to a map.
    @Test func aHasherOfYourOwn() throws {
        let database = try Database(creating: MemoryStorage(), hashing: ByteSum.self)
        #expect(database.header.hashSize == 1)
        #expect(ByteSum.keyHash(of: "ab") == [195])
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put(UInt64(1), forKey: "ab")
        #expect(try map.value(forKey: "ba", as: UInt64.self) == 1)
        #expect(try map.value(forKey: "bb", as: UInt64.self) == nil)
    }

    /// `KeyHashing.keyHash(of:)`: the hash of a key by hand names the entry
    /// that the keyed call reads.
    @Test func theHashOfAKeyByHand() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { cursor in
            let ages = try HashMap<ReadWrite>(cursor)

            let hash = SHA256.keyHash(of: "alice")
            try ages.put(.uint(25), forHash: hash)
            let age = try ages.value(forKey: "alice", as: UInt64.self)
            #expect(age == 25)
            #expect(hash.count == 32)
        }
    }

    /// `XitDBError.carrying(_:)`: a function that declares the library's
    /// error makes a transaction inside the adapter, with no error spelled
    /// on a closure, and is given the library's own error as itself.
    @Test func aTransactionWhereTheLibrarysErrorIsDeclared() throws {
        func addVisit(to database: Database) throws(XitDBError) {
            try XitDBError.carrying {
                try database.withTransaction { root in
                    let map = try HashMap(root)
                    let visits = try map.value(forKey: "visits", as: UInt64.self) ?? 0
                    try map.put(visits + 1, forKey: "visits")
                }
            }
        }

        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try addVisit(to: database)
        try addVisit(to: database)
        #expect(try HashMap(database.rootCursor.readOnly).value(forKey: "visits", as: UInt64.self) == 2)

        // A database with no hasher cannot hash the key: the library's
        // error, as itself and not carried.
        let unhashed = try Database(creating: MemoryStorage(), hashSize: 32)
        #expect(throws: XitDBError.noKeyHashing) { try addVisit(to: unhashed) }
    }
}
