// How a seed damages the sample database: the generator, the places it
// picks and the values it writes. Everything here is a function of the seed
// and the undamaged file alone, so that a seed names one damaged file for
// as long as the library builds the same sample.

import XitDB

/// A xorshift generator: small and the same on every machine, so that a seed
/// names the same damage everywhere.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    /// The generator for a seed. A xorshift state of zero stays zero, so
    /// the low bit is always set.
    init(seed: Int) {
        state = (UInt64(seed) &* 0x9E37_79B9_7F4A_7C15) | 1
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Collects the positions the targeted mode aims at: the file offsets held
/// by the slots `cursor` reaches, and those of the keys stored as byte
/// records, to a depth of eight and within a budget of cursors. A record, a
/// header or a block starts at each of them.
func harvestPositions<Access: CursorAccess>(
    from cursor: Cursor<Access>, depth: Int, budget: inout Int, into positions: inout [Int]
) {
    guard depth < 8, budget > 0 else { return }
    budget -= 1
    guard let slot = try? cursor.slot else { return }
    switch slot.tag {
    case .none, .uint, .int, .float, .shortBytes:
        break
    default:
        positions.append(Int(slot.value))
    }
    if let entry = try? cursor.readEntry() {
        if let key = try? entry.key.slot, key.tag == .bytes {
            positions.append(Int(key.value))
        }
        harvestPositions(from: entry.value, depth: depth + 1, budget: &budget, into: &positions)
    }
    if var iterator = try? cursor.iterator() {
        var visited = 0
        while visited < 400, let element = try? iterator.next() {
            visited += 1
            harvestPositions(from: element, depth: depth + 1, budget: &budget, into: &positions)
        }
    }
}

/// The positions reachable from the last moment of `sample`, each once and
/// in order.
///
/// - Throws: What opening the sample and reading its history throws, which
///   for the undamaged sample is nothing.
func harvestedPositions(of sample: [UInt8]) throws -> [Int] {
    var positions: [Int] = []
    var budget = 200_000
    let database = try Database(opening: MemoryStorage(bytes: sample))
    let history = try ArrayList<ReadOnly>(database.rootCursor)
    if let last = try history.cursor(at: -1) {
        harvestPositions(from: last, depth: 0, budget: &budget, into: &positions)
    }
    return Array(Set(positions)).sorted()
}

/// The eight-byte values a change may write: the edges of a size, a count
/// or a position, the file's own size and its neighbours, and where the
/// headers' parts are: the root header at 20; the committed size at 24, the
/// first data at 32 and a new database's end at 57 in format version 2,
/// which the sample is; and 37 and 62, the last two in version 1.
func interestingValues(fileSize: Int) -> [UInt64] {
    let size = UInt64(fileSize)
    return [
        0, 1, 2, 15, 16, 17, 255, 256, 1 << 32, 1 << 60, (1 << 60) + 1, 1 << 63, UInt64.max, UInt64.max - 1,
        UInt64.max - 15, size, size - 1, size - 9, 20, 24, 32, 57, 37, 62, UInt64.max - (1 << 60) + 2,
        UInt64(Int64.max), UInt64(Int64.max) + 1,
    ]
}

/// The sample database and what a seed may do to it.
struct DamagePlan {
    /// The undamaged file.
    let sample: [UInt8]

    /// Where targeted changes land, from ``harvestedPositions(of:)``.
    let positions: [Int]

    /// Whether a change lands near a harvested position or anywhere.
    let targeted: Bool

    /// The values of ``interestingValues(fileSize:)`` for the sample.
    let interesting: [UInt64]

    /// How far from a harvested position a targeted change lands: in the
    /// slot, the header or the block of the record that starts there.
    static let offsets = [0, 0, 0, 1, 2, 8, 8, 9, 10, 11, 16, 18, 19, 27, 146, 147, 155, 275, 283]

    init(sample: [UInt8], positions: [Int], targeted: Bool) {
        self.sample = sample
        self.positions = positions
        self.targeted = targeted
        interesting = interestingValues(fileSize: sample.count)
    }

    /// The sample with the one to three changes of `seed`. Each change sets
    /// a byte, flips a bit, or writes an interesting value big-endian at its
    /// place, pulled back so that it fits.
    func damaged(seed: Int) -> [UInt8] {
        var generator = SeededGenerator(seed: seed)
        var bytes = sample
        let changes = Int.random(in: 1...3, using: &generator)
        for _ in 0..<changes {
            var position = Int.random(in: 0..<bytes.count, using: &generator)
            if targeted, let base = positions.randomElement(using: &generator) {
                let offset = Self.offsets.randomElement(using: &generator) ?? 0
                let slots = Bool.random(using: &generator) ? 0 : 9 * Int.random(in: 0..<16, using: &generator)
                position = min(bytes.count - 1, base + offset + slots)
            }
            switch Int.random(in: 0..<4, using: &generator) {
            case 0:
                bytes[position] = UInt8.random(in: 0...255, using: &generator)
            case 1:
                bytes[position] ^= 1 << UInt8.random(in: 0..<8, using: &generator)
            default:
                let value = interesting.randomElement(using: &generator) ?? 0
                let start = min(position, bytes.count - 8)
                for index in 0..<8 {
                    bytes[start + index] = UInt8(truncatingIfNeeded: value >> (56 - 8 * UInt64(index)))
                }
            }
        }
        return bytes
    }
}
