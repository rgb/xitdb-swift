/// A key, as the bytes that stand for it.
///
/// The calls of the maps and sets that take a key take any conformer. On
/// ``HashMap``, ``CountedHashMap``, ``HashSet`` and ``CountedHashSet`` the
/// key's bytes are hashed by the hasher the database was given, and the
/// hash names the entry. On ``SortedMap`` and ``SortedSet`` the bytes are
/// the key itself, kept in the collection and compared byte by byte, and
/// nothing is hashed. Either way two keys with the same bytes are one key,
/// whatever their types.
///
/// A `String` or a `Substring` is its UTF-8, with nothing added and
/// nothing normalised, so the bytes are the ones a program in any language
/// has for the same text; `[UInt8]` is itself, and ``Bytes`` is its value
/// without its format tag.
///
/// A type of your own gives its bytes. One whose raw value is a key
/// conforms by declaring the conformance, and is then the key its raw
/// value is, which keeps the names of a record's fields in one place:
///
/// ```swift
/// enum Field: String, KeyRepresentable {
///     case name, age
/// }
/// try person.put(.uint(25), forKey: Field.age)
/// ```
///
/// A database that was given no hasher has none of the hashed
/// collections' calls by key: each throws ``XitDBError/noKeyHashing``.
/// The calls that take a hash work on every database, and so do the
/// sorted collections' calls by key.
public protocol KeyRepresentable {
    /// The bytes that stand for the key: what a hashed collection hashes
    /// and a sorted one keeps.
    var keyBytes: [UInt8] { get }
}

extension String: KeyRepresentable {
    /// The string's UTF-8 bytes.
    public var keyBytes: [UInt8] { Array(utf8) }
}

extension Substring: KeyRepresentable {
    /// The substring's UTF-8 bytes.
    public var keyBytes: [UInt8] { Array(utf8) }
}

extension [UInt8]: KeyRepresentable {
    /// The array itself.
    public var keyBytes: [UInt8] { self }
}

extension Bytes: KeyRepresentable {
    /// The value's bytes. The format tag is not part of the key: a tagged
    /// value and an untagged one with the same bytes are one key.
    public var keyBytes: [UInt8] { value }
}

extension KeyRepresentable where Self: RawRepresentable, RawValue: KeyRepresentable {
    /// The raw value's bytes: the key a type with a raw value is, once it
    /// declares the conformance.
    public var keyBytes: [UInt8] { rawValue.keyBytes }
}

extension KeyHashing {
    /// The hash of a key, as an array of ``size`` bytes: what a database
    /// that was given this hasher computes for the key.
    ///
    /// A call that takes a key is its call by hash with this hash, so it is
    /// what to give a `forHash:` call in order to reach the entry a keyed
    /// call wrote, on a database opened without the hasher or where the
    /// hash is kept and used again:
    ///
    /// ```swift
    /// let hash = SHA256.keyHash(of: "alice")
    /// try ages.put(.uint(25), forHash: hash)
    /// let age = try ages.value(forKey: "alice", as: UInt64.self)
    /// ```
    ///
    /// The key's bytes are its ``KeyRepresentable/keyBytes``: for text its
    /// UTF-8, for an array of bytes the array.
    ///
    /// - Parameter key: The key.
    /// - Returns: The hash. A conformer that appends fewer bytes than its
    ///   ``size`` gives fewer here, which a call by hash refuses.
    public static func keyHash(of key: some KeyRepresentable) -> [UInt8] {
        let bytes = key.keyBytes
        return [UInt8](capacity: size) { (output: inout OutputSpan<UInt8>) in
            hash(bytes.span, into: &output)
        }
    }
}

extension KeyRepresentable {
    /// The key as the data that is stored where a key is stored: its bytes
    /// as a byte array, with the format tag of a ``Bytes`` key that has
    /// one.
    var keyData: WritableData {
        keyData(of: keyBytes)
    }

    /// ``keyData`` from the key's bytes where they are in hand already, so
    /// that a call which hashes the key and stores it asks for them once.
    ///
    /// - Parameter bytes: The key's ``keyBytes``.
    func keyData(of bytes: [UInt8]) -> WritableData {
        if let tagged = self as? Bytes {
            return .bytes(bytes, formatTag: tagged.formatTag)
        }
        return .bytes(bytes)
    }
}

extension Cursor {
    /// The hash of a key, by the hasher the cursor's database was given.
    ///
    /// - Throws: `noKeyHashing` if the database was given none.
    func keyHash(of key: some KeyRepresentable) throws(XitDBError) -> KeyHash {
        try engine.keyHash(of: key.keyBytes)
    }

    /// The hash of a key and the key as the data that is stored beside a
    /// value, from one asking for the key's bytes: what a put that stores
    /// its key needs.
    ///
    /// - Throws: `noKeyHashing` if the database was given no hasher.
    func keyHashAndData(of key: some KeyRepresentable) throws(XitDBError) -> (hash: KeyHash, data: WritableData) {
        let bytes = key.keyBytes
        return (try engine.keyHash(of: bytes), key.keyData(of: bytes))
    }
}
