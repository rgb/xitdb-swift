import Foundation
import Testing
import XitDBDumpKit

@testable import XitDB

/// What the haxy app project, the client that asked for format version 2,
/// checks the package against (`director/request-from-haxy-app-format-v2.md`,
/// section 6): four databases that haxy and xit wrote with the original at
/// `89da8e7`, samples of real use and not byte-identity fixtures. They are
/// version 2 with SHA-1 hashes.
///
/// The files are in the conformance fixtures, under `samples/haxy`, with
/// the listing the original's `dump` prints for each. Everything in them
/// is throwaway test data, as their `README.md` says: one user, `alice`,
/// with the address `alice@example.com` and a password used nowhere else,
/// a repository, an issue and a comment, typed into haxy's forms on a
/// server run for the purpose.
///
/// Items 1 to 5 of that section are here. Item 6, that 0.2.1 still opens a
/// version 1 file this release has committed to, was checked once by hand.
@Suite struct ClientAcceptanceTests {
    static let names = ["admin", "user-repo", "project-repo", "users-index"]

    /// The commits each file holds, the first being the one that created
    /// it.
    static let commitCounts = ["admin": 8, "user-repo": 7, "project-repo": 6, "users-index": 3]

    static func url(_ name: String) throws -> URL {
        try #require(Bundle.module.resourceURL).appendingPathComponent("fixtures/samples/haxy/\(name).db")
    }

