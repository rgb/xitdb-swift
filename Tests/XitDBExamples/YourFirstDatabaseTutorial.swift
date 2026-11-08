import CryptoKit
import Testing
import XitDB

@Suite("Tutorial: Your first database") struct YourFirstDatabaseTutorial {
    @Test func theWholeProgramTwice() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }

        func run() throws -> (moments: UInt64, name: [UInt8]) {
            func sha256(_ key: String) -> SHA256Digest {
                SHA256.hash(data: Array(key.utf8))
            }

            let storage = try BufferedFileStorage(path: scratch.path("people.db"), access: .create)
            let database =
                try storage.length == 0
                ? Database(creating: storage, hashSize: 32, hashID: "sha2")
                : Database(opening: storage, hashSize: 32)

            let history = try ArrayList<ReadWrite>(database.rootCursor)

            try history.append(.slot(try history.slot(at: -1))) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                try moment.put(.bytes(Array("Alice".utf8)), forHash: sha256("name"))
                try moment.put(.uint(25), forHash: sha256("age"))
            }

            let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)
            let name = try moment.cursor(forHash: sha256("name"))!.readBytes()
            let age = try moment.cursor(forHash: sha256("age"))!.readUInt64()
            print(String(decoding: name, as: UTF8.self), age)  // Alice 25

            print("moments:", try history.count)  // 1, then 2 if you run it again

            struct NotToday: Error {}

            do {
                try history.append(.slot(try history.slot(at: -1))) { cursor in
                    let moment = try HashMap<ReadWrite>(cursor)
                    try moment.put(.uint(99), forHash: sha256("age"))
                    throw NotToday()
                }
            } catch is NotToday {
                print("moments:", try history.count)  // the same as before
            }
            return (try history.count, name)
        }

        // The first run creates the file, and the second opens it and adds to it.
        let first = try run()
        #expect(first.moments == 1)
        #expect(first.name == Array("Alice".utf8))
        let second = try run()
        #expect(second.moments == 2)
    }
}
