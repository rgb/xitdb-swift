/// The CRC-64/XZ checksum: reflected polynomial `0xC96C5795D7870F42`, initial
/// value and final XOR all ones.
///
/// It is computed a byte at a time from a table of 256 entries, made the
/// first time a checksum is needed. The format checksums the 33 bytes
/// behind a root trailer: once per commit, and once more each time the
/// root is read through its trailer, which a transaction does several
/// times. Bit by bit, that was a fifth of a small transaction.
struct CRC64XZ: Sendable {
    private var state: UInt64 = ~0

    /// For each byte value, the checksum state after that byte, from a
    /// state of zero.
    private static let table: InlineArray<256, UInt64> = {
        var table = InlineArray<256, UInt64>(repeating: 0)
        for byte in 0..<256 {
            var state = UInt64(byte)
            for _ in 0..<8 {
                // The mask is all ones when the low bit is set and zero
                // otherwise.
                let mask = 0 &- (state & 1)
                state = (state >> 1) ^ (0xC96C_5795_D787_0F42 & mask)
            }
            table[byte] = state
        }
        return table
    }()

    /// Adds one byte to the checksum.
    mutating func update(_ byte: UInt8) {
        state = (state >> 8) ^ Self.table[Int(byte ^ UInt8(truncatingIfNeeded: state))]
    }

    /// Adds `count` bytes of `bytes`, starting at `offset`.
    mutating func update(_ bytes: Span<UInt8>, at offset: Int, count: Int) {
        for index in offset..<(offset + count) {
            update(bytes[index])
        }
    }

    /// Adds an integer's eight bytes in big-endian order.
    mutating func updateBigEndian(_ value: UInt64) {
        var shift = 64
        while shift > 0 {
            shift -= 8
            update(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    /// The checksum of everything added so far.
    var checksum: UInt64 {
        ~state
    }

    /// The checksum of `bytes`.
    static func checksum(of bytes: Span<UInt8>) -> UInt64 {
        var crc = CRC64XZ()
        crc.update(bytes, at: 0, count: bytes.count)
        return crc.checksum
    }
}
