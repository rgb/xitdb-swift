// Codable onto the store: keyed containers are hash maps, unkeyed
// containers are array lists, single values the format's own.

import XitDB

/// Encodes an `Encodable` value at a handle: a keyed container becomes a
/// hash map keyed by the coding keys' names, hashed with the store's hash;
/// an unkeyed container an array list; a single value the format's scalar,
/// string or bytes.
///
/// Each entry of a keyed container also stores its key's name, so that
/// decoding can list the keys, which enums with associated values and
/// dictionaries do, and so that a dump or another implementation sees the
/// field names where a plain hashed map shows only hashes; a keyed entry
/// thus carries its key's bytes beside the hash, and a record costs its
/// field names once per entry. A map written by other means decodes only by
/// the keys the type asks for. A container is made when the type asks for
/// it, so a container with nothing in it leaves an empty map or list, and
/// an empty array or dictionary comes back empty. `encodeNil` writes
/// nothing at the key, `encodeIfPresent` with `nil` skips the key, so an
/// optional that is `nil` leaves no entry. Integers are stored as the
/// format's signed or unsigned 64-bit integers and come back exactly, or
/// decoding fails. A `[UInt8]` is stored as bytes, any other array as a
/// list. A nested value is a nested map or list; a class's superclass
/// encoder writes under the key `super`. Encoding at a place replaces what
/// was there, as ``Handle/set(_:)`` does: the place is cleared first.
public struct XitDBEncoder {
    let options: CodingOptions

    /// An encoder with the given strategies for the Foundation types that
    /// have a better form than their own: dates as seconds since 1970, data
    /// as bytes, URLs as strings, unless told to defer to the type.
    public init(
        dates: DateCodingStrategy = .secondsSince1970,
        data: DataCodingStrategy = .bytes,
        urls: URLCodingStrategy = .string
    ) {
        options = CodingOptions(dates: dates, data: data, urls: urls)
    }

    /// Encodes `value` at the handle's place, in place of whatever was
    /// there.
    ///
    /// At the moment's root place only a keyed value can go: a single value
    /// or an unkeyed one there is refused with `XitDBError.unexpectedTag`.
    ///
    /// - Throws: `XitDBError.expectedTxStart` in a read-only moment, the
    ///   error of a write that fails, or what the value's own `encode(to:)`
    ///   throws. Where the Codable protocols let a step throw nothing, the
    ///   step's error is kept and thrown when the encoding returns.
    public func encode(_ value: some Encodable, at handle: Handle) throws {
        try handle.clear()
        let fault = EncodingFault()
        try write(value, at: handle, codingPath: [], options: options, fault: fault)
        if let error = fault.first { throw error }
    }
}

/// Decodes a `Decodable` value from a handle: the inverse of
/// ``XitDBEncoder``, reading maps as keyed containers, lists as unkeyed
/// containers and the format's values as single values.
///
/// A key with no entry decodes as `nil` for an optional and fails with
/// `DecodingError.keyNotFound` otherwise; a value of another kind than the
/// one asked for, a list where a struct is expected included, fails with
/// `DecodingError.typeMismatch`; an integer that does not fit fails with
/// `DecodingError.dataCorrupted`.
public struct XitDBDecoder {
    let options: CodingOptions

    /// A decoder with the given strategies, which must be the ones the value
    /// was encoded with.
    public init(
        dates: DateCodingStrategy = .secondsSince1970,
        data: DataCodingStrategy = .bytes,
        urls: URLCodingStrategy = .string
    ) {
        options = CodingOptions(dates: dates, data: data, urls: urls)
    }

    /// The value of `type` at the handle's place, or nil if the place holds
    /// nothing.
    ///
    /// - Throws: A `DecodingError` for a shape or a value the type does not
    ///   take, an `XitDBError` of the reads, or what the type's own
    ///   `init(from:)` throws.
    public func decode<Value: Decodable>(_ type: Value.Type, at handle: Handle) throws -> Value? {
        guard try handle.exists else { return nil }
        return try read(type, at: handle, codingPath: [], options: options)
    }
}

/// The strategies an encoder or decoder runs with.
struct CodingOptions {
    let dates: DateCodingStrategy
    let data: DataCodingStrategy
    let urls: URLCodingStrategy
}

