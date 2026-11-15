// The two cold lines of the memory map: a walk of a large list in file
// order, and the stream of a whole file's committed bytes, each read
// through the map when none of the file's pages is in memory.
//
//     XitDBBenchmark --cold prepare <path> <elements>
//     XitDBBenchmark --cold walk <path> [--no-advice] [--warm]
//     XitDBBenchmark --cold stream <path> [--no-advice] [--warm]
//
// `prepare` writes a database whose one moment is a list of `elements`
// values of 256 bytes each, appended in order in one transaction, so that
// the list's walk goes through the file from its start to its end. `walk`
// and `stream` first drop the file's pages from memory, by the file's own
// advice on Linux and by an invalidating sync of a mapping on macOS, and
// then CHECK how many are still there: if more than one in two hundred,
// the line is not cold, and the tool says so and exits with status 3. With
// `--warm` nothing is dropped and nothing checked. Then the file is opened
// to be read through a memory map, and the line is run once and timed.
//
// The map tells the system that it is read in no order; `--no-advice` runs
// the same without that, which is what the walk is measured against. The
// stream reads by file calls, which the advice does not reach.
//
// One line of JSON a run: the line, the advice, the seconds, the elements
// or bytes, the major faults the run took, and the part of the file that
// was in memory before it.

import Foundation
import XitDB

/// The payload of element `index`: 256 bytes that differ from element to
/// element, so that nothing is stored once and pointed at many times.
private func payload(_ index: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: 256)
    var value = UInt64(index) &* 0x9E37_79B9_7F4A_7C15
    for position in 0..<8 {
        bytes[position] = UInt8(truncatingIfNeeded: value)
        value >>= 8
    }
    return bytes
}

/// Writes the list of `elements` values at `path`, and syncs it.
private func prepare(path: String, elements: Int) throws {
    let storage = try BufferedFileStorage(path: path, access: .truncate, durability: .none)
    let database = try Database(creating: storage, hashSize: 20)
    let history = try ArrayList<ReadWrite>(database.rootCursor)
    try history.append(.slot(nil)) { cursor in
        let list = try ArrayList<ReadWrite>(cursor)
        for index in 0..<elements {
            try list.append(.bytes(payload(index)))
        }
    }
    try storage.flush()
    let size = try storage.length
    print(#"{"line": "prepare", "elements": \#(elements), "file_size": \#(size)}"#)
}

/// A mapping of a whole file for reading, for asking about its pages.
private struct WholeFile {
    let descriptor: Int32
    let address: UnsafeMutableRawPointer
    let length: Int

    init(_ path: String) throws {
        descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw BenchmarkFailure(description: "cannot open \(path)") }
        // the length by seeking and not from the file's status: on Linux
        // the compiler does not reliably find a C structure's members in a
        // target that imports Foundation
        let end = lseek(descriptor, 0, SEEK_END)
        guard end > 0 else {
            close(descriptor)
            throw BenchmarkFailure(description: "cannot ask the length of \(path)")
        }
        length = Int(end)
        guard let mapped = mmap(nil, length, PROT_READ, MAP_SHARED, descriptor, 0), mapped != MAP_FAILED else {
            close(descriptor)
            throw BenchmarkFailure(description: "cannot map \(path)")
        }
        address = mapped
    }

    /// Unmaps the file and closes it.
    func release() {
        munmap(address, length)
        _ = close(descriptor)
    }

    /// The part of the file's pages that is in memory, from 0 to 1.
    func inMemory() throws -> Double {
        let page = Int(getpagesize())
        let pages = (length + page - 1) / page
        #if canImport(Darwin)
            var states = [CChar](repeating: 0, count: pages)
        #else
            var states = [UInt8](repeating: 0, count: pages)
        #endif
        guard mincore(address, length, &states) == 0 else {
            throw BenchmarkFailure(description: "mincore failed with \(errno)")
        }
        let there = states.reduce(0) { $0 + (Int($1) & 1) }
        return Double(there) / Double(pages)
    }
}

/// Drops the file's pages from memory, as far as the system does on being
/// asked, and returns the part of them that is still there.
private func dropPages(of path: String) throws -> Double {
    let file = try WholeFile(path)
    defer { file.release() }
    #if canImport(Darwin)
        guard msync(file.address, file.length, MS_SYNC | MS_INVALIDATE) == 0 else {
            throw BenchmarkFailure(description: "msync failed with \(errno)")
        }
    #else
        guard fsync(file.descriptor) == 0 else { throw BenchmarkFailure(description: "fsync failed with \(errno)") }
        let advice = posix_fadvise(file.descriptor, 0, 0, POSIX_FADV_DONTNEED)
        guard advice == 0 else { throw BenchmarkFailure(description: "posix_fadvise failed with \(advice)") }
    #endif
    return try file.inMemory()
}

