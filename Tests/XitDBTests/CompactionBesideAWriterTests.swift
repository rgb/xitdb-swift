import Foundation
import Testing
import XitDBHashing

@testable import XitDB

/// A compaction from a reader of its own, beside the writer, in one
/// process: the way the pages give a server that compacts while it writes.
///
/// A compaction's second view is the storage's, and a snapshot has none: a
/// snapshot of a storage opened `.memoryMap` reads through that storage's
/// map as it was told, and a compaction from it brings a file that is not
/// in memory in a page at a time. So the task that compacts opens the file
/// itself, to be read, through a map left to the system's reading ahead and
/// with no lock, takes a snapshot of the database over that, and compacts
/// from the snapshot, while the writer goes on through its own storage.
///
/// That the system reads ahead in the reader's map is the system's and is
/// not seen from here. What is held is that the pieces fit: the reader
/// opens beside a writer that holds the exclusive lock, on each kind of
/// file storage a writer has; it is mapped; its snapshot stays at its commit
/// while the writer commits on and the reader follows; the compacted
/// database is that commit and nothing after it; and the writer's lock is
/// the writer's still when the reader has gone.
@Suite struct CompactionBesideAWriterTests {
    /// The writer's storage: a file or a buffered file, read by file calls
    /// or through a map, each opened with the exclusive lock, which a map
    /// needs and the others may take.
    enum WriterKind: String, CaseIterable, CustomTestStringConvertible {
        case file, bufferedFile, mappedFile, mappedBufferedFile

        var testDescription: String { rawValue }

        var isMapped: Bool { self == .mappedFile || self == .mappedBufferedFile }

        /// Creates the writer's file at `path` and opens it, as a client
        /// opens it.
        func create(at path: String) throws -> any WritableStorage {
            let reading: FileReading = isMapped ? .memoryMap : .fileCalls
            switch self {
            case .file, .mappedFile:
                let storage = try FileStorage(
                    path: path, access: .create, durability: .none, lock: .exclusive, reading: reading)
                guard storage.isMemoryMapped == isMapped else { throw NotReadThroughTheMap(path: path) }
                return storage
            case .bufferedFile, .mappedBufferedFile:
                let storage = try BufferedFileStorage(
                    path: path, access: .create, durability: .none, lock: .exclusive, reading: reading)
                guard storage.isMemoryMapped == isMapped else { throw NotReadThroughTheMap(path: path) }
                return storage
            }
        }
    }

    /// The bytes a round's moment holds under "blob": long enough to be a
    /// record of their own in the file.
    private static func blob(_ round: Int) -> [UInt8] {
        [UInt8](repeating: UInt8(truncatingIfNeeded: round), count: 3000)
    }