extension Handle {
    /// Encodes a value at this place with ``XitDBEncoder``'s defaults, in
    /// place of whatever was there.
    public func set(encoding value: some Encodable) throws {
        try XitDBEncoder().encode(value, at: self)
    }

    /// Decodes the value at this place with ``XitDBDecoder``'s defaults, or
    /// nil if the place holds nothing.
    public func value<Value: Decodable>(decoding type: Value.Type) throws -> Value? {
        try XitDBDecoder().decode(type, at: self)
    }
}

// MARK: - Encoding

/// The first error of an encoding step the Codable protocols let throw
/// nothing, a container's making or an element's appending: kept, and
/// thrown when the encoding returns.
final class EncodingFault {
    private(set) var first: (any Error)?

    func record(_ error: any Error) {
        if first == nil { first = error }
    }
}

/// The encoder at one place.
struct StoreEncoder: Encoder {
    let handle: Handle
    let codingPath: [any CodingKey]
    let options: CodingOptions
    let fault: EncodingFault
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(
            KeyedStoreEncoding(handle: handle, codingPath: codingPath, options: options, fault: fault))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        UnkeyedStoreEncoding(handle: handle, codingPath: codingPath, options: options, fault: fault)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        SingleValueStoreEncoding(handle: handle, codingPath: codingPath, options: options, fault: fault)
    }
}

/// Writes one value at a place: the scalars and strings directly, anything
/// else through its own `encode(to:)` at the place.
func write<Value: Encodable>(
    _ value: Value, at handle: Handle, codingPath: [any CodingKey], options: CodingOptions, fault: EncodingFault
) throws {
    if try writeFoundationValue(value, at: handle, codingPath: codingPath, options: options) { return }
    // By the static type: an empty array of anything passes a runtime cast
    // to [UInt8], and would be written as empty bytes.
    if Value.self == [UInt8].self, let bytes = value as? [UInt8] {
        try handle.set(bytes)
        return
    }
    switch value {
    case let value as Bool: try handle.set(value)
    case let value as String: try handle.set(value)
    case let value as Double: try handle.set(value)
    case let value as Float: try handle.set(Double(value))
    case let value as Int: try handle.set(Int64(value))
    case let value as Int8: try handle.set(Int64(value))
    case let value as Int16: try handle.set(Int64(value))
    case let value as Int32: try handle.set(Int64(value))
    case let value as Int64: try handle.set(value)
    case let value as UInt: try handle.set(UInt64(value))
    case let value as UInt8: try handle.set(UInt64(value))
    case let value as UInt16: try handle.set(UInt64(value))
    case let value as UInt32: try handle.set(UInt64(value))
    case let value as UInt64: try handle.set(value)
    default:
        try value.encode(to: StoreEncoder(handle: handle, codingPath: codingPath, options: options, fault: fault))
    }
}

/// A keyed container at a place: a hash map keyed by the keys' names, each
/// entry storing its name as the key, so that the keys can be listed. The
/// map is made with the container, so that one with no entries leaves an
/// empty map.
struct KeyedStoreEncoding<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let handle: Handle
    let codingPath: [any CodingKey]
    let options: CodingOptions
    let fault: EncodingFault

    init(handle: Handle, codingPath: [any CodingKey], options: CodingOptions, fault: EncodingFault) {
        self.handle = handle
        self.codingPath = codingPath
        self.options = options
        self.fault = fault
        do {
            _ = try HashMap<ReadWrite>(try handle.write())
        } catch {
            fault.record(error)
        }
    }

    /// The place for a key, its name stored in the entry.
    private func place(_ name: String) throws(XitDBError) -> Handle {
        let map = try HashMap<ReadWrite>(try handle.write())
        try map.putKey(.bytes(Array(name.utf8)), forHash: handle.hasher.hash(name))
        return handle[name]
    }

    /// The place for a key where the protocol allows no error: a failure is
    /// kept for the end of the encoding.
    private func placeRecording(_ name: String) -> Handle {
        do {
            return try place(name)
        } catch {
            fault.record(error)
            return handle[name]
        }
    }

    mutating func encodeNil(forKey key: Key) throws {
        try place(key.stringValue).clear()
    }

    mutating func encode(_ value: some Encodable, forKey key: Key) throws {
        try write(value, at: try place(key.stringValue), codingPath: codingPath + [key], options: options, fault: fault)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key)
        -> KeyedEncodingContainer<NestedKey>
    {
        KeyedEncodingContainer(
            KeyedStoreEncoding<NestedKey>(
                handle: placeRecording(key.stringValue), codingPath: codingPath + [key], options: options,
                fault: fault))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        UnkeyedStoreEncoding(
            handle: placeRecording(key.stringValue), codingPath: codingPath + [key], options: options, fault: fault)
    }

    mutating func superEncoder() -> any Encoder {
        StoreEncoder(
            handle: placeRecording("super"), codingPath: codingPath + [SuperKey()], options: options, fault: fault)
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        StoreEncoder(
            handle: placeRecording(key.stringValue), codingPath: codingPath + [key], options: options, fault: fault)
    }
}

