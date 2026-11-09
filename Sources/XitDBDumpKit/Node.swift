// The tree a dump shows, rendered as text or as JSON.

/// One thing in a file: a value, a collection with its children, or what
/// stood in the way of reading one.
package struct Node: Equatable, Sendable {
    /// What the node is.
    package enum Kind: String, Equatable, Sendable {
        /// A slot with nothing in it.
        case empty
        /// A slot written as nothing: it was something once, or was cleared.
        case nothing
        case uint, int, float, bytes
        case map, set
        case countedMap = "counted map"
        case countedSet = "counted set"
        case list, linked
        case sortedMap = "sorted map"
        case sortedSet = "sorted set"
        /// A collection seen before in this dump: `text` names where.
        case shared
        /// A collection that contains itself: `text` names the place it
        /// repeats; it is not followed.
        case cycle
        /// Nesting past the depth limit.
        case truncated
        /// Something the file holds that could not be read: `text` says what
        /// went wrong.
        case unreadable
    }

    /// One child of a collection: an element or an entry.
    package struct Child: Equatable, Sendable {
        /// An element's index, `#3`.
        package var index: Int?
        /// An entry's hash, as stored; all zeros in a sorted collection.
        package var hash: [UInt8]?
        /// An entry's key, when the file stores it or `--keys` names it; a
        /// sorted collection's key always.
        package var name: String?
        /// A key that is bytes but not text, as hex.
        package var keyHex: String?
        package var node: Node

        package init(index: Int? = nil, hash: [UInt8]? = nil, name: String? = nil, keyHex: String? = nil, node: Node) {
            self.index = index
            self.hash = hash
            self.name = name
            self.keyHex = keyHex
            self.node = node
        }
    }

    package var kind: Kind
    /// The number as text, the bytes as text or hex, or the note.
    package var text: String?
    /// For bytes: how many, when more than the text shows.
    package var length: UInt64?
    /// For a byte array with a format tag: the tag.
    package var formatTag: String?
    /// For a collection: the count it keeps, or the number of children for
    /// one that keeps none.
    package var count: UInt64?
    /// Where the record begins in the file, for a value read from the file
    /// or a collection.
    package var position: UInt64?
    /// The record's size, where the format fixes it.
    package var size: UInt64?
    package var children: [Child] = []

    package init(_ kind: Kind, text: String? = nil) {
        self.kind = kind
        self.text = text
    }
}

/// The file as a whole: its header, its history and what was found.
package struct Dump: Equatable, Sendable {
    package struct Header: Equatable, Sendable {
        package var fileSize: UInt64
        package var committedSize: UInt64
        package var hashSize: Int
        /// The header's four-byte hash ID, a label its creator chose, which
        /// the format does not interpret: as text when its bytes are
        /// printable ASCII.
        package var hashIDText: String?
        /// The same four bytes as hex.
        package var hashIDHex: String
        package var fileID: String
        package var momentCount: UInt64?
    }

    package struct Moment: Equatable, Sendable {
        package var index: Int
        package var root: Node
    }

    package struct Commit: Equatable, Sendable {
        package var end: UInt64
        package var commitID: String
        package var rootTag: String
    }

    package struct Verification: Equatable, Sendable {
        package var commits: [Commit]
        package var fileSize: UInt64
        /// Nil when the last commit ends at the file's end.
        package var bytesPastLastCommit: UInt64?
    }

    package var header: Header?
    package var moments: [Moment] = []
    package var verification: Verification?
    /// What stood out: damage and what was done about it.
    package var notes: [String] = []
    /// 0 for a sound file, 1 for a damaged one that was partly dumped, 2 for
    /// a file that is not xitdb.
    package var exitCode: Int32 = 0
}
