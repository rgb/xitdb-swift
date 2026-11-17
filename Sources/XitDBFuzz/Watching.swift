// A reader in another process than the writer, for the tests of what such a
// reader is told when the file under its path is replaced: `XitDBFuzz
// watch`.
//
//     XitDBFuzz watch <kind> <path>
//
// The kinds are the port's six file kinds, by the words the conformance
// suite's reader has for them (`XitDBConformanceReader`): `file`,
// `buffered`, and each through a memory map in either of its two ways,
// `file-map`, `file-map-read-ahead`, `buffered-map`,
// `buffered-map-read-ahead`.
//
// Opens the file at the path to be read, with no lock, as a reader beside a
// writer in another process does, prints `open`, and then answers each line
// it is given on its standard input with one line:
//
//     still    `true` or `false`, the storage's `isStillAtPath`; or
//              `error` and what the asking threw
//     mapped   `true` or `false`, the storage's `isMemoryMapped`
//     read     the file's first sixteen bytes as the storage reads them, in
//              hexadecimal, fewer if the file is shorter. On every kind
//              these come by a file call: no storage reads its two headers
//              through its map, and one opened to read maps nothing until a
//              database has verified a commit in it.
//     quit     nothing; the process ends with status 0
//
// It uses nothing of the library that a program of another package could
// not use. It ends when its input ends, and after twenty seconds whatever
// happens, so that a test that fails leaves no process behind.

import Foundation
import XitDB

/// The kinds of file storage a watching reader opens, each by the word the
/// command line has for it: the two file storages, each read by file calls
/// and through a memory map in either of its two ways.
enum WatchKind: String, CaseIterable {
    case file, buffered
    case fileMap = "file-map"
    case fileMapReadAhead = "file-map-read-ahead"
    case bufferedMap = "buffered-map"
    case bufferedMapReadAhead = "buffered-map-read-ahead"

    /// Whether the storage is the buffered one.
    var buffered: Bool {
        switch self {
        case .file, .fileMap, .fileMapReadAhead: false
        case .buffered, .bufferedMap, .bufferedMapReadAhead: true
        }
    }

    /// How the storage reads its file.
    var reading: FileReading {
        switch self {
        case .file, .buffered: .fileCalls
        case .fileMap, .bufferedMap: .memoryMap
        case .fileMapReadAhead, .bufferedMapReadAhead: .memoryMapReadAhead
        }
    }
}

/// What a test asks a watching reader, a word to a line.
enum WatchQuestion: String {
    /// Whether the storage's file is still the one its path names.
    case still
    /// Whether the storage reads through a memory map.
    case mapped
    /// The file's first sixteen bytes, as the storage reads them.
    case read
    /// To end.
    case quit
}

/// Answers the lines of a test about the file at `path`, read through a
/// storage of the kind named.
func watch(_ kind: WatchKind, path: String) {
    alarm(20)
    let storage: any WritableStorage
    let still: () throws(XitDBError) -> Bool
    let isMapped: Bool
    do {
        if kind.buffered {
            let opened = try BufferedFileStorage(path: path, access: .readOnly, reading: kind.reading)
            storage = opened
            still = { () throws(XitDBError) in try opened.isStillAtPath }
            isMapped = opened.isMemoryMapped
        } else {
            let opened = try FileStorage(path: path, access: .readOnly, reading: kind.reading)
            storage = opened
            still = { () throws(XitDBError) in try opened.isStillAtPath }
            isMapped = opened.isMemoryMapped
        }
    } catch {
        fail("XitDBFuzz: cannot open \(path): \(error.description)", status: 1)
    }
    say("open")
    while let line = readLine() {
        guard let question = WatchQuestion(rawValue: line) else {
            say("unknown \(line)")
            continue
        }
        switch question {
        case .still:
            do {
                say(try still() ? "true" : "false")
            } catch {
                // The case's own name, by its code: a line a test reads is
                // never what an error prints.
                say("error \(error.code.rawValue)")
            }
        case .mapped:
            say(isMapped ? "true" : "false")
        case .read:
            do {
                var bytes = [UInt8](repeating: 0, count: 16)
                var span = bytes.mutableSpan
                let count = try storage.read(into: &span, range: 0..<16, at: 0)
                say(bytes[..<count].map { String(format: "%02x", $0) }.joined())
            } catch {
                // The case's own name, by its code: a line a test reads is
                // never what an error prints.
                say("error \(error.code.rawValue)")
            }
        case .quit:
            exit(0)
        }
    }
}