/// The major faults this process has taken so far: reads of a page that
/// had to be brought in from the file. On Linux from the system's own file
/// about the process, whose twelfth field it is, and not from `getrusage`,
/// for the reason given at the file's length; `-1` if it cannot be read.
private func majorFaults() -> Int {
    #if canImport(Darwin)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_majflt)
    #else
        guard let text = try? String(contentsOfFile: "/proc/self/stat", encoding: .utf8),
            let name = text.range(of: ") ", options: .backwards)
        else { return -1 }
        // what follows the name starts at the third field
        let fields = text[name.upperBound...].split(separator: " ")
        return fields.count > 9 ? Int(fields[9]) ?? -1 : -1
    #endif
}

/// A sink that counts what it is given and keeps nothing.
private struct CountingSink: ByteSink {
    var count = 0

    mutating func write(_ bytes: Span<UInt8>) throws {
        count += bytes.count
    }
}

/// Runs `--cold` with what follows it on the command line.
func runColdLines(_ arguments: [String]) throws {
    var arguments = arguments
    let usage = BenchmarkFailure(
        description: """
            usage: --cold prepare <path> <elements>
                   --cold walk <path> [--no-advice] [--warm]
                   --cold stream <path> [--no-advice] [--warm]
            """)
    func flag(_ name: String) -> Bool {
        guard let index = arguments.firstIndex(of: name) else { return false }
        arguments.remove(at: index)
        return true
    }
    let advised = !flag("--no-advice")
    let warm = flag("--warm")
    guard arguments.count >= 2 else { throw usage }
    let line = arguments[0]
    let path = arguments[1]
    if line == "prepare" {
        guard arguments.count == 3, let elements = Int(arguments[2]), elements > 0 else { throw usage }
        try prepare(path: path, elements: elements)
        return
    }
    guard arguments.count == 2, line == "walk" || line == "stream" else { throw usage }

    var before = -1.0
    if !warm {
        before = try dropPages(of: path)
        guard before <= 0.005 else {
            FileHandle.standardError.write(
                Data("NOT COLD: \(before * 100)% of the file's pages are in memory after they were dropped\n".utf8))
            exit(3)
        }
    }

    let file = try FileStorage(path: path, access: .readOnly, lock: .shared, memoryMapped: true)
    guard file.isMemoryMapped else {
        throw BenchmarkFailure(description: "the file at \(path) is on a volume that is not read through a map")
    }
    if !advised { file.calls.advise = { (_: UInt, _: Int) in } }
    let database = try Database(opening: file, hashSize: 20)
    let faults = majorFaults()
    let clock = ContinuousClock()
    let began = clock.now
    var done = 0
    switch line {
    case "walk":
        let last: InlineArray<1, PathPart> = [.arrayListGet(-1)]
        guard let moment = try database.rootCursor.readOnly.readPath(last.span) else {
            throw BenchmarkFailure(description: "the database has no moment")
        }
        var iterator = try ArrayList<ReadOnly>(moment).iterator()
        var buffer = [UInt8](repeating: 0, count: 512)
        var sum: UInt64 = 0
        while let element = try iterator.next() {
            var span = buffer.mutableSpan
            let count = try element.readBytes(into: &span)
            guard count == 256 else { throw BenchmarkFailure(description: "an element of \(count) bytes") }
            sum &+= UInt64(buffer[0]) &+ UInt64(buffer[255])
            done += 1
        }
        guard sum != 0 else { throw BenchmarkFailure(description: "the walk read nothing") }
    default:
        var sink = CountingSink()
        try database.readCommitted(from: 0, to: try database.committedSize, into: &sink)
        done = sink.count
    }
    let elapsed = clock.now - began
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    print(
        String(
            format: #"{"line": "%@", "advice": %@, "seconds": %.4f, "#
                + #""done": %d, "major_faults": %d, "in_memory_before": %@, "file_size": %llu}"#,
            line, advised ? "true" : "false", seconds, done, majorFaults() - faults,
            warm ? "null" : String(format: "%.4f", before), try file.length))
}
