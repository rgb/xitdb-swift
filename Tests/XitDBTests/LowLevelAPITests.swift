import Testing

@testable import XitDB

// A port of `testLowLevelApi` from the Zig original (`src/test.zig`, lines 1313 to 2774), as far as the engine
// goes today. Zig runs it once for each of the memory, file and buffered-file databases (test.zig 38-67), so
// every test here takes the storage kind as its argument.
//
// Lines 2576-2599 call `testSlice`, `testConcat` and `testInsertAndRemove` (test.zig 958-1312) for several
// sizes and offsets. Those are ported in `LinkedArrayListTests`, with each call as a test case of its own.
//
// The tests are in the order of the Zig function, one for each of its top-level blocks, and each one says which
// lines it ports. The comments inside them are Zig's. Where Zig clears the storage and makes a database, a test
// makes a new storage and a database in it. Zig's allocator arguments and `defer allocator.free` lines have no
// counterpart, nor do the buffers it hands to `cursor.reader` and `cursor.writer`. Zig's
// `reader.interface.readSliceAll` is `readAll(into:)` here, `readSliceShort` is `read(into:)`, `takeInt(u8)` is
// a read of one byte, `allocRemaining` is `readRemaining(maxCount:)` and `seekTo` is `seek(to:)`.
//
// The port also has the tests that the fix branch of the Zig original (`xitdb-fixes`) added to this function,
// in the places that branch's test.zig has them. They pin three read behaviours that the Swift port has from
// the start (findings 8, 9 and 21 of the director's list of Zig behaviours to correct); the line numbers are
// those of the fix branch's test.zig at its commit d6f3fee:
//
// - 1672-1695, after "write bar -> shortstr" (commit 1486fbf): a reader gives the value its cursor was made
//   with, even if the slot was overwritten since. 1762-1774, in the "shorts" block (the same commit): a cursor
//   with no position can stream a short value.
// - 2506-2524, in "iterate over inner array_list" (commits f1550c2 and 7312ad8): a slot set to nothing reads
//   as empty bytes into any buffer, and streams as nothing.
//
// The fix branch's addition to `testSortedMap` (3650-3675 of its test.zig, commit 1486fbf: a short key of a
// sorted set, whose cursor has no position, read with a reader) is ported in `SortedMapTests`.
//
// Everything in lines 1313 to 2774 is ported.
//
// Beyond what Zig asserts, the tests check the length of the storage at the points where a run of the Zig test
// was made to print it (a copy of test.zig with prints added, run with Zig 0.17.1 against the lib.zig next to
// it): the lengths are the same on Zig's three kinds of database. They pin how much a transaction appends, which
// the values read back do not show: an engine that copied more than Zig does would still read back right. The
// numbers in the tests up to "iterate over inner hash_map" come from the fix branch (`xitdb-fixes`); the fix
// branch's extra transaction in "array_list of hash_maps" moves the numbers after it, so that block's are not
// the original's. The numbers in the four linked array list tests at the end come from the original repository
// (`xitdb`, at commit 6b93af1), whose concat the port reproduces.

/// Zig's "low level api" test: the path API used directly.
@Suite struct LowLevelAPITests {
    /// The storage kinds of the three databases Zig runs the test for.
    static let storageKinds: [StorageKind] = [.memory, .file, .bufferedFile]

    /// Zig's `MAX_READ_BYTES`.
    private let maxReadBytes = 1024

    /// Zig's `xitdb.SLOT_COUNT`.
    private let slotCount = Int64(Trie.slotsPerBlock)

    /// Zig's `error.CancelTransaction`.
    private struct CancelTransaction: Error {}

    /// Zig's `error.Fail`.
    private struct Fail: Error {}

    /// Zig's `error.InvalidHashAlgo`.
    private struct InvalidHashAlgo: Error {}

    /// Zig's `ArrayList(.read_write)` (lib.zig 4310-4399), which Swift does not have yet. Each method makes the
    /// one path call that the Zig method of the same name makes.
    private struct PathArrayList {
        let cursor: Cursor<ReadWrite>

        /// lib.zig 4314-4324.
        init(_ cursor: Cursor<ReadWrite>) throws {
            self.cursor = try cursor.writePath([.arrayListInit])
        }

        /// lib.zig 4334-4336.
        func count() throws -> UInt64 {
            try cursor.count
        }

        /// lib.zig 4352-4356.
        func getSlot(_ index: Int64) throws -> Slot? {
            try cursor.readPathSlot([.arrayListGet(index)])
        }

        /// lib.zig 4371-4376.
        func append(_ data: WritableData) throws {
            _ = try cursor.writePath([.arrayListAppend, .write(data)])
        }

        /// lib.zig 4378-4382.
        func appendCursor() throws -> Cursor<ReadWrite> {
            try cursor.writePath([.arrayListAppend])
        }

        /// lib.zig 4393-4397.
        func slice(_ size: UInt64) throws {
            _ = try cursor.writePath([.arrayListSlice(size: size)])
        }
    }

    /// Zig's `HashId.fromBytes(name)`.
    private func hashID(_ name: String) -> HashID {
        HashID(string: name)!
    }

    /// Zig's `(hashInt(text) & ~mask) | (other & mask)`, where the hashes are `u160` and `mask` is a `u64`.
    ///
    /// Zig computes `~mask` in sixty-four bits and widens the result to the hash's width with zeros, so nothing
    /// of the first twelve bytes of either hash gets through: they are zero in the result.
    private func maskedKey(_ text: String, mask: UInt64, with other: KeyHash) -> KeyHash {
        let hash = sha1(text).bytes
        let otherBytes = other.bytes
        var result = [UInt8](repeating: 0, count: 20)
        for index in 12..<20 {
            let maskByte = UInt8(truncatingIfNeeded: mask >> (8 * UInt64(19 - index)))
            result[index] = (hash[index] & ~maskByte) | (otherBytes[index] & maskByte)
        }
        return KeyHash(result)
    }

