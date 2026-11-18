import Foundation
import Testing
import XitDB
import XitDBFoundation
import XitDBHashing

#if canImport(System)
    import System
#endif

/// The file storages opened by a `URL`, and on Apple's platforms by a
/// `FilePath` (the first client's review of 0.5.1, item 14; decision D66):
/// each is the initialiser that takes a path, with the same arguments.
@Suite struct StorageByURLTests {
    /// A folder for one test's files, removed when the value goes away.
    private final class Folder {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("xitdb-foundation-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A name with a space, a letter outside ASCII and a per cent sign,
    /// which a URL writes percent-encoded.
    private static let name = "my café 100% notes.db"

    /// Writes a database with one value through a storage, and gives the
    /// value back as another storage reads it.
    private static func writeAndReadBack(_ storage: any WritableStorage, _ reader: any ReadableStorage) throws
        -> UInt64?
    {
        do {
            let database = try Database(creating: storage, hashing: SHA256.self)
            try HashMap(database.rootCursor).put(UInt64(42), forKey: "answer")
        }
        let database = try ReadOnlyDatabase(opening: reader, hashing: SHA256.self)
        return try HashMap(database.rootCursor).value(forKey: "answer", as: UInt64.self)
    }

    /// A URL opens the file its path names, whatever the name holds: a
    /// storage opened by the URL to be made makes the file of that name
    /// and no other, what it wrote is read through a storage opened by the
    /// path, and a file made by the path is opened by the URL, on both
    /// file storages.
    @Test func aURLOpensTheFileItsPathNames() throws {
        let folder = try Folder()
        let url = folder.url.appendingPathComponent(Self.name)
        let path = url.path(percentEncoded: false)
        #expect(path.hasSuffix("/" + Self.name))
        #expect(url.absoluteString.contains("%20"))

        /// The names of the files in the folder.
        func names() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: folder.url.path(percentEncoded: false)).sorted()
        }
        /// The value a database in a storage holds under "answer".
        func answer(in storage: any ReadableStorage) throws -> UInt64? {
            let database = try ReadOnlyDatabase(opening: storage, hashing: SHA256.self)
            return try HashMap(database.rootCursor).value(forKey: "answer", as: UInt64.self)
        }