/// An unkeyed container at a place: an array list, each value appended.
/// The list is made with the container, so that one with no elements
/// leaves an empty list.
struct UnkeyedStoreEncoding: UnkeyedEncodingContainer {
    let handle: Handle
    let codingPath: [any CodingKey]
    let options: CodingOptions
    let fault: EncodingFault
    private(set) var count = 0

    init(handle: Handle, codingPath: [any CodingKey], options: CodingOptions, fault: EncodingFault) {
        self.handle = handle
        self.codingPath = codingPath
        self.options = options
        self.fault = fault
        // The moment's root place is its map, and takes no list.
        guard !handle.steps.isEmpty else {
            fault.record(XitDBError.unexpectedTag)
            return
        }
        do {
            _ = try ArrayList<ReadWrite>(try handle.write())
        } catch {
            fault.record(error)
        }
    }

    /// The handle of a new element at the end.
    private mutating func next() throws -> Handle {
        let element = try handle.appendElement()
        count += 1
        return element
    }

    /// A new element where the protocol allows no error: a failure is kept
    /// for the end of the encoding.
    private mutating func nextRecording() -> Handle {
        do {
            return try next()
        } catch {
            fault.record(error)
            return handle[index: count]
        }
    }

    private var nextKey: IndexKey { IndexKey(intValue: count) }

    mutating func encodeNil() throws {
        try next().clear()
    }

    mutating func encode(_ value: some Encodable) throws {
        let key = nextKey
        try write(value, at: try next(), codingPath: codingPath + [key], options: options, fault: fault)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type)
        -> KeyedEncodingContainer<NestedKey>
    {
        let key = nextKey
        return KeyedEncodingContainer(
            KeyedStoreEncoding<NestedKey>(
                handle: nextRecording(), codingPath: codingPath + [key], options: options, fault: fault))
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let key = nextKey
        return UnkeyedStoreEncoding(
            handle: nextRecording(), codingPath: codingPath + [key], options: options, fault: fault)
    }

    mutating func superEncoder() -> any Encoder {
        let key = nextKey
        return StoreEncoder(handle: nextRecording(), codingPath: codingPath + [key], options: options, fault: fault)
    }
}

/// A single value at a place.
struct SingleValueStoreEncoding: SingleValueEncodingContainer {
    let handle: Handle
    let codingPath: [any CodingKey]
    let options: CodingOptions
    let fault: EncodingFault

    mutating func encodeNil() throws {
        try handle.clear()
    }

    mutating func encode(_ value: some Encodable) throws {
        try write(value, at: handle, codingPath: codingPath, options: options, fault: fault)
    }
}

// MARK: - Decoding

/// The decoder at one place.
struct StoreDecoder: Decoder {
    let handle: Handle
    let codingPath: [any CodingKey]
    let options: CodingOptions
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(try KeyedStoreDecoding(handle: handle, codingPath: codingPath, options: options))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        try UnkeyedStoreDecoding(handle: handle, codingPath: codingPath, options: options)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        SingleValueStoreDecoding(handle: handle, codingPath: codingPath, options: options)
    }
}

/// The decoding error for a place that holds another kind of thing than
/// the one asked for.
func mismatch(_ type: Any.Type, _ codingPath: [any CodingKey], _ what: String) -> DecodingError {
    .typeMismatch(type, DecodingError.Context(codingPath: codingPath, debugDescription: what))
}

