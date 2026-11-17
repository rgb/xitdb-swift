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

    /// A sync from zero onto a file brings the new database in a new file,
    /// so the readers' snapshots read the old one on, each its own commit:
    /// every read gives the snapshot's own number, and none is refused or
    /// fails, whatever the timing, on every kind of file storage. Under
    /// the thread sanitizer this is also the readers copying from the old
    /// file, through file calls or through its map, while the writer
    /// writes the new one and gives it the name.
    @Test(arguments: StorageKind.files)
    func readersReadTheirOwnCommitWhileTheWriterSyncsFromZero(kind: StorageKind) async throws {
        let fixture = try Fixture(kind)
        // Databases to sync from, each with its own number under both keys
        // and a different layout, so that a snapshot that read another
        // file's bytes at its own offsets could not find a consistent pair
        // by chance.
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

        let outcome = try await withThrowingTaskGroup(of: (wrong: Int, read: Int).self) { group in
            for _ in 0..<4 {
                group.addTask {
                    var wrong = 0
                    var read = 0
                    while true {
                        let (published, done) = await latest.current()
                        if let published {
                            // Any error ends the test: a snapshot's read is
                            // never refused here.
                            let (first, second) = try Self.pair(of: published.snapshot)
                            if first != published.number || second != published.number { wrong += 1 }
                            read += 1
                        }
                        // Cancelled when the writer throws: the group then
                        // waits for its readers, which must not wait for a
                        // finish that will not come.
                        if done || Task.isCancelled { break }
                        await Task.yield()
                    }
                    return (wrong, read)
                }
            }
            for round in 0..<60 {
                let number = UInt64(1000 * (round % 3 + 1))
                try fixture.database.applyReplicated(at: 0, bytes: replicas[round % 3])
                await latest.publish(try fixture.database.snapshot(), number)
            }
            await latest.finish()
            return try await group.reduce((wrong: 0, read: 0)) {
                (wrong: $0.wrong + $1.wrong, read: $0.read + $1.read)
            }
        }
        #expect(outcome.wrong == 0)
        #expect(outcome.read > 0)

        // Whatever the readers' timing was: a snapshot held across a sync
        // from zero reads its own commit after it, and across the next.
        let held = try fixture.database.snapshot()
        let before = try Self.pair(of: held)
        try fixture.database.applyReplicated(at: 0, bytes: replicas[0])
        #expect(try Self.pair(of: held) == before)
        try fixture.database.applyReplicated(at: 0, bytes: replicas[1])
        #expect(try Self.pair(of: held) == before)
        #expect(try Self.pair(of: try fixture.database.snapshot()) == (2000, 2000))
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

    /// The lock is the storage's, on every kind of file storage, and goes
    /// when the storage goes: a snapshot that outlives the storage keeps
    /// the file open and reads its commit, and holds no lock, so the next
    /// writer opens the file with its own.
    @Test(arguments: [StorageKind.file, .bufferedFile, .mappedFile, .mappedBufferedFile])
    func theLockGoesWithTheStorageAndNotWithASnapshot(kind: StorageKind) throws {
        let directory = try TemporaryDirectory()
        let path = directory.path()
        let mapped = kind == .mappedFile || kind == .mappedBufferedFile
        func writer(_ access: FileAccess) throws -> any WritableStorage {
            let file = try FileStorage(
                path: path, access: access, durability: .none, lock: .exclusive, memoryMapped: mapped,
                segmentSize: Platform.pageSize)
            return kind == .bufferedFile || kind == .mappedBufferedFile ? BufferedFileStorage(file) : file
        }
        var snapshot: Snapshot?
        do {
            let storage = try writer(.create)
            let database = try Database(creating: storage, hashSize: 20)
            try HashMap<ReadWrite>(database.rootCursor).put(.uint(1), forHash: sha1("a").bytes)
            snapshot = try database.snapshot()
            // While the storage lives the lock is held.
            #expect(throws: XitDBError.storageFailure(errno: EWOULDBLOCK)) {
                try FileStorage(path: path, access: .readWrite, durability: .none, lock: .exclusive)
            }
        }
        // The storage is gone, and its lock with it; the snapshot holds the
        // descriptor, and reads.
        let next = try Database(opening: try writer(.readWrite), hashSize: 20)
        let kept = try #require(snapshot)
        #expect(try HashMap<ReadOnly>(kept.rootCursor).cursor(forHash: sha1("a").bytes)?.readUInt64() == 1)
        // The next writer commits, and the snapshot reads its own commit on.
        try HashMap<ReadWrite>(next.rootCursor).put(.uint(2), forHash: sha1("a").bytes)
        #expect(try HashMap<ReadOnly>(kept.rootCursor).cursor(forHash: sha1("a").bytes)?.readUInt64() == 1)
        snapshot = nil
        #expect(try HashMap<ReadOnly>(next.rootCursor.readOnly).cursor(forHash: sha1("a").bytes)?.readUInt64() == 2)
    }
}
