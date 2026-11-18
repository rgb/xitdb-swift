import Testing
import XitDB
import XitDBHashing

@Suite("How a file is read") struct HowAFileIsReadExamples {
    @Test func aWriterAndAReaderThroughTheMap() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }

        // A writer that asks for the map without the lock is refused before the file is opened.
        #expect(throws: XitDBError.memoryMapNeedsLock) {
            try BufferedFileStorage(path: scratch.path("main.db"), access: .create, reading: .memoryMap)
        }
        #expect(!scratch.has("main.db"))

        // The writer: a map needs the exclusive lock.
        let writer = try BufferedFileStorage(
            path: scratch.path("main.db"), access: .create, lock: .exclusive, reading: .memoryMap)
        let written = try Database(creating: writer, hashing: SHA256.self)
        let writerHistory = try ArrayList<ReadWrite>(written.rootCursor)
        try writerHistory.append(.slot(nil)) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            try moment.put("Alice", forKey: "name")
            try moment.put(UInt64(25), forKey: "age")
        }
        #expect(writer.requestedReading == .memoryMap)

        // A reader that reads by key, through a map the system is told is read in no order.
        let storage = try ReadOnlyFileStorage(path: scratch.path("main.db"), reading: .memoryMap)
        let database = try ReadOnlyDatabase(opening: storage, hashing: SHA256.self)
        #expect(storage.requestedReading == .memoryMap)
        // A scratch folder is on this machine's own volume, which is mapped.
        #expect(storage.isMemoryMapped)

        // One reading of the root for the newest moment, and none for what is read in it.
        let history = try ArrayList(database.rootCursor)
        let moment = try HashMap(history.cursor(at: -1)!)
        let name = try moment.value(forKey: "name", as: String.self)
        let age = try moment.value(forKey: "age", as: UInt64.self)
        #expect(name == "Alice")
        #expect(age == 25)

        // The moment's cursor reads its commit until the history is asked again.
        try writerHistory.append(.slot(try writerHistory.slot(at: -1))) { cursor in
            try HashMap<ReadWrite>(cursor).put(UInt64(26), forKey: "age")
        }
        #expect(try moment.value(forKey: "age", as: UInt64.self) == 25)
        let newest = try HashMap(history.cursor(at: -1)!)
        #expect(try newest.value(forKey: "age", as: UInt64.self) == 26)
    }
}
