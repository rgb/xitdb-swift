// What hashing a key costs, with no database: `XitDBBenchmark --hash-cost`.
//
// A keyed call is its call by hash and the hash, and for a short key the
// hash is the larger part. This measures the hash alone, for SHA-1 and
// SHA-256 and keys of 9, 64 and 1024 bytes, by each way of computing it:
//
//   loop          the loop over the keys with no hashing, to take off the rest
//   by_hand       the digest copied into an array, as the caller of a call
//                 by hash holds it: `Array(SHA256.hash(data: key))`
//   hasher        through the hasher a database holds, to the engine's hash:
//                 what a keyed call does
//   portable      the package's own implementation, which stands behind the
//                 public names where CryptoKit is not, into a buffer on the
//                 stack and from there into the engine's hash
//   cryptokit     CryptoKit called directly, the digest read where it is and
//                 put straight into the engine's hash (where CryptoKit is)
//   commoncrypto  the system's one-shot C routine, into a buffer on the stack
//                 and from there into the engine's hash (where it is)
//
// Every way but the first checks each hash against the one computed before
// the clock started, so the ways are held to one another and none can skip
// its work. One line of JSON for each, the median of five runs with the
// fastest and the slowest, in nanoseconds a key.

import Foundation
import XitDB
import XitDBHashing

#if canImport(CryptoKit)
    import CryptoKit
#endif
#if canImport(CommonCrypto)
    import CommonCrypto
#endif

/// The two hashes measured.
private enum MeasuredHash: String, CaseIterable {
    case sha1, sha256

    var size: Int { self == .sha1 ? 20 : 32 }

    /// The hash through `XitDBHashing`, as an array.
    func byHand(_ key: [UInt8]) -> [UInt8] {
        switch self {
        case .sha1: Array(XitDBHashing.Insecure.SHA1.hash(data: key))
        case .sha256: Array(XitDBHashing.SHA256.hash(data: key))
        }
    }

    /// The hash by the package's own implementation, appended to a buffer
    /// on the stack and from there put into the engine's hash: no array is
    /// made on the way.
    func portable(_ key: [UInt8]) -> KeyHash {
        switch self {
        case .sha1:
            let digest = InlineArray<20, UInt8> { (output: inout OutputSpan<UInt8>) in
                PortableSHA1.hash(key.span, into: &output)
            }
            return KeyHash(digest.span)
        case .sha256:
            let digest = InlineArray<32, UInt8> { (output: inout OutputSpan<UInt8>) in
                PortableSHA256.hash(key.span, into: &output)
            }
            return KeyHash(digest.span)
        }
    }

    /// The hasher a database given this hash holds.
    var hasher: KeyHasher {
        switch self {
        case .sha1: KeyHasher(XitDBHashing.Insecure.SHA1.self)
        case .sha256: KeyHasher(XitDBHashing.SHA256.self)
        }
    }
}

/// `count` different keys of `length` bytes: the index in decimal, then a
/// pattern that depends on it, so that no two keys share a block.
private func measuredKeys(length: Int, count: Int) -> [[UInt8]] {
    (0..<count).map { index in
        var key = Array("k\(index)-".utf8)
        var filler = UInt8(truncatingIfNeeded: index &* 31 &+ 7)
        while key.count < length {
            key.append(filler)
            filler = filler &* 5 &+ 1
        }
        return Array(key.prefix(length))
    }
}

#if canImport(CommonCrypto)
    /// CommonCrypto's SHA-1 is marked deprecated, as a warning against using
    /// SHA-1 for security; it is measured here beside the other ways and
    /// nothing is secured by it. A deprecated function may call it, and a
    /// requirement of a protocol may be witnessed by one.
    private protocol SystemOneShot {
        static func sha1(_ input: UnsafeRawBufferPointer, into output: UnsafeMutablePointer<UInt8>)
    }

    private enum CommonCryptoOneShot: SystemOneShot {
        @available(*, deprecated, message: "SHA-1 through CommonCrypto, for measuring only")
        static func sha1(_ input: UnsafeRawBufferPointer, into output: UnsafeMutablePointer<UInt8>) {
            _ = CC_SHA1(input.baseAddress, CC_LONG(input.count), output)
        }
    }

    private func systemSHA1<OneShot: SystemOneShot>(
        _ type: OneShot.Type, _ input: UnsafeRawBufferPointer, into output: UnsafeMutablePointer<UInt8>
    ) {
        OneShot.sha1(input, into: output)
    }

    /// The hash by the system's one-shot routine, into a buffer on the
    /// stack and from there into the engine's hash.
    private func commonCrypto(_ hash: MeasuredHash, _ key: [UInt8]) -> KeyHash {
        key.withUnsafeBytes { input in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: hash.size) { output in
                switch hash {
                case .sha1: systemSHA1(CommonCryptoOneShot.self, input, into: output.baseAddress!)
                case .sha256: _ = CC_SHA256(input.baseAddress, CC_LONG(input.count), output.baseAddress)
                }
                return KeyHash(UnsafeBufferPointer(output).span)
            }
        }
    }
