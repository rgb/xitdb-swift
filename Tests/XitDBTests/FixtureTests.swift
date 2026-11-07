import Foundation
import Testing

@testable import XitDB

/// Reads the headers and trailers of `test.db`, the fixture shared by the Go,
/// Java and TypeScript ports. It was written with SHA-1 hashes.
@Suite struct FixtureTests {
    static func load() throws -> [UInt8] {
        let url = try #require(Bundle.module.url(forResource: "test", withExtension: "db"))
        return [UInt8](try Data(contentsOf: url))
    }

    @Test func fixtureIsTheSharedOne() throws {
        #expect(try Self.load().count == 8550)
    }

    @Test func databaseHeader() throws {
        let file = try Self.load()
        let header = try DatabaseHeader(decoding: file.span)
        #expect(header.version == 1)
        #expect(header.hashSize == 20)
        #expect(header.hashID == HashID(rawValue: 0))
        #expect(header.fileID == 0x172A_756F_2208_A5EC)

        // the header encodes back to the bytes it was decoded from
        #expect(encoded(capacity: 20) { header.encode(into: &$0) } == Array(file[0..<20]))
    }

    @Test func rootHeader() throws {
        let file = try Self.load()
        let rootHeader = try RootHeader(decoding: file.span, at: Int(RootHeader.position))
        #expect(rootHeader.root == Slot(value: 4847, tag: .arrayList))
        #expect(rootHeader.fileSize == 8550)
        #expect(rootHeader.fileSize == UInt64(file.count))
    }

    @Test func firstTrailer() throws {
        let file = try Self.load()
        let header = try DatabaseHeader(decoding: file.span)
        let position = RootHeader.minimumFileSize - RootTrailer.byteCount
        #expect(position == 37)

        let trailer = try RootTrailer(decoding: file.span, at: 37, fileID: header.fileID, position: position)
        #expect(trailer.root.isEmpty)
        #expect(trailer.root == Slot())
        #expect(trailer.commitID == 0)
        #expect(
            trailer.checksum
                == RootTrailer.checksum(
                    fileID: header.fileID,
                    position: position,
                    root: trailer.root,
                    commitID: trailer.commitID
                )
        )
    }

    @Test func lastTrailer() throws {
        let file = try Self.load()
        let header = try DatabaseHeader(decoding: file.span)
        let rootHeader = try RootHeader(decoding: file.span, at: Int(RootHeader.position))
        let position = rootHeader.fileSize - RootTrailer.byteCount
        #expect(position == 8525)

        let trailer = try RootTrailer(
            decoding: file.span,
            at: Int(position),
            fileID: header.fileID,
            position: position
        )
        #expect(trailer.root == rootHeader.root)
        #expect(
            trailer.checksum
                == RootTrailer.checksum(
                    fileID: header.fileID,
                    position: position,
                    root: trailer.root,
                    commitID: trailer.commitID
                )
        )
    }

    @Test func rootArrayListHeader() throws {
        let file = try Self.load()
        let list = try ArrayListHeader(decoding: file.span, at: 4847)
        #expect(list.size == 2)
        // on creation the root index block directly follows the header
        #expect(list.ptr == 4847 + ArrayListHeader.byteCount)
        let block = try IndexBlock(decoding: file.span, at: Int(list.ptr))
        #expect(!block.slots[0].isEmpty)
        #expect(!block.slots[1].isEmpty)
        #expect(array(block.slots)[2...].allSatisfy { $0.isEmpty })
    }
}
