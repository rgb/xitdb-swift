// The Foundation types that have a better form in the store than their own
// Codable one, and the strategies that choose it. This is the one place the
// store module uses Foundation: XitDB itself stays without it.

import XitDB

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// How a `Date` is stored.
public enum DateCodingStrategy: Sendable {
    /// Seconds since 1970 as a double: the default.
    case secondsSince1970

    /// What `Date` encodes itself as: seconds since 2001 as a double.
    case deferred
}

/// How a `Data` is stored.
public enum DataCodingStrategy: Sendable {
    /// The format's byte array: the default.
    case bytes

    /// What `Data` encodes itself as: a list of 8-bit integers, one element
    /// each, which is slow and large.
    case deferred
}

/// How a `URL` is stored.
public enum URLCodingStrategy: Sendable {
    /// Its absolute string: the default.
    case string

    /// What `URL` encodes itself as: a map with the relative string and the
    /// base.
    case deferred
}

/// Writes a `Date`, `Data` or `URL` as its strategy says; false for any
/// other value or for a deferring strategy, which leaves the type to its
/// own `encode(to:)`.
func writeFoundationValue(
    _ value: some Encodable, at handle: Handle, codingPath: [any CodingKey], options: CodingOptions
) throws -> Bool {
    switch value {
    case let date as Date where options.dates == .secondsSince1970:
        try handle.set(date.timeIntervalSince1970)
    case let data as Data where options.data == .bytes:
        try handle.set([UInt8](data))
    case let url as URL where options.urls == .string:
        try handle.set(url.absoluteString)
    default:
        return false
    }
    return true
}

/// Reads a `Date`, `Data` or `URL` as its strategy says; nil for any other
/// type or for a deferring strategy.
func readFoundationValue<Value: Decodable>(
    _ type: Value.Type, at handle: Handle, codingPath: [any CodingKey], options: CodingOptions
) throws -> Value? {
    func corrupted(_ what: String) -> DecodingError {
        .dataCorrupted(DecodingError.Context(codingPath: codingPath, debugDescription: what))
    }
    /// The stored value of a kind, or a decoding error for another kind.
    func stored<Stored: StorableValue>(_: Stored.Type, _ what: String) throws -> Stored {
        do {
            guard let value = try handle.value(Stored.self) else { throw corrupted(what) }
            return value
        } catch XitDBError.unexpectedTag {
            throw DecodingError.typeMismatch(
                type, DecodingError.Context(codingPath: codingPath, debugDescription: "another kind of value"))
        }
    }
    switch type {
    case is Date.Type where options.dates == .secondsSince1970:
        return Date(timeIntervalSince1970: try stored(Double.self, "no seconds at the place")) as? Value
    case is Data.Type where options.data == .bytes:
        return Data(try stored([UInt8].self, "no bytes at the place")) as? Value
    case is URL.Type where options.urls == .string:
        let string = try stored(String.self, "no string at the place")
        guard let url = URL(string: string) else { throw corrupted("not a URL: \(string)") }
        return url as? Value
    default:
        return nil
    }
}