    /// One commit of the writer: a moment appended to the history, which
    /// starts as the moment before it, with the round's number under
    /// "round", bytes under "blob", and the number appended to the list
    /// under "rounds".
    private static func commit(_ round: Int, through writer: Database) throws {
        let history = try ArrayList<ReadWrite>(writer.rootCursor)
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            try moment.put(UInt64(round), forKey: "round")
            try moment.put(blob(round), forKey: "blob")
            try ArrayList<ReadWrite>(try moment.putCursor(forKey: "rounds")).append(UInt64(round))
        }
    }

    /// What is read at a root: how many moments the history has, and its
    /// last moment's number, bytes, and list.
    private struct State: Equatable {
        var moments: UInt64
        var round: UInt64?
        var blob: [UInt8]?
        var rounds: UInt64?
        var lastRound: UInt64?

        /// The state after the writer's commit of `round`, in a history of
        /// `moments` moments.
        init(round: Int, moments: Int) {
            self.moments = UInt64(moments)
            self.round = UInt64(round)
            blob = CompactionBesideAWriterTests.blob(round)
            rounds = UInt64(round)
            lastRound = UInt64(round)
        }

        init(at root: Cursor<ReadOnly>) throws {
            let history = try ArrayList(root)
            moments = try history.count
            guard let last = try history.cursor(at: -1) else { return }
            let moment = try HashMap(last)
            round = try moment.value(forKey: "round", as: UInt64.self)
            blob = try moment.value(forKey: "blob", as: [UInt8].self)
            if let cursor = try moment.cursor(forKey: "rounds") {
                let list = try ArrayList(cursor)
                rounds = try list.count
                lastRound = try list.value(at: -1, as: UInt64.self)
            }
        }
    }

    /// The whole of the way: a reader's own storage beside the writer's on
    /// one file, a snapshot of the reader's database, the writer committing
    /// on, and a compaction from that snapshot into a new file.
    @Test(arguments: WriterKind.allCases)
    func aCompactionFromAReadersSnapshotHoldsItsCommitBesideAWriterThatGoesOn(kind: WriterKind) throws {
        let directory = try TemporaryDirectory()
        let path = directory.path()
        let writer = try Database(creating: try kind.create(at: path), hashing: SHA256.self)
        for round in 1...3 { try Self.commit(round, through: writer) }
        let busy = XitDBError.storageFailure(errno: EWOULDBLOCK)

        // The task that compacts opens the file itself, to be read, through
        // a map left to the system's reading ahead. It asks for no lock,
        // and the writer's exclusive one does not keep it out.
        let readerStorage = try ReadOnlyFileStorage(path: path, reading: .memoryMapReadAhead)
        #expect(readerStorage.requestedReading == .memoryMapReadAhead)
        guard readerStorage.isMemoryMapped else { throw NotReadThroughTheMap(path: path) }
        do {
            let reader = try ReadOnlyDatabase(opening: readerStorage, hashing: SHA256.self)
            let snapshot = try reader.snapshot()
            #expect(try State(at: snapshot.rootCursor) == State(round: 3, moments: 3))

            // The writer commits on through its own storage. The reader
            // follows it, and the snapshot stays where it was taken.
            for round in 4...6 { try Self.commit(round, through: writer) }
            #expect(try State(at: reader.rootCursor) == State(round: 6, moments: 6))
            #expect(try State(at: snapshot.rootCursor) == State(round: 3, moments: 3))

            // The compaction, from the reader's snapshot into a new file:
            // the snapshot's commit as the one moment of a new history, and
            // none of the writer's commits since.
            var offsets = MemoryOffsetMap()
            let compacted = try SnapshotDatabase(snapshot).compact(
                into: try BufferedFileStorage(path: directory.path("compacted.db"), access: .create, durability: .none),
                fileID: 9, offsetMap: &offsets)
            #expect(try State(at: compacted.rootCursor.readOnly) == State(round: 3, moments: 1))

            // The writer goes on after it, the reader still follows, and
            // the snapshot is where it was.
            try Self.commit(7, through: writer)
            #expect(try State(at: reader.rootCursor) == State(round: 7, moments: 7))
            #expect(try State(at: snapshot.rootCursor) == State(round: 3, moments: 3))

            // All along the lock is the writer's: an opener that asks for
            // one is refused, beside a reader that asked for none.
            #expect(throws: busy) { _ = try FileStorage(path: path, access: .readWrite, lock: .exclusive) }
            // A snapshot holds the reader's file open still.
            #expect(!readerStorage.close())
        }

        // The reader has gone: its snapshot and its database with the scope
        // above, and its file now, which no snapshot holds any more.
        #expect(readerStorage.close())
        // Its going did not let the writer's lock go.
        #expect(throws: busy) { _ = try FileStorage(path: path, access: .readWrite, lock: .exclusive) }
        #expect(throws: busy) { _ = try ReadOnlyFileStorage(path: path, lock: .shared) }
        // And the writer writes on.
        try Self.commit(8, through: writer)
        #expect(try State(at: writer.rootCursor.readOnly) == State(round: 8, moments: 8))
    }
}