#endif

#if canImport(CryptoKit)
    /// The hash by CryptoKit called directly on the array, the digest read
    /// where it is and put straight into the engine's hash.
    private func cryptoKit(_ hash: MeasuredHash, _ key: [UInt8]) -> KeyHash {
        switch hash {
        case .sha1:
            CryptoKit.Insecure.SHA1.hash(data: key).withUnsafeBytes { bytes in
                KeyHash(bytes.bindMemory(to: UInt8.self).span)
            }
        case .sha256:
            CryptoKit.SHA256.hash(data: key).withUnsafeBytes { bytes in
                KeyHash(bytes.bindMemory(to: UInt8.self).span)
            }
        }
    }
#endif

/// Runs `body` over the keys five times and returns the nanoseconds a key
/// of each run. `body` returns how many keys it found right.
private func nanosecondsPerKey(_ count: Int, _ body: () -> Int) -> [Double] {
    (0..<5).map { _ in
        let start = DispatchTime.now().uptimeNanoseconds
        let right = body()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        precondition(right == count, "\(count - right) keys hashed to another hash")
        return Double(elapsed) / Double(count)
    }
}

private func reportHashCost(_ hash: MeasuredHash, bytes: Int, way: String, count: Int, _ times: [Double]) {
    let sorted = times.sorted()
    print(
        String(
            format:
                #"{"measure": "hash_cost", "hash": "%@", "bytes": %ld, "way": "%@", "n": %ld, "median_ns": %.1f, "min_ns": %.1f, "max_ns": %.1f}"#,
            hash.rawValue, bytes, way, count, sorted[sorted.count / 2], sorted[0], sorted[sorted.count - 1]))
}

func runHashCost() {
    for hash in MeasuredHash.allCases {
        for (length, full) in [(9, 100_000), (64, 100_000), (1024, 20_000)] {
            let count = sized(full)
            let keys = measuredKeys(length: length, count: count)
            // Before the clock: the hash of every key, both as the array a
            // caller holds and as the engine holds it.
            let arrays = keys.map { hash.byHand($0) }
            let hashes = arrays.map { KeyHash($0) }

            reportHashCost(
                hash, bytes: length, way: "loop", count: count,
                nanosecondsPerKey(count) {
                    var right = 0
                    for index in keys.indices where keys[index].count == length && arrays[index].count == hash.size {
                        right += 1
                    }
                    return right
                })
            reportHashCost(
                hash, bytes: length, way: "by_hand", count: count,
                nanosecondsPerKey(count) {
                    var right = 0
                    for index in keys.indices where hash.byHand(keys[index]) == arrays[index] {
                        right += 1
                    }
                    return right
                })
            let hasher = hash.hasher
            reportHashCost(
                hash, bytes: length, way: "hasher", count: count,
                nanosecondsPerKey(count) {
                    var right = 0
                    for index in keys.indices where hasher.hash(keys[index]) == hashes[index] {
                        right += 1
                    }
                    return right
                })
            reportHashCost(
                hash, bytes: length, way: "portable", count: count,
                nanosecondsPerKey(count) {
                    var right = 0
                    for index in keys.indices where hash.portable(keys[index]) == hashes[index] {
                        right += 1
                    }
                    return right
                })
            #if canImport(CryptoKit)
                reportHashCost(
                    hash, bytes: length, way: "cryptokit", count: count,
                    nanosecondsPerKey(count) {
                        var right = 0
                        for index in keys.indices where cryptoKit(hash, keys[index]) == hashes[index] {
                            right += 1
                        }
                        return right
                    })
            #endif
            #if canImport(CommonCrypto)
                reportHashCost(
                    hash, bytes: length, way: "commoncrypto", count: count,
                    nanosecondsPerKey(count) {
                        var right = 0
                        for index in keys.indices where commonCrypto(hash, keys[index]) == hashes[index] {
                            right += 1
                        }
                        return right
                    })
            #endif
        }
    }
}
