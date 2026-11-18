// The port's reader for the conformance suite's test of two processes
// (section 15 of the suite's SCRIPT-FORMAT.md, `two-processes.sh`): the
// original commits to a file while this program, in another process, with
// no lock and one database object, is asked what it sees.
//
//     XitDBConformanceReader --kinds
//     XitDBConformanceReader <kind> <file>
//
// `--kinds` prints the reader's kinds, one word to a line: the three ways
// the port reads a file that is opened to be read, a `ReadOnlyFileStorage`
// read by file calls and through a memory map in either of its two ways,
// under the database a reader opens, a `ReadOnlyDatabase`, whose root is
// read-only. The suite runs its three runs on each of the three. (A file
// opened to be read is a type of its own in the port, with no buffered
// form, and a `Database` does not open over it.)
//
// With a kind and a file it opens the file once, to be read, with no lock,
// and prints `open`, or `error <name>` and ends. Then, for each line on its
// standard input, whatever the line says, it prints one line and flushes
// it: `state <n> <sha256> <count>`, all three read through ONE cursor at
// the root's last moment, so that an answer cannot mix two commits: the
// number at the key `n`, the SHA-256 of the bytes at the key `blob` in
// lowercase hexadecimal, and the count of the list at the key `items`; or
// `error <name>` if any of that fails. At the end of its input it ends with
// status 0.
//
// A kind that is to read through a memory map says `error` and ends if the
// map was not had (a file on a volume that is not this machine's is read
// by file calls though the map was asked for): a run that passed without
// the map would say nothing of it.
//
// It is a tool for the suite and for the gate, in no product, and uses
// nothing of the library that a program of another package could not use.

import Foundation
import XitDB
import XitDBHashing

/// The reader's kinds, each by its own word, in the order `--kinds` prints
/// them: a file opened to be read, read by file calls and through a memory
/// map in either of its two ways.
enum Kind: String, CaseIterable {
    case file
    case fileMap = "file-map"
    case fileMapReadAhead = "file-map-read-ahead"

    /// How the storage reads its file.
    var reading: FileReading {
        switch self {
        case .file: .fileCalls
        case .fileMap: .memoryMap
        case .fileMapReadAhead: .memoryMapReadAhead
        }
    }
}

/// Prints a line and flushes it: the suite reads each answer before it
/// asks again.
func say(_ line: String) {
    print(line)
    fflush(nil)
}

/// Writes to the standard error and ends with a status.
func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

/// What the reader itself finds wrong, beside the library's errors.
enum ReaderError: String, Error {
    /// A kind that is to read through a memory map was not given one.
    case notReadThroughAMap
    /// The history at the root has no moment.
    case noMoment
    /// The last moment lacks one of the three keys.
    case noSuchKey
}

/// An error's name in the reader's own words, which is what the suite's
/// format asks for after `error`: for the library's error the case's own
/// name, which is its code's raw value, and for the reader's own its name
/// above. That is by design. The line is read by the suite's driver and
/// shown to a person, and a name that code writes is never what an error
/// prints: the library's description is a sentence for a person, whose
/// words may change.
func name(of error: any Error) -> String {
    if let error = error as? XitDBError { return error.code.rawValue }
    if let error = error as? ReaderError { return error.rawValue }
    return "unknownError"
}

/// The file at `path` opened to be read, with no lock, as the kind says.
func open(_ kind: Kind, _ path: String) throws -> ReadOnlyFileStorage {
    let storage = try ReadOnlyFileStorage(path: path, reading: kind.reading)
    guard storage.isMemoryMapped == (kind.reading != .fileCalls) else { throw ReaderError.notReadThroughAMap }
    return storage
}

/// The state the database is in, read from a cursor at its root:
/// everything through one cursor at the root's last moment.
func state(at root: Cursor<ReadOnly>) throws -> String {
    guard let moment = try ArrayList<ReadOnly>(root).cursor(at: -1) else {
        throw ReaderError.noMoment
    }
    let map = try HashMap<ReadOnly>(moment)
    guard
        let number = try map.cursor(forKey: "n"), let blob = try map.cursor(forKey: "blob"),
        let items = try map.cursor(forKey: "items")
    else { throw ReaderError.noSuchKey }
    let n = try number.read(UInt64.self)
    let digest = SHA256.keyHash(of: try blob.readBytes())
    let hex = digest.map { byte in
        let digits = String(byte, radix: 16)
        return digits.count == 1 ? "0" + digits : digits
    }.joined()
    let count = try ArrayList<ReadOnly>(items).count
    return "state \(n) \(hex) \(count)"
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--kinds"] {
    for kind in Kind.allCases { say(kind.rawValue) }
    exit(0)
}
guard arguments.count == 2, let kind = Kind(rawValue: arguments[0]) else {
    fail("usage: XitDBConformanceReader --kinds\n       XitDBConformanceReader <kind> <file>", status: 2)
}

/// The one database the reader opens, which only reads: its root cursor is
/// taken anew at each asking.
let database: ReadOnlyDatabase
do {
    database = try ReadOnlyDatabase(opening: try open(kind, arguments[1]), hashing: Insecure.SHA1.self)
} catch {
    say("error \(name(of: error))")
    exit(1)
}
say("open")
while readLine() != nil {
    do {
        say(try state(at: database.rootCursor))
    } catch {
        say("error \(name(of: error))")
    }
}
exit(0)
