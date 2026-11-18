import Testing
import XitDB
import XitDBHashing

@Suite("Iterating") struct IteratingExamples {
    /// "So does an element that was appended and never written, which is a
    /// slot set to nothing, for a number; a `String`, a `[UInt8]` or `Bytes`
    /// reads it as empty, with no error."
    @Test func anElementNeverWrittenReadAsAType() throws {
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let numbers = try ArrayList<ReadWrite>(database.rootCursor)
        try numbers.append(UInt64(1))
        // At the root the append is a transaction of its own, and the
        // element is left a slot set to nothing.
        _ = try numbers.appendCursor()
        #expect(try numbers.count == 2)
        #expect(try numbers.slot(at: 1)?.tag == Slot.Tag.none)

        // A number: the loop ends with the error, after the element before it.
        var given: [UInt64] = []
        var elements = try numbers.elements(as: UInt64.self)
        #expect(throws: XitDBError.unexpectedTag) {
            while let number = try elements.next() {
                given.append(number)
            }
        }
        #expect(given == [1])

        // Text and bytes read it as empty, with no error.
        let words = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let wordList = try ArrayList<ReadWrite>(words.rootCursor)
        try wordList.append("one")
        _ = try wordList.appendCursor()
        var read: [String] = []
        try wordList.forEachElement(as: String.self) { word in
            read.append(word)
        }
        #expect(read == ["one", ""])
        var bytes = try wordList.elements(as: [UInt8].self)
        #expect(try bytes.next() == Array("one".utf8))
        #expect(try bytes.next() == [])
        #expect(try bytes.next() == nil)
        var asBytes = try wordList.elements(as: Bytes.self)
        #expect(try asBytes.next() != nil)
        #expect(try asBytes.next() == Bytes([]))
    }
}