        for buffered in [false, true] {
            // Made by the URL: the one file in the folder has the name, and
            // not the name as the URL writes it.
            do {
                let made: any WritableStorage =
                    buffered
                    ? try BufferedFileStorage(url: url, access: .create) : try FileStorage(url: url, access: .create)
                let database = try Database(creating: made, hashing: SHA256.self)
                try HashMap(database.rootCursor).put(UInt64(42), forKey: "answer")
            }
            #expect(try names() == [Self.name], "made by its URL, buffered: \(buffered)")
            guard try names() == [Self.name] else { return }
            // Read by the path.
            #expect(try answer(in: try FileStorage(path: path, access: .readOnly)) == 42)
            // And a file that is there by its path is opened by the URL.
            #expect(throws: Never.self) {
                let byURL: any ReadableStorage =
                    buffered
                    ? try BufferedFileStorage(url: url, access: .readOnly)
                    : try FileStorage(url: url, access: .readOnly)
                let read = try answer(in: byURL)
                #expect(read == 42)
            }
            try FileManager.default.removeItem(atPath: path)
        }
        #expect(try names().isEmpty)
    }

    /// A URL that is not a file's is refused before anything is opened.
    @Test func aURLThatIsNoFilesIsRefused() throws {
        let web = try #require(URL(string: "https://example.com/main.db"))
        #expect(throws: XitDBError.storageFailure(errno: EINVAL)) { try FileStorage(url: web, access: .create) }
        #expect(throws: XitDBError.storageFailure(errno: EINVAL)) {
            try BufferedFileStorage(url: web, access: .create)
        }
    }

    /// The arguments are the path initialiser's and reach it: the access,
    /// the lock, how the file is read, and the buffer's limit.
    @Test func theArgumentsReachTheStorage() throws {
        let folder = try Folder()
        let url = folder.url.appendingPathComponent("main.db")

        // The access: a file that is not there is not made by reading.
        #expect(throws: XitDBError.storageFailure(errno: ENOENT)) { try FileStorage(url: url, access: .readOnly) }
        #expect(throws: XitDBError.storageFailure(errno: ENOENT)) {
            try BufferedFileStorage(url: url, access: .readWrite)
        }

        // The lock: a second asker is refused while the first holds it.
        let locked = try FileStorage(url: url, access: .create, durability: .none, lock: .exclusive)
        #expect(throws: XitDBError.storageFailure(errno: EWOULDBLOCK)) {
            try BufferedFileStorage(url: url, access: .readWrite, lock: .exclusive)
        }
        // How the file is read: the map needs the lock, and says so.
        #expect(throws: XitDBError.memoryMapNeedsLock) {
            try FileStorage(url: url, access: .readWrite, reading: .memoryMap)
        }
        #expect(throws: XitDBError.memoryMapNeedsLock) {
            try BufferedFileStorage(url: url, access: .readWrite, reading: .memoryMap)
        }
        _ = locked

        // The buffer's limit.
        let other = folder.url.appendingPathComponent("other.db")
        #expect(try BufferedFileStorage(url: other, access: .create, bufferLimit: 4096).bufferLimit == 4096)
        #expect(
            try BufferedFileStorage(url: other, access: .readWrite).bufferLimit
                == BufferedFileStorage.defaultBufferLimit)
    }

    #if canImport(System)
        /// On Apple's platforms a `FilePath` opens the file it names, on
        /// both file storages, with the same arguments; and a path written
        /// as a string literal is still a `String`'s, so that importing
        /// this module makes no call ambiguous.
        @Test func aFilePathOpensTheFileItNames() throws {
            let folder = try Folder()
            let url = folder.url.appendingPathComponent(Self.name)
            let path = FilePath(url.path(percentEncoded: false))

            #expect(
                try Self.writeAndReadBack(
                    try FileStorage(path: path, access: .create), try FileStorage(url: url, access: .readOnly)) == 42)
            try FileManager.default.removeItem(at: url)
            #expect(
                try Self.writeAndReadBack(
                    try BufferedFileStorage(path: path, access: .create, bufferLimit: 4096),
                    try BufferedFileStorage(path: path, access: .readOnly)) == 42)
            #expect(throws: XitDBError.storageFailure(errno: EWOULDBLOCK)) {
                let first = try FileStorage(path: path, access: .readWrite, lock: .exclusive)
                _ = try BufferedFileStorage(path: path, access: .readWrite, lock: .exclusive)
                _ = first
            }

            // The arguments reach the storage: the access, how the file is
            // read, and the buffer's limit, as the lock did above.
            let missing = FilePath(folder.url.appendingPathComponent("none.db").path(percentEncoded: false))
            #expect(throws: XitDBError.storageFailure(errno: ENOENT)) {
                try FileStorage(path: missing, access: .readOnly)
            }
            #expect(throws: XitDBError.storageFailure(errno: ENOENT)) {
                try BufferedFileStorage(path: missing, access: .readWrite)
            }
            #expect(throws: XitDBError.memoryMapNeedsLock) {
                try FileStorage(path: path, access: .readWrite, reading: .memoryMap)
            }
            #expect(throws: XitDBError.memoryMapNeedsLock) {
                try BufferedFileStorage(path: path, access: .readWrite, reading: .memoryMap)
            }
            #expect(try BufferedFileStorage(path: path, access: .readWrite, bufferLimit: 4096).bufferLimit == 4096)
            #expect(!FileManager.default.fileExists(atPath: missing.string))

            // A literal: the string's initialiser, as before the import.
            #expect(throws: XitDBError.storageFailure(errno: ENOENT)) {
                try FileStorage(path: "/xitdb-foundation-tests-no-such-folder/none.db", access: .readOnly)
            }
            #expect(throws: XitDBError.storageFailure(errno: ENOENT)) {
                try BufferedFileStorage(path: "/xitdb-foundation-tests-no-such-folder/none.db", access: .readOnly)
            }
        }
    #endif
}