/// Reads one value at a place: the scalars and strings directly, with the
/// integers checked to fit, anything else through its own `init(from:)`.
func read<Value: Decodable>(
    _ type: Value.Type, at handle: Handle, codingPath: [any CodingKey], options: CodingOptions
) throws -> Value {
    if let value = try readFoundationValue(type, at: handle, codingPath: codingPath, options: options) { return value }
    func stored<Stored: StorableValue>(_: Stored.Type) throws -> Stored {
        do {
            guard let value = try handle.value(Stored.self) else {
                throw DecodingError.valueNotFound(
                    type, DecodingError.Context(codingPath: codingPath, debugDescription: "nothing at the place"))
            }
            return value
        } catch XitDBError.unexpectedTag {
            throw mismatch(type, codingPath, "another kind of value")
        }
    }
    func fitting<Target: FixedWidthInteger, Source: FixedWidthInteger>(_ source: Source, as: Target.Type) throws
        -> Target
    {
        guard let target = Target(exactly: source) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: codingPath, debugDescription: "\(source) does not fit \(Target.self)")
            )
        }
        return target
    }
    switch type {
    case is Bool.Type: return try stored(Bool.self) as! Value
    case is String.Type: return try stored(String.self) as! Value
    case is Double.Type: return try stored(Double.self) as! Value
    case is Float.Type: return Float(try stored(Double.self)) as! Value
    case is Int.Type: return try fitting(try stored(Int64.self), as: Int.self) as! Value
    case is Int8.Type: return try fitting(try stored(Int64.self), as: Int8.self) as! Value
    case is Int16.Type: return try fitting(try stored(Int64.self), as: Int16.self) as! Value
    case is Int32.Type: return try fitting(try stored(Int64.self), as: Int32.self) as! Value
    case is Int64.Type: return try stored(Int64.self) as! Value
    case is UInt.Type: return try fitting(try stored(UInt64.self), as: UInt.self) as! Value
    case is UInt8.Type: return try fitting(try stored(UInt64.self), as: UInt8.self) as! Value
    case is UInt16.Type: return try fitting(try stored(UInt64.self), as: UInt16.self) as! Value
    case is UInt32.Type: return try fitting(try stored(UInt64.self), as: UInt32.self) as! Value
    case is UInt64.Type: return try stored(UInt64.self) as! Value
    case is [UInt8].Type: return try stored([UInt8].self) as! Value
    default: return try Value(from: StoreDecoder(handle: handle, codingPath: codingPath, options: options))
    }
}

/// A keyed container at a place: the hash map there, its keys read when
/// the container is made, so that a failing read is an error and not a
/// shorter list of keys.
struct KeyedStoreDecoding<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let handle: Handle
    let codingPath: [any CodingKey]
    let options: CodingOptions

    /// The keys whose names the entries store, as ``XitDBEncoder`` stores
    /// them; entries written without a name are not listed.
    let allKeys: [Key]

    /// Over the map at a place; a place that holds nothing is an empty
    /// container.
    ///
    /// - Throws: `DecodingError.typeMismatch` if the place holds anything
    ///   but a map, or the error of a read.
    init(handle: Handle, codingPath: [any CodingKey], options: CodingOptions) throws {
        self.handle = handle
        self.codingPath = codingPath
        self.options = options
        allKeys = try Self.storedKeys(at: handle, codingPath: codingPath)
    }

    private static func storedKeys(at handle: Handle, codingPath: [any CodingKey]) throws -> [Key] {
        guard let cursor = try handle.read(), try cursor.slot.tag != .none else { return [] }
        let map: HashMap<ReadOnly>
        do {
            map = try HashMap<ReadOnly>(cursor)
        } catch XitDBError.unexpectedTag {
            throw mismatch([String: Any].self, codingPath, "the place holds no map")
        }
        var keys: [Key] = []
        var entries = try map.iterator()
        while let entry = try entries.next() {
            let pair = try entry.readEntry()
            // An entry written by a map put stores no name, and lists no key.
            guard try pair.key.slot.tag != .none else { continue }
            guard let key = Key(stringValue: String(decoding: try pair.key.readBytes(), as: UTF8.self)) else {
                continue
            }
            keys.append(key)
        }
        return keys
    }

    private func place(_ key: Key) -> Handle { handle[key.stringValue] }

    /// Whether the key has an entry. The protocol lets this throw nothing:
    /// a read that fails says the key is not there, and the decode that
    /// follows reports the error.
    func contains(_ key: Key) -> Bool {
        (try? place(key).exists) ?? false
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        try !place(key).exists
    }

    /// The place for a key that must have an entry.
    private func present(_ key: Key) throws -> Handle {
        let place = place(key)
        guard try place.exists else {
            throw DecodingError.keyNotFound(
                key, DecodingError.Context(codingPath: codingPath, debugDescription: "no entry for the key"))
        }
        return place
    }

    func decode<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Value {
        try read(type, at: try present(key), codingPath: codingPath + [key], options: options)
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws
        -> KeyedDecodingContainer<NestedKey>
    {
        KeyedDecodingContainer(
            try KeyedStoreDecoding<NestedKey>(
                handle: try present(key), codingPath: codingPath + [key], options: options))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try UnkeyedStoreDecoding(handle: try present(key), codingPath: codingPath + [key], options: options)
    }

    func superDecoder() throws -> any Decoder {
        StoreDecoder(handle: handle["super"], codingPath: codingPath + [SuperKey()], options: options)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        StoreDecoder(handle: place(key), codingPath: codingPath + [key], options: options)
    }
}

