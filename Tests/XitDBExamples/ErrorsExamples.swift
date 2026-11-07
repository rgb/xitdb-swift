import Testing
import XitDB

@Suite("Errors") struct ErrorsExamples {
    private func newDatabaseBytes() throws -> [UInt8] {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashSize: 32)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put(.bytes([UInt8](repeating: 7, count: 100)), forHash: sha256("value"))
        return storage.bytes
    }

    @Test func whatTheFileCanCause() throws {
        let good = try newDatabaseBytes()

        // Not a database.
        #expect(throws: XitDBError.invalidDatabase) {
            try Database(opening: MemoryStorage(bytes: Array(repeating: 0, count: 100)))
        }
        // Shorter than a header.
        #expect(throws: XitDBError.endOfStream) {
            try Database(opening: MemoryStorage(bytes: Array(good[..<10])))
        }
        // Cut short: it says it has more than it has.
        #expect(throws: XitDBError.truncatedDatabase) {
            try Database(opening: MemoryStorage(bytes: Array(good[..<(good.count - 1)])))
        }
        // Long enough for a header and too short for the root header after it.
        #expect(throws: XitDBError.endOfStream) {
            try Database(opening: MemoryStorage(bytes: Array(good[..<30])))
        }
        // A later version of the format.
        var newer = good
        newer[5] = 9
        #expect(throws: XitDBError.invalidVersion) {
            try Database(opening: MemoryStorage(bytes: newer))
        }
    }

    @Test func aDamagedFileIsAnErrorNotACrash() throws {
        // Every byte of a file overwritten in turn: whatever happens, it is
        // not a trap, and this test finishing says so.
        let good = try newDatabaseBytes()
        var opened = 0
        for position in good.indices {
            var damaged = good
            damaged[position] ^= 0xFF
            do {
                let database = try Database(opening: MemoryStorage(bytes: damaged))
                let map = try HashMap<ReadOnly>(database.rootCursor)
                _ = try map.cursor(forHash: sha256("value"))?.readBytes()
                opened += 1
            } catch {
                // An `XitDBError`, which this is typed to. Any error will do.
                continue
            }
        }
        #expect(opened < good.count)
    }

    @Test func aChangedByteInAValueIsNotNoticed() throws {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashSize: 32)
        let value = Array("a value long enough for a record".utf8)
        try HashMap<ReadWrite>(database.rootCursor).put(.bytes(value), forHash: sha256("value"))

        // Only the trailer that ends a commit is checksummed, so damage to the data
        // opens without complaint and reads back wrong.
        var bytes = storage.bytes
        let place = try #require(bytes.indices.first { bytes[$0...].starts(with: value) })
        bytes[place] ^= 0x01
        let damaged = try Database(opening: MemoryStorage(bytes: bytes))
        let read = try HashMap<ReadOnly>(damaged.rootCursor).cursor(forHash: sha256("value"))!.readBytes()
        #expect(read != value)
        #expect(read.count == value.count)
    }

    @Test func aFreezeOutsideATransaction() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        #expect(throws: XitDBError.expectedTxStart) {
            try database.freeze()
        }
        var root = database.rootCursor
        #expect(throws: XitDBError.expectedTxStart) {
            try root.freeze()
        }
    }

    @Test func aBadCursorInAProgram() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put(.uint(1), forHash: sha256("a"))
        #expect(throws: XitDBError.unexpectedTag) {
            try map.cursor(forHash: sha256("a"))!.readBytes()
        }
    }

    @Test func handlingTheCasesYouExpect() throws {
        // A program handles the few it expects, and lets the rest go up.
        func open(_ storage: any WritableStorage) throws -> Database? {
            do {
                return try Database(opening: storage)
            } catch XitDBError.invalidDatabase, XitDBError.truncatedDatabase, XitDBError.endOfStream {
                return nil
            }
        }
        #expect(try open(MemoryStorage()) == nil)
        #expect(try open(MemoryStorage(bytes: [1, 2, 3])) == nil)
        #expect(try open(MemoryStorage(bytes: try newDatabaseBytes())) != nil)
    }

    @Test func aFailureOfTheSystem() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }
        do {
            _ = try BufferedFileStorage(path: scratch.path("nothing-here.db"), access: .readOnly)
            Issue.record("opening should have failed")
        } catch {
            guard case .storageFailure(let number) = error else {
                Issue.record("expected storageFailure, got \(error)")
                return
            }
            #expect(number > 0)
        }
    }

    @Test func aWriteToAListYouClearedAfterMakingIt() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        try database.withTransaction { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            var slot = try moment.putCursor(forHash: sha256("list"))
            let list = try ArrayList<ReadWrite>(slot)
            try slot.write(.slot(nil))
            #expect(throws: XitDBError.keyNotFound) {
                try list.put(.uint(1), at: 0)
            }

            var other = try moment.putCursor(forHash: sha256("map"))
            let map = try HashMap<ReadWrite>(other)
            try other.write(.slot(nil))
            #expect(throws: XitDBError.keyNotFound) {
                try map.put(.uint(1), forHash: sha256("a"))
            }
        }
    }

    @Test func twoCallerErrorsCompareByDescription() {
        struct Failed: Error {}
        #expect(XitDBError.callerError(Failed()) == XitDBError.callerError(Failed()))
        #expect(XitDBError.storageFailure(errno: 2) != XitDBError.storageFailure(errno: 3))
    }

    @Test func typedThrowsWhereThereIsNoClosure() throws {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)

        // A method with no closure throws only `XitDBError`, so the error is typed.
        do {
            _ = try database.committedSize
            try database.freeze()
        } catch {
            let typed: XitDBError = error
            #expect(typed == .expectedTxStart)
        }

        // A method that runs your closure throws what the closure does as well.
        struct Mine: Error {}
        #expect(throws: Mine.self) {
            try database.withTransaction { _ in throw Mine() }
        }
    }
}
