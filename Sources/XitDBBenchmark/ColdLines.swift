// The cold lines of the memory map: what reading through the map costs when
// none of a file's pages is in memory, with the advice the map gives the
// system ("read in no order") and without it.
//
//     XitDBBenchmark --cold report <folder> [--elements <n>] [--keys <n>] [--passes <n>]
//                                           [--seconds <n>] [--under-limit] [--no-compaction]
//     XitDBBenchmark --cold prepare <path> <elements>
//     XitDBBenchmark --cold walk <path> [--no-advice] [--warm]
//     XitDBBenchmark --cold stream <path> [--no-advice] [--warm]
//
// `report` is the whole of it as one command, for a machine that is asked
// once. It prints the machine (the system, the memory, the page, the file
// system and the device under the folder, how far the system reads ahead
// there, the memory limit it finds itself under), makes two files in the
// folder if they are not there, and runs four lines, each with the advice
// and without, `--passes` times, the order turned from pass to pass:
//
//   walk        a walk of a list of `--elements` values of 256 bytes, written
//               in order, so that the walk goes through the file from its
//               start to its end;
//   stream      the stream of that file's committed bytes, which feeds a
//               replica and reads by file calls;
//   random      reads by key from a hash map of `--keys` values of 256 bytes,
//               the keys drawn the same way in every run, for `--seconds`
//               seconds on one thread, counted a second. It is this
//               benchmark's line and no server's;
//   compaction  the list's file compacted into a new file, the source read
//               through the map. It keeps an offset map in memory, some tens
//               of bytes an element: under a limit near that the system may
//               end the process, so it runs last, and `--no-compaction`
//               leaves it out.
//
// Before each run the file's pages are dropped from memory, by the file's
// own advice after a sync on Linux and by an invalidating sync of a mapping
// on macOS, and what is still there is CHECKED: above one page in two
// hundred the run is not cold, is said to be so and is not timed.
//
// THE LIMIT. The command does not hold itself to a memory limit: it is run
// inside whatever holds it, finds the limit from the system's files, and
// prints it beside the files' lengths. It never calls a line "under a
// limit" when it finds none, and with `--under-limit` it stops at once
// then. To run it under half and under a quarter of a file, run it once
// without a limit, which makes the files and prints their lengths, and
// then inside a container (`docker run --memory=<bytes> --memory-swap=<bytes>`)
// or a scope of the system's (`systemd-run --user --scope -p MemoryMax=<bytes>
// -p MemorySwapMax=0`) given half and a quarter of the larger length. The
// files' pages are dropped before each run, so what a run brings in is
// counted against the limit it runs under.
//
// `prepare`, `walk` and `stream` are the single lines: one run, one line of
// JSON, and status 3 with "NOT COLD" for a run that is not cold.

import Foundation
import XitDB

// MARK: The two files

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

/// A step of SplitMix64: the next state, and the number drawn from it.
private func mixed(_ state: inout UInt64) -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
}

/// The hash key `index` of the map is stored under: twenty bytes drawn
/// from the index, so that the keys lie in the map as hashes do and no
/// hashing is on the clock.
private func keyHash(_ index: Int, into hash: inout [UInt8]) {
    var state = UInt64(index)
    for word in 0..<3 {
        var value = mixed(&state)
        for position in (word * 8)..<min(word * 8 + 8, 20) {
            hash[position] = UInt8(truncatingIfNeeded: value)
            value >>= 8
        }
    }
}

/// Writes a database whose one moment is made by `fill`, under a name of
/// its own, and gives it `path` when it is whole: a file that is there is
/// one that was finished.
private func writeDatabase(_ path: String, _ fill: (Cursor<ReadWrite>) throws -> Void) throws -> UInt64 {
    let partial = path + ".partial"
    let storage = try BufferedFileStorage(path: partial, access: .truncate, durability: .none)
    let database = try Database(creating: storage, hashSize: 20)
    let history = try ArrayList<ReadWrite>(database.rootCursor)
    try history.append(.slot(nil)) { cursor in try fill(cursor) }
    try storage.flush()
    let size = try storage.length
    guard rename(partial, path) == 0 else { throw BenchmarkFailure(description: "cannot name \(path)") }
    return size
}

