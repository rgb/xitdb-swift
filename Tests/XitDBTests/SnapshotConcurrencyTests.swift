import Foundation
import Testing

@testable import XitDB

/// Snapshots under concurrency (D25): a writer committing while tasks read
/// snapshots, the fence under a sync from zero, and what a snapshot holds
/// open. The gate runs this suite under the thread sanitizer as well.
@Suite struct SnapshotConcurrencyTests {
    /// The three storages a client has; the small window adds nothing here.
    static let storageKinds: [StorageKind] = [.memory, .file, .bufferedFile]

    /// A database whose root map holds the same number under two keys at
    /// every commit, so that a reader can tell a consistent moment.
    private struct Fixture {
        let subject: StorageUnderTest
        let database: Database

        init(_ kind: StorageKind) throws {
            subject = try StorageUnderTest(kind)
            database = try Database(creating: subject.storage, hashSize: 20)
            try commit(0)
        }

        func commit(_ number: UInt64) throws {
            func body(_ cursor: inout Cursor<ReadWrite>) throws {
                let map = try HashMap<ReadWrite>(cursor)
                try map.put(.uint(number), forHash: sha1("first").bytes)
                try map.put(.uint(number), forHash: sha1("second").bytes)
            }
            try database.withTransaction(body)
        }
    }

