import Testing
import XitDB
import XitDBHashing

@Suite("README") struct ReadmeExamples {
    @Test func quickExample() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }

        // XitDB never hashes anything itself: the caller hashes each key.
        func sha256(_ key: String) -> SHA256Digest {
            SHA256.hash(data: Array(key.utf8))
        }

        // Open the file, and create the database in it if it is new.
        let storage = try BufferedFileStorage(path: scratch.path("main.db"), access: .create)
        let database =
            try storage.length == 0
            ? Database(creating: storage, hashSize: 32, hashID: "sha2")
            : Database(opening: storage, hashSize: 32)

        // The root is a list with one element for each transaction, so that
        // every earlier state of the database stays readable: the history.
        // On a new database, making it is a small transaction of its own.
        let history = try ArrayList<ReadWrite>(database.rootCursor)

        // A transaction. The new element starts as the last one, and the body
        // changes it. If the body throws, the database is as it was.
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)

            try moment.put(.bytes(Array("foo".utf8)), forHash: sha256("foo"))
            try moment.put(.bytes(Array("bar".utf8)), forHash: sha256("bar"))

            let fruits = try ArrayList<ReadWrite>(moment.putCursor(forHash: sha256("fruits")))
            try fruits.append(.bytes(Array("apple".utf8)))
            try fruits.append(.bytes(Array("pear".utf8)))
            try fruits.append(.bytes(Array("grape".utf8)))

            let people = try ArrayList<ReadWrite>(moment.putCursor(forHash: sha256("people")))

            let alice = try HashMap<ReadWrite>(people.appendCursor())
            try alice.put(.bytes(Array("Alice".utf8)), forHash: sha256("name"))
            try alice.put(.uint(25), forHash: sha256("age"))

            let bob = try HashMap<ReadWrite>(people.appendCursor())
            try bob.put(.bytes(Array("Bob".utf8)), forHash: sha256("name"))
            try bob.put(.uint(42), forHash: sha256("age"))
        }

        // The latest moment: -1 is the last element of a list.
        let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)

        let foo = try moment.cursor(forHash: sha256("foo"))!.readBytes()
        print(String(decoding: foo, as: UTF8.self))  // foo
        #expect(foo == Array("foo".utf8))

        let fruits = try ArrayList<ReadOnly>(moment.cursor(forHash: sha256("fruits"))!)
        let apple = try fruits.cursor(at: 0)!.readBytes()
        print(String(decoding: apple, as: UTF8.self))  // apple
        #expect(apple == Array("apple".utf8))

        // Every word of that, again from the file: what is committed survives
        // the storage it was written through.
        let reopened = try Database(opening: BufferedFileStorage(path: scratch.path("main.db"), access: .readOnly))
        #expect(reopened.header.hashSize == 32)
        #expect(reopened.header.hashID == "sha2")
        let last = try HashMap<ReadOnly>(ArrayList<ReadOnly>(reopened.rootCursor).cursor(at: -1)!)
        let people = try ArrayList<ReadOnly>(last.cursor(forHash: sha256("people"))!)
        #expect(try people.count == 2)
        let bob = try HashMap<ReadOnly>(people.cursor(at: 1)!)
        #expect(try bob.cursor(forHash: sha256("age"))!.readUInt64() == 42)
    }

    @Test func openingAgainFindsTheMoments() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }
        let path = scratch.path("main.db")

        // The same code, run twice against one file, creates and then opens.
        for run in 1...2 as ClosedRange<UInt64> {
            let storage = try BufferedFileStorage(path: path, access: .create)
            let database =
                try storage.length == 0
                ? Database(creating: storage, hashSize: 32, hashID: "sha2")
                : Database(opening: storage, hashSize: 32)
            let history = try ArrayList<ReadWrite>(database.rootCursor)
            try history.append(.slot(try history.slot(at: -1))) { cursor in
                try HashMap<ReadWrite>(cursor).put(.uint(run), forHash: sha256("run"))
            }
            #expect(try history.count == run)
        }

        // And the first run's moment is still there after the second.
        let database = try Database(opening: BufferedFileStorage(path: path, access: .readOnly))
        let history = try ArrayList<ReadOnly>(database.rootCursor)
        let first = try HashMap<ReadOnly>(history.cursor(at: 0)!)
        #expect(try first.cursor(forHash: sha256("run"))!.readUInt64() == 1)
    }
}
