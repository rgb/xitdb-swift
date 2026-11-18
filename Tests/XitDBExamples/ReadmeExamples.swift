import Testing
import XitDB
import XitDBHashing

@Suite("README") struct ReadmeExamples {
    @Test func quickExample() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }

        // Open the file, and create the database in it if it is new. The database
        // is given the hash its keys are hashed with.
        let storage = try BufferedFileStorage(path: scratch.path("main.db"), access: .create)
        let database =
            try storage.length == 0
            ? Database(creating: storage, hashing: SHA256.self, hashID: "sha2")
            : Database(opening: storage, hashing: SHA256.self)

        // The root is a list with one element for each transaction, so that
        // every earlier state of the database stays readable: the history.
        // On a new database, making it is a small transaction of its own.
        let history = try ArrayList<ReadWrite>(database.rootCursor)

        // A transaction. The new element starts as the last one, and the body
        // changes it. If the body throws, the database is as it was.
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)

            // A put hashes the key and stores the value under the hash.
            try moment.put("foo", forKey: "foo")
            try moment.put("bar", forKey: "bar")

            let fruits = try ArrayList<ReadWrite>(moment.putCursor(forKey: "fruits"))
            try fruits.append("apple")
            try fruits.append("pear")
            try fruits.append("grape")

            let people = try ArrayList<ReadWrite>(moment.putCursor(forKey: "people"))

            let alice = try HashMap<ReadWrite>(people.appendCursor())
            try alice.put("Alice", forKey: "name")
            try alice.put(UInt64(25), forKey: "age")

            let bob = try HashMap<ReadWrite>(people.appendCursor())
            try bob.put("Bob", forKey: "name")
            try bob.put(UInt64(42), forKey: "age")
        }

        // The latest moment: -1 is the last element of a list.
        let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)

        // A read names the type it reads, and gives nil where there is no value.
        let foo = try moment.value(forKey: "foo", as: String.self)
        print(foo ?? "none")  // foo
        #expect(foo == "foo")

        let fruits = try ArrayList<ReadOnly>(moment.cursor(forKey: "fruits")!)
        let apple = try fruits.value(at: 0, as: String.self)
        print(apple ?? "none")  // apple
        #expect(apple == "apple")

        // The map holds the hash of "foo" and the value, and not the key.
        print(try moment.keyCursor(forKey: "foo") == nil)  // true
        #expect(try moment.keyCursor(forKey: "foo") == nil)
        #expect(try moment.value(forKey: "baz", as: String.self) == nil)

        // In the file each value is under the SHA-256 hash of its name, and the
        // names are not stored: the moment is the one the original's example
        // writes with hashInt and put, entry for entry.
        #expect(try moment.cursor(forHash: sha256("foo"))!.readBytes() == Array("foo".utf8))
        var names = 0
        var entries = try moment.iterator()
        while let entry = try entries.next() {
            #expect(try entry.readEntry().key.slot.isEmpty)
            names += 1
        }
        #expect(names == 4)

        // Every word of that, again from the file: what is committed survives
        // the storage it was written through. Only the hasher's size is
        // checked, and the hash ID is the label the creator wrote.
        let reopened = try ReadOnlyDatabase(opening: ReadOnlyFileStorage(path: scratch.path("main.db")))
        #expect(reopened.header.hashSize == 32)
        #expect(reopened.header.hashID == "sha2")
        let last = try HashMap<ReadOnly>(ArrayList<ReadOnly>(reopened.rootCursor).cursor(at: -1)!)
        let people = try ArrayList<ReadOnly>(last.cursor(forHash: sha256("people"))!)
        #expect(try people.count == 2)
        let bob = try HashMap<ReadOnly>(people.cursor(at: 1)!)
        #expect(try bob.cursor(forHash: sha256("age"))!.slot.tag == .uint)
        #expect(try bob.cursor(forHash: sha256("age"))!.readUInt64() == 42)
        #expect(throws: XitDBError.invalidHashSize) {
            try ReadOnlyDatabase(
                opening: ReadOnlyFileStorage(path: scratch.path("main.db")), hashing: Insecure.SHA1.self)
        }
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
                ? Database(creating: storage, hashing: SHA256.self, hashID: "sha2")
                : Database(opening: storage, hashing: SHA256.self)
            let history = try ArrayList<ReadWrite>(database.rootCursor)
            try history.append(.slot(try history.slot(at: -1))) { cursor in
                try HashMap<ReadWrite>(cursor).put(run, forKey: "run")
            }
            #expect(try history.count == run)
        }

        // And the first run's moment is still there after the second.
        let database = try ReadOnlyDatabase(opening: ReadOnlyFileStorage(path: path), hashing: SHA256.self)
        let history = try ArrayList<ReadOnly>(database.rootCursor)
        let first = try HashMap<ReadOnly>(history.cursor(at: 0)!)
        #expect(try first.value(forKey: "run", as: UInt64.self) == 1)
    }
}