    /// Zig's `cursor.readBytes(&buffer)` with a buffer of `bufferSize` zero bytes: the part of the buffer that
    /// holds the value.
    private func readBytesIntoBuffer<Access>(_ cursor: Cursor<Access>, bufferSize: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var span = buffer.mutableSpan
        let count = try cursor.readBytes(into: &span)
        return Array(buffer[..<count])
    }

    /// Zig's `cursor.readBytesObject(&buffer)` with a buffer of `bufferSize` zero bytes: the part of the buffer
    /// that holds the value, and the value's format tag.
    private func readBytesObjectIntoBuffer<Access>(_ cursor: Cursor<Access>, bufferSize: Int) throws -> Bytes {
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var span = buffer.mutableSpan
        let read = try cursor.readBytesWithFormatTag(into: &span)
        return Bytes(Array(buffer[..<read.count]), formatTag: read.formatTag)
    }

    /// Zig's `reader.interface.readSliceAll(&buffer)` with a buffer of `size` zero bytes: the buffer, filled.
    private func readAll(_ reader: inout ByteReader, size: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: size)
        var span = buffer.mutableSpan
        try reader.readAll(into: &span)
        return buffer
    }

    /// Zig's `reader.interface.readSliceShort(&buffer)` with a buffer of `size` zero bytes: the number of bytes
    /// read, and the buffer.
    private func readShort(_ reader: inout ByteReader, size: Int) throws -> (count: Int, buffer: [UInt8]) {
        var buffer = [UInt8](repeating: 0, count: size)
        var span = buffer.mutableSpan
        let count = try reader.read(into: &span)
        return (count, buffer)
    }

    /// Reads a slot straight from the storage, behind the engine. Zig seeks `db.core.reader()` to the position
    /// and casts the nine bytes there, as a big-endian `u72`, to a `Slot`.
    private func storedSlot(_ storage: any WritableStorage, at position: UInt64) throws -> Slot {
        let bytes = try readBytes(storage, at: position, count: Int(Slot.byteCount))
        return try Slot(decoding: bytes.span)
    }

    /// test.zig 1314-1355: "open and re-open empty database".
    @Test(arguments: storageKinds)
    func opensAndReopensAnEmptyDatabase(kind: StorageKind) throws {
        // make empty database
        let subject = try StorageUnderTest(kind)
        _ = try Database(storage: subject.storage, hashSize: 20)

        // re-open without error
        _ = try Database(storage: subject.storage, hashSize: 20)

        // modify the magic number
        try writeBytes(subject.storage, [UInt8(ascii: "g")], at: 0)
        try subject.storage.flush()

        // re-open with error
        #expect(throws: XitDBError.invalidDatabase) {
            try Database(storage: subject.storage, hashSize: 20)
        }

        // modify the version
        let version = DatabaseHeader.currentVersion + 1
        try writeBytes(subject.storage, [UInt8(ascii: "x")], at: 0)
        try writeBytes(subject.storage, [UInt8(version >> 8), UInt8(version & 0xFF)], at: 4)
        try subject.storage.flush()

        // re-open with error
        #expect(throws: XitDBError.invalidVersion) {
            try Database(storage: subject.storage, hashSize: 20)
        }
    }

    /// test.zig 1357-1392: "save hash id in header".
    @Test(arguments: storageKinds)
    func savesTheHashIDInTheHeader(kind: StorageKind) throws {
        // make empty database
        let subject = try StorageUnderTest(kind)
        _ = try Database(storage: subject.storage, hashSize: 20, hashID: hashID("sha1"))

        // read header without initializing database
        let stored = try subject.stored()
        let header = try DatabaseHeader(decoding: stored.span)
        #expect(header.hashSize == 20)
        #expect(array(header.hashID.bytes) == utf8("sha1"))

        // determine the hashing algorithm
        enum HashAlgo {
            case sha1
            case sha256
            case sha512
        }
        let hashAlgo: HashAlgo
        switch header.hashID {
        case hashID("sha1"):
            hashAlgo = .sha1
        case hashID("sha2"):
            switch header.hashSize {
            case 32: hashAlgo = .sha256
            case 64: hashAlgo = .sha512
            default: throw XitDBError.invalidHashSize
            }
        default:
            throw InvalidHashAlgo()
        }
        #expect(hashAlgo == .sha1)
    }

    /// test.zig 1394-2177: "array_list of hash_maps". The block is one database from start to finish, each
    /// part reading what the parts before it wrote, so it is one test. It has the fix branch's two additions,
    /// after "write bar -> shortstr" and in the "shorts" block.
    @Test(arguments: storageKinds)
    func arrayListOfHashMaps(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)
        let rootCursor = database.rootCursor

        // write foo -> bar with a writer
        let fooKey = sha1("foo")
        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .hashMapInit(),
            .hashMapGet(.value, fooKey),
            .ctx,
        ]) { (cursor: inout Cursor<ReadWrite>) in
            #expect(try cursor.slot.tag == .none)
            try cursor.writeBytes { writer in
                try writer.write(utf8("bar"))
            }
            let root = cursor.database.rootCursor
            #expect(throws: XitDBError.nestedTopLevelWrite) {
                try root.writePath([.arrayListAppend])
            }
            #expect(throws: XitDBError.nestedTopLevelWrite) {
                try root.writePath([.arrayListSlice(size: 0)])
            }
        }

        // callbacks must run inside an appended moment
        do {
            // the callback runs inside a transaction on the root,
            // so the top-level write inside it is a nested one
            #expect(throws: XitDBError.nestedTopLevelWrite) {
                try rootCursor.writePath([.ctx]) { (cursor: inout Cursor<ReadWrite>) in
                    _ = try cursor.database.rootCursor.writePath([.arrayListAppend])
                }
            }
            #expect(try database.rootCursor.count == 1)
        }

        // read foo
        do {
            let barCursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .hashMapGet(.value, fooKey),
                ])
            )
            #expect(try barCursor.count == 3)
            let barValue = try barCursor.readBytes(maxCount: maxReadBytes)
            #expect(barValue == utf8("bar"))
        }

        // read foo from ctx
        do {
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .hashMapGet(.value, fooKey),
                .ctx,
            ]) { (cursor: inout Cursor<ReadWrite>) in
                #expect(try cursor.slot.tag != .none)

                let value = try cursor.readBytes(maxCount: maxReadBytes)
                #expect(value == utf8("bar"))

                var barReader = try cursor.reader()

                // read into buffer
                // Zig reads into the first three bytes of a ten-byte buffer, then into all ten
                #expect(try readAll(&barReader, size: 3) == utf8("bar"))
                barReader.seek(to: 0)
                let barBytes = try readShort(&barReader, size: 10)
                #expect(barBytes.count == 3)
                #expect(Array(barBytes.buffer[0..<3]) == utf8("bar"))

                // read one char at a time
                do {
                    barReader.seek(to: 0)

                    #expect(try readAll(&barReader, size: 1) == utf8("b"))

                    #expect(try readAll(&barReader, size: 1) == utf8("a"))

                    #expect(try readAll(&barReader, size: 1) == utf8("r"))

                    #expect(throws: XitDBError.endOfStream) { try readAll(&barReader, size: 1) }

                    barReader.seek(to: 1)
                    #expect(try readAll(&barReader, size: 1)[0] == UInt8(ascii: "a"))

                    barReader.seek(to: 0)
                    #expect(try readAll(&barReader, size: 1)[0] == UInt8(ascii: "b"))

                    barReader.seek(to: 4)
                    #expect(throws: XitDBError.endOfStream) { try readAll(&barReader, size: 1) }
                }
            }
        }

        // overwrite foo -> baz
        do {
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .hashMapGet(.value, fooKey),
                .ctx,
            ]) { (cursor: inout Cursor<ReadWrite>) in
                #expect(try cursor.slot.tag != .none)

                try cursor.writeBytes { writer in
                    try writer.write(utf8("x"))
                    try writer.write(utf8("x"))
                    try writer.write(utf8("x"))
                    writer.seek(to: 0)
                    try writer.write(utf8("b"))
                    writer.seek(to: 2)
                    try writer.write(utf8("z"))
                    writer.seek(to: 1)
                    try writer.write(utf8("a"))
                }

                let value = try cursor.readBytes(maxCount: maxReadBytes)
                #expect(value == utf8("baz"))
            }
        }

        // if error in ctx, db doesn't change
        do {
            let sizeBefore = try subject.storage.length

            do {
                _ = try rootCursor.writePath([
                    .arrayListInit,
                    .arrayListAppend,
                    .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                    .hashMapInit(),
                    .hashMapGet(.value, fooKey),
                    .ctx,
                ]) { (cursor: inout Cursor<ReadWrite>) in
                    try cursor.writeBytes { writer in
                        try writer.write(utf8("this value won't be visible"))
                    }
                    throw CancelTransaction()
                }
            } catch is CancelTransaction {
                // Zig: `error.CancelTransaction => {}`. Any other error leaves the test.
            }

            // read foo
            let valueCursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .hashMapGet(.value, fooKey),
                ])
            )
            let value = try valueCursor.readBytes(maxCount: nil)  // make sure null max size works
            #expect(value == utf8("baz"))

            // verify that the db is properly truncated back to its original size after error
            let sizeAfter = try subject.storage.length
            #expect(sizeBefore == sizeAfter)
            #expect(sizeAfter == 1212)  // as in a run of the Zig test

            // appending must clear the failed moment's slot, including its stored value
            let history = try PathArrayList(database.rootCursor)
            let countBefore = try history.count()
            #expect(try history.appendCursor().slot.isEmpty)
            #expect(try history.getSlot(-1) == nil)
            try history.slice(countBefore)
            try history.append(.uint(999))
            try history.slice(countBefore)
            #expect(try history.appendCursor().slot.isEmpty)
            #expect(try history.getSlot(-1) == nil)
            try history.slice(countBefore)
            #expect(countBefore == 3)  // as in a run of the Zig test, with the length after it
            #expect(try subject.storage.length == 2376)
        }

        // write bar -> longstring
        let barKey = sha1("bar")
        do {
            let barCursor = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .hashMapGet(.value, barKey),
                .write(.bytes(utf8("longstring"))),
            ])

            // the slot tag is .bytes because the byte array is > 8 bytes long
            #expect(try barCursor.slot.tag == .bytes)

            // writing again returns the same slot
            do {
                var nextBarCursor = try rootCursor.writePath([
                    .arrayListInit,
                    .arrayListAppend,
                    .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                    .hashMapInit(),
                    .hashMapGet(.value, barKey),
                ])
                try nextBarCursor.writeIfEmpty(.bytes(utf8("longstring")))
                #expect(barCursor.slotPointer.slot == nextBarCursor.slotPointer.slot)
            }

            // writing with write returns a new slot
            do {
                let nextBarCursor = try rootCursor.writePath([
                    .arrayListInit,
                    .arrayListAppend,
                    .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                    .hashMapInit(),
                    .hashMapGet(.value, barKey),
                    .write(.bytes(utf8("longstring"))),
                ])
                #expect(barCursor.slotPointer.slot != nextBarCursor.slotPointer.slot)
            }

            // read bar
            do {
                let readBarCursor = try #require(
                    try rootCursor.readPath([
                        .arrayListGet(-1),
                        .hashMapGet(.value, barKey),
                    ])
                )
                let barValue = try readBarCursor.readBytes(maxCount: maxReadBytes)
                #expect(barValue == utf8("longstring"))
            }
        }

        // write bar -> shortstr
        do {
            let barCursor = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .hashMapGet(.value, barKey),
                .write(.bytes(utf8("shortstr"))),
            ])

            // the slot tag is .short_bytes because the byte array is <= 8 bytes long
            #expect(try barCursor.slot.tag == .shortBytes)
            #expect(try barCursor.count == 8)

            // make sure .short_bytes can be read with a reader
            var barReader = try barCursor.reader()
            let barValue = try barReader.readRemaining(maxCount: maxReadBytes)
            #expect(barValue == utf8("shortstr"))
        }

        // a reader gives the value its cursor was made with, like readBytes,
        // even if the slot was overwritten since then
        do {
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .hashMapGet(.value, barKey),
                .ctx,
            ]) { (cursor: inout Cursor<ReadWrite>) in
                let oldCursor = cursor
                try cursor.write(.bytes(utf8("changed")))

                #expect(try readBytesIntoBuffer(oldCursor, bufferSize: 8) == utf8("shortstr"))
                var oldReader = try oldCursor.reader()
                let read = try readShort(&oldReader, size: 8)
                #expect(read.count == 8)
                #expect(read.buffer == utf8("shortstr"))
            }
        }

        // write bytes with a format tag
        do {
            // shortstr
            do {
                let barCursor = try rootCursor.writePath([
                    .arrayListInit,
                    .arrayListAppend,
                    .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                    .hashMapInit(),
                    .hashMapGet(.value, barKey),
                    .write(.bytes(utf8("shortstr"), formatTag: "st")),
                ])

                // the slot tag is .bytes because the byte array is > 8 bytes long including the format tag
                #expect(try barCursor.slot.tag == .bytes)
                #expect(try barCursor.count == 8)

                // read bar
                let readBarCursor = try #require(
                    try rootCursor.readPath([
                        .arrayListGet(-1),
                        .hashMapGet(.value, barKey),
                    ])
                )
                let bytes = try readBarCursor.readBytesWithFormatTag(maxCount: maxReadBytes)
                #expect(bytes.value == utf8("shortstr"))
                let tag = try #require(bytes.formatTag)
                #expect(tag == "st")

                // make sure .bytes can be read with a reader
                var barReader = try barCursor.reader()
                let barValue = try barReader.readRemaining(maxCount: maxReadBytes)
                #expect(barValue == utf8("shortstr"))
            }

            // shorts
            do {
                let barCursor = try rootCursor.writePath([
                    .arrayListInit,
                    .arrayListAppend,
                    .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                    .hashMapInit(),
                    .hashMapGet(.value, barKey),
                    .write(.bytes(utf8("shorts"), formatTag: "st")),
                ])

                // the slot tag is .short_bytes because the byte array is <= 8 bytes long including the format tag
                #expect(try barCursor.slot.tag == .shortBytes)
                #expect(try barCursor.count == 6)

                // read bar
                let readBarCursor = try #require(
                    try rootCursor.readPath([
                        .arrayListGet(-1),
                        .hashMapGet(.value, barKey),
                    ])
                )
                let bytes = try readBytesObjectIntoBuffer(readBarCursor, bufferSize: maxReadBytes)
                #expect(bytes.value == utf8("shorts"))
                let tag = try #require(bytes.formatTag)
                #expect(tag == "st")

                // make sure .short_bytes can be read with a reader
                var barReader = try barCursor.reader()
                let barValue = try barReader.readRemaining(maxCount: maxReadBytes)
                #expect(barValue == utf8("shorts"))

                // the value is in the slot, so a cursor with no position can be
                // read with a reader too. the format tag is not part of the value.
                let slotCursor = Cursor<ReadOnly>(
                    slotPointer: SlotPointer(position: nil, slot: try barCursor.slot),
                    database: database
                )
                var slotReader = try slotCursor.reader()
                let slotBytes = try readShort(&slotReader, size: 8)
                #expect(slotBytes.count == 6)
                #expect(Array(slotBytes.buffer[0..<6]) == utf8("shorts"))
                slotReader.seek(to: 4)
                let slotTail = try readShort(&slotReader, size: 8)
                #expect(slotTail.count == 2)
                #expect(Array(slotTail.buffer[0..<2]) == utf8("ts"))
            }

            // short
            do {
                let barCursor = try rootCursor.writePath([
                    .arrayListInit,
                    .arrayListAppend,
                    .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                    .hashMapInit(),
                    .hashMapGet(.value, barKey),
                    .write(.bytes(utf8("short"), formatTag: "st")),
                ])

                // the slot tag is .short_bytes because the byte array is <= 8 bytes long including the format tag
                #expect(try barCursor.slot.tag == .shortBytes)
                #expect(try barCursor.count == 5)

                // read bar
                let readBarCursor = try #require(
                    try rootCursor.readPath([
                        .arrayListGet(-1),
                        .hashMapGet(.value, barKey),
                    ])
                )
                let bytes = try readBytesObjectIntoBuffer(readBarCursor, bufferSize: maxReadBytes)
                #expect(bytes.value == utf8("short"))
                let tag = try #require(bytes.formatTag)
                #expect(tag == "st")

                // make sure .short_bytes can be read with a reader
                var barReader = try barCursor.reader()
                let barValue = try barReader.readRemaining(maxCount: maxReadBytes)
                #expect(barValue == utf8("short"))
            }
        }

        // read foo into stack-allocated buffer
        do {
            let barCursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .hashMapGet(.value, fooKey),
                ])
            )
            let barBufferValue = try readBytesIntoBuffer(barCursor, bufferSize: 3)
            #expect(barBufferValue == utf8("baz"))
        }

        // write bar and get slot to it
        let barSlot = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .hashMapInit(),
            .hashMapGet(.value, barKey),
            .write(.bytes(utf8("bar"))),
        ]).slotPointer.slot

        // overwrite foo -> bar using the bar slot
        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .hashMapInit(),
            .hashMapGet(.value, fooKey),
            .write(.slot(barSlot)),
        ])
        let barCursor = try #require(
            try rootCursor.readPath([
                .arrayListGet(-1),
                .hashMapGet(.value, fooKey),
            ])
        )
        let barValue = try barCursor.readBytes(maxCount: maxReadBytes)
        #expect(barValue == utf8("bar"))

        // can still read the old value
        let bazCursor = try #require(
            try rootCursor.readPath([
                .arrayListGet(-2),
                .hashMapGet(.value, fooKey),
            ])
        )
        let bazValue = try bazCursor.readBytes(maxCount: maxReadBytes)
        #expect(bazValue == utf8("baz"))

        // key not found
        let notFoundKey = sha1("this doesn't exist")
        #expect(
            try rootCursor.readPath([
                .arrayListGet(-1),
                .hashMapGet(.value, notFoundKey),
            ]) == nil
        )

        // write key that conflicts with foo the first two bytes
        let smallConflictMask: UInt64 = 0b1111_1111
        let smallConflictKey = maskedKey("small conflict", mask: smallConflictMask, with: fooKey)
        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .hashMapInit(),
            .hashMapGet(.value, smallConflictKey),
            .write(.bytes(utf8("small"))),
        ])

        // write key that conflicts with foo the first four bytes
        let conflictMask: UInt64 = 0b1111_1111_1111_1111
        let conflictKey = maskedKey("conflict", mask: conflictMask, with: fooKey)
        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .hashMapInit(),
            .hashMapGet(.value, conflictKey),
            .write(.bytes(utf8("hello"))),
        ])

        // read conflicting key
        let helloCursor = try #require(
            try rootCursor.readPath([
                .arrayListGet(-1),
                .hashMapGet(.value, conflictKey),
            ])
        )
        let helloValue = try helloCursor.readBytes(maxCount: maxReadBytes)
        #expect(helloValue == utf8("hello"))

        // we can still read foo
        let barCursor2 = try #require(
            try rootCursor.readPath([
                .arrayListGet(-1),
                .hashMapGet(.value, fooKey),
            ])
        )
        let barValue2 = try barCursor2.readBytes(maxCount: maxReadBytes)
        #expect(barValue2 == utf8("bar"))

        // overwrite conflicting key
        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .hashMapInit(),
            .hashMapGet(.value, conflictKey),
            .write(.bytes(utf8("goodbye"))),
        ])
        let goodbyeCursor = try #require(
            try rootCursor.readPath([
                .arrayListGet(-1),
                .hashMapGet(.value, conflictKey),
            ])
        )
        let goodbyeValue = try goodbyeCursor.readBytes(maxCount: maxReadBytes)
        #expect(goodbyeValue == utf8("goodbye"))

        // we can still read the old conflicting key
        let helloCursor2 = try #require(
            try rootCursor.readPath([
                .arrayListGet(-2),
                .hashMapGet(.value, conflictKey),
            ])
        )
        let helloValue2 = try helloCursor2.readBytes(maxCount: maxReadBytes)
        #expect(helloValue2 == utf8("hello"))

        // remove the conflicting keys
        do {
            // foo's slot is an .index slot due to the conflict
            do {
                let mapCursor = try #require(
                    try rootCursor.readPath([
                        .arrayListGet(-1)
                    ])
                )
                let indexPosition = try mapCursor.slot.value
                #expect(indexPosition == 7975)  // as in a run of the fix branch's Zig test
                #expect(try mapCursor.slot.tag == .hashMap)

                let slotSize = Slot.byteCount

                let index = UInt64(fooKey.bytes[19]) & Trie.mask
                let slotPosition = indexPosition + (slotSize * index)
                let slot = try storedSlot(subject.storage, at: slotPosition)

                #expect(slot.tag == .index)
            }

            // remove the small conflict key
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .hashMapRemove(smallConflictKey),
            ])

            // the conflict key still exists in history
            #expect(
                try rootCursor.readPath([
                    .arrayListGet(-2),
                    .hashMapGet(.value, smallConflictKey),
                ]) != nil
            )

            // the conflict key doesn't exist in the latest moment
            #expect(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .hashMapGet(.value, smallConflictKey),
                ]) == nil
            )

            // the other conflict key still exists
            #expect(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .hashMapGet(.value, conflictKey),
                ]) != nil
            )

            // foo's slot is still an .index slot due to the other conflicting key
            do {
                let mapCursor = try #require(
                    try rootCursor.readPath([
                        .arrayListGet(-1)
                    ])
                )
                let indexPosition = try mapCursor.slot.value
                #expect(indexPosition == 9215)  // as in a run of the fix branch's Zig test
                #expect(try mapCursor.slot.tag == .hashMap)

                let slotSize = Slot.byteCount

                let index = UInt64(fooKey.bytes[19]) & Trie.mask
                let slotPosition = indexPosition + (slotSize * index)
                let slot = try storedSlot(subject.storage, at: slotPosition)

                #expect(slot.tag == .index)
            }

            // remove the conflict key
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .hashMapRemove(conflictKey),
            ])

            // the conflict keys don't exist in the latest moment
            #expect(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .hashMapGet(.value, smallConflictKey),
                ]) == nil
            )
            #expect(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .hashMapGet(.value, conflictKey),
                ]) == nil
            )

            // foo's slot is now a .kv_pair slot, because the branch was shortened
            do {
                let mapCursor = try #require(
                    try rootCursor.readPath([
                        .arrayListGet(-1)
                    ])
                )
                let indexPosition = try mapCursor.slot.value
                #expect(indexPosition == 9985)  // as in a run of the fix branch's Zig test
                #expect(try mapCursor.slot.tag == .hashMap)

                let slotSize = Slot.byteCount

                let index = UInt64(fooKey.bytes[19]) & Trie.mask
                let slotPosition = indexPosition + (slotSize * index)
                let slot = try storedSlot(subject.storage, at: slotPosition)

                #expect(slot.tag == .kvPair)
            }
        }

        do {
            // overwrite foo with a uint
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .hashMapGet(.value, fooKey),
                .write(.uint(42)),
            ])

            // read foo
            let uintValue = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .hashMapGet(.value, fooKey),
                ])
            ).readUInt64()
            #expect(uintValue == 42)
        }

        do {
            // overwrite foo with an int
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .hashMapGet(.value, fooKey),
                .write(.int(-42)),
            ])

            // read foo
            let intValue = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .hashMapGet(.value, fooKey),
                ])
            ).readInt64()
            #expect(intValue == -42)
        }

        do {
            // overwrite foo with a float
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .hashMapGet(.value, fooKey),
                .write(.double(42.5)),
            ])

            // read foo
            let floatValue = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .hashMapGet(.value, fooKey),
                ])
            ).readDouble()
            #expect(floatValue == 42.5)
        }

        // remove foo
        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .hashMapInit(),
            .hashMapRemove(fooKey),
        ])

        // remove key that does not exist
        #expect(throws: XitDBError.keyNotFound) {
            try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .hashMapRemove(sha1("doesn't exist")),
            ])
        }

        // make sure foo doesn't exist anymore
        #expect(
            try rootCursor.readPath([
                .arrayListGet(-1),
                .hashMapGet(.value, fooKey),
            ]) == nil
        )

        // non-top-level list
        do {
            // write apple
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .hashMapGet(.value, sha1("fruits")),
                .arrayListInit,
                .arrayListAppend,
                .write(.bytes(utf8("apple"))),
            ])

            // read apple
            let appleCursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .hashMapGet(.value, sha1("fruits")),
                    .arrayListGet(-1),
                ])
            )
            let appleValue = try appleCursor.readBytes(maxCount: maxReadBytes)
            #expect(appleValue == utf8("apple"))

            // write banana
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .hashMapGet(.value, sha1("fruits")),
                .arrayListInit,
                .arrayListAppend,
                .write(.bytes(utf8("banana"))),
            ])

            // read banana
            let bananaCursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .hashMapGet(.value, sha1("fruits")),
                    .arrayListGet(-1),
                ])
            )
            let bananaValue = try bananaCursor.readBytes(maxCount: maxReadBytes)
            #expect(bananaValue == utf8("banana"))

            // can't read banana in older array_list
            #expect(
                try rootCursor.readPath([
                    .arrayListGet(-2),
                    .hashMapGet(.value, sha1("fruits")),
                    .arrayListGet(1),
                ]) == nil
            )

            // write pear
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .hashMapGet(.value, sha1("fruits")),
                .arrayListInit,
                .arrayListAppend,
                .write(.bytes(utf8("pear"))),
            ])

            // write grape
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .hashMapGet(.value, sha1("fruits")),
                .arrayListInit,
                .arrayListAppend,
                .write(.bytes(utf8("grape"))),
            ])

            // read pear
            let pearCursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .hashMapGet(.value, sha1("fruits")),
                    .arrayListGet(-2),
                ])
            )
            let pearValue = try pearCursor.readBytes(maxCount: maxReadBytes)
            #expect(pearValue == utf8("pear"))

            // read grape
            let grapeCursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .hashMapGet(.value, sha1("fruits")),
                    .arrayListGet(-1),
                ])
            )
            let grapeValue = try grapeCursor.readBytes(maxCount: maxReadBytes)
            #expect(grapeValue == utf8("grape"))
        }

        // the length of the storage here in a run of the fix branch's Zig test, on every kind of storage
        #expect(try subject.storage.length == 14916)
    }

    /// test.zig 2179-2283: "append to top-level array_list many times, filling up the array_list until a root
    /// overflow occurs".
    @Test(arguments: storageKinds)
    func appendsToTheTopLevelArrayListUntilTheRootOverflows(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)
        let rootCursor = database.rootCursor

        let watKey = sha1("wat")
        for i in 0..<(slotCount + 1) {
            let value = "wat\(i)"
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .hashMapGet(.value, watKey),
                .write(.bytes(utf8(value))),
            ])
        }

        for i in 0..<(slotCount + 1) {
            let value = "wat\(i)"
            let cursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(i),
                    .hashMapGet(.value, watKey),
                ])
            )
            let value2 = try cursor.readBytes(maxCount: maxReadBytes)
            #expect(value2 == utf8(value))
        }

        // add more slots to cause a new index block to be created.
        // a new index block will be created when i == 32 (the 33rd append).
        // during that transaction, return an error so the transaction is
        // cancelled, causing truncation to happen. this test ensures that
        // the new index block is NOT truncated. this is prevented by updating
        // the file size in the header immediately after making a new index block.
        // see `readArrayListSlot` for more.
        do {
            var failed = false
            for i in (slotCount + 1)..<(slotCount * 2 + 1) {
                let value = "wat\(i)"

                do {
                    _ = try rootCursor.writePath([
                        .arrayListInit,
                        .arrayListAppend,
                        .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                        .hashMapInit(),
                        .hashMapGet(.value, watKey),
                        .write(.bytes(utf8(value))),
                        .ctx,
                    ]) { (_: inout Cursor<ReadWrite>) in
                        if i == 32 {
                            throw Fail()
                        }
                    }
                } catch is Fail {
                    failed = true
                    break
                }
            }
            // Zig: the loop's `else` branch, taken when it ends without the break, returns `error.ExpectedFail`
            try #require(failed)
            #expect(try subject.storage.length == 14542)  // as in a run of the Zig test

            // try another append to make sure we still can.
            // if truncation destroyed the index block, this would fail.
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .hashMapGet(.value, watKey),
                .write(.bytes(utf8("wat32"))),
            ])
        }

        // slice so it contains exactly SLOT_COUNT,
        // so we have the old root again
        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListSlice(size: UInt64(slotCount)),
        ])

        // we can iterate over the remaining slots
        for i in 0..<slotCount {
            let value = "wat\(i)"
            let cursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(i),
                    .hashMapGet(.value, watKey),
                ])
            )
            let value2 = try cursor.readBytes(maxCount: maxReadBytes)
            #expect(value2 == utf8(value))
        }

        // but we can't get the value that we sliced out of the array list
        #expect(
            try rootCursor.readPath([
                .arrayListGet(slotCount + 1)
            ]) == nil
        )

        // the length of the storage here in a run of the Zig test, on every kind of storage
        #expect(try subject.storage.length == 15400)
    }

    /// test.zig 2285-2397: "append to inner array_list many times, filling up the array_list until a root
    /// overflow occurs".
    @Test(arguments: storageKinds)
    func appendsToAnInnerArrayListUntilTheRootOverflows(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)
        let rootCursor = database.rootCursor

        for i in 0..<(slotCount + 1) {
            let value = "wat\(i)"
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .arrayListInit,
                .arrayListAppend,
                .write(.bytes(utf8(value))),
            ])
        }

        for i in 0..<(slotCount + 1) {
            let value = "wat\(i)"
            let cursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .arrayListGet(i),
                ])
            )
            let value2 = try cursor.readBytes(maxCount: maxReadBytes)
            #expect(value2 == utf8(value))
        }

        // slice inner array list so it contains exactly SLOT_COUNT,
        // so we have the old root again
        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .arrayListInit,
            .arrayListSlice(size: UInt64(slotCount)),
        ])

        // we can iterate over the remaining slots
        for i in 0..<slotCount {
            let value = "wat\(i)"
            let cursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .arrayListGet(i),
                ])
            )
            let value2 = try cursor.readBytes(maxCount: maxReadBytes)
            #expect(value2 == utf8(value))
        }

        // but we can't get the value that we sliced out of the array list
        #expect(
            try rootCursor.readPath([
                .arrayListGet(-1),
                .arrayListGet(slotCount + 1),
            ]) == nil
        )

        // overwrite last value with hello
        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .arrayListInit,
            .arrayListGet(-1),
            .write(.bytes(utf8("hello"))),
        ])

        // read last value
        do {
            let cursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .arrayListGet(-1),
                ])
            )
            let value = try cursor.readBytes(maxCount: maxReadBytes)
            #expect(value == utf8("hello"))
        }

        // overwrite last value with goodbye
        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .arrayListInit,
            .arrayListGet(-1),
            .write(.bytes(utf8("goodbye"))),
        ])

        // read last value
        do {
            let cursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .arrayListGet(-1),
                ])
            )
            let value = try cursor.readBytes(maxCount: maxReadBytes)
            #expect(value == utf8("goodbye"))
        }

        // previous last value is still hello
        do {
            let cursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-2),
                    .arrayListGet(-1),
                ])
            )
            let value = try cursor.readBytes(maxCount: maxReadBytes)
            #expect(value == utf8("hello"))
        }

        // the length of the storage here in a run of the Zig test, on every kind of storage
        #expect(try subject.storage.length == 8294)
    }

    /// test.zig 2399-2473: "iterate over inner array_list", with the fix branch's reads of the slot set to
    /// none.
    @Test(arguments: storageKinds)
    func iteratesOverAnInnerArrayList(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)
        let rootCursor = database.rootCursor

        // add wats
        for i in 0..<10 {
            let value = "wat\(i)"
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .arrayListInit,
                .arrayListAppend,
                .write(.bytes(utf8(value))),
            ])

            let cursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .arrayListGet(-1),
                ])
            )
            let value2 = try cursor.readBytes(maxCount: maxReadBytes)
            #expect(value2 == utf8(value))
        }

        // iterate over array_list
        do {
            let innerCursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1)
                ])
            )
            var iter = try innerCursor.iterator()
            var i = 0
            while let nextCursor = try iter.next() {
                let value = "wat\(i)"
                let value2 = try nextCursor.readBytes(maxCount: maxReadBytes)
                #expect(value2 == utf8(value))
                i += 1
            }
            #expect(i == 10)
        }

        // set first slot to .none and make sure iteration still works.
        // this validates that it correctly returns .none slots if
        // their flag is set, rather than skipping over them.
        do {
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .arrayListInit,
                .arrayListGet(0),
                .write(.slot(nil)),
            ])
            let innerCursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1)
                ])
            )
            var iter = try innerCursor.iterator()
            var i = 0
            while try iter.next() != nil {
                i += 1
            }
            #expect(i == 10)

            // a .none slot is read as an empty byte array,
            // whether or not the buffer has room for more
            let noneCursor = try #require(
                try innerCursor.readPath([
                    .arrayListGet(0)
                ])
            )
            #expect(try noneCursor.slot.tag == .none)
            let noneValue = try noneCursor.readBytes(maxCount: maxReadBytes)
            #expect(noneValue == [])
            #expect(try readBytesIntoBuffer(noneCursor, bufferSize: 8) == [])
            #expect(try readBytesIntoBuffer(noneCursor, bufferSize: 0) == [])
            #expect(try readBytesObjectIntoBuffer(noneCursor, bufferSize: 8).formatTag == nil)

            // and with a reader as an empty stream
            var noneReader = try noneCursor.reader()
            #expect(try readShort(&noneReader, size: 8).count == 0)
            noneReader.seek(to: 0)
            #expect(throws: XitDBError.endOfStream) { try readAll(&noneReader, size: 1) }
        }

        // get list slot
        let listCursor = try #require(
            try rootCursor.readPath([
                .arrayListGet(-1)
            ])
        )
        #expect(try listCursor.count == 10)

        // the length of the storage here in a run of the Zig test, on every kind of storage
        #expect(try subject.storage.length == 3956)
    }

    /// test.zig 2475-2574: "iterate over inner hash_map".
    @Test(arguments: storageKinds)
    func iteratesOverAnInnerHashMap(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)
        let rootCursor = database.rootCursor

        // add wats
        for i in 0..<10 {
            let value = "wat\(i)"
            let watKey = sha1(value)
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .hashMapInit(),
                .hashMapGet(.value, watKey),
                .write(.bytes(utf8(value))),
            ])

            let cursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1),
                    .hashMapGet(.value, watKey),
                ])
            )
            let value2 = try cursor.readBytes(maxCount: maxReadBytes)
            #expect(value2 == utf8(value))
        }

        // add foo
        let fooKey = sha1("foo")
        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .hashMapInit(),
            .hashMapGet(.key, fooKey),
            .write(.bytes(utf8("foo"))),
        ])
        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .hashMapInit(),
            .hashMapGet(.value, fooKey),
            .write(.uint(42)),
        ])

        // remove a wat
        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .hashMapInit(),
            .hashMapRemove(sha1("wat0")),
        ])

        // iterate over hash_map
        do {
            let innerCursor = try #require(
                try rootCursor.readPath([
                    .arrayListGet(-1)
                ])
            )
            var iter = try innerCursor.iterator()
            var i = 0
            while let kvPairCursor = try iter.next() {
                let kvPair = try kvPairCursor.readEntry()
                if kvPair.hash == fooKey.bytes {
                    let key = try kvPair.key.readBytes(maxCount: maxReadBytes)
                    #expect(key == utf8("foo"))
                    #expect(kvPair.value.slotPointer.slot.value == 42)
                } else {
                    let value = try kvPair.value.readBytes(maxCount: maxReadBytes)
                    #expect(kvPair.hash == sha1(String(decoding: value, as: UTF8.self)).bytes)
                }
                i += 1
            }
            #expect(i == 10)
        }

        // iterate over hash_map with writeable cursor
        do {
            let innerCursor = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            ])
            var iter = try innerCursor.iterator()
            var i = 0
            while let kvPairCursor = try iter.next() {
                let kvPair = try kvPairCursor.readEntry()
                if kvPair.hash == fooKey.bytes {
                    #expect(try kvPair.value.readUInt64() == 42)
                }
                i += 1
            }
            #expect(i == 10)
        }

        // the length of the storage here in a run of the Zig test, on every kind of storage
        #expect(try subject.storage.length == 6258)
    }

    // test.zig 2576-2599, the calls of `testSlice`, `testConcat` and `testInsertAndRemove`, are ported in
    // `LinkedArrayListTests`.

    /// test.zig 2601-2688: "concat linked_array_list multiple times".
    @Test(arguments: storageKinds)
    func concatsALinkedArrayListMultipleTimes(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)
        let rootCursor = database.rootCursor

        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .hashMapInit(),
            .ctx,
        ]) { (cursor: inout Cursor<ReadWrite>) in
            var values: [UInt64] = []

            // create list
            for i in 0..<UInt64(slotCount + 1) {
                let n = i * 2
                values.append(n)
                _ = try cursor.writePath([
                    .hashMapGet(.value, sha1("even")),
                    .linkedArrayListInit,
                    .linkedArrayListAppend,
                    .write(.uint(n)),
                ])
            }

            // get list slot
            let evenListCursor = try #require(
                try cursor.readPath([
                    .hashMapGet(.value, sha1("even"))
                ])
            )
            #expect(UInt64(slotCount + 1) == (try evenListCursor.count))

            // iterate over list
            let innerCursor = try #require(
                try cursor.readPath([
                    .hashMapGet(.value, sha1("even"))
                ])
            )
            var iter = try innerCursor.iterator()
            var i: UInt64 = 0
            while try iter.next() != nil {
                i += 1
            }
            #expect(UInt64(slotCount + 1) == i)

            // concat the list with itself multiple times.
            // since each list has 17 items, each concat
            // will create a gap, causing a root overflow
            // before a normal array list would've.
            var comboListCursor = try cursor.writePath([
                .hashMapGet(.value, sha1("combo")),
                .write(.slot(evenListCursor.slotPointer.slot)),
                .linkedArrayListInit,
            ])
            for _ in 0..<16 {
                comboListCursor = try comboListCursor.writePath([
                    .linkedArrayListConcat(evenListCursor.slotPointer.slot)
                ])
            }

            // each concat froze the transaction: the callback's cursor goes on
            // through the map's init, and what follows goes through the cursor
            // that gives (D18); Zig's test goes on through the cursor as it is
            let cursor = try cursor.writePath([.hashMapInit()])

            // append to the new list
            _ = try cursor.writePath([
                .hashMapGet(.value, sha1("combo")),
                .linkedArrayListAppend,
                .write(.uint(3)),
            ])

            // read the new value from the list
            #expect(
                try #require(
                    try cursor.readPath([
                        .hashMapGet(.value, sha1("combo")),
                        .linkedArrayListGet(-1),
                    ])
                ).slotPointer.slot.value == 3
            )

            // append more to the new list
            for _ in 0..<500 {
                _ = try cursor.writePath([
                    .hashMapGet(.value, sha1("combo")),
                    .linkedArrayListAppend,
                    .write(.uint(1)),
                ])
            }
        }

        // the length of the storage here. Zig's test, whose concat froze before its join, gave 20706 on every
        // kind of storage; here the concat freezes after it (finding 22), so the first append after the concats
        // copies the joined nodes it touches, and the map's init copies its root block once. The number is the
        // port's own, not Zig's.
        #expect(try subject.storage.length == 21398)
    }

    /// test.zig 2690-2718: "append items to linked_array_list without setting their value".
    @Test(arguments: storageKinds)
    func appendsItemsToALinkedArrayListWithoutSettingTheirValue(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)
        let rootCursor = database.rootCursor

        // appending without setting any value should work
        for _ in 0..<8 {
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .linkedArrayListInit,
                .linkedArrayListAppend,
            ])
        }

        // explicitly writing a null slot should also work
        for _ in 0..<8 {
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .linkedArrayListInit,
                .linkedArrayListAppend,
                .write(.slot(nil)),
            ])
        }

        // the length of the storage here in a run of the original's Zig test, on every kind of storage
        #expect(try subject.storage.length == 5758)
    }

    /// test.zig 2720-2745: "insert at beginning of linked_array_list many times".
    @Test(arguments: storageKinds)
    func insertsAtTheBeginningOfALinkedArrayListManyTimes(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)
        let rootCursor = database.rootCursor

        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .linkedArrayListInit,
            .linkedArrayListAppend,
            .write(.uint(42)),
        ])

        for i in 0..<UInt64(1_000) {
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .linkedArrayListInit,
                .linkedArrayListInsert(0),
                .write(.uint(i)),
            ])
        }

        // the length of the storage here in a run of the original's Zig test, on every kind of storage
        #expect(try subject.storage.length == 1_127_690)
    }

    /// test.zig 2747-2772: "insert at end of linked_array_list many times".
    @Test(arguments: storageKinds)
    func insertsAtTheEndOfALinkedArrayListManyTimes(kind: StorageKind) throws {
        let subject = try StorageUnderTest(kind)
        let database = try Database(storage: subject.storage, hashSize: 20)
        let rootCursor = database.rootCursor

        _ = try rootCursor.writePath([
            .arrayListInit,
            .arrayListAppend,
            .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
            .linkedArrayListInit,
            .linkedArrayListAppend,
            .write(.uint(42)),
        ])

        for i in 0..<UInt64(1_000) {
            _ = try rootCursor.writePath([
                .arrayListInit,
                .arrayListAppend,
                .write(.slot(try rootCursor.readPathSlot([.arrayListGet(-1)]))),
                .linkedArrayListInit,
                .linkedArrayListInsert(Int64(i)),
                .write(.uint(i)),
            ])
        }

        // the length of the storage here in a run of the original's Zig test, on every kind of storage
        #expect(try subject.storage.length == 1_134_666)
    }
}
