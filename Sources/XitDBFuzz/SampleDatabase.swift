// The sample database the fuzzer damages: a history of three moments, each
// a map that holds every kind of collection and values of every kind. It is
// built in memory at every start from the same operations, with a fixed
// file ID and commit IDs drawn from the fuzzer's own generator at a fixed
// seed, so that the undamaged file is the same bytes from one run to the
// next and a seed names the same damaged file, byte for byte, everywhere.

import CryptoKit
import XitDB

/// The hash of a key as the sample database stores it: the SHA-256 of the
/// text, repeated and cut to `size` bytes, for whatever hash size the
/// database has.
func hash(_ text: String, _ size: Int) -> [UInt8] {
    let digest = Array(SHA256.hash(data: Array(text.utf8)))
    return Array((digest + digest + digest).prefix(size))
}

/// The keys of each moment's map, which the read walk looks up by hash.
let keyNames = ["n", "short", "long", "a", "aa", "l", "hs", "cm", "cs", "sm", "ss"]

/// The seed of the generator the sample's commit IDs are drawn from. Any
/// constant does; changing it changes the commit ID and checksum of the
/// sample's trailers, and with them every file a seed names.
let sampleSeed = 7

/// Builds the sample database with hashes of `hashSize` bytes and returns
/// its bytes: the same bytes at every call, since the file ID is fixed and
/// the commit IDs come from ``SeededGenerator`` at ``sampleSeed``.
///
/// - Throws: What the library throws while building it, which for a hash
///   size from 1 to 65535 is nothing.
func buildSample(hashSize: Int) throws -> [UInt8] {
    let storage = MemoryStorage()
    let database = try Database(
        creating: storage, hashSize: hashSize, hashID: nil, fileID: 7, random: SeededGenerator(seed: sampleSeed))
    let history = try ArrayList<ReadWrite>(database.rootCursor)
    for round in 0..<3 {
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            try moment.put(.uint(UInt64(round)), forHash: hash("n", hashSize))
            try moment.put(.bytes(Array("short".utf8)), forHash: hash("short", hashSize))
            try moment.put(
                .bytes(Array("a long byte value \(round)".utf8), formatTag: "xx"), forHash: hash("long", hashSize))
            try moment.putKey(.bytes(Array("long".utf8)), forHash: hash("long", hashSize))

            let list = try ArrayList<ReadWrite>(moment.putCursor(forHash: hash("a", hashSize)))
            for index in 0..<20 {
                try list.append(.uint(UInt64(index)))
            }
            let longList = try ArrayList<ReadWrite>(moment.putCursor(forHash: hash("aa", hashSize)))
            for index in 0..<300 {
                if index % 50 == 0 {
                    try longList.append(.bytes(Array("elem number \(index) long".utf8)))
                } else {
                    try longList.append(.uint(UInt64(index)))
                }
            }
            let linked = try LinkedArrayList<ReadWrite>(moment.putCursor(forHash: hash("l", hashSize)))
            for index in 0..<40 {
                try linked.append(.uint(UInt64(index)))
            }
            try linked.insert(.bytes(Array("inserted long value".utf8)), at: 3)
            try linked.remove(at: 5)

            let set = try HashSet<ReadWrite>(moment.putCursor(forHash: hash("hs", hashSize)))
            for index in 0..<30 {
                try set.insert(.bytes(Array("k\(index)".utf8)), forHash: hash("k\(index)", hashSize))
            }
            let countedMap = try CountedHashMap<ReadWrite>(moment.putCursor(forHash: hash("cm", hashSize)))
            for index in 0..<30 {
                try countedMap.put(.uint(UInt64(index)), forHash: hash("k\(index)", hashSize))
            }
            let countedSet = try CountedHashSet<ReadWrite>(moment.putCursor(forHash: hash("cs", hashSize)))
            for index in 0..<10 {
                try countedSet.insert(.uint(UInt64(index)), forHash: hash("k\(index)", hashSize))
            }

            let sortedMap = try SortedMap<ReadWrite>(moment.putCursor(forHash: hash("sm", hashSize)))
            for index in 0..<60 {
                try sortedMap.put(.uint(UInt64(index)), forKey: Array("key-\(index)-long-enough-for-a-record".utf8))
            }
            for index in 0..<20 {
                try sortedMap.put(.uint(UInt64(index)), forKey: Array("k\(index)".utf8))
            }
            try sortedMap.remove(forKey: Array("k3".utf8))
            let sortedSet = try SortedSet<ReadWrite>(moment.putCursor(forHash: hash("ss", hashSize)))
            for index in 0..<40 {
                try sortedSet.insert(Array("s\(index)-long-key-long-key".utf8))
            }
        }
    }
    return storage.bytes
}
