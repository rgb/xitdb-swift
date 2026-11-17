import Testing
import XitDB
import XitDBHashing

/// `XitDBError.carrying`, the adapter for code that declares
/// `throws(XitDBError)` and makes one of the four calls that take a closure
/// of the caller's (the first client's review of 0.5.1, item 5; the names
/// are the user's of 2026-11-17).
///
/// Those calls throw `any Error` and pass a closure's own error on as
/// itself, which is unchanged and held here too, for the contrast. Through
/// the adapter an error of the library's comes out as itself and anything
/// else comes out carried, once. That a typed function cannot make the four
/// calls bare, and can through the adapter, is the compiler's to say and is
/// held by the gate's step for what must not compile; this file imports the
/// library as a client does, so it also holds that the adapter is public.
@Suite struct CarryingTests {
    /// An error of the caller's own.
    private struct Mine: Error, Equatable {
        let number: Int
    }

    private func makeDatabase() throws(XitDBError) -> Database {
        try Database(creating: MemoryStorage(), hashing: Insecure.SHA1.self)
    }

    /// What `body` threw through the adapter, or `nil` if it threw nothing.
    /// The adapter's declaration is what makes the `catch` exhaustive with
    /// no cast: it throws the library's error and nothing else.
    private func thrown(_ body: () throws -> Void) -> XitDBError? {
        do {
            try XitDBError.carrying(body)
            return nil
        } catch {
            return error
        }
    }

    /// The error of the caller's that `error` carries, if it carries one.
    private func carried(by error: XitDBError?) -> Mine? {
        guard case .callerError(let carried) = error else { return nil }
        return carried as? Mine
    }

    @Test func whatTheBodyReturnsIsReturned() throws {
        let seven = try XitDBError.carrying { 7 }
        #expect(seven == 7)
        let words = try XitDBError.carrying {
            let first = "one"
            return [first, "two"]
        }
        #expect(words == ["one", "two"])
        #expect(thrown {} == nil)
    }

    /// As itself, with its values, and not carried: a `catch` for the case
    /// matches as it would have without the adapter.
    @Test func anErrorOfTheLibrarysComesOutAsItself() {
        #expect(thrown { throw XitDBError.keyNotFound } == .keyNotFound)
        #expect(thrown { throw XitDBError.storageFailure(errno: 28) } == .storageFailure(errno: 28))
        let untrusted = thrown { throw XitDBError.untrustedRootHeader(lastVerified: 57) }
        #expect(untrusted == .untrustedRootHeader(lastVerified: 57))
        // Thrown from a closure whose error is spelled, too.
        #expect(thrown { () throws(XitDBError) in throw .invalidDatabase } == .invalidDatabase)
    }

    @Test func anErrorOfTheCallersIsCarried() {
        let error = thrown { throw Mine(number: 3) }
        #expect(carried(by: error) == Mine(number: 3))
        guard case .callerError = error else {
            Issue.record("thrown as \(String(describing: error)), not carried")
            return
        }
    }

    /// One that was carried already, by the library or by an adapter
    /// further in, comes out as it is: what it carries is the caller's
    /// error, and not a carried error carrying it.
    @Test func aCarriedErrorIsNotCarriedAgain() {
        #expect(carried(by: thrown { throw XitDBError.callerError(Mine(number: 4)) }) == Mine(number: 4))
        #expect(carried(by: thrown { try XitDBError.carrying { throw Mine(number: 5) } }) == Mine(number: 5))
    }

    /// A function of a client's that declares the library's error and makes
    /// each of the four calls, with no error spelled on any closure.
    /// `failing` is thrown inside the transaction once everything is
    /// written. It returns what the two appends' bodies read through the
    /// cursors they were given, and then the two lists' counts.
    private func writeEverything(_ database: Database, failing: (any Error)? = nil) throws(XitDBError) -> [UInt64] {
        try XitDBError.carrying {
            try database.withTransaction { root in
                var seen: [UInt64] = []
                let map = try HashMap(root)
                let list = try ArrayList(try map.putCursor(forKey: "list"))
                try list.append(.uint(1)) { element in seen.append(try element.read(UInt64.self)) }
                let linked = try LinkedArrayList(try map.putCursor(forKey: "linked"))
                try linked.append(.uint(2)) { element in
                    let value = try element.read(UInt64.self)
                    seen.append(value)
                }
                var bytes = try map.putCursor(forKey: "bytes")
                try bytes.writeBytes { writer in try writer.write([1, 2, 3]) }
                if let failing { throw failing }
                return seen + [try list.count, try linked.count]
            }
        }
    }

    /// Whether the root map has anything under `key`.
    private func has(_ database: Database, _ key: String) throws -> Bool {
        let root = database.rootCursor.readOnly
        guard try !root.slot.isEmpty else { return false }
        return try HashMap(root).cursor(forKey: key) != nil
    }

