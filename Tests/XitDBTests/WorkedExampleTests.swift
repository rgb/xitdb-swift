import Testing

@testable import XitDB

/// The worked example of the conformance script format (section 12): one
/// transaction that appends a hash map to a list at the root and puts one
/// value in it.
@Suite struct WorkedExampleTests {
    private func run(commitID: UInt64) throws -> (bytes: [UInt8], database: Database) {
        let storage = MemoryStorage()
        let random = FixedRandom([commitID])
        let database = try Database(
            storage: storage,
            hashSize: 20,
            hashID: "sha1",
            fileID: 0x0011_2233_4455_6677,
            random: random
        )
        #expect(storage.bytes.count == 57)
        #expect(try database.committedSize == 57)

        _ = try database.rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .hashMapInit(),
            .hashMapGet(.value, sha1("foo")),
            .write(.uint(42)),
        ])

        #expect(try database.committedSize == 433)
        #expect(random.remaining == 0)
        #expect(!random.exhausted)
        return (storage.bytes, database)
    }

    /// With the commit ID Zig drew when the fixture was made, the file is
    /// the fixture, byte for byte.
    @Test func producesTheFileZigWrote() throws {
        let (bytes, _) = try run(commitID: 0x6A06_410C_5A28_7D4A)
        #expect(firstDifference(bytes, try fixtureFile("valid/worked-example.db")) == nil)
    }

    /// With the commit ID the document uses, the trailer has a checksum
    /// computed with a separate implementation of the CRC: CRC-64/XZ over
    /// the file ID, the trailer's position 408, the root slot and the
    /// commit ID, worked out bit by bit outside this package, by the same
    /// few lines that give the document's version 1 checksum,
    /// `3eddda5bf08686bc`, for its version 1 trailer at 413. Everything
    /// before the trailer does not depend on the commit ID.
    @Test func producesTheTrailerInTheDocument() throws {
        let (bytes, _) = try run(commitID: 0x3035_85F7_ED65_083C)
        let fixture = try fixtureFile("valid/worked-example.db")
        // the root header at 20 and everything from 32 to the trailer
        #expect(Array(bytes[..<408]) == Array(fixture[..<408]))
        #expect(
            Array(bytes[408...])
                == hex("020000000000000042") + hex("303585f7ed65083c") + hex("1a176fd7f219b5fc")
        )
    }

    @Test func readsBack() throws {
        let (_, database) = try run(commitID: 1)
        let moment = try #require(try database.rootCursor.readPath([.arrayListGet(-1)]))
        let value = try #require(try moment.readPath([.hashMapGet(.value, sha1("foo"))]))
        #expect(try value.readUInt64() == 42)
        #expect(try moment.readPath([.hashMapGet(.value, sha1("bar"))]) == nil)
        #expect(try database.rootCursor.count == 1)
        #expect(try database.rootCursor.slot == Slot(value: 66, tag: .arrayList))
    }
}
