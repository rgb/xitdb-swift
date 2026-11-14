import Testing
import XitDB
import XitDBHashing

@Suite("Large byte arrays") struct LargeByteArraysExamples {
    private func newMoment(_ body: (HashMap<ReadWrite>) throws -> Void) throws -> HashMap<ReadOnly> {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(nil)) { cursor in
            try body(try HashMap<ReadWrite>(cursor))
        }
        return try HashMap<ReadOnly>(history.cursor(at: -1)!)
    }

    private func newLongText() throws -> HashMap<ReadOnly> {
        try newMoment { moment in
            var cursor = try moment.putCursor(forKey: "long-text")
            try cursor.writeBytes { writer in
                for _ in 0..<50 {
                    try writer.write(Array("hello, world!\n".utf8))
                }
            }
        }
    }

    @Test func writingAPartAtATime() throws {
        let moment = try newLongText()
        #expect(try moment.cursor(forKey: "long-text")!.count == 700)
    }

    @Test func readingAPartAtATime() throws {
        let moment = try newLongText()

        var reader = try moment.cursor(forKey: "long-text")!.reader()
        var buffer = [UInt8](repeating: 0, count: 1024)
        var span = buffer.mutableSpan

        var lines = 0
        var count = try reader.read(into: &span)
        while count > 0 {
            for index in 0..<count where span[index] == UInt8(ascii: "\n") {
                lines += 1
            }
            count = try reader.read(into: &span)
        }
        #expect(lines == 50)
        #expect(reader.size == 700)
        #expect(reader.position == 700)
    }

    @Test func readingOnePart() throws {
        let moment = try newLongText()

        // The second line: seek to it, and read exactly its length.
        var reader = try moment.cursor(forKey: "long-text")!.reader()
        reader.seek(to: 14)

        var line = [UInt8](repeating: 0, count: 14)
        var span = line.mutableSpan
        try reader.readAll(into: &span)
        #expect(String(decoding: line, as: UTF8.self) == "hello, world!\n")

        // And the rest, whatever is left of it, with a limit on how much.
        let rest = try reader.readRemaining(maxCount: 1024)
        #expect(rest.count == 700 - 28)
    }

    @Test func fillingABufferNeedsTheBytes() throws {
        let moment = try newMoment { moment in
            try moment.put("hello, world", forKey: "short")
        }
        var reader = try moment.cursor(forKey: "short")!.reader()
        var buffer = [UInt8](repeating: 0, count: 100)
        var span = buffer.mutableSpan
        #expect(throws: XitDBError.endOfStream) {
            try reader.readAll(into: &span)
        }
        #expect(reader.position == 12)
    }

    @Test func aFormatTagOnAWrittenValue() throws {
        let moment = try newMoment { moment in
            var cursor = try moment.putCursor(forKey: "photo")
            try cursor.writeBytes(formatTag: "jp") { writer in
                try writer.write([0xFF, 0xD8, 0xFF])
            }

            // The body can decide on the tag once it has seen the bytes.
            var other = try moment.putCursor(forKey: "other")
            try other.writeBytes { writer in
                try writer.write(Array("GIF89a".utf8))
                writer.formatTag = "gi"
            }
        }

        let photo = try moment.cursor(forKey: "photo")!.readBytesWithFormatTag()
        #expect(photo.formatTag == "jp")
        #expect(try moment.cursor(forKey: "other")!.readBytesWithFormatTag().formatTag == "gi")
    }

    @Test func seekingWhileWriting() throws {
        let moment = try newMoment { moment in
            var cursor = try moment.putCursor(forKey: "record")
            try cursor.writeBytes { writer in
                // Room for a length, written once it is known.
                try writer.write([0, 0])
                try writer.write(Array("payload".utf8))
                writer.seek(to: 0)
                try writer.write([0, 7])
            }
        }
        let record = try moment.value(forKey: "record", as: [UInt8].self)
        #expect(record == [0, 7] + Array("payload".utf8))
    }

    /// A writer that fails has already appended the record it was filling,
    /// so its transaction is poisoned: nothing more can be written in it,
    /// and it rolls back when the body returns.
    @Test func aSeekBeyondAnyPosition() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let outcome = Result {
            try database.withTransaction { cursor in
                var value = try HashMap<ReadWrite>(cursor).putCursor(forKey: "value")
                #expect(throws: XitDBError.unexpectedWriterPosition) {
                    try value.writeBytes { writer in
                        writer.seek(to: UInt64.max - 1)
                        try writer.write([1, 2, 3, 4])
                    }
                }
            }
        }
        #expect(throws: XitDBError.poisonedTransaction) { try outcome.get() }
    }

    @Test func nothingElseWhileWriting() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let outcome = Result {
            try database.withTransaction { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                var value = try moment.putCursor(forKey: "value")
                #expect(throws: XitDBError.unexpectedWriterPosition) {
                    try value.writeBytes { writer in
                        try writer.write(Array("first".utf8))
                        try moment.put("something else", forKey: "other")
                        try writer.write(Array("second".utf8))
                    }
                }
            }
        }
        // the writer had written, so the transaction is poisoned and rolls back
        #expect(throws: XitDBError.poisonedTransaction) { try outcome.get() }
    }

    @Test func aFormatTagAfterAnotherWrite() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let outcome = Result {
            try database.withTransaction { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                var value = try moment.putCursor(forKey: "value")
                #expect(throws: XitDBError.unexpectedWriterPosition) {
                    try value.writeBytes { writer in
                        try writer.write(Array("first".utf8))
                        try moment.put("something else", forKey: "other")
                        writer.formatTag = "xx"
                    }
                }
            }
        }
        #expect(throws: XitDBError.poisonedTransaction) { try outcome.get() }
    }

    @Test func anotherWriteThatTheArrayDoesNotOutgrow() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            var value = try moment.putCursor(forKey: "value")
            try value.writeBytes { writer in
                try writer.write(Array("first".utf8))
                try moment.put("something else", forKey: "other")
                writer.seek(to: 0)
                try writer.write(Array("FI".utf8))
            }
            #expect(try value.readBytes() == Array("FIrst".utf8))
        }
    }

    @Test func aTransactionsBodyCanWriteBytesAtTheRoot() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        try database.withTransaction { cursor in
            try cursor.writeBytes { writer in
                try writer.write(Array("at the root".utf8))
            }
        }
        #expect(try database.rootCursor.readBytes() == Array("at the root".utf8))
    }

    private struct NoMoreBytes: Error {}

    /// The slot keeps its value; the bytes the body wrote stay behind, which
    /// poisons the transaction, so it rolls back as a whole.
    @Test func aBodyThatThrowsLeavesTheSlot() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let outcome = Result {
            try database.withTransaction { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                var value = try moment.putCursor(forKey: "value")
                try value.write(.uint(1))
                #expect(throws: NoMoreBytes.self) {
                    try value.writeBytes { writer in
                        try writer.write(Array("partial".utf8))
                        throw NoMoreBytes()
                    }
                }
                #expect(try moment.value(forKey: "value", as: UInt64.self) == 1)
                #expect(throws: XitDBError.poisonedTransaction) { try value.write(.uint(2)) }
            }
        }
        #expect(throws: XitDBError.poisonedTransaction) { try outcome.get() }
    }

    @Test func aBodyThatThrowsBeforeWritingPoisonsToo() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        #expect(throws: XitDBError.poisonedTransaction) {
            try database.withTransaction { cursor in
                var value = try HashMap<ReadWrite>(cursor).putCursor(forKey: "value")
                #expect(throws: NoMoreBytes.self) {
                    try value.writeBytes { _ in throw NoMoreBytes() }
                }
            }
        }
        #expect(try database.rootCursor.slot.isEmpty)
    }

    @Test func aFreezeInsideTheBodyIsByteWriterOpen() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        // Uncaught, the error comes out of the transaction, which rolls back.
        #expect(throws: XitDBError.byteWriterOpen) {
            try database.withTransaction { cursor in
                var value = try HashMap<ReadWrite>(cursor).putCursor(forKey: "value")
                try value.writeBytes { writer in
                    try writer.write([1, 2, 3])
                    try database.freeze()
                }
            }
        }
        #expect(try database.rootCursor.slot.isEmpty)
        // Caught, the transaction is poisoned.
        var caught: (any Error)?
        #expect(throws: XitDBError.poisonedTransaction) {
            try database.withTransaction { cursor in
                var value = try HashMap<ReadWrite>(cursor).putCursor(forKey: "value")
                do {
                    try value.writeBytes { writer in
                        try writer.write([1, 2, 3])
                        try database.freeze()
                    }
                } catch {
                    caught = error
                }
            }
        }
        #expect(caught as? XitDBError == .byteWriterOpen)
        #expect(try database.rootCursor.slot.isEmpty)

        // A join is a freeze too.
        let joins = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        #expect(throws: XitDBError.byteWriterOpen) {
            try joins.withTransaction { cursor in
                let moment = try HashMap<ReadWrite>(cursor)
                let tasks = try LinkedArrayList<ReadWrite>(moment.putCursor(forKey: "tasks"))
                let more = try LinkedArrayList<ReadWrite>(moment.putCursor(forKey: "more"))
                try tasks.append(.uint(1))
                try more.append(.uint(2))
                var value = try moment.putCursor(forKey: "value")
                try value.writeBytes { _ in try tasks.append(contentsOf: more) }
            }
        }
        #expect(try joins.rootCursor.slot.isEmpty)
    }

    @Test func aWrittenValueHasARecordHoweverShort() throws {
        let moment = try newMoment { moment in
            var cursor = try moment.putCursor(forKey: "hi")
            try cursor.writeBytes { writer in
                try writer.write(Array("hi".utf8))
            }
        }
        #expect(try moment.slot(forKey: "hi")!.tag == .bytes)
    }

    @Test func theRootCannotBeWrittenAPartAtATime() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        var root = database.rootCursor
        #expect(throws: XitDBError.cursorNotWritable) {
            try root.writeBytes { writer in
                try writer.write([1, 2, 3])
            }
        }
    }

    @Test func aReaderKeepsReadingWhatItWasMadeFrom() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let map = try HashMap<ReadWrite>(database.rootCursor)
        try map.put("the first value", forKey: "value")

        var reader = try map.cursor(forKey: "value")!.reader()
        try map.put("the second value", forKey: "value")

        #expect(try reader.readRemaining() == Array("the first value".utf8))
    }

    @Test func readingOtherSlots() throws {
        let moment = try newMoment { moment in
            try moment.put(UInt64(1), forKey: "number")
            try moment.put(.slot(nil), forKey: "nothing")
        }
        #expect(throws: XitDBError.unexpectedTag) {
            try moment.cursor(forKey: "number")!.reader()
        }
        var reader = try moment.cursor(forKey: "nothing")!.reader()
        #expect(reader.size == 0)
        #expect(try reader.readRemaining() == [])
    }
}
