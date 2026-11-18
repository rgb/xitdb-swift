import Foundation
import Synchronization
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
                path: path, access: access, durability: .none, lock: .exclusive,
                reading: mapped ? .memoryMap : .fileCalls,
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
        // The storage is gone, and its lock with it: the lock is not
        // refused, though the snapshot holds the descriptor, and reads.
        #expect(throws: Never.self) {
            _ = try FileStorage(path: path, access: .readWrite, durability: .none, lock: .exclusive)
        }
        let next = try Database(opening: try writer(.readWrite), hashSize: 20)
        let kept = try #require(snapshot)
        #expect(try HashMap<ReadOnly>(kept.rootCursor).cursor(forHash: sha1("a").bytes)?.readUInt64() == 1)
        // The next writer commits, and the snapshot reads its own commit on.
        try HashMap<ReadWrite>(next.rootCursor).put(.uint(2), forHash: sha1("a").bytes)
        #expect(try HashMap<ReadOnly>(kept.rootCursor).cursor(forHash: sha1("a").bytes)?.readUInt64() == 1)
        snapshot = nil
        #expect(try HashMap<ReadOnly>(next.rootCursor.readOnly).cursor(forHash: sha1("a").bytes)?.readUInt64() == 2)
    }

    // MARK: The fence, tripped while a read is under way

    /// What a read made on a thread of its own leaves for the test's.
    private final class ReadUnderWay: Sendable {
        enum Outcome: Sendable {
            /// The read was refused with `snapshotOverwritten`.
            case refused
            /// The read returned, with these bytes, after this long.
            case read([UInt8], Duration)
            /// The read threw something else.
            case failed(String)
        }

        /// Set by the reader as the last thing before its read.
        let started = Atomic<Bool>(false)
        let outcome = Mutex<Outcome?>(nil)
        let ended = DispatchSemaphore(value: 0)
    }

    /// Whether two arrays hold the same bytes, by the C library's
    /// comparison: megabytes are compared in every round, which the
    /// arrays' own `==` takes milliseconds for where nothing is optimised.
    private static func sameBytes(_ one: [UInt8], _ other: [UInt8]) -> Bool {
        guard one.count == other.count else { return false }
        return one.withUnsafeBytes { first in
            other.withUnsafeBytes { second in
                // no address where there are no bytes: two empty arrays
                guard let first = first.baseAddress, let second = second.baseAddress else { return true }
                return memcmp(first, second, one.count) == 0
            }
        }
    }

    /// A caller's write into a snapshot's commit, through the storage,
    /// WHILE a read through the snapshot is under way on another thread:
    /// the read is refused, or it gives the commit's bytes; it never
    /// returns bytes the write brought. On every kind of file storage.
    ///
    /// This is what the fence is asked for AFTER a read. Every other test
    /// trips the fence before the read it looks at begins, and there an
    /// asking after the read cannot be told from one before it: dropped
    /// after a read through the map, or moved before the read, the fence
    /// passed every suite, the proof and the sanitizer's run among them.
    ///
    /// The read is of the whole commit, two megabytes in one call, and the
    /// write changes the commit's last bytes a part of the way into the
    /// read, by the time a read was seen to take: the copy is under way
    /// and has not come to them. Neither the map nor, as macOS and Linux
    /// were seen to do it, a read by a file call keeps such a write out of
    /// the bytes read: a read that the fence did not refuse then has the
    /// new bytes.
    ///
    /// The expectation is the guarantee and holds however the threads are
    /// scheduled. What the scheduling decides is only whether a round
    /// shows anything: the write shows something where it comes while the
    /// read is under way, and on a machine with few processors and much
    /// else to do the writer often gets no turn inside a read that takes a
    /// fifth of a millisecond. So the rounds are bounded by time and not
    /// counted: they go on until three reads were refused, for a minute at
    /// most, each round a fraction of a millisecond's work; the first read
    /// that gave the write's bytes ends them. A run in which no read was
    /// refused has shown nothing and fails. (Held to two processors, with
    /// the whole suite or a build beside it, three refusals took up to six
    /// thousand rounds and five seconds; held to one, up to thirty
    /// thousand and ten seconds; with all of a machine, three rounds.)
    @Test(arguments: StorageKind.files)
    func aReadUnderWayWhileItsCommitIsWrittenIntoIsRefusedOrGivesTheOldBytes(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(creating: subject.storage, hashSize: 20)
        // One value, which is all but the whole of the commit: the write
        // goes into its last bytes, and changes nothing a database is read
        // by, so that a snapshot can be taken again for the next round.
        let payload = [UInt8](repeating: 0x5A, count: 2 << 20)
        func body(_ cursor: inout Cursor<ReadWrite>) throws {
            try HashMap<ReadWrite>(cursor).put(.bytes(payload), forHash: sha1("payload").bytes)
        }
        try database.withTransaction(body)
        let committed = Int(try database.committedSize)
        try subject.storage.flush()
        var original = try subject.stored()
        #expect(original.count == committed)
        let first = try #require(
            original.indices.first { index in
                index + payload.count <= original.count && original[index..<(index + 64)].allSatisfy { $0 == 0x5A }
            }, "the value's bytes are in the file as they were given")
        let last = (first + payload.count - 64)..<(first + payload.count)
        #expect(original[last].allSatisfy { $0 == 0x5A })
        // late in the read: the copy has nine tenths of the commit to go
        // through before it comes to them
        #expect(last.lowerBound > committed / 10 * 9)

        // How long a read of the whole commit takes here, the least seen,
        // so that a write can be made to come a part of the way into one,
        // on any machine and under the sanitizer. (A write made as soon as
        // the reader says it is about to read mostly comes before the
        // read's first look at the fence, which refuses it whatever is
        // asked after the read: such rounds show nothing of the second
        // asking.)
        let clock = ContinuousClock()
        var whole = Duration.seconds(1)
        do {
            let half = try database.snapshot().storage
            var buffer = [UInt8](repeating: 0, count: committed)
            for _ in 0..<3 {
                var span = buffer.mutableSpan
                let began = clock.now
                let read = try half.read(into: &span, at: 0)
                whole = min(whole, clock.now - began)
                #expect(read == committed)
            }
        }

        var refused = 0
        var round = 0
        let end = clock.now + .seconds(60)
        while refused < 3, clock.now < end {
            let half = try database.snapshot().storage
            let reading = ReadUnderWay()
            let thread = Thread {
                // Whatever takes time is done before the reader says it
                // has begun: from there to the read's first look at the
                // fence there is nothing.
                var buffer = [UInt8](repeating: 0, count: committed)
                var span = buffer.mutableSpan
                let outcome: ReadUnderWay.Outcome
                let clock = ContinuousClock()
                reading.started.store(true, ordering: .sequentiallyConsistent)
                let began = clock.now
                do throws(XitDBError) {
                    let read = try half.read(into: &span, at: 0)
                    let took = clock.now - began
                    outcome = .read(read == buffer.count ? buffer : Array(buffer[..<read]), took)
                } catch {
                    outcome = error == .snapshotOverwritten ? .refused : .failed("\(error)")
                }
                reading.outcome.withLock { $0 = outcome }
                reading.ended.signal()
            }
            // other bytes each round, and never the value's own
            let new = [UInt8](repeating: UInt8(round % 64 + 1), count: last.count)
            // A quarter of the way into the read, then an eighth, a
            // sixteenth and a thirty-second, round by round: a read time
            // that was taken while something else had the processor is too
            // long, and a quarter of it may be past the read's end.
            let partOfTheWayIn = whole / (4 << (round % 4))
            thread.start()
            // The processor is given up while the reader has not begun:
            // where there is one processor, the reader needs it to begin.
            let limit = clock.now + .seconds(30)
            while !reading.started.load(ordering: .sequentiallyConsistent) {
                guard clock.now < limit else {
                    Issue.record("round \(round): the reader's thread did not begin")
                    return
                }
                sched_yield()
            }
            let begun = clock.now
            while clock.now - begun < partOfTheWayIn {}
            // A buffered storage holds the write in its window until it
            // flushes: the fence is tripped when the bytes go to the file.
            try writeBytes(subject.storage, new, at: UInt64(last.lowerBound))
            try subject.storage.flush()
            guard reading.ended.wait(timeout: .now() + 30) == .success else {
                Issue.record("round \(round): the read did not end")
                return
            }
            var gaveOtherBytes = false
            switch try #require(reading.outcome.withLock { $0 }) {
            case .refused:
                refused += 1
            case .read(let bytes, let took):
                // It was not refused: then it saw nothing of the write.
                gaveOtherBytes = !Self.sameBytes(bytes, original)
                whole = min(whole, took)
            case .failed(let error):
                Issue.record("round \(round): the read threw \(error)")
            }
            #expect(
                !gaveOtherBytes, "round \(round): a read that was not refused gave bytes that are not the commit's")
            // And from the write on the snapshot is refused, whatever it
            // was read for before.
            #expect(throws: XitDBError.snapshotOverwritten) { try readBytes(half, at: 0, count: 64) }
            original.replaceSubrange(last, with: new)
            round += 1
            if gaveOtherBytes { break }
        }
        #expect(refused > 0, "no write came while a read was under way in \(round) rounds: nothing was shown")
        // The file holds the last write and nothing else changed.
        try subject.storage.flush()
        let stored = Self.sameBytes(try subject.stored(), original)
        #expect(stored, "the file is the commit with the last round's bytes at its end")
    }
}
