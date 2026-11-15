import Foundation
import Testing

@testable import XitDB

/// Snapshots under concurrency (D25): a writer committing while tasks read
/// snapshots, the fence under a sync from zero, and what a snapshot holds
/// open. The gate runs this suite under the thread sanitizer as well.
@Suite struct SnapshotConcurrencyTests {
    /// The storages a client has, the two that read through a memory map
    /// among them; the small window adds nothing here.
    static let storageKinds: [StorageKind] = [.memory, .file, .bufferedFile, .mappedFile, .mappedBufferedFile]

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
        func withdraw() { published = nil }
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
                        // Cancelled when the writer throws: the group then
                        // waits for its readers, which must not wait for a
                        // finish that will not come.
                        if done || Task.isCancelled { break }
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
                        // Cancelled when the writer throws: the group then
                        // waits for its readers, which must not wait for a
                        // finish that will not come.
                        if done || Task.isCancelled { break }
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

    /// On a storage that reads through a memory map a sync from zero is
    /// refused while a snapshot lives, so the writer withdraws the snapshot
    /// it published and tries until the readers have let go of theirs. No
    /// reader ever sees the file change under a snapshot: every read gives
    /// the snapshot's own number, and none is refused or fails, which the
    /// fence's `snapshotOverwritten` would be. Under the thread sanitizer
    /// this is also the readers copying from the map while the writer
    /// writes the file.
    @Test(arguments: [StorageKind.mappedFile, .mappedBufferedFile])
    func aSyncFromZeroWaitsForTheReadersOfAMappedFile(kind: StorageKind) async throws {
        let fixture = try Fixture(kind)
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
        // Each longer than a segment of the tests' map, which is one page.
        let page = Platform.pageSize
        let replicas = [
            try replica(1000, padding: page + 16), try replica(2000, padding: 2 * page + 300),
            try replica(3000, padding: 3 * page + 1200),
        ]
        let latest = Latest()
        await latest.publish(try fixture.database.snapshot(), 0)

        /// One look of a reader at what is published. The snapshot it took
        /// is let go of when this returns, before the reader yields.
        @Sendable func look() async throws -> (wrong: Int, read: Int, done: Bool) {
            let (published, done) = await latest.current()
            guard let published else { return (0, 0, done) }
            let (first, second) = try Self.pair(of: published.snapshot)
            return (first != published.number || second != published.number ? 1 : 0, 1, done)
        }

        let outcome = try await withThrowingTaskGroup(of: (wrong: Int, read: Int).self) { group in
            for _ in 0..<4 {
                group.addTask {
                    var wrong = 0
                    var read = 0
                    while true {
                        let one = try await look()
                        wrong += one.wrong
                        read += one.read
                        // Cancelled when the writer throws, as above.
                        if one.done || Task.isCancelled { break }
                        await Task.yield()
                    }
                    return (wrong, read)
                }
            }
            var refused = 0
            for round in 0..<40 {
                let number = UInt64(1000 * (round % 3 + 1))
                // Let the readers read what is published before it is
                // taken away, so that some hold it when the sync is tried.
                for _ in 0..<3 { await Task.yield() }
                await latest.withdraw()
                while true {
                    do {
                        try fixture.database.applyReplicated(at: 0, bytes: replicas[round % 3])
                        break
                    } catch XitDBError.snapshotStillMapped {
                        refused += 1
                        await Task.yield()
                    }
                }
                await latest.publish(try fixture.database.snapshot(), number)
            }
            await latest.finish()
            let readers = try await group.reduce((wrong: 0, read: 0)) {
                (wrong: $0.wrong + $1.wrong, read: $0.read + $1.read)
            }
            return (wrong: readers.wrong, read: readers.read, refused: refused)
        }
        #expect(outcome.wrong == 0)
        #expect(outcome.read > 0)

        // Whatever the readers' timing, a sync from zero under a snapshot
        // that is held is refused, and the snapshot reads its commit.
        await latest.withdraw()
        let held = try fixture.database.snapshot()
        let number = try Self.pair(of: held)
        #expect(throws: XitDBError.snapshotStillMapped) {
            try fixture.database.applyReplicated(at: 0, bytes: replicas[0])
        }
        #expect(try Self.pair(of: held) == number)
    }

    /// How many of the process's descriptors are open on the file at
    /// `path`. Other tests open files of their own meanwhile, so only this
    /// file is counted. Apple platforms answer `F_GETPATH` for a descriptor;
    /// Linux shows each one as a link in `/proc/self/fd`.
    private static func descriptors(on path: String) throws -> Int {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var count = 0
        #if canImport(Darwin)
            for name in try FileManager.default.contentsOfDirectory(atPath: "/dev/fd") {
                guard let descriptor = Int32(name) else { continue }
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
                guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { continue }
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let openPath = String(decoding: bytes, as: UTF8.self)
                if URL(fileURLWithPath: openPath).standardizedFileURL.path == standardized { count += 1 }
            }
        #else
            for name in try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd") {
                guard let openPath = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(name)")
                else { continue }
                if URL(fileURLWithPath: openPath).standardizedFileURL.path == standardized { count += 1 }
            }
        #endif
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
