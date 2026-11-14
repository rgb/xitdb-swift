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

extension KeyRepresentable {
    /// The key as the data that is stored where a key is stored: its bytes
    /// as a byte array, with the format tag of a ``Bytes`` key that has
    /// one.
    var keyData: WritableData {
        if let tagged = self as? Bytes {
            return .bytes(tagged.value, formatTag: tagged.formatTag)
        }
        return .bytes(keyBytes)
    }
}

extension Cursor {
    /// The hash of a key, by the hasher the cursor's database was given.
    ///
    /// - Throws: `noKeyHashing` if the database was given none.
    func keyHash(of key: some KeyRepresentable) throws(XitDBError) -> KeyHash {
        try engine.keyHash(of: key.keyBytes)
    }
}
