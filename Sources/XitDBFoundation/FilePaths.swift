// A storage opened by a `FilePath`, where the system has the type without
// a dependency: Apple's platforms, whose System framework it is. On Linux
// `FilePath` is the swift-system package's, which this package does not
// take, so these two initialisers are not there.
#if canImport(System)
    public import System
    public import XitDB

    extension FileStorage {
        /// Opens the file at a `FilePath` as a storage:
        /// `init(path:access:durability:lock:reading:)` with the path's
        /// string. On Apple's platforms only.
        ///
        /// - Parameters:
        ///   - path: The file's path.
        ///   - access: How to open the file.
        ///   - durability: How far a commit goes to reach the disk.
        ///   - lock: The advisory lock to take, if any.
        ///   - reading: How the storage reads the file.
        /// - Throws: What the initialiser that takes a string throws.
        public convenience init(
            path: FilePath,
            access: FileAccess,
            durability: Durability = .full,
            lock: FileLock? = nil,
            reading: FileReading = .fileCalls
        ) throws(XitDBError) {
            try self.init(path: path.string, access: access, durability: durability, lock: lock, reading: reading)
        }
    }

    extension BufferedFileStorage {
        /// Opens the file at a `FilePath` as a buffered storage:
        /// `init(path:access:durability:lock:reading:bufferLimit:)` with
        /// the path's string. On Apple's platforms only.
        ///
        /// - Parameters:
        ///   - path: The file's path.
        ///   - access: How to open the file.
        ///   - durability: How far a commit goes to reach the disk.
        ///   - lock: The advisory lock to take, if any.
        ///   - reading: How the storage reads the file.
        ///   - bufferLimit: The most bytes to hold before flushing.
        /// - Throws: What the initialiser that takes a string throws.
        public convenience init(
            path: FilePath,
            access: FileAccess,
            durability: Durability = .full,
            lock: FileLock? = nil,
            reading: FileReading = .fileCalls,
            bufferLimit: UInt64 = BufferedFileStorage.defaultBufferLimit
        ) throws(XitDBError) {
            try self.init(
                path: path.string, access: access, durability: durability, lock: lock, reading: reading,
                bufferLimit: bufferLimit)
        }
    }
#endif
