import Foundation
import Testing
import XitDB

@Suite("Compaction") struct CompactionExamples {
    private func newHistory(moments: Int) throws -> Database {
        let database = try Database(creating: MemoryStorage(), hashSize: 32)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        for number in 0..<moments {
            try history.append(.slot(try history.slot(at: -1))) { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                try moment.put(.uint(UInt64(number)), forHash: sha256("latest"))
                try moment.put(.uint(UInt64(number)), forHash: sha256("key \(number % 100)"))
            }
        }
        return database
    }

    @Test func compactingIntoANewFile() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }
        let database = try newHistory(moments: 3)

        // A new file, for the compacted database.
        let target = try BufferedFileStorage(path: scratch.path("compact.db"), access: .truncate)

        // Where the copy remembers what went where.
        var offsets = MemoryOffsetMap()

        let compacted = try database.compact(into: target, offsetMap: &offsets)

        // The history is one moment long, and it is the latest.
        let history = try ArrayList<ReadOnly>(compacted.rootCursor)
        #expect(try history.count == 1)
        let moment = try HashMap<ReadOnly>(history.cursor(at: 0)!)
        #expect(try moment.cursor(forHash: sha256("latest"))!.readUInt64() == 2)
    }

    /// The numbers the article quotes.
    @Test func whatItSaves() throws {
        let database = try newHistory(moments: 1000)
        let target = MemoryStorage()
        var offsets = MemoryOffsetMap()
        let compacted = try database.compact(into: target, offsetMap: &offsets)
        let before = try database.committedSize
        let after = try compacted.committedSize
        #expect(before == 1_025_632)
        #expect(after == 10_634)
    }

    @Test func aTargetYouOpened() throws {
        let database = try newHistory(moments: 3)

        // A database you opened yourself, with its own file ID and hash ID.
        let target = try Database(creating: MemoryStorage(), hashSize: 32, hashID: "sha2")
        var offsets = MemoryOffsetMap()
        try database.compact(into: target, offsetMap: &offsets)

        #expect(try ArrayList<ReadOnly>(target.rootCursor).count == 1)
        #expect(target.header.hashID == "sha2")
    }

    @Test func aTargetMustBeEmpty() throws {
        let database = try newHistory(moments: 3)
        var offsets = MemoryOffsetMap()

        // Its own file is the case to be glad of.
        #expect(throws: XitDBError.targetNotEmpty) {
            try database.compact(into: database, offsetMap: &offsets)
        }

        let smaller = try Database(creating: MemoryStorage(), hashSize: 20)
        #expect(throws: XitDBError.invalidHashSize) {
            try database.compact(into: smaller, offsetMap: &offsets)
        }
    }

    @Test func theStorageShapeTakesTheSourcesHashID() throws {
        let source = try Database(creating: MemoryStorage(), hashSize: 32, hashID: "sha2")
        _ = try ArrayList<ReadWrite>(source.rootCursor)
        var offsets = MemoryOffsetMap()

        let compacted = try source.compact(into: MemoryStorage(), offsetMap: &offsets)
        #expect(compacted.header.hashID == "sha2")
        #expect(compacted.header.hashSize == 32)
        #expect(compacted.header.fileID != source.header.fileID)

        var again = MemoryOffsetMap()
        let renamed = try source.compact(into: MemoryStorage(), hashID: "sha3", fileID: 7, offsetMap: &again)
        #expect(renamed.header.hashID == "sha3")
        #expect(renamed.header.fileID == 7)
    }

    @Test func anEmptyRootCommitsNothing() throws {
        let source = try Database(creating: MemoryStorage(), hashSize: 32)
        let target = MemoryStorage()
        var offsets = MemoryOffsetMap()
        let compacted = try source.compact(into: target, offsetMap: &offsets)
        #expect(try compacted.committedSize == 62)
        #expect(try compacted.rootCursor.slot.isEmpty)

        // A history with no moments commits nothing either: the list is lost.
        let empty = try Database(creating: MemoryStorage(), hashSize: 32)
        _ = try ArrayList<ReadWrite>(empty.rootCursor)
        var more = MemoryOffsetMap()
        let compactedEmpty = try empty.compact(into: MemoryStorage(), offsetMap: &more)
        #expect(try compactedEmpty.rootCursor.slot.isEmpty)
    }

    @Test func aRootThatIsNotAListIsCopiedWhole() throws {
        let source = try Database(creating: MemoryStorage(), hashSize: 32)
        let map = try HashMap<ReadWrite>(source.rootCursor)
        try map.put(.uint(1), forHash: sha256("a"))
        try map.put(.uint(2), forHash: sha256("a"))
        try map.put(.uint(3), forHash: sha256("b"))
        var offsets = MemoryOffsetMap()
        let compacted = try source.compact(into: MemoryStorage(), offsetMap: &offsets)

        let copy = try HashMap<ReadOnly>(compacted.rootCursor)
        #expect(try copy.cursor(forHash: sha256("a"))!.readUInt64() == 2)
        #expect(try copy.cursor(forHash: sha256("b"))!.readUInt64() == 3)
        #expect(try compacted.committedSize < source.committedSize)
    }

    @Test func thingsSharedStayShared() throws {
        let source = try Database(creating: MemoryStorage(), hashSize: 32)
        let history = try ArrayList<ReadWrite>(source.rootCursor)
        try history.append(.slot(nil)) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            try moment.put(.bytes([UInt8](repeating: 7, count: 1000)), forHash: sha256("first"))
        }
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let shared = try moment.slot(forHash: sha256("first"))!
            try moment.put(.slot(shared), forHash: sha256("second"))
        }

        var offsets = MemoryOffsetMap()
        let compacted = try source.compact(into: MemoryStorage(), offsetMap: &offsets)
        let moment = try HashMap<ReadOnly>(ArrayList<ReadOnly>(compacted.rootCursor).cursor(at: 0)!)
        let first = try moment.slot(forHash: sha256("first"))!
        let second = try moment.slot(forHash: sha256("second"))!
        #expect(first == second)
        #expect(try compacted.committedSize < 2000)
    }

    @Test func offsetsOnDisk() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }
        let database = try newHistory(moments: 50)

        // A scratch database holds the offsets, with hashes of eight bytes.
        struct DiskOffsets: OffsetMap {
            var map: HashMap<ReadWrite>

            private func hash(_ offset: UInt64) -> [UInt8] {
                withUnsafeBytes(of: offset.bigEndian) { Array($0) }
            }

            mutating func reset() throws {
                var cursor = map.cursor
                try cursor.write(.slot(nil))
                map = try HashMap<ReadWrite>(cursor)
            }

            mutating func get(_ sourceOffset: UInt64) throws -> UInt64? {
                try map.cursor(forHash: hash(sourceOffset))?.readUInt64()
            }

            mutating func put(_ sourceOffset: UInt64, _ targetOffset: UInt64) throws {
                try map.put(.uint(targetOffset), forHash: hash(sourceOffset))
            }
        }

        // Nothing here needs to survive a crash, so nothing is synced.
        let scratchStorage = try FileStorage(path: scratch.path("offsets.db"), access: .truncate, durability: .none)
        let offsetsDatabase = try Database(creating: scratchStorage, hashSize: 8)
        let target = try BufferedFileStorage(path: scratch.path("compact.db"), access: .truncate)

        // One transaction around the whole compaction, so that the offsets
        // are not each committed on their own.
        let compacted = try offsetsDatabase.withTransaction { cursor in
            var offsets = DiskOffsets(map: try HashMap<ReadWrite>(cursor))
            return try database.compact(into: target, offsetMap: &offsets)
        }

        let history = try ArrayList<ReadOnly>(compacted.rootCursor)
        #expect(try history.count == 1)
        let moment = try HashMap<ReadOnly>(history.cursor(at: 0)!)
        #expect(try moment.cursor(forHash: sha256("latest"))!.readUInt64() == 49)

        // The two ways agree, byte for byte, apart from the IDs.
        var inMemory = MemoryOffsetMap()
        let viaMemory = try database.compact(into: MemoryStorage(), offsetMap: &inMemory)
        #expect(try viaMemory.committedSize == compacted.committedSize)
    }

    @Test func anOffsetMapsErrorIsCarried() throws {
        struct OutOfRoom: Error {}
        struct FailingOffsets: OffsetMap {
            mutating func reset() throws {}
            mutating func get(_ sourceOffset: UInt64) throws -> UInt64? { nil }
            mutating func put(_ sourceOffset: UInt64, _ targetOffset: UInt64) throws { throw OutOfRoom() }
        }

        let database = try newHistory(moments: 3)
        let target = try Database(creating: MemoryStorage(), hashSize: 32)
        var offsets = FailingOffsets()
        do {
            try database.compact(into: target, offsetMap: &offsets)
            Issue.record("the compaction should have failed")
        } catch {
            guard case .callerError(let carried) = error else {
                Issue.record("expected callerError, got \(error)")
                return
            }
            #expect(carried is OutOfRoom)
        }
        // Nothing of it is reachable.
        #expect(try target.rootCursor.slot.isEmpty)
    }

    @Test func replacingTheOldFile() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }

        var mainStorage: BufferedFileStorage? = try BufferedFileStorage(
            path: scratch.path("main.db"), access: .create, durability: .none)
        var database: Database? = try Database(creating: mainStorage!, hashSize: 32)
        let history = try ArrayList<ReadWrite>(database!.rootCursor)
        try history.append(.slot(nil)) { cursor in
            try HashMap<ReadWrite>(cursor).put(.uint(1), forHash: sha256("a"))
        }
        let target = try BufferedFileStorage(path: scratch.path("compact.db"), access: .truncate)
        var offsets = MemoryOffsetMap()
        _ = try database!.compact(into: target, offsetMap: &offsets)
        database = nil
        mainStorage = nil

        // Once nothing is writing to the old file, put the new one in its place.
        _ = try FileManager.default.replaceItemAt(
            URL(fileURLWithPath: scratch.path("main.db")),
            withItemAt: URL(fileURLWithPath: scratch.path("compact.db")))

        let reopened = try Database(opening: BufferedFileStorage(path: scratch.path("main.db"), access: .readOnly))
        #expect(try ArrayList<ReadOnly>(reopened.rootCursor).count == 1)
    }

    /// The original's design for evicting one person's data while keeping the
    /// history of everyone else.
    @Test func evictingOnePersonsData() throws {
        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashSize: 32)
        let history = try ArrayList<ReadWrite>(database.rootCursor)

        // Each person is a list of that person's versions, and `versions` says
        // which version of each person each global version had, by index.
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let people = try ArrayList<ReadWrite>(moment.putCursor(forHash: sha256("people")))

            let alice = try ArrayList<ReadWrite>(people.appendCursor())
            try alice.append(.bytes(Array("Alice, 25".utf8)))

            let bob = try ArrayList<ReadWrite>(people.appendCursor())
            try bob.append(.bytes(Array("Bob, 42".utf8)))

            let versions = try ArrayList<ReadWrite>(moment.putCursor(forHash: sha256("versions")))
            let first = try ArrayList<ReadWrite>(versions.appendCursor())
            try first.append(.uint(0))
            try first.append(.uint(0))
        }

        // Bob turns 43.
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let people = try ArrayList<ReadWrite>(moment.putCursor(forHash: sha256("people")))
            let bob = try ArrayList<ReadWrite>(people.putCursor(at: 1))
            try bob.append(.bytes(Array("Bob, 43".utf8)))

            let versions = try ArrayList<ReadWrite>(moment.putCursor(forHash: sha256("versions")))
            let second = try ArrayList<ReadWrite>(versions.appendCursor())
            try second.append(.uint(0))
            try second.append(.uint(1))
        }

        // Alice asks to be forgotten: clear her slot, and compact.
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let people = try ArrayList<ReadWrite>(moment.putCursor(forHash: sha256("people")))
            try people.put(.slot(nil), at: 0)
        }

        let target = MemoryStorage()
        var offsets = MemoryOffsetMap()
        let compacted = try database.compact(into: target, offsetMap: &offsets)

        func contains(_ needle: String, in bytes: [UInt8]) -> Bool {
            let needle = Array(needle.utf8)
            return bytes.indices.contains { bytes[$0...].starts(with: needle) }
        }
        #expect(contains("Alice", in: storage.bytes))
        #expect(!contains("Alice", in: target.bytes))
        #expect(contains("Bob, 42", in: target.bytes))
        #expect(contains("Bob, 43", in: target.bytes))

        let moment = try HashMap<ReadOnly>(ArrayList<ReadOnly>(compacted.rootCursor).cursor(at: -1)!)
        let people = try ArrayList<ReadOnly>(moment.cursor(forHash: sha256("people"))!)
        let versions = try ArrayList<ReadOnly>(moment.cursor(forHash: sha256("versions"))!)
        let bob = try ArrayList<ReadOnly>(people.cursor(at: 1)!)
        #expect(try bob.count == 2)
        #expect(try versions.count == 2)
        #expect(try people.slot(at: 0)!.tag == .none)
    }
}
