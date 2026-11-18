public import Foundation
public import XitDB

extension FileStorage {
    /// Opens the file a URL names as a storage: `init(path:access:durability:lock:reading:)`
    /// with the URL's path.
    ///
    /// The URL has to be a file's (`isFileURL`). Its path is taken without
    /// percent-encoding, so a name with a space or a letter outside ASCII
    /// opens the file of that name. A URL to a folder the app was granted
    /// (a security-scoped one) is the caller's to start and stop accessing
    /// around the storage's life.
    ///
    /// - Parameters:
    ///   - url: The file's URL.
    ///   - access: How to open the file.
    ///   - durability: How far a commit goes to reach the disk.
    ///   - lock: The advisory lock to take, if any.
    ///   - reading: How the storage reads the file.
    /// - Throws: `storageFailure(errno:)` carrying `EINVAL` if the URL is
    ///   not a file's, before anything is opened, and what the
    ///   initialiser that takes a path throws.
    public convenience init(
        url: URL,
        access: FileAccess,
        durability: Durability = .full,
        lock: FileLock? = nil,
        reading: FileReading = .fileCalls
    ) throws(XitDBError) {
        guard url.isFileURL else { throw .storageFailure(errno: EINVAL) }
        try self.init(
            path: url.path(percentEncoded: false), access: access, durability: durability, lock: lock,
            reading: reading)
    }
}

extension BufferedFileStorage {
    /// Opens the file a URL names as a buffered storage:
    /// `init(path:access:durability:lock:reading:bufferLimit:)` with the
    /// URL's path.
    ///
    /// The URL has to be a file's (`isFileURL`). Its path is taken without
    /// percent-encoding, so a name with a space or a letter outside ASCII
    /// opens the file of that name. A URL to a folder the app was granted
    /// (a security-scoped one) is the caller's to start and stop accessing
    /// around the storage's life.
    ///
    /// - Parameters:
    ///   - url: The file's URL.
    ///   - access: How to open the file.
    ///   - durability: How far a commit goes to reach the disk.
    ///   - lock: The advisory lock to take, if any.
    ///   - reading: How the storage reads the file.
    ///   - bufferLimit: The most bytes to hold before flushing.
    /// - Throws: `storageFailure(errno:)` carrying `EINVAL` if the URL is
    ///   not a file's, before anything is opened, and what the
    ///   initialiser that takes a path throws.
    public convenience init(
        url: URL,
        access: FileAccess,
        durability: Durability = .full,
        lock: FileLock? = nil,
        reading: FileReading = .fileCalls,
        bufferLimit: UInt64 = BufferedFileStorage.defaultBufferLimit
    ) throws(XitDBError) {
        guard url.isFileURL else { throw .storageFailure(errno: EINVAL) }
        try self.init(
            path: url.path(percentEncoded: false), access: access, durability: durability, lock: lock,
            reading: reading, bufferLimit: bufferLimit)
    }
}