    /// The two numbers of a snapshot's root map.
    private static func pair(of snapshot: Snapshot) throws -> (UInt64, UInt64) {
        let map = try HashMap<ReadOnly>(snapshot.rootCursor)
        let first = try map.cursor(forHash: sha1("first").bytes)?.readUInt64()
        let second = try map.cursor(forHash: sha1("second").bytes)?.readUInt64()
        return (try #require(first), try #require(second))
    }

    /// A snapshot with the number both its keys hold.
    private struct Published: Sendable {
        let snapshot: Snapshot
        let number: UInt64
    }

    /// The newest snapshot the writer has published, for the readers.
    private actor Latest {
        private var published: Published?
        private var done = false

        func publish(_ snapshot: Snapshot, _ number: UInt64) {
            published = Published(snapshot: snapshot, number: number)
        }
        func finish() { done = true }
        func current() -> (Published?, Bool) { (published, done) }
    }

    @Test(arguments: storageKinds)
    func readersOnOtherTasksReadConsistentMomentsWhileTheWriterCommits(kind: StorageKind) async throws {
        let fixture = try Fixture(kind)
        let latest = Latest()
        let commits: UInt64 = 300

        let mismatches = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    var mismatches = 0
                    var newest: UInt64 = 0
                    var reads = 0
                    while true {
                        let (published, done) = await latest.current()
                        if let published {
                            let (first, second) = try Self.pair(of: published.snapshot)
                            // The commit it was published as, whole, and never
                            // an older one than a snapshot published before it.
                            if first != published.number || second != published.number || first < newest {
                                mismatches += 1
                            }
                            newest = first
                            reads += 1
                        }
                        if done { break }
                        await Task.yield()
                    }
                    return reads > 0 ? mismatches : 1
                }
            }
            // The writer, on this task: a commit, then its snapshot.
            for number in 1...commits {
                try fixture.commit(number)
                await latest.publish(try fixture.database.snapshot(), number)
            }
            await latest.finish()
            return try await group.reduce(0, +)
        }
        #expect(mismatches == 0)
    }

    @Test(arguments: [StorageKind.file, .bufferedFile])
    func readersHammerTheFenceWhileTheWriterSyncsFromZero(kind: StorageKind) async throws {
        let fixture = try Fixture(kind)
        // Databases to sync from, each with its own number under both keys
        // and a different layout, so that a stale snapshot reading the new
        // file at its old offsets cannot find a consistent pair by chance.
        func replica(_ number: UInt64, padding: Int) throws -> [UInt8] {
            let other = try Database(creating: MemoryStorage(), hashSize: 20)
            func body(_ cursor: inout Cursor<ReadWrite>) throws {
                let map = try HashMap<ReadWrite>(cursor)
                try map.put(.bytes(Array(repeating: 0xAB, count: padding)), forHash: sha1("padding").bytes)
                try map.put(.uint(number), forHash: sha1("first").bytes)
                try map.put(.uint(number), forHash: sha1("second").bytes)
            }
            try other.withTransaction(body)
            return try other.readCommitted(from: 0, to: try other.committedSize)
        }
        let replicas = [
            try replica(1000, padding: 16), try replica(2000, padding: 300), try replica(3000, padding: 1200),
        ]
        let latest = Latest()
        await latest.publish(try fixture.database.snapshot(), 0)

        let outcome = try await withThrowingTaskGroup(of: (wrong: Int, refused: Int, read: Int).self) { group in
            for _ in 0..<4 {
                group.addTask {
                    var wrong = 0
                    var refused = 0
                    var read = 0
                    while true {
                        let (published, done) = await latest.current()
                        if let published {
                            do {
                                let (first, second) = try Self.pair(of: published.snapshot)
                                // A read that goes through gives the snapshot's
                                // own number, never another replica's.
                                if first != published.number || second != published.number { wrong += 1 }
                                read += 1
                            } catch XitDBError.snapshotOverwritten {
                                // The file was rewritten under it: refused,
                                // never wrong.
                                refused += 1
                            }
                        }
                        if done { break }
                        await Task.yield()
                    }
                    return (wrong, refused, read)
                }
            }
            for round in 0..<60 {
                let number = UInt64(1000 * (round % 3 + 1))
                try fixture.database.applyReplicated(at: 0, bytes: replicas[round % 3])
                await latest.publish(try fixture.database.snapshot(), number)
            }
            await latest.finish()
            return try await group.reduce((wrong: 0, refused: 0, read: 0)) {
                (wrong: $0.wrong + $1.wrong, refused: $0.refused + $1.refused, read: $0.read + $1.read)
            }
        }
        #expect(outcome.wrong == 0)
        #expect(outcome.read > 0)

        // Whatever the readers' timing, a snapshot held across a sync from
        // zero refuses: the fence must have tripped at least this once.
        let held = try fixture.database.snapshot()
        try fixture.database.applyReplicated(at: 0, bytes: replicas[0])
        var refused = outcome.refused
        do {
            _ = try Self.pair(of: held)
        } catch XitDBError.snapshotOverwritten {
            refused += 1
        }
        #expect(refused > 0)
        #expect(refused > outcome.refused, "the fence did not trip for the snapshot held across the last sync")
    }

    #if canImport(Darwin)
        /// How many of the process's descriptors are open on the file at
        /// `path`. Other tests open files of their own meanwhile, so only this
        /// file is counted.
        private static func descriptors(on path: String) throws -> Int {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            var count = 0
            for name in try FileManager.default.contentsOfDirectory(atPath: "/dev/fd") {
                guard let descriptor = Int32(name) else { continue }
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
                guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { continue }
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let openPath = String(decoding: bytes, as: UTF8.self)
                if URL(fileURLWithPath: openPath).standardizedFileURL.path == standardized { count += 1 }
            }
            return count
        }

        @Test func aSnapshotOpensNoDescriptorOfItsOwn() throws {
            let subject = try StorageUnderTest(.bufferedFile)
            let path = try #require(subject.path)
            let database = try Database(creating: subject.storage, hashSize: 20)
            try HashMap<ReadWrite>(database.rootCursor).put(.uint(1), forHash: sha1("a").bytes)
            let before = try Self.descriptors(on: path)
            #expect(before == 1)
            var snapshots: [Snapshot] = []
            for _ in 0..<100 {
                snapshots.append(try database.snapshot())
            }
            #expect(try Self.descriptors(on: path) == before)
            #expect(
                try HashMap<ReadOnly>(snapshots[99].rootCursor).cursor(forHash: sha1("a").bytes)?.readUInt64() == 1)
        }
    #endif

    @Test func theLockLivesWhileASnapshotDoes() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path()
        var snapshot: Snapshot?
        do {
            let storage = try BufferedFileStorage(path: path, access: .create, durability: .none, lock: .exclusive)
            let database = try Database(creating: storage, hashSize: 20)
            try HashMap<ReadWrite>(database.rootCursor).put(.uint(1), forHash: sha1("a").bytes)
            snapshot = try database.snapshot()
        }
        // The storage is gone; the snapshot holds its descriptor, and with
        // it the lock.
        #expect(throws: XitDBError.storageFailure(errno: EWOULDBLOCK)) {
            try FileStorage(path: path, access: .readWrite, durability: .none, lock: .exclusive)
        }
        do {
            let kept = try #require(snapshot)
            #expect(try HashMap<ReadOnly>(kept.rootCursor).cursor(forHash: sha1("a").bytes)?.readUInt64() == 1)
        }
        // The last reference to the descriptor goes with the snapshot, and
        // the lock with it.
        snapshot = nil
        _ = try FileStorage(path: path, access: .readWrite, durability: .none, lock: .exclusive)
    }
}