/// Writes the list of `elements` values at `path`.
private func prepareList(path: String, elements: Int) throws -> UInt64 {
    try writeDatabase(path) { cursor in
        let list = try ArrayList<ReadWrite>(cursor)
        for index in 0..<elements {
            try list.append(.bytes(payload(index)))
        }
    }
}

/// Writes the hash map of `keys` values at `path`.
private func prepareMap(path: String, keys: Int) throws -> UInt64 {
    try writeDatabase(path) { cursor in
        let map = try HashMap<ReadWrite>(cursor)
        var hash = [UInt8](repeating: 0, count: 20)
        for index in 0..<keys {
            keyHash(index, into: &hash)
            try map.put(.bytes(payload(index)), forHash: hash)
        }
    }
}

// MARK: A file's pages

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

/// The part of the file's pages that is in memory now.
private func partInMemory(of path: String) throws -> Double {
    let file = try WholeFile(path)
    defer { file.release() }
    return try file.inMemory()
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

// MARK: The lines

/// A sink that counts what it is given and keeps nothing.
private struct CountingSink: ByteSink {
    var count = 0

    mutating func write(_ bytes: Span<UInt8>) throws {
        count += bytes.count
    }
}

/// The lines a run can be of.
private enum ColdLine: String, CaseIterable {
    case walk, stream, random, compaction
}

/// One run of a line, as it is printed.
private struct ColdRun {
    let line: ColdLine
    let advised: Bool
    /// The part of the file in memory before the run, after its pages were
    /// dropped; `nil` for a run that dropped nothing.
    let before: Double?
    var seconds = 0.0
    /// What the run did: elements walked, bytes streamed or written, reads.
    var done = 0
    var faults = 0
    var fileSize: UInt64 = 0
    /// For the random line: the reads of each whole second, and the part of
    /// the file in memory when the run ended.
    var perSecond: [Int] = []
    var after: Double?

    /// The line's figure: seconds, or for the random line reads a second.
    var figure: Double {
        line == .random ? Double(done) / seconds : seconds
    }

    var json: String {
        var fields = [
            #""line": "\#(line.rawValue)""#, #""advice": \#(advised)"#,
            String(format: #""seconds": %.4f"#, seconds), #""done": \#(done)"#, #""major_faults": \#(faults)"#,
            #""in_memory_before": \#(before.map { String(format: "%.4f", $0) } ?? "null")"#,
            #""file_size": \#(fileSize)"#,
        ]
        if line == .random {
            fields.append(String(format: #""reads_a_second": %.0f"#, figure))
            fields.append(#""each_second": [\#(perSecond.map(String.init).joined(separator: ", "))]"#)
            fields.append(#""in_memory_after": \#(after.map { String(format: "%.4f", $0) } ?? "null")"#)
        }
        return "{" + fields.joined(separator: ", ") + "}"
    }
}

/// A run that could not be made cold.
private struct NotCold: Error {
    let part: Double
}

/// What a run of a line is given.
private struct ColdTask {
    let line: ColdLine
    /// The file the line reads.
    let path: String
    var advised = true
    var warm = false
    /// For the random line: how many keys the map has, and for how long.
    var keys = 0
    var seconds = 0.0
    /// For the compaction: where the new file goes. It is removed after.
    var target = ""
}

/// Runs one line once: drops the file's pages and checks that they are
/// gone, opens the file to be read through a memory map, with the advice
/// or without, and times the line.
///
/// - Throws: `NotCold` if more than one page in two hundred is still in
///   memory after the pages were dropped.
private func run(_ task: ColdTask) throws -> ColdRun {
    var before: Double?
    if !task.warm {
        let part = try dropPages(of: task.path)
        guard part <= 0.005 else { throw NotCold(part: part) }
        before = part
    }
    var result = ColdRun(line: task.line, advised: task.advised, before: before)

    // with the advice, the map as it is read unless told otherwise; without
    // it, the map left to the system's own reading ahead
    let file = try FileStorage(
        path: task.path, access: .readOnly, lock: .shared,
        reading: task.advised ? .memoryMap : .memoryMapReadAhead)
    guard file.isMemoryMapped else {
        throw BenchmarkFailure(description: "the file at \(task.path) is on a volume that is not read through a map")
    }
    let database = try Database(opening: file, hashSize: 20)
    result.fileSize = try file.length
    let last: InlineArray<1, PathPart> = [.arrayListGet(-1)]
    func moment() throws -> Cursor<ReadOnly> {
        guard let moment = try database.rootCursor.readOnly.readPath(last.span) else {
            throw BenchmarkFailure(description: "the database has no moment")
        }
        return moment
    }

    let faults = majorFaults()
    let clock = ContinuousClock()
    let began = clock.now
    func elapsed() -> Double {
        let time = clock.now - began
        return Double(time.components.seconds) + Double(time.components.attoseconds) / 1e18
    }
    switch task.line {
    case .walk:
        var iterator = try ArrayList<ReadOnly>(try moment()).iterator()
        var buffer = [UInt8](repeating: 0, count: 512)
        var sum: UInt64 = 0
        while let element = try iterator.next() {
            var span = buffer.mutableSpan
            let count = try element.readBytes(into: &span)
            guard count == 256 else { throw BenchmarkFailure(description: "an element of \(count) bytes") }
            sum &+= UInt64(buffer[0]) &+ UInt64(buffer[255])
            result.done += 1
        }
        guard sum != 0 else { throw BenchmarkFailure(description: "the walk read nothing") }
    case .stream:
        var sink = CountingSink()
        try database.readCommitted(from: 0, to: try database.committedSize, into: &sink)
        result.done = sink.count
    case .random:
        let map = try HashMap<ReadOnly>(try moment())
        var hash = [UInt8](repeating: 0, count: 20)
        var buffer = [UInt8](repeating: 0, count: 512)
        // the same keys in the same order in every run
        var state: UInt64 = 0x5EED_0F_C01D_11E5
        var second = 1.0
        var counted = 0
        while true {
            // the clock is looked at once in sixty-four reads
            for _ in 0..<64 {
                let index = Int(mixed(&state) % UInt64(task.keys))
                keyHash(index, into: &hash)
                guard let value = try map.cursor(forHash: hash.span) else {
                    throw BenchmarkFailure(description: "key \(index) is not in the map")
                }
                var span = buffer.mutableSpan
                let count = try value.readBytes(into: &span)
                guard count == 256, buffer[255] == UInt8(truncatingIfNeeded: index) else {
                    throw BenchmarkFailure(description: "key \(index) does not read back")
                }
            }
            result.done += 64
            let now = elapsed()
            while now >= second, second <= task.seconds {
                result.perSecond.append(result.done - counted)
                counted = result.done
                second += 1
            }
            if now >= task.seconds { break }
        }
    case .compaction:
        let target = try BufferedFileStorage(path: task.target, access: .truncate, durability: .none)
        var offsets = MemoryOffsetMap()
        _ = try database.compact(into: target, fileID: 0x0011_2233_4455_6677, offsetMap: &offsets)
        try target.flush()
        result.done = Int(try target.length)
    }
    result.seconds = elapsed()
    result.faults = majorFaults() - faults
    if task.line == .random { result.after = try partInMemory(of: task.path) }
    if task.line == .compaction { unlink(task.target) }
    return result
}

// MARK: The report

/// Prints a line at once, so that what was measured is on the record if a
/// later line ends the process.
private func say(_ line: String = "") {
    print(line)
    // every stream, and not the standard output by its name, which Linux
    // gives as a variable no code may touch from anywhere
    fflush(nil)
}

/// The least, the median and the most of some figures.
private func spread(_ figures: [Double]) -> (least: Double, median: Double, most: Double) {
    let sorted = figures.sorted()
    let middle = sorted.count / 2
    let median = sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    return (sorted[0], median, sorted[sorted.count - 1])
}

/// What `report` was asked for.
private struct ReportOptions {
    var elements = 4_000_000
    var keys = 3_000_000
    var passes = 3
    var seconds = 20.0
    var underLimit = false
    var compaction = true
}

/// The whole report: the machine, the two files, the four lines.
private func report(folder: String, _ options: ReportOptions) throws {
    do {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    } catch {
        throw BenchmarkFailure(description: "the folder \(folder) is not there and cannot be made: \(error)")
    }
    let machine = ColdMachine(directory: folder)
    say("THE COLD LINES OF THE MEMORY MAP")
    say("what a read through the map costs when none of a file's pages is in memory, with the advice the map")
    say("gives the system (\"read in no order\") and without it. Say which commit of xitdb-swift this was built from.")
    say()
    say("THE MACHINE")
    for line in machine.lines { say("  " + line) }
    if options.underLimit && machine.limit == nil {
        say()
        say("NO MEMORY LIMIT WAS FOUND, and --under-limit asks for one: nothing is run.")
        exit(4)
    }

    say()
    say("THE FILES")
    let list = folder + "/cold-list-\(options.elements).db"
    let map = folder + "/cold-map-\(options.keys).db"
    func length(_ path: String, _ what: String, _ make: () throws -> UInt64) throws -> UInt64 {
        if FileManager.default.fileExists(atPath: path) {
            let file = try WholeFile(path)
            defer { file.release() }
            say("  \(path): \(file.length) bytes, \(what), found there")
            return UInt64(file.length)
        }
        let size = try make()
        say("  \(path): \(size) bytes, \(what), written now")
        return size
    }
    let listSize = try length(list, "a list of \(options.elements) values of 256 bytes") {
        try prepareList(path: list, elements: options.elements)
    }
    let mapSize = try length(map, "a hash map of \(options.keys) values of 256 bytes") {
        try prepareMap(path: map, keys: options.keys)
    }
    func part(_ limit: UInt64, of size: UInt64) -> String {
        String(format: "%.2f", Double(limit) / Double(size))
    }
    if let limit = machine.limit {
        say(
            "  UNDER A LIMIT of \(limit.bytes) bytes: \(part(limit.bytes, of: listSize)) of the list's file, "
                + "\(part(limit.bytes, of: mapSize)) of the map's")
    } else {
        say("  NOT UNDER A LIMIT: no memory limit was found, and no line below is one under a limit.")
        say(
            "  Half and a quarter of the larger file are \(max(listSize, mapSize) / 2) and "
                + "\(max(listSize, mapSize) / 4) bytes.")
    }

    var lines: [ColdLine] = [.walk, .stream, .random]
    if options.compaction { lines.append(.compaction) }
    var runs: [ColdRun] = []
    var notCold = 0
    say()
    say("THE RUNS, each begun with the file's pages dropped from memory and that checked")
    for line in lines {
        for pass in 0..<options.passes {
            // the order turned from pass to pass
            for advised in pass % 2 == 0 ? [true, false] : [false, true] {
                var task = ColdTask(line: line, path: line == .random ? map : list, advised: advised)
                task.keys = options.keys
                task.seconds = options.seconds
                task.target = folder + "/cold-compacted.db"
                do {
                    let result = try run(task)
                    runs.append(result)
                    say("  " + result.json)
                } catch let error as NotCold {
                    notCold += 1
                    say(
                        String(
                            format: "  NOT COLD, and not timed: %@ %@, %.2f%% of the file's pages still in memory",
                            line.rawValue, advised ? "with the advice" : "without the advice", error.part * 100))
                }
            }
        }
    }
    // the walk once more with nothing dropped, for what the advice costs when the pages are there
    for advised in [true, false] {
        var task = ColdTask(line: .walk, path: list, advised: advised)
        task.warm = true
        let result = try run(task)
        say("  " + result.json + "   (nothing dropped before this one)")
    }

    say()
    say(
        machine.limit.map { "SUMMARY, UNDER A LIMIT of \($0.bytes) bytes" }
            ?? "SUMMARY, NOT UNDER A LIMIT")
    say("  seconds, or for the random line reads a second: median (least to most) of the runs that were cold")
    for line in lines {
        var medians: [Bool: Double] = [:]
        for advised in [true, false] {
            let figures = runs.filter { $0.line == line && $0.advised == advised }.map(\.figure)
            let name = "\(line.rawValue), \(advised ? "with the advice" : "without the advice")"
            guard !figures.isEmpty else {
                say("  \(name): no cold run")
                continue
            }
            let (least, median, most) = spread(figures)
            medians[advised] = median
            let format = line == .random ? "  %@: %.0f (%.0f to %.0f), %d runs" : "  %@: %.3f (%.3f to %.3f), %d runs"
            say(String(format: format, name, median, least, most, figures.count))
        }
        if let with = medians[true], let without = medians[false], with > 0, without > 0 {
            say(String(format: "  %@: with the advice over without, %.2f", line.rawValue, with / without))
        }
    }
    say("  the ratio is of times for the walk, the stream and the compaction, and of rates for the random line,")
    say("  which is this benchmark's own: reads by key from its hash map on one thread, and no server's.")
    if notCold > 0 { say("  \(notCold) runs could not be made cold and are not in the summary.") }
}

/// Runs `--cold` with what follows it on the command line.
func runColdLines(_ arguments: [String]) throws {
    var arguments = arguments
    let usage = BenchmarkFailure(
        description: """
            usage: --cold report <folder> [--elements <n>] [--keys <n>] [--passes <n>] [--seconds <n>]
                                          [--under-limit] [--no-compaction]
                   --cold prepare <path> <elements>
                   --cold walk <path> [--no-advice] [--warm]
                   --cold stream <path> [--no-advice] [--warm]
            To run the report under a memory limit, run it inside one: it finds the limit and prints it.
            """)
    func flag(_ name: String) -> Bool {
        guard let index = arguments.firstIndex(of: name) else { return false }
        arguments.remove(at: index)
        return true
    }
    func number(_ name: String) throws -> Int? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else { throw usage }
        arguments.removeSubrange(index...(index + 1))
        return value
    }
    guard let line = arguments.first else { throw usage }

    if line == "report" {
        var options = ReportOptions()
        options.elements = try number("--elements") ?? options.elements
        options.keys = try number("--keys") ?? options.keys
        options.passes = try number("--passes") ?? options.passes
        options.seconds = try number("--seconds").map(Double.init) ?? options.seconds
        options.underLimit = flag("--under-limit")
        options.compaction = !flag("--no-compaction")
        guard arguments.count == 2 else { throw usage }
        try report(folder: arguments[1], options)
        return
    }

    let advised = !flag("--no-advice")
    let warm = flag("--warm")
    guard arguments.count >= 2 else { throw usage }
    let path = arguments[1]
    if line == "prepare" {
        guard arguments.count == 3, let elements = Int(arguments[2]), elements > 0 else { throw usage }
        let size = try prepareList(path: path, elements: elements)
        print(#"{"line": "prepare", "elements": \#(elements), "file_size": \#(size)}"#)
        return
    }
    guard arguments.count == 2, let line = ColdLine(rawValue: line), line == .walk || line == .stream else {
        throw usage
    }
    var task = ColdTask(line: line, path: path, advised: advised)
    task.warm = warm
    do {
        print(try run(task).json)
    } catch let error as NotCold {
        FileHandle.standardError.write(
            Data("NOT COLD: \(error.part * 100)% of the file's pages are in memory after they were dropped\n".utf8))
        exit(3)
    }
}
