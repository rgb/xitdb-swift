// A writer that dies in the middle of a full copy, for the tests of what a
// copy cut short by the process's end leaves behind: `XitDBFuzz die`.
//
//     XitDBFuzz die <step> <kind> <database> <bytes> [<write>]
//
// Opens the database at a path as its writer, with an exclusive lock, and
// applies to it, from 0, the bytes of another database kept in a second
// file, a thousand at a time. At the step named the process ends at once,
// by `_exit` with status 86, with nothing flushed and nothing cleaned up,
// as a process that is killed ends. `kind` is one of the four kinds of
// file storage: `file`, `buffered`, and `mapped-file` and
// `mapped-buffered`, which read through a memory map. `write` says which of the copy's
// writes to the file is the one that `mid-copy` dies at, before making it,
// the fifth if nothing is said: a buffered storage writes a copy in fewer.
//
// The steps are the places of a copy into a new file that is then given
// the old one's name:
//
//     new-file         the new file has been made, and nothing written
//     mid-copy         some of the copy's blocks are written, others not
//     before-rename    the new file is whole and synced, and not renamed
//     after-rename     the new file has the name, the directory not synced
//
// Exits 0 if the copy ran to its end without reaching the step, which the
// tests take for a failure, and 1 if the database could not be opened or
// the copy failed otherwise.

import Foundation
import XitDB

/// The steps of a full copy at which a writer can be made to die.
enum DyingStep: String {
    case newFile = "new-file"
    case midCopy = "mid-copy"
    case beforeRename = "before-rename"
    case afterRename = "after-rename"
}

/// The status a writer ends with when it dies at its step.
let diedAtItsStep: Int32 = 86

/// Gives bytes a thousand at a time, so that a copy is written block by
/// block and has a middle.
private struct Piecewise: ByteSource {
    let bytes: [UInt8]
    var given = 0

    mutating func read(into buffer: inout MutableSpan<UInt8>) throws -> Int {
        let count = min(1000, buffer.count, bytes.count - given)
        for index in 0..<count {
            buffer[index] = bytes[given + index]
        }
        given += count
        return count
    }
}

/// Opens the database at `path` as its writer and copies `bytes` onto it,
/// dying at `step`.
func dieInACopy(
    at step: DyingStep, buffered: Bool, mapped: Bool, path: String, bytes: [UInt8], midWrite: Int
) -> Never {
    // The process ends by itself if it is still here after twenty seconds.
    alarm(20)
    // the platform's own calls, which the counted ones go on to
    let platform = FileCalls()
    var calls = FileCalls()
    var counting = false
    var writes = 0
    calls.open = { (path: String, access: FileAccess) throws(XitDBError) -> Int32 in
        let descriptor = try platform.open(path, access)
        if counting, step == .newFile { _exit(diedAtItsStep) }
        return descriptor
    }
    calls.write = { (descriptor: Int32, bytes: Span<UInt8>, offset: UInt64) throws(XitDBError) -> Void in
        if counting {
            writes += 1
            // some of the copy's writes are in the file, and this one and
            // the ones after it are not
            if step == .midCopy, writes == midWrite { _exit(diedAtItsStep) }
        }
        try platform.write(descriptor, bytes, offset)
    }
    calls.rename = { (source: String, destination: String) throws(XitDBError) -> Void in
        if counting, step == .beforeRename { _exit(diedAtItsStep) }
        try platform.rename(source, destination)
    }
    calls.syncDirectory = { (path: String, call: SyncCall) in
        if counting, step == .afterRename { _exit(diedAtItsStep) }
        return platform.syncDirectory(path, call)
    }
    do {
        let file = try FileStorage(
            path: path, access: .readWrite, lock: .exclusive, reading: mapped ? .memoryMap : .fileCalls,
            segmentSize: FileStorage.defaultSegmentSize, calls: calls)
        let database: Database
        if buffered {
            database = try Database(opening: BufferedFileStorage(file), hashSize: 20)
        } else {
            database = try Database(opening: file, hashSize: 20)
        }
        counting = true
        var source = Piecewise(bytes: bytes)
        try database.applyReplicated(at: 0, from: &source, count: UInt64(bytes.count))
    } catch {
        fail("the copy failed: \(error)", status: 1)
    }
    exit(0)
}