    static func bytes(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: try url(name)))
    }

    static func walk(_ database: Database) throws -> String {
        try StructureWalk.describe(database.rootCursor.readOnly)
    }

    /// Whether a dump's tree has a node the tool could not read, or one it
    /// cut short.
    static func isIncomplete(_ node: Node) -> Bool {
        if node.kind == .unreadable || node.kind == .truncated { return true }
        return node.children.contains { isIncomplete($0.node) }
    }

    // MARK: Item 1

    /// Each opens read-only without error, on the plain and the buffered
    /// file storage, with hash size 20, and reads the same through both.
    /// The header is what the request's evidence says: the magic, version
    /// 2, hash size 20, `sha1`, zeros at 20 to 23 and the file's own length
    /// at 24. Nothing requires the hash ID: the size alone is checked.
    @Test(arguments: names)
    func itOpensReadOnlyOnThePlainAndTheBufferedFile(name: String) throws {
        let path = try Self.url(name).path
        let bytes = try Self.bytes(name)
        #expect(Array(bytes[..<12]) == [0x78, 0x69, 0x74, 0x00, 0x00, 0x02, 0x00, 0x14, 0x73, 0x68, 0x61, 0x31])
        #expect(Array(bytes[20..<24]) == zeros(4))
        #expect(Array(bytes[24..<32]) == bigEndianBytes(UInt64(bytes.count)))

        let plain = try FileStorage(path: path, access: .readOnly)
        let buffered = try BufferedFileStorage(path: path, access: .readOnly)
        var walks: [String] = []
        for storage in [plain, buffered] as [any WritableStorage] {
            for hashSize in [20, nil] as [Int?] {
                let database = try Database(opening: storage, hashSize: hashSize)
                #expect(database.header.version == 2)
                #expect(database.header.hashSize == 20)
                #expect(database.header.hashID == "sha1")
                #expect(try database.committedSize == UInt64(bytes.count))
                walks.append(try Self.walk(database))
            }
            #expect(throws: XitDBError.invalidHashSize) { try Database(opening: storage, hashSize: 32) }
        }
        #expect(Set(walks).count == 1)
        #expect(walks[0].count > 50)
        #expect(try Self.bytes(name) == bytes)
    }

    // MARK: Item 2

    /// `xitdb-dump --verify` lists the file's commits, each with a trailer
    /// that verifies, the first ending at 57 as a new version 2 database
    /// does and the last at the file's end; and a dump of every moment
    /// walks every reachable value, with nothing unreadable and nothing cut
    /// short.
    @Test(arguments: names)
    func verifyListsItsCommitsAndTheWholeDumpReads(name: String) throws {
        let bytes = try Self.bytes(name)
        var options = DumpOptions()
        options.verify = true
        options.allMoments = true
        options.hash = .sha1
        var dumper = Dumper(options: options)
        let dump = dumper.dump(try FileStorage(path: try Self.url(name).path, access: .readOnly))

        #expect(dump.exitCode == 0)
        #expect(dump.header?.version == 2)
        #expect(dump.header?.hashSize == 20)
        #expect(dump.header?.hashIDText == "sha1")
        #expect(dump.header?.fileSize == UInt64(bytes.count))
        #expect(dump.header?.committedSize == UInt64(bytes.count))

        let verification = try #require(dump.verification)
        #expect(verification.commits.count == Self.commitCounts[name])
        #expect(verification.commits.first?.end == 57)
        #expect(verification.commits.last?.end == UInt64(bytes.count))
        #expect(verification.bytesPastLastCommit == nil)
        #expect(verification.commits.map(\.end) == verification.commits.map(\.end).sorted())

        #expect(!dump.moments.isEmpty)
        for moment in dump.moments {
            #expect(!Self.isIncomplete(moment.root), "moment \(moment.index)")
        }
        let text = TextRenderer.render(dump, options: options)
        #expect(!text.contains("unreadable"))
        var asJSON = options
        asJSON.json = true
        #expect(
            try JSONSerialization.jsonObject(with: Data(JSONRenderer.render(dump, options: asJSON).utf8))
                is [String: Any])
    }

    // MARK: Item 3

    /// What the port reads from each file is what the original reads, line
    /// for line: the listing the conformance repository's `dump` printed
    /// through the original, which is beside the file, against the same
    /// listing made here through the port. Nothing in either could not be
    /// read.
    @Test(arguments: names)
    func thePortReadsWhatTheOriginalReads(name: String) throws {
        let path = try Self.url(name).path
        let expected = String(
            decoding: try Data(contentsOf: try Self.url(name).deletingPathExtension().appendingPathExtension("txt")),
            as: UTF8.self)
        let listing = try OriginalListing.listing(ofFileAt: path)
        #expect(listing.errors == 0)
        #expect(!expected.contains(": error "))

        let ours = listing.text.split(separator: "\n", omittingEmptySubsequences: false)
        let theirs = expected.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(theirs.count > 10)
        let first = zip(ours, theirs).enumerated().first { $0.element.0 != $0.element.1 }
        if let first {
            Issue.record(
                "line \(first.offset + 1): the port reads '\(first.element.0)', the original '\(first.element.1)'")
        }
        #expect(ours.count == theirs.count)
        #expect(listing.text == expected)
    }

    // MARK: Item 4

    /// The dump of each file contains what was typed into haxy's forms: the
    /// issue's title and the comment in the project's database, the user in
    /// the admin database, the repository's name and description in the
    /// user's.
    ///
    /// The issue's body is two lines, `Line one` and `Line two`, in one
    /// value with a line feed between them, which the dump prints as text
    /// with the line feed written `\n`.
    @Test func theDumpsHoldWhatWasTypedIn() throws {
        let expected: [(String, [String])] = [
            (
                "project-repo",
                [
                    "bytes 11 \"First issue\"", "bytes 15 \"A first comment\"",
                    #"bytes 17 "Line one\nLine two""#,
                ]
            ),
            ("admin", ["bytes 5 \"alice\""]),
            ("user-repo", ["bytes 4 \"demo\"", "bytes 11 \"a test repo\""]),
        ]
        for (name, lines) in expected {
            let options = DumpOptions()
            var dumper = Dumper(options: options)
            let text = TextRenderer.render(dumper.dump(MemoryStorage(bytes: try Self.bytes(name))), options: options)
            for line in lines {
                #expect(text.contains(line), "\(name): \(line)")
            }
        }
    }

    // MARK: Item 5

    /// A snapshot taken from a version 2 database reads the same as the
    /// database, from a database of its own over it too, and serves the
    /// commit's bytes as the database does.
    @Test(arguments: names, [StorageKind.memory, .file, .bufferedFile])
    func aSnapshotReadsTheSameAsTheDatabase(name: String, kind: StorageKind) throws {
        let bytes = try Self.bytes(name)
        let subject = try StorageUnderTest(kind)
        try writeBytes(subject.storage, bytes, at: 0)
        try subject.storage.flush()
        let database = try Database(opening: subject.storage, hashSize: 20)
        let walk = try Self.walk(database)

        let snapshot = try database.snapshot()
        #expect(snapshot.header == database.header)
        #expect(snapshot.committedSize == UInt64(bytes.count))
        #expect(try StructureWalk.describe(snapshot.rootCursor) == walk)
        let reading = SnapshotDatabase(snapshot)
        #expect(try StructureWalk.describe(reading.rootCursor) == walk)
        #expect(try reading.replicaState == (try database.replicaState))
        #expect(try reading.readCommitted(from: 0, to: snapshot.committedSize) == bytes)
    }

    /// A version 2 database recovers: cut inside its last commit, opening
    /// names the commit before, and recovery leaves exactly the bytes that
    /// commit left, which open and read.
    @Test(arguments: names, [StorageKind.memory, .file, .bufferedFile])
    func itRecovers(name: String, kind: StorageKind) throws {
        let bytes = try Self.bytes(name)
        let ends = try Database.verifiedCommits(in: MemoryStorage(bytes: bytes)).map(\.end)
        let previous = try #require(ends.dropLast().last)

        let subject = try StorageUnderTest(kind)
        try writeBytes(subject.storage, Array(bytes.dropLast(3)), at: 0)
        try subject.storage.flush()
        #expect(throws: XitDBError.untrustedRootHeader(lastVerified: previous)) {
            try Database(opening: subject.storage, hashSize: 20)
        }
        let recovered = try Database.recover(subject.storage)
        #expect(recovered.header.version == 2)
        #expect(try recovered.committedSize == previous)
        try subject.storage.flush()
        var expected = Array(bytes[..<Int(previous)])
        expected.replaceSubrange(24..<32, with: bigEndianBytes(previous))
        #expect(firstDifference(try subject.stored(), expected) == nil)
        _ = try Self.walk(recovered)

        // and what it reads is what the whole file read at that commit
        let earlier = try Database(opening: MemoryStorage(bytes: expected), hashSize: 20)
        #expect(try Self.walk(recovered) == Self.walk(earlier))
    }

    /// A version 2 database compacts: the target is a version 2 database
    /// that holds the source's last moment, or its whole root where the
    /// root is not a history, and the source is left as it was.
    @Test(arguments: names, [StorageKind.memory, .file, .bufferedFile])
    func itCompacts(name: String, kind: StorageKind) throws {
        let bytes = try Self.bytes(name)
        let source = try Database(opening: MemoryStorage(bytes: bytes), hashSize: 20)
        let targetSubject = try StorageUnderTest(kind)
        var offsets = MemoryOffsetMap()
        let target = try source.compact(into: targetSubject.storage, fileID: 0x20, offsetMap: &offsets)
        #expect(target.header.version == 2)
        #expect(target.header.hashID == "sha1")
        #expect(try target.committedSize < UInt64(bytes.count))

        let root = try source.rootCursor.slot
        if root.tag == .arrayList {
            let sourceMoment = try #require(try ArrayList<ReadOnly>(source.rootCursor.readOnly).cursor(at: -1))
            let moments = try ArrayList<ReadOnly>(target.rootCursor.readOnly)
            #expect(try moments.count == 1)
            let targetMoment = try #require(try moments.cursor(at: 0))
            #expect(try StructureWalk.describe(targetMoment) == StructureWalk.describe(sourceMoment))
        } else {
            #expect(try Self.walk(target) == Self.walk(source))
        }
        let reopened = try Database(opening: targetSubject.storage, hashSize: 20)
        #expect(try Self.walk(reopened) == Self.walk(target))
    }

    /// A version 2 database replicates: a new replica is replaced by a sync
    /// from 0 up to an earlier commit, then brought up to date from its
    /// committed size, and ends as the source's bytes.
    @Test(arguments: names, [StorageKind.memory, .file, .bufferedFile])
    func itReplicates(name: String, kind: StorageKind) throws {
        let bytes = try Self.bytes(name)
        let source = try Database(opening: MemoryStorage(bytes: bytes), hashSize: 20)
        let ends = try Database.verifiedCommits(in: MemoryStorage(bytes: bytes)).map(\.end)
        let earlier = try #require(ends.dropLast().last)

        let subject = try StorageUnderTest(kind)
        let replica = try Database(creating: subject.storage, hashSize: 20)
        #expect(try source.replicationStart(for: try replica.replicaState) == 0)
        var first = ArrayByteSource(try source.readCommitted(from: 0, to: earlier))
        try replica.applyReplicated(at: 0, from: &first, count: earlier)
        #expect(replica.header == source.header)
        #expect(try replica.committedSize == earlier)

        let start = try source.replicationStart(for: try replica.replicaState)
        #expect(start == earlier)
        let end = try source.committedSize
        try replica.applyReplicated(at: start, bytes: try source.readCommitted(from: start, to: end))
        #expect(try replica.replicaState == (try source.replicaState))
        try subject.storage.flush()
        #expect(firstDifference(try subject.stored(), bytes) == nil)
        #expect(try Self.walk(replica) == Self.walk(source))
    }
}
