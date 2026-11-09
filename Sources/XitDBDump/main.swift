// xitdb-dump: prints an xitdb file as it is on disk.
//
//   xitdb-dump FILE [--moment N] [--all-moments] [--depth D] [--path k1/k2/#3]
//              [--json] [--keys NAMES] [--hash sha256|sha1|siphash128]
//              [--verify] [--offsets] [--full-hashes] [--limit N]
//
// Exit code 0 for a sound file, 1 for a damaged one that was partly dumped,
// 2 for a file that is not xitdb or arguments that are not understood.

import XitDB
import XitDBDumpKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

let usage = """
    usage: xitdb-dump FILE [options]
      --moment N        the moment to show, negative from the end (default: the last)
      --all-moments     every moment, with sharing between them marked
      --depth D         how deep to descend
      --path k1/k2/#3   start under the moment's root: a key by name, by hex hash, or #index
      --json            JSON instead of text
      --keys FILE       key names, one per line, to label hash-only entries
      --hash NAME       sha256 (default), sha1 or siphash128, for --keys and named path steps
      --verify          walk the commits' trailers and report them
      --offsets         each record's position and size
      --full-hashes     whole hashes instead of their first eight bytes
      --limit N         the most elements one collection shows (default 100000)

    """

func fail(_ message: String) -> Never {
    var error = StandardError()
    print("xitdb-dump: \(message)", to: &error)
    print(usage, to: &error)
    exit(2)
}

struct StandardError: TextOutputStream {
    mutating func write(_ string: String) {
        for byte in string.utf8 {
            var byte = byte
            _ = writeByteToStandardError(&byte)
        }
    }
}

func writeByteToStandardError(_ byte: UnsafeRawPointer) -> Int {
    write(2, byte, 1)
}

func readLines(_ path: String) -> [String] {
    guard let storage = try? FileStorage(path: path, access: .readOnly, durability: .none),
        let length = try? storage.length, let count = Int(exactly: length)
    else { fail("cannot read \(path)") }
    var bytes = [UInt8](repeating: 0, count: count)
    var span = bytes.mutableSpan
    guard let read = try? storage.read(into: &span, range: 0..<count, at: 0), read == count else {
        fail("cannot read \(path)")
    }
    return String(decoding: bytes, as: UTF8.self).split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
}

/// The options and the file from the command line.
func parse(_ given: [String]) -> (DumpOptions, String) {
    var arguments = given
    var options = DumpOptions()
    var file: String?
    func next(_ flag: String) -> String {
        guard !arguments.isEmpty else { fail("\(flag) needs a value") }
        return arguments.removeFirst()
    }
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--moment":
            guard let value = Int(next(argument)) else { fail("--moment needs a number") }
            options.moment = value
        case "--all-moments": options.allMoments = true
        case "--depth":
            guard let value = Int(next(argument)), value >= 0 else { fail("--depth needs a number") }
            options.depth = value
        case "--path":
            for part in next(argument).split(separator: "/") {
                if part.hasPrefix("#"), let index = Int(part.dropFirst()) {
                    options.path.append(.index(index))
                } else if part.count >= 16, part.count % 2 == 0, part.allSatisfy(\.isHexDigit) {
                    var bytes: [UInt8] = []
                    var text = Substring(part)
                    while !text.isEmpty {
                        bytes.append(UInt8(text.prefix(2), radix: 16)!)
                        text = text.dropFirst(2)
                    }
                    options.path.append(.hash(bytes))
                } else {
                    options.path.append(.key(String(part)))
                }
            }
        case "--json": options.json = true
        case "--keys": options.keys += readLines(next(argument))
        case "--hash":
            guard let hash = DumpOptions.Hash(rawValue: next(argument)) else {
                fail("--hash takes sha256, sha1 or siphash128")
            }
            options.hash = hash
        case "--verify": options.verify = true
        case "--offsets": options.offsets = true
        case "--full-hashes": options.fullHashes = true
        case "--limit":
            guard let value = Int(next(argument)), value > 0 else { fail("--limit needs a number above zero") }
            options.limit = value
        case "--help", "-h":
            print(usage)
            exit(0)
        default:
            if argument.hasPrefix("-") || file != nil { fail("unknown argument \(argument)") }
            file = argument
        }
    }
    guard let file else { fail("a file is needed") }
    return (options, file)
}

let (options, file) = parse(Array(CommandLine.arguments.dropFirst()))
let storage: FileStorage
do {
    storage = try FileStorage(path: file, access: .readOnly, durability: .none)
} catch {
    fail("cannot open \(file): \(error)")
}
var dumper = Dumper(options: options)
let dump = dumper.dump(storage)
print(
    options.json ? JSONRenderer.render(dump, options: options) : TextRenderer.render(dump, options: options),
    terminator: "")
exit(dump.exitCode)
