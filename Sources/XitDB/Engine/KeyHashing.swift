/// A hash function that turns a key's bytes into the hash a hash map stores
/// the key by.
///
/// XitDB has no hash function of its own. A database is given a conformer
/// when it is made, with ``Database/init(creating:hashing:hashID:fileID:)``
/// or ``Database/init(opening:hashing:)``, and the calls of its hash maps
/// and sets that take a key hash the key's bytes with it. Its snapshots
/// take the conformer from it, and so does the target that a compaction
/// makes over a storage; a target the caller opened keeps the hasher it was
/// opened with. A database made without one takes hashes alone, which its
/// caller makes with a conformer's ``keyHash(of:)`` or in any other way.
/// The `XitDBHashing` target has SHA-256 and SHA-1.
///
/// A conformer is a number and a function: how many bytes every hash has,
/// and the hash of some bytes, appended where the database holds it. This
/// one adds the bytes up, which is no hash to keep keys apart by and shows
/// all there is to write:
///
/// ```swift
/// enum ByteSum: KeyHashing {
///     static let size = 1
///
///     static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>) {
///         var sum: UInt8 = 0
///         for index in bytes.indices { sum &+= bytes[index] }
///         output.append(sum)
///     }
/// }
/// ```
///
/// ``size`` is the hash size of a database created with the conformer, and
/// a database of another hash size is refused with
/// ``XitDBError/invalidHashSize`` when it is opened with it, before
/// anything but its header is read. A hash of the wrong size given to a
/// collection directly is refused by that call. Two keys with the same
/// hash name one entry, so a hash that is not secure against collisions is
/// for keys the caller controls.
public protocol KeyHashing: Sendable {
    /// The number of bytes in every hash, and the hash size a database
    /// must have for this hasher.
    static var size: Int { get }

    /// Appends the hash of `bytes` to `output`: ``size`` bytes.
    ///
    /// The same bytes must always give the same hash, on every run and
    /// every machine, since the hash is what a file's entries are stored
    /// under. The function is called from any thread.
    ///
    /// Appending fewer bytes than ``size`` makes a hash that the call it
    /// was made for refuses with ``XitDBError/invalidHashSize``. Appending
    /// more is a mistake in the conformer that no file can cause, and
    /// stops the program.
    ///
    /// - Parameters:
    ///   - bytes: The key's bytes.
    ///   - output: Where the hash goes. The database hands over the place
    ///     it keeps the hash in, so nothing is allocated on the way.
    static func hash(_ bytes: Span<UInt8>, into output: inout OutputSpan<UInt8>)
}

/// The hasher a database was given, as a value: its size, and the hash of
/// a key's bytes. The database, its snapshots and its cursors hold this one
/// value and no type parameter.
package struct KeyHasher: Sendable {
    /// The number of bytes in every hash: the conformer's
    /// ``KeyHashing/size``, read once when the hasher is made.
    package let size: Int

    private let hashing: any KeyHashing.Type

    /// The hasher of a conformer.
    package init<Hashing: KeyHashing>(_ type: Hashing.Type) {
        size = Hashing.size
        hashing = type
    }

    /// The hash of a key's bytes, written by the conformer into the hash
    /// itself: ``size`` bytes for a conformer that keeps its word, fewer
    /// for one that appends fewer.
    ///
    /// - Precondition: The conformer appends no more than ``size`` bytes.
    package func hash(_ bytes: [UInt8]) -> KeyHash {
        KeyHash(maximumCount: size) { (output: inout OutputSpan<UInt8>) in
            hashing.hash(bytes.span, into: &output)
        }
    }
}
