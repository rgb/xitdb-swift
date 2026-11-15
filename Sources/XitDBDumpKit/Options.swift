// What a dump shows: the options of xitdb-dump, as the tool parses them and
// the tests set them.

import XitDB
import XitDBHashing

/// The options of a dump.
package struct DumpOptions: Sendable {
    /// The hash key names are hashed with, for `--keys` and for a `--path`
    /// step given by name.
    package enum Hash: String, Sendable {
        case sha256, sha1

        /// The hash of a key's bytes, the database's hash size long.
        package func hash(_ bytes: [UInt8]) -> [UInt8] {
            switch self {
            case .sha256: SHA256.keyHash(of: bytes)
            case .sha1: Insecure.SHA1.keyHash(of: bytes)
            }
        }
    }

    /// One step of `--path`: into a map or a set by a key's name or its
    /// hash, or by position into a list, a sorted map or a sorted set, which
    /// have an order; a negative position counts from the end.
    package enum PathStep: Equatable, Sendable {
        case key(String)
        case hash([UInt8])
        case index(Int)
    }

    /// The moment to show, negative from the end; nil for the last.
    package var moment: Int? = nil
    /// Every moment, with sharing between them marked.
    package var allMoments = false
    /// How deep to descend; nil for the tool's own limit.
    package var depth: Int? = nil
    /// Where to start under the moment's root.
    package var path: [PathStep] = []
    /// JSON instead of text.
    package var json = false
    /// Key names to label hash-only entries with.
    package var keys: [String] = []
    /// The hash `keys` and named path steps are hashed with.
    package var hash: Hash = .sha256
    /// Walk the commits' trailers and report them.
    package var verify = false
    /// Show each record's position and size.
    package var offsets = false
    /// Whole hashes instead of their first eight bytes.
    package var fullHashes = false
    /// The most elements or entries one collection shows; past it, a note
    /// stands in for the rest and names this option.
    package var limit = 100_000

    package init() {}

    /// The limit on nesting when `depth` is not given: deeper data is cut
    /// with a note, so that a damaged file that nests without end cannot
    /// run the tool out of stack.
    package static let defaultDepth = 200
}
