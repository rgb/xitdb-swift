import Testing

@testable import XitDB

/// Applies the same random sequence of operations to a storage and to a plain
/// array, and requires them to agree at every step.
///
/// This is the main test of the buffered file's window logic: with a small
/// window the sequence keeps hitting every way a write can meet the window.
@Suite struct StorageConformanceTests {
    static let seeds: [UInt64] = [1, 2, 3, 4, 5, 6, 7, 8]

    @Test(arguments: StorageKind.allCases, seeds)
    func agreesWithAPlainArray(kind: StorageKind, seed: UInt64) throws {
        let subject = try StorageUnderTest(kind)
        let storage = subject.storage
        var model: [UInt8] = []
        var random = SeededGenerator(seed: seed)

        for step in 0..<600 {
            let length = UInt64(model.count)
            switch Int.random(in: 0..<100, using: &random) {
            case 0..<45:
                // a write: mostly at the end, often inside, sometimes beyond
                let offset: UInt64
                switch Int.random(in: 0..<100, using: &random) {
                case 0..<50: offset = length
                case 50..<85: offset = UInt64.random(in: 0...length, using: &random)
                default: offset = length + UInt64.random(in: 1...300, using: &random)
                }
                let count =
                    Int.random(in: 0..<10, using: &random) == 0
                    ? Int.random(in: 300...3000, using: &random)
                    : Int.random(in: 0...120, using: &random)
                let bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &random) }
                try storage.write(bytes.span, at: offset)
                if !bytes.isEmpty {
                    let end = Int(offset) + count
                    if end > model.count {
                        model.append(contentsOf: [UInt8](repeating: 0, count: end - model.count))
                    }
                    model.replaceSubrange(Int(offset)..<end, with: bytes)
                }
            case 45..<75:
                // a read: anywhere, including across and beyond the end
                let offset = UInt64.random(in: 0...(length + 20), using: &random)
                let count = Int.random(in: 0...700, using: &random)
                let expected = offset < length ? Array(model[Int(offset)..<min(model.count, Int(offset) + count)]) : []
                let actual = try readBytes(storage, at: offset, count: count)
                #expect(actual == expected, "step \(step): read of \(count) at \(offset), length \(length)")
            case 75..<85:
                // a truncation, sometimes to the current length
                let newLength =
                    Int.random(in: 0..<4, using: &random) == 0 ? length : UInt64.random(in: 0...length, using: &random)
                try storage.truncate(to: newLength)
                model.removeLast(model.count - Int(newLength))
            case 85..<93:
                try storage.flush()
            default:
                try storage.sync(Bool.random(using: &random) ? .beforeRootHeader : .afterRootHeader)
            }
            #expect(try storage.length == UInt64(model.count), "step \(step)")
        }

        // everything, read back in one call and in small pieces
        #expect(try readBytes(storage, at: 0, count: model.count + 10) == model)
        var pieces: [UInt8] = []
        while pieces.count < model.count {
            let piece = try readBytes(storage, at: UInt64(pieces.count), count: 97)
            try #require(!piece.isEmpty)
            pieces.append(contentsOf: piece)
        }
        #expect(pieces == model)

        // and what has reached memory or the disk
        try storage.flush()
        #expect(try subject.stored() == model)
    }
}
