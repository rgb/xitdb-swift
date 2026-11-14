import Foundation
import Testing

@testable import XitDB

/// D24 item 3 as refined on 2026-11-09: after a freeze or a join, a write
/// through the transaction body's own cursor passes as an init does, in its
/// three forms, a plain `write`, a `writeIfEmpty` and a path that begins
/// with a write, whose later parts go on from there; the bytes are the Zig
/// original's for the same sequence, from `Resources/zig`. Every other
/// cursor from before the freeze stays refused, which `GuardTests` holds.
@Suite struct BodyCursorWriteTests {
    static let storageKinds = StorageKind.allCases

    /// What the Zig original wrote for the script of the same name.
    private func zigBytes(_ name: String) throws -> [UInt8] {
        // One component at a time: a component with a slash in it is not a
        // path on every platform's Foundation.
        let resources = try #require(Bundle.module.resourceURL)
        let file = resources.appendingPathComponent("zig").appendingPathComponent("\(name).db")
        return Array(try Data(contentsOf: file))
    }

    /// `write-first-after-freeze.json`: a `writeIfEmpty` through the body's
    /// cursor right after a freeze, on an empty element, writes; a plain
    /// write of none after a freeze empties the moment, and an init-first
    /// path makes it a map again; a write-first path after a freeze empties
    /// it and goes on to a fresh map with its later parts.
    @Test(arguments: storageKinds)
    func afterADatabaseFreeze(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(
            storage: subject.storage, hashSize: 20, hashID: nil, fileID: 7,
            random: FixedRandom([0x5f2c_a032_972b_eb99, 0x5fb9_b9f4_dffd_666e]))
        _ = try database.rootCursor.writePath([.arrayListInit, .arrayListAppend, .ctx]) { m in
            try database.freeze()
            try m.writeIfEmpty(.uint(5))
        }
        let last = try ArrayList<ReadOnly>(database.rootCursor).slot(at: -1)
        _ = try database.rootCursor.writePath([.arrayListInit, .arrayListAppend, .write(.slot(last)), .ctx]) { n in
            _ = try n.writePath([.write(.slot(nil)), .hashMapInit(), .hashMapGet(.value, sha1("a")), .write(.uint(1))])
            try database.freeze()
            try n.write(.slot(nil))
            _ = try n.writePath([.hashMapInit(), .hashMapGet(.value, sha1("b")), .write(.uint(2))])
            try database.freeze()
            _ = try n.writePath([.write(.slot(nil)), .hashMapInit(), .hashMapGet(.value, sha1("c")), .write(.uint(3))])
            _ = try n.writePath([.hashMapInit(), .hashMapGet(.value, sha1("d")), .write(.uint(4))])
        }
        let expected = try zigBytes("write-first-after-freeze")
        let actual = try wholeStorage(subject.storage)
        #expect(actual == expected, "lengths \(actual.count) and \(expected.count)")

        let history = try ArrayList<ReadOnly>(database.rootCursor)
        #expect(try history.count == 2)
        #expect(try history.cursor(at: 0)?.readUInt64() == 5)
        let moment = try HashMap<ReadOnly>(try #require(try history.cursor(at: 1)))
        #expect(try moment.cursor(forHash: sha1("a").bytes) == nil)
        #expect(try moment.cursor(forHash: sha1("b").bytes) == nil)
        #expect(try moment.cursor(forHash: sha1("c").bytes)?.readUInt64() == 3)
        #expect(try moment.cursor(forHash: sha1("d").bytes)?.readUInt64() == 4)
    }

    /// `write-first-after-join.json`: after a join, a `writeIfEmpty` through
    /// the body's cursor finds the moment's map and writes nothing, and is
    /// not refused; a plain write of none empties the moment; after a second
    /// join a write-first path empties it and goes on with its later parts.
    @Test(arguments: storageKinds)
    func afterAJoin(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(
            storage: subject.storage, hashSize: 20, hashID: nil, fileID: 8,
            random: FixedRandom([0x91fc_38b1_1688_0017, 0xa854_d4bb_f2ab_821c]))
        func linked(_ key: String) -> [PathPart] {
            [.hashMapInit(), .hashMapGet(.value, sha1(key)), .linkedArrayListInit]
        }
        _ = try database.rootCursor.writePath([.arrayListInit, .arrayListAppend, .write(.slot(nil)), .ctx]) { m in
            _ = try m.writePath(linked("la") + [.linkedArrayListAppend, .write(.uint(1))])
            _ = try m.writePath(linked("lb") + [.linkedArrayListAppend, .write(.uint(2))])
        }
        let last = try ArrayList<ReadOnly>(database.rootCursor).slot(at: -1)
        _ = try database.rootCursor.writePath([.arrayListInit, .arrayListAppend, .write(.slot(last)), .ctx]) { n in
            let lb = try n.writePath([.hashMapInit(), .hashMapGet(.value, sha1("lb"))])
            _ = try n.writePath(linked("la") + [.linkedArrayListConcat(try lb.slot)])
            try n.writeIfEmpty(.uint(9))
            try n.write(.slot(nil))
            _ = try n.writePath(linked("la") + [.linkedArrayListAppend, .write(.uint(3))])
            _ = try n.writePath(linked("lb") + [.linkedArrayListAppend, .write(.uint(4))])
            let lbAgain = try n.writePath([.hashMapInit(), .hashMapGet(.value, sha1("lb"))])
            _ = try n.writePath(linked("la") + [.linkedArrayListConcat(try lbAgain.slot)])
            _ = try n.writePath([.write(.slot(nil)), .hashMapInit(), .hashMapGet(.value, sha1("c")), .write(.uint(3))])
            _ = try n.writePath([.hashMapInit(), .hashMapGet(.value, sha1("d")), .write(.uint(4))])
        }
        let expected = try zigBytes("write-first-after-join")
        let actual = try wholeStorage(subject.storage)
        #expect(actual == expected, "lengths \(actual.count) and \(expected.count)")

        let history = try ArrayList<ReadOnly>(database.rootCursor)
        #expect(try history.count == 2)
        let first = try HashMap<ReadOnly>(try #require(try history.cursor(at: 0)))
        #expect(try LinkedArrayList<ReadOnly>(try #require(try first.cursor(forHash: sha1("la").bytes))).count == 1)
        let moment = try HashMap<ReadOnly>(try #require(try history.cursor(at: 1)))
        #expect(try moment.cursor(forHash: sha1("la").bytes) == nil)
        #expect(try moment.cursor(forHash: sha1("c").bytes)?.readUInt64() == 3)
        #expect(try moment.cursor(forHash: sha1("d").bytes)?.readUInt64() == 4)
    }
}
