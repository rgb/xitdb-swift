/// The CRC-64/XZ checksum: reflected polynomial `0xC96C5795D7870F42`, initial
/// value and final XOR all ones.
///
/// It is computed one bit at a time, without a lookup table. The only thing
/// the format checksums is the 33 bytes behind a root trailer, once per
/// commit, so a table would cost more than it saves.
struct CRC64XZ: Sendable {
    private var state: UInt64 = ~0

    /// Adds one byte to the checksum.
    mutating func update(_ byte: UInt8) {
        state ^= UInt64(byte)
        for _ in 0..<8 {
            // The mask is all ones when the low bit is set and zero otherwise.
            let mask = 0 &- (state & 1)
            state = (state >> 1) ^ (0xC96C_5795_D787_0F42 & mask)
        }
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