    @Test func theFourCallsAreMadeThroughItWhereTheLibrarysErrorIsDeclared() throws {
        let database = try makeDatabase()
        #expect(try writeEverything(database) == [1, 2, 1, 1])
        let map = try HashMap(database.rootCursor.readOnly)
        #expect(try ArrayList(try #require(try map.cursor(forKey: "list"))).count == 1)
        #expect(try LinkedArrayList(try #require(try map.cursor(forKey: "linked"))).count == 1)
        #expect(try #require(try map.cursor(forKey: "bytes")).readBytes() == [1, 2, 3])
    }

    /// The transaction rolls back as it does for any error that leaves its
    /// body, and the caller of the typed function is given the error
    /// carried.
    @Test func anErrorOfTheCallersInsideATransactionIsCarriedAndTheTransactionRollsBack() throws {
        let database = try makeDatabase()
        do {
            _ = try writeEverything(database, failing: Mine(number: 6))
            Issue.record("nothing was thrown")
        } catch .callerError(let carried) {
            #expect(carried as? Mine == Mine(number: 6))
        } catch {
            Issue.record("thrown as \(error), not carried")
        }
        #expect(try has(database, "list") == false)
        #expect(try has(database, "bytes") == false)
    }

    /// An error the library itself gives inside the body, here a
    /// transaction begun inside a transaction, is the library's when it
    /// comes out.
    @Test func anErrorOfTheLibrarysInsideATransactionComesOutAsItself() throws {
        let database = try makeDatabase()
        let error = thrown {
            try database.withTransaction { root in
                try HashMap(root).put(UInt64(1), forKey: "one")
                try database.withTransaction { _ in }
            }
        }
        #expect(error == .nestedTopLevelWrite)
        #expect(try has(database, "one") == false)

        #expect(throws: XitDBError.keyNotFound) { try self.writeEverything(database, failing: XitDBError.keyNotFound) }
    }

    /// The calls themselves are as they were: without the adapter a
    /// closure's own error comes out of each as itself.
    @Test func withoutItAClosuresOwnErrorComesOutOfEachCallAsItself() throws {
        let database = try makeDatabase()
        #expect(throws: Mine(number: 7)) { try database.withTransaction { _ in throw Mine(number: 7) } }
        #expect(throws: Mine(number: 8)) {
            try database.withTransaction { root in
                let list = try ArrayList(try HashMap(root).putCursor(forKey: "list"))
                try list.append(.uint(1)) { _ in throw Mine(number: 8) }
            }
        }
        #expect(throws: Mine(number: 9)) {
            try database.withTransaction { root in
                let linked = try LinkedArrayList(try HashMap(root).putCursor(forKey: "linked"))
                try linked.append(.uint(1)) { _ in throw Mine(number: 9) }
            }
        }
        #expect(throws: Mine(number: 10)) {
            try database.withTransaction { root in
                var bytes = try HashMap(root).putCursor(forKey: "bytes")
                try bytes.writeBytes { _ in throw Mine(number: 10) }
            }
        }
    }

    /// A sink, a source and an offset map of the caller's, each throwing an
    /// error that happens to be of the library's type.
    private struct LibraryTypedSink: ByteSink {
        mutating func write(_ bytes: Span<UInt8>) throws { throw XitDBError.keyNotFound }
    }
    private struct LibraryTypedSource: ByteSource {
        mutating func read(into buffer: inout MutableSpan<UInt8>) throws -> Int { throw XitDBError.keyNotFound }
    }
    private struct LibraryTypedOffsetMap: OffsetMap {
        mutating func reset() throws { throw XitDBError.keyNotFound }
        mutating func get(_ sourceOffset: UInt64) throws -> UInt64? { nil }
        mutating func put(_ sourceOffset: UInt64, _ targetOffset: UInt64) throws {}
    }

    /// The adapter passes the library's error on as itself because inside
    /// it the library's calls are what throws that type. Where the library
    /// calls a type of the caller's it is the other way about, and stays
    /// so: what that type throws is the caller's whatever its type, and is
    /// carried, so that it is not taken for an error the library met in
    /// the file.
    @Test func anErrorOfTheLibrarysTypeThrownByATypeOfTheCallersIsStillCarried() throws {
        let source = try makeDatabase()
        try ArrayList(source.rootCursor).append(.slot(nil)) { moment in
            try HashMap(moment).put(UInt64(1), forKey: "one")
        }
        let committed = try source.committedSize
        let carriedKeyNotFound = XitDBError.callerError(XitDBError.keyNotFound)
        #expect(carriedKeyNotFound != .keyNotFound)

        var sink = LibraryTypedSink()
        #expect(throws: carriedKeyNotFound) { try source.readCommitted(from: 0, to: committed, into: &sink) }

        let replica = try makeDatabase()
        var bytes = LibraryTypedSource()
        #expect(throws: carriedKeyNotFound) { try replica.applyReplicated(at: 0, from: &bytes, count: committed) }

        let target = try makeDatabase()
        var map = LibraryTypedOffsetMap()
        #expect(throws: carriedKeyNotFound) { try source.compact(into: target, offsetMap: &map) }
    }
}
