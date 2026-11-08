// A fuzzer for damaged files: the check that a damaged database gives an
// error and never a trap or a hang (R23). It builds one sample database in
// memory, damages it in one to three places chosen by a seed, and runs each
// damaged file through the battery of `Battery.swift`. It checks nothing
// else: every error is discarded.
//
//     XitDBFuzz run <hashSize> <from> <to> [targeted] [--progress <file>]
//     XitDBFuzz save <hashSize> <seed|good> [targeted] <path>
//     XitDBFuzz check <file>...
//
// `run` runs the seeds from `from` up to but not including `to` on the
// sample of that hash size. With `targeted` each change lands near a
// position taken from the undamaged file, in a slot, a header or a block;
// without it, anywhere. With `--progress` each seed is written to the file
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
    usage: XitDBFuzz run <hashSize> <from> <to> [targeted] [--progress <file>]
           XitDBFuzz save <hashSize> <seed|good> [targeted] <path>
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

/// The sample of `hashSize` and the positions a targeted run aims at, or
/// exits 1 when the sample cannot be built or gives nothing to aim at.
func makePlan(hashSize: Int, targeted: Bool) -> DamagePlan {
    do {
        let sample = try buildSample(hashSize: hashSize)
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

func run(hashSize: Int, seeds: Range<Int>, targeted: Bool, progress: String?) {
    let plan = makePlan(hashSize: hashSize, targeted: targeted)
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
    say("done: \(seeds.count) files, seeds \(seeds.lowerBound)..<\(seeds.upperBound), hash size \(hashSize), \(mode)")
}

func save(hashSize: Int, seed: Int?, targeted: Bool, to path: String) {
    let plan = makePlan(hashSize: hashSize, targeted: targeted)
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
        let hashSize = Int(arguments[0]), hashSize > 0,
        let from = Int(arguments[1]), from >= 0,
        let to = Int(arguments[2]), to >= from
    else { fail(usage, status: 2) }
    run(hashSize: hashSize, seeds: from..<to, targeted: arguments.count == 4, progress: progress)
case "save":
    guard arguments.count == 3 || arguments.count == 4 && arguments[2] == "targeted",
        let hashSize = Int(arguments[0]), hashSize > 0
    else { fail(usage, status: 2) }
    let seed: Int?
    if arguments[1] == "good" {
        seed = nil
    } else if let value = Int(arguments[1]), value >= 0 {
        seed = value
    } else {
        fail(usage, status: 2)
    }
    save(hashSize: hashSize, seed: seed, targeted: arguments.count == 4, to: arguments[arguments.count - 1])
case "check":
    guard !arguments.isEmpty else { fail(usage, status: 2) }
    check(arguments)
default:
    fail(usage, status: 2)
}