/// An unkeyed container at a place: the array list there, read in order.
struct UnkeyedStoreDecoding: UnkeyedDecodingContainer {
    let handle: Handle
    let codingPath: [any CodingKey]
    let options: CodingOptions
    let total: Int
    private(set) var currentIndex = 0

    /// Over the list at a place; a place that holds nothing is an empty
    /// container.
    ///
    /// - Throws: `DecodingError.typeMismatch` if the place holds anything
    ///   but a list, or the error of a read.
    init(handle: Handle, codingPath: [any CodingKey], options: CodingOptions) throws {
        self.handle = handle
        self.codingPath = codingPath
        self.options = options
        do {
            total = try handle.list(UInt64.self).count
        } catch XitDBError.unexpectedTag {
            throw mismatch([Any].self, codingPath, "the place holds no list")
        }
    }

    var count: Int? { total }
    var isAtEnd: Bool { currentIndex >= total }

    private mutating func next() throws -> Handle {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(
                Any.self, DecodingError.Context(codingPath: codingPath, debugDescription: "past the list's end"))
        }
        let element = handle[index: currentIndex]
        currentIndex += 1
        return element
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { return false }
        if try !handle[index: currentIndex].exists {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        let key = IndexKey(intValue: currentIndex)
        return try read(type, at: try next(), codingPath: codingPath + [key], options: options)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws
        -> KeyedDecodingContainer<NestedKey>
    {
        let key = IndexKey(intValue: currentIndex)
        return KeyedDecodingContainer(
            try KeyedStoreDecoding<NestedKey>(handle: try next(), codingPath: codingPath + [key], options: options))
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let key = IndexKey(intValue: currentIndex)
        return try UnkeyedStoreDecoding(handle: try next(), codingPath: codingPath + [key], options: options)
    }

    mutating func superDecoder() throws -> any Decoder {
        let key = IndexKey(intValue: currentIndex)
        return StoreDecoder(handle: try next(), codingPath: codingPath + [key], options: options)
    }
}

/// A single value at a place.
struct SingleValueStoreDecoding: SingleValueDecodingContainer {
    let handle: Handle
    let codingPath: [any CodingKey]
    let options: CodingOptions

    /// Whether the place holds nothing. The protocol lets this throw
    /// nothing: a read that fails says there is a value, and the decode
    /// that follows reports the error.
    func decodeNil() -> Bool {
        !((try? handle.exists) ?? true)
    }

    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try read(type, at: handle, codingPath: codingPath, options: options)
    }
}

/// The key of an element of an unkeyed container, for the coding path.
struct IndexKey: CodingKey {
    let intValue: Int?
    var stringValue: String { "\(intValue ?? 0)" }

    init(intValue: Int) {
        self.intValue = intValue
    }

    init?(stringValue: String) {
        guard let value = Int(stringValue) else { return nil }
        intValue = value
    }
}

/// The key a superclass's encoder writes under.
struct SuperKey: CodingKey {
    var stringValue: String { "super" }
    var intValue: Int? { nil }

    init() {}

    init?(stringValue: String) {
        guard stringValue == "super" else { return nil }
    }

    init?(intValue: Int) {
        nil
    }
}
