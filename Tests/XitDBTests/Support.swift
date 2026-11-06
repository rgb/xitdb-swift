@testable import XitDB

/// Swift Testing has a `Tag` type of its own, so a test file that imports both
/// modules cannot say `Tag` unqualified. Within the tests it means ours.
typealias Tag = XitDB.Tag

/// Runs an encoder and returns the bytes it appended.
///
/// The capacity is the number of bytes the encoder is expected to produce. An
/// encoder that appends more traps, so the tests also compare the count.
func encoded(capacity: Int, _ body: (inout OutputSpan<UInt8>) -> Void) -> [UInt8] {
    [UInt8](capacity: capacity) { output in
        body(&output)
    }
}

/// The elements of an inline array as an ordinary array, for comparing.
func array<let count: Int, Element>(_ values: InlineArray<count, Element>) -> [Element] {
    var result: [Element] = []
    for index in values.indices {
        result.append(values[index])
    }
    return result
}

/// The nine bytes of a slot.
func slotBytes(_ slot: Slot) -> [UInt8] {
    encoded(capacity: 9) { slot.encode(into: &$0) }
}

/// The eight big-endian bytes of an integer.
func bigEndianBytes(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - 8 * $0)) }
}

/// `count` zero bytes.
func zeros(_ count: Int) -> [UInt8] {
    [UInt8](repeating: 0, count: count)
}
