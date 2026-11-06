/// Constants and index arithmetic shared by the hash trie and the array
/// list's radix trie. Both descend four bits at a time through blocks of
/// sixteen slots.
enum Trie {
    /// The number of bits of a hash or an index consumed at each level.
    static let bitsPerLevel: UInt64 = 4

    /// The number of slots in an index block, and the most entries a tree
    /// node can hold.
    static let slotsPerBlock: UInt64 = 16

    /// Selects the bits of one level.
    static let mask: UInt64 = 15

    /// The slot a hash selects at a level of a hash trie.
    ///
    /// Zig holds a hash as one wide integer and computes
    /// `(hash >> (level * 4)) & 0xF`. On disk that integer is big endian, so
    /// level 0 is the low four bits of the last byte, level 1 the high four
    /// bits of the last byte, level 2 the low four bits of the byte before
    /// it, and so on.
    ///
    /// - Parameters:
    ///   - hash: The hash's bytes, in the order they are stored in the file.
    ///   - level: The depth in the trie, starting at zero for the root block.
    /// - Returns: A slot index from 0 to 15.
    /// - Throws: `keyOffsetExceeded` if the hash has no bits left for
    ///   `level`, that is if `level` is at least twice the hash's size.
    static func index(ofHash hash: Span<UInt8>, level: Int) throws(XitDBError) -> Int {
        guard level >= 0, level < hash.count * 2 else { throw .keyOffsetExceeded }
        let byte = hash[hash.count - 1 - level / 2]
        return Int(level % 2 == 0 ? byte & 0x0F : byte >> 4)
    }

    /// The depth of an array list's trie, as a shift: zero when the last
    /// index fits in the root block, otherwise the whole part of the base-16
    /// logarithm of the last index.
    ///
    /// The slot used at a level with shift `s` is `(index >> (s * 4)) & 0xF`.
    ///
    /// - Parameter lastIndex: The index of the list's last element.
    static func arrayListShift(lastIndex: UInt64) -> UInt8 {
        guard lastIndex >= slotsPerBlock else { return 0 }
        let highestSetBit = UInt64.bitWidth - 1 - lastIndex.leadingZeroBitCount
        return UInt8(highestSetBit / 4)
    }
}
