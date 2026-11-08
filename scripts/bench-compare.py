#!/usr/bin/env python3
#
# Compares the Swift benchmark with the Zig original's, as the benchmark workflow does.
#
#   scripts/bench-compare.py <zig bench> <swift benchmark> [--passes 3] [--divide d] [--raw DIR]
#
# For example, with the conformance repository's release build beside this package:
#
#   scripts/bench-compare.py ../conformance/out/release/bin/bench .build/release/XitDBBenchmark
#
# Both binaries print one JSON object per line, one per workload, phase and kind:
#
#   {"workload": "map_insert", "phase": "write", "kind": "memory", "n": 100000, "median_ms": 15.2, "file_size": 9397536}
#
# A pass is one run of a binary over every workload, and each of its lines is already the
# median of five runs. The two alternate, Zig first, for the number of passes, so that a
# change in the machine's load falls on both. The table, Markdown on standard output, has
# for each workload, kind and phase the median over the passes of each side and the ratio
# Swift / Zig. It is a report: nothing is compared with a threshold, and the script fails
# only when a benchmark does, or prints something it cannot read.
#
# --divide passes the same divisor to both binaries, for a quick check that everything
# runs; the numbers then mean nothing. --raw keeps every pass's lines as
# <DIR>/<side>-<pass>.jsonl.
#
# The Zig bench writes its scratch files under out/ in its working directory, so it runs
# in a temporary directory of its own; the Swift benchmark uses the system's temporary
# directory. The Zig bench must be a ReleaseFast build: a debug build refuses to run
# without --divide.

import argparse
import json
import os
import statistics
import subprocess
import sys
import tempfile
import time

SIDES = ("zig", "swift")


def fail(message):
    sys.stderr.write("bench-compare: " + message + "\n")
    sys.exit(1)


def run(side, binary, extra, cwd, current, passes):
    """One pass of one side: the parsed records, in the order printed."""
    sys.stderr.write("pass %d of %d, %s: " % (current, passes, side))
    sys.stderr.flush()
    started = time.monotonic()
    try:
        completed = subprocess.run(
            [binary] + extra, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
        )
    except OSError as error:
        sys.stderr.write("\n")
        fail("cannot run %s: %s" % (binary, error))
    elapsed = time.monotonic() - started
    if completed.returncode != 0:
        sys.stderr.write("failed\n")
        sys.stderr.write(completed.stderr)
        fail("%s exited with status %d in pass %d" % (binary, completed.returncode, current))
    records = []
    for line in completed.stdout.splitlines():
        if not line.strip():
            continue
        try:
            record = json.loads(line)
            key = (record["workload"], record["kind"], record["phase"])
            float(record["median_ms"])
            int(record["file_size"])
            int(record["n"])
        except (ValueError, KeyError, TypeError):
            sys.stderr.write("\n")
            fail("%s printed a line that is not a benchmark record: %s" % (binary, line))
        records.append((key, record))
    if not records:
        sys.stderr.write("\n")
        fail("%s printed nothing" % binary)
    sys.stderr.write("%d lines in %.1f s\n" % (len(records), elapsed))
    return records


def milliseconds(value):
    if value >= 10:
        return "%.1f" % value
    if value >= 1:
        return "%.2f" % value
    return "%.4f" % value


def sizes(records):
    """The file sizes a side reported for one key, without repeats, in order."""
    seen = []
    for record in records:
        size = int(record["file_size"])
        if size not in seen:
            seen.append(size)
    return seen


def table(order, results, passes, divide):
    lines = [
        "| Workload | Kind | Phase | n | Zig ms | Swift ms | Swift / Zig | File size |",
        "|---|---|---|---:|---:|---:|---:|---:|",
    ]
    for key in order:
        workload, kind, phase = key
        zig = results["zig"].get(key, [])
        swift = results["swift"].get(key, [])
        n = int((zig or swift)[0]["n"])
        cells = []
        for records in (zig, swift):
            if records:
                cells.append(milliseconds(statistics.median(float(r["median_ms"]) for r in records)))
            else:
                cells.append("-")
        if zig and swift:
            zig_median = statistics.median(float(r["median_ms"]) for r in zig)
            swift_median = statistics.median(float(r["median_ms"]) for r in swift)
            ratio = "%.2f" % (swift_median / zig_median) if zig_median > 0 else "-"
        else:
            ratio = "-"
        zig_sizes, swift_sizes = sizes(zig), sizes(swift)
        if zig_sizes == swift_sizes and len(zig_sizes) == 1:
            size = "{:,}".format(zig_sizes[0])
        else:
            size = "Zig %s, Swift %s" % (
                ", ".join("{:,}".format(s) for s in zig_sizes) or "-",
                ", ".join("{:,}".format(s) for s in swift_sizes) or "-",
            )
        lines.append(
            "| `%s` | %s | %s | %s | %s | %s | %s | %s |"
            % (workload, kind, phase, "{:,}".format(n), cells[0], cells[1], ratio, size)
        )
    lines.append("")
    lines.append(
        "Times in milliseconds: each side's median over %d pass%s, each pass the benchmark's own median of "
        "five runs. The ratio is Swift divided by Zig; below 1 the port is faster. The file size is the same on "
        "both sides unless the row says otherwise." % (passes, "" if passes == 1 else "es")
    )
    if divide:
        lines.append("")
        lines.append("Every size was divided by %d: the numbers mean nothing, this is a check that both run." % divide)
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        usage="%(prog)s <zig bench> <swift benchmark> [--passes 3] [--divide d] [--raw DIR]",
        description="Runs the Zig and the Swift benchmark alternately and prints a Markdown table comparing them.",
    )
    parser.add_argument("zig", help="the conformance repository's bench, a ReleaseFast build")
    parser.add_argument("swift", help="XitDBBenchmark, a release build")
    parser.add_argument("--passes", type=int, default=3, help="runs of each side, alternated (default 3)")
    parser.add_argument("--divide", type=int, help="divide every size by this, to check that both run")
    parser.add_argument("--raw", metavar="DIR", help="keep every pass's lines as DIR/<side>-<pass>.jsonl")
    args = parser.parse_args()
    if args.passes < 1:
        parser.error("--passes needs at least 1")
    if args.divide is not None and args.divide < 1:
        parser.error("--divide needs at least 1")
    binaries = {"zig": os.path.abspath(args.zig), "swift": os.path.abspath(args.swift)}
    for side in SIDES:
        if not os.path.isfile(binaries[side]) or not os.access(binaries[side], os.X_OK):
            fail("%s is not an executable file" % binaries[side])
    extra = ["--divide", str(args.divide)] if args.divide else []
    if args.raw:
        os.makedirs(args.raw, exist_ok=True)

    order = []
    results = {side: {} for side in SIDES}
    with tempfile.TemporaryDirectory(prefix="bench-compare-") as scratch:
        for current in range(1, args.passes + 1):
            for side in SIDES:
                cwd = scratch if side == "zig" else None
                records = run(side, binaries[side], extra, cwd, current, args.passes)
                if args.raw:
                    with open(os.path.join(args.raw, "%s-%d.jsonl" % (side, current)), "w") as raw:
                        for _, record in records:
                            raw.write(json.dumps(record) + "\n")
                for key, record in records:
                    if key not in order:
                        order.append(key)
                    results[side].setdefault(key, []).append(record)
    print(table(order, results, args.passes, args.divide))


if __name__ == "__main__":
    main()
