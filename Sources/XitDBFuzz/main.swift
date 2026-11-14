// A fuzzer for damaged files: the check that a damaged database gives an
// error and never a trap or a hang (R23). It takes one sample database,
// damages it in one to three places chosen by a seed, and runs each damaged
// file through the battery of `Battery.swift`. It checks nothing else:
// every error is discarded.
//
//     XitDBFuzz run <hashSize|v1> <from> <to> [targeted] [--progress <file>]
//     XitDBFuzz save <hashSize|v1> <seed|good> [targeted] <path>
//     XitDBFuzz check <file>...
//
// The sample is built in memory with hashes of `hashSize` bytes, in format
// version 2, as every new database is; `v1` names the version 1 sample of
// `VersionOneSample.swift` instead, whose bytes are kept.
//
// `run` runs the seeds from `from` up to but not including `to` on the
// sample. With `targeted` each change lands near a position taken from the
// undamaged file, in a slot, a header or a block; without it, anywhere.
// With `--progress` each seed is written to the file
// before it runs and `done` at the end, which is how `scripts/fuzz.sh` goes
// on after a crash. `save` writes the damaged file of a seed, or the
// undamaged sample for `good`, to a path. `check` runs files through the
// battery, printing each path before it runs, so that a trap names the
// file. A file gets twenty seconds; a hang is ended by the alarm.
//
// Exits 2 on bad arguments, 1 when the sample cannot be built or a file
// cannot be read or written, and 0 otherwise. A trap ends the process with
// a signal, which is what the driver and the gate look for.

import Foundation
import XitDB

let usage = """
    usage: XitDBFuzz run <hashSize|v1> <from> <to> [targeted] [--progress <file>]
           XitDBFuzz save <hashSize|v1> <seed|good> [targeted] <path>
           XitDBFuzz check <file>...
    """

/// Prints `message` to standard error and exits with `status`.
func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

/// Prints a line and flushes it, so that it is on record before a trap.
func say(_ line: String) {
    print(line)
    fflush(nil)
}

/// Writes `text` over the file at `path`, or exits 1.
func write(_ text: String, to path: String) {
    do {
        try text.write(toFile: path, atomically: false, encoding: .utf8)
    } catch {
        fail("XitDBFuzz: cannot write \(path): \(error)", status: 1)
    }
}

/// Which sample a run damages.
enum SampleChoice: CustomStringConvertible {
    /// The sample built at start with hashes of this many bytes, in format
    /// version 2.
    case built(hashSize: Int)

    /// The version 1 sample, whose bytes are kept.
    case versionOne

    /// The choice an argument names: `v1`, or a hash size above zero.
    init?(_ argument: String) {
        if argument == "v1" {
            self = .versionOne
        } else if let hashSize = Int(argument), hashSize > 0 {
            self = .built(hashSize: hashSize)
        } else {
            return nil
        }
    }

    var description: String {
        switch self {
        case .built(let hashSize): "hash size \(hashSize)"
        case .versionOne: "the version 1 sample"
        }
    }

    /// The sample's bytes.
    func bytes() throws -> [UInt8] {
        switch self {
        case .built(let hashSize): try buildSample(hashSize: hashSize)
        case .versionOne: versionOneSample
        }
    }
}

/// The sample chosen and the positions a targeted run aims at, or exits 1
/// when the sample cannot be built or gives nothing to aim at.
func makePlan(_ choice: SampleChoice, targeted: Bool) -> DamagePlan {
    do {
        let sample = try choice.bytes()
        let positions = try harvestedPositions(of: sample)
        if targeted && positions.isEmpty {
            fail("XitDBFuzz: the sample gives no position to aim at", status: 1)
        }
        return DamagePlan(sample: sample, positions: positions, targeted: targeted)
    } catch {
        fail("XitDBFuzz: cannot build the sample database: \(error)", status: 1)
    }
}

/// Runs the battery on `bytes` with the alarm set, so that a hang ends the
/// process after twenty seconds.
func runTimed(_ bytes: [UInt8]) {
    alarm(20)
    runBattery(on: bytes)
    alarm(0)
}

func run(_ choice: SampleChoice, seeds: Range<Int>, targeted: Bool, progress: String?) {
    let plan = makePlan(choice, targeted: targeted)
    say("file size \(plan.sample.count)")
    say("harvested \(plan.positions.count)")
    for seed in seeds {
        if let progress {
            write(String(seed), to: progress)
        }
        runTimed(plan.damaged(seed: seed))
    }
    if let progress {
        write("done", to: progress)
    }
    let mode = targeted ? "targeted" : "untargeted"
    say("done: \(seeds.count) files, seeds \(seeds.lowerBound)..<\(seeds.upperBound), \(choice), \(mode)")
}

func save(_ choice: SampleChoice, seed: Int?, targeted: Bool, to path: String) {
    let plan = makePlan(choice, targeted: targeted)
    let bytes = seed.map { plan.damaged(seed: $0) } ?? plan.sample
    do {
        try Data(bytes).write(to: URL(fileURLWithPath: path))
    } catch {
        fail("XitDBFuzz: cannot write \(path): \(error)", status: 1)
    }
}

func check(_ paths: [String]) {
    for path in paths {
        let bytes: [UInt8]
        do {
            bytes = Array(try Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            fail("XitDBFuzz: cannot read \(path): \(error)", status: 1)
        }
        say(path)
        runTimed(bytes)
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage, status: 2) }
arguments.removeFirst()
switch command {
case "run":
    var progress: String? = nil
    if let index = arguments.firstIndex(of: "--progress") {
        guard index + 1 < arguments.count else { fail(usage, status: 2) }
        progress = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
    }
    guard arguments.count == 3 || arguments.count == 4 && arguments[3] == "targeted",
        let choice = SampleChoice(arguments[0]),
        let from = Int(arguments[1]), from >= 0,
        let to = Int(arguments[2]), to >= from
    else { fail(usage, status: 2) }
    run(choice, seeds: from..<to, targeted: arguments.count == 4, progress: progress)
case "save":
    guard arguments.count == 3 || arguments.count == 4 && arguments[2] == "targeted",
        let choice = SampleChoice(arguments[0])
    else { fail(usage, status: 2) }
    let seed: Int?
    if arguments[1] == "good" {
        seed = nil
    } else if let value = Int(arguments[1]), value >= 0 {
        seed = value
    } else {
        fail(usage, status: 2)
    }
    save(choice, seed: seed, targeted: arguments.count == 4, to: arguments[arguments.count - 1])
case "check":
    guard !arguments.isEmpty else { fail(usage, status: 2) }
    check(arguments)
default:
    fail(usage, status: 2)
}
