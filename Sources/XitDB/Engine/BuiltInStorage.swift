// The storage as the engine holds it (decision D23). A database is opened
// over `any WritableStorage`, and the M3 profile put the calls through that
// existential at six to seven percent of an insert in memory. The engine
// therefore keeps its storage in this enum, which names each of the three
// built-in storages by its class and keeps the existential only for a
// storage of the caller's own, so that a read or write on a built-in storage
// is a `switch` and a direct call to a final class. Nothing public changes:
// the inits wrap the storage they are given, and the enum is never seen
// outside the module.

/// The storage a database reads and writes: one of the three storages this
/// package provides, held as its class, or any other behind
/// ``WritableStorage``.
///
/// The engine calls this and not the protocol, so that a call on a built-in
/// storage is dispatched by `switch` rather than through a witness table.
/// The enum cannot conform to the protocol, which is class-constrained, so
/// it has the protocol's methods instead, each a switch that calls the case's
/// storage. The three cases are final classes, and a storage of none of
/// those classes goes in the fourth, called through the protocol as before.
///
/// The read side of the engine holds this too, and a reader made from a
/// database's storage therefore has its writing methods at hand, which it
/// never calls.
enum BuiltInStorage {
    /// Bytes in memory.
    case memory(MemoryStorage)
    /// A file, every call a system call.
    case file(FileStorage)
    /// A file behind a write buffer.
    case bufferedFile(BufferedFileStorage)
    /// A storage of the caller's own, called through the protocol.
    case custom(any WritableStorage)

    /// Wraps a storage: a built-in one by its class, any other as custom.
    init(_ storage: any WritableStorage) {
        if let memory = storage as? MemoryStorage {
            self = .memory(memory)
        } else if let file = storage as? FileStorage {
            self = .file(file)
        } else if let bufferedFile = storage as? BufferedFileStorage {
            self = .bufferedFile(bufferedFile)
        } else {
            self = .custom(storage)
        }
    }

    // MARK: ReadableStorage

    /// ``ReadableStorage/read(into:range:at:)`` on the storage.
    func read(into buffer: inout MutableSpan<UInt8>, range: Range<Int>, at offset: UInt64) throws(XitDBError) -> Int {
        switch self {
        case .memory(let storage): try storage.read(into: &buffer, range: range, at: offset)
        case .file(let storage): try storage.read(into: &buffer, range: range, at: offset)
        case .bufferedFile(let storage): try storage.read(into: &buffer, range: range, at: offset)
        case .custom(let storage): try storage.read(into: &buffer, range: range, at: offset)
        }
    }

    /// ``ReadableStorage/read(into:at:)`` on the storage: a read into the
    /// whole of `buffer`.
    func read(into buffer: inout MutableSpan<UInt8>, at offset: UInt64) throws(XitDBError) -> Int {
        try read(into: &buffer, range: 0..<buffer.count, at: offset)
    }

    /// ``ReadableStorage/length`` of the storage.
    var length: UInt64 {
        get throws(XitDBError) {
            switch self {
            case .memory(let storage): try storage.length
            case .file(let storage): try storage.length
            case .bufferedFile(let storage): try storage.length
            case .custom(let storage): try storage.length
            }
        }
    }

    // MARK: WritableStorage

    /// ``WritableStorage/write(_:at:)`` on the storage.
    func write(_ bytes: Span<UInt8>, at offset: UInt64) throws(XitDBError) {
        switch self {
        case .memory(let storage): try storage.write(bytes, at: offset)
        case .file(let storage): try storage.write(bytes, at: offset)
        case .bufferedFile(let storage): try storage.write(bytes, at: offset)
        case .custom(let storage): try storage.write(bytes, at: offset)
        }
    }

    /// ``WritableStorage/truncate(to:)`` on the storage.
    func truncate(to length: UInt64) throws(XitDBError) {
        switch self {
        case .memory(let storage): try storage.truncate(to: length)
        case .file(let storage): try storage.truncate(to: length)
        case .bufferedFile(let storage): try storage.truncate(to: length)
        case .custom(let storage): try storage.truncate(to: length)
        }
    }

    /// ``WritableStorage/flush()`` on the storage.
    func flush() throws(XitDBError) {
        switch self {
        case .memory(let storage): try storage.flush()
        case .file(let storage): try storage.flush()
        case .bufferedFile(let storage): try storage.flush()
        case .custom(let storage): try storage.flush()
        }
    }

    /// ``WritableStorage/sync(_:)`` on the storage.
    func sync(_ point: SyncPoint) throws(XitDBError) {
        switch self {
        case .memory(let storage): try storage.sync(point)
        case .file(let storage): try storage.sync(point)
        case .bufferedFile(let storage): try storage.sync(point)
        case .custom(let storage): try storage.sync(point)
        }
    }
}
