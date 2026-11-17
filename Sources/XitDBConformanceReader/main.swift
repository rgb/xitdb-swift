// The port's reader for the conformance suite's test of two processes
// (section 15 of the suite's SCRIPT-FORMAT.md, `two-processes.sh`): the
// original commits to a file while this program, in another process, with
// no lock and one database object, is asked what it sees.
//
//     XitDBConformanceReader --kinds
//     XitDBConformanceReader <kind> <file>
//
// `--kinds` prints the kinds of file storage the port has, one word to a
// line: the two file storages, each read by file calls and through a memory
// map in either of its two ways. The suite runs its three runs on each.
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

/// The port's kinds of file storage, in the reader's own words.
let kinds: [(name: String, buffered: Bool, reading: FileReading)] = [
    ("file", false, .fileCalls),
    ("buffered", true, .fileCalls),
    ("file-map", false, .memoryMap),
    ("file-map-read-ahead", false, .memoryMapReadAhead),
    ("buffered-map", true, .memoryMap),
    ("buffered-map-read-ahead", true, .memoryMapReadAhead),
]

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

/// An error's name in the port's own words: the case's name, without what
/// it carries.
func name(of error: any Error) -> String {
    let text = String(describing: error)
    return String(text.prefix { $0 != "(" && $0 != " " })
}

/// The file at `path` opened to be read, with no lock, as the kind says.
func open(_ kind: (name: String, buffered: Bool, reading: FileReading), _ path: String) throws -> any WritableStorage {
    struct NotReadThroughAMap: Error {}
    if kind.buffered {
        let storage = try BufferedFileStorage(path: path, access: .readOnly, reading: kind.reading)
        guard storage.isMemoryMapped == (kind.reading != .fileCalls) else { throw NotReadThroughAMap() }
        return storage
    }
    let storage = try FileStorage(path: path, access: .readOnly, reading: kind.reading)
    guard storage.isMemoryMapped == (kind.reading != .fileCalls) else { throw NotReadThroughAMap() }
    return storage
}

/// The state the database is in: everything read through one cursor at the
/// root's last moment.
func state(of database: Database) throws -> String {
    struct NoMoment: Error {}
    struct NoSuchKey: Error {}
    guard let moment = try ArrayList<ReadOnly>(database.rootCursor.readOnly).cursor(at: -1) else {
        throw NoMoment()
    }
    let map = try HashMap<ReadOnly>(moment)
    guard
        let number = try map.cursor(forKey: "n"), let blob = try map.cursor(forKey: "blob"),
        let items = try map.cursor(forKey: "items")
    else { throw NoSuchKey() }
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
    for kind in kinds { say(kind.name) }
    exit(0)
}
guard arguments.count == 2, let kind = kinds.first(where: { $0.name == arguments[0] }) else {
    fail("usage: XitDBConformanceReader --kinds\n       XitDBConformanceReader <kind> <file>", status: 2)
}

let database: Database
do {
    database = try Database(opening: try open(kind, arguments[1]), hashing: Insecure.SHA1.self)
} catch {
    say("error \(name(of: error))")
    exit(1)
}
say("open")
while readLine() != nil {
    do {
        say(try state(of: database))
    } catch {
        say("error \(name(of: error))")
    }
}
exit(0)
