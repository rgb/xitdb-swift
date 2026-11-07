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
        #expect(storage.bytes.count == 62)
        #expect(try database.committedSize == 62)

        _ = try database.rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .hashMapInit(),
            .hashMapGet(.value, sha1("foo")),
            .write(.uint(42)),
        ])

        #expect(try database.committedSize == 438)
        #expect(random.remaining == 0)
        #expect(!random.exhausted)
        return (storage.bytes, database)
    }

    /// With the commit ID Zig drew when the fixture was made, the file is
    /// the fixture, byte for byte.
    @Test func producesTheFileZigWrote() throws {
        let (bytes, _) = try run(commitID: 0xEF69_2113_3A4E_92A8)
        #expect(firstDifference(bytes, try fixtureFile("valid/worked-example.db")) == nil)
    }

    /// With the commit ID the document uses, the trailer is the one in the
    /// document's table, whose checksum was computed there with a separate
    /// implementation of the CRC. Everything before the trailer does not
    /// depend on the commit ID.
    @Test func producesTheTrailerInTheDocument() throws {
        let (bytes, _) = try run(commitID: 0x3035_85F7_ED65_083C)
        let fixture = try fixtureFile("valid/worked-example.db")
        // the root header at 20 and everything from 37 to the trailer
        #expect(Array(bytes[..<413]) == Array(fixture[..<413]))
        #expect(
            Array(bytes[413...])
                == hex("020000000000000047") + hex("303585f7ed65083c") + hex("3eddda5bf08686bc")
        )
    }

    @Test func readsBack() throws {
        let (_, database) = try run(commitID: 1)
        let moment = try #require(try database.rootCursor.readPath([.arrayListGet(-1)]))
        let value = try #require(try moment.readPath([.hashMapGet(.value, sha1("foo"))]))
        #expect(try value.readUInt64() == 42)
        #expect(try moment.readPath([.hashMapGet(.value, sha1("bar"))]) == nil)
        #expect(try database.rootCursor.count == 1)
        #expect(try database.rootCursor.slot == Slot(value: 71, tag: .arrayList))
    }
}
