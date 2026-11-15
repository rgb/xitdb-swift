// A reader in another process than the writer, for the tests of what such a
// reader is told when the file under its path is replaced: `XitDBFuzz
// watch`.
//
//     XitDBFuzz watch <file|buffered> <path>
//
// Opens the file at the path to be read, with no lock and no memory map, as
// a reader beside a writer in another process does, prints `open`, and then
// answers each line it is given on its standard input with one line:
//
//     still    `true` or `false`, the storage's `isStillAtPath`; or
//              `error` and what the asking threw
//     read     the file's first sixteen bytes as the storage reads them, in
//              hexadecimal, fewer if the file is shorter
//     quit     nothing; the process ends with status 0
//
// It uses nothing of the library that a program of another package could
// not use. It ends when its input ends, and after twenty seconds whatever
// happens, so that a test that fails leaves no process behind.

import Foundation
import XitDB

/// Answers the lines of a test about the file at `path`, read through a
/// storage of the kind named.
func watch(buffered: Bool, path: String) {
    alarm(20)
    let storage: any WritableStorage
    let still: () throws -> Bool
    do {
        if buffered {
            let opened = try BufferedFileStorage(path: path, access: .readOnly)
            storage = opened
            still = { try opened.isStillAtPath }
        } else {
            let opened = try FileStorage(path: path, access: .readOnly)
            storage = opened
            still = { try opened.isStillAtPath }
        }
    } catch {
        fail("XitDBFuzz: cannot open \(path): \(error)", status: 1)
    }
    say("open")
    while let line = readLine() {
        switch line {
        case "still":
            do {
                say(try still() ? "true" : "false")
            } catch {
                say("error \(error)")
            }
        case "read":
            do {
                var bytes = [UInt8](repeating: 0, count: 16)
                var span = bytes.mutableSpan
                let count = try storage.read(into: &span, range: 0..<16, at: 0)
                say(bytes[..<count].map { String(format: "%02x", $0) }.joined())
            } catch {
                say("error \(error)")
            }
        case "quit":
            exit(0)
        default:
            say("unknown \(line)")
        }
    }
}
