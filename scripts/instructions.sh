#!/usr/bin/env bash
#
# The instructions a write, a read and a walk take in memory, a map's compaction in
# memory, three reads through a mapped file, and a list's read by index through a
# snapshot of a mapped file and of a database in memory, held to figures kept in the
# repository: scripts/instructions.txt.
#
#   scripts/instructions.sh check [figures]
#       runs the benchmark's four collections and a map's compaction in memory with
#       the release build that is there (the gate calls this right after its plain
#       release build), eight times with the stack at eight places (forty seconds),
#       three reads through a mapped file three times (ten seconds) and a read
#       through each of two snapshots three times (five seconds), and compares the least
#       instructions an operation took, line by line, with the figures. A line
#       that takes more than a per cent more fails: ROSE, status 1. A line that takes
#       more than a per cent less fails too and says to take the figures again: FELL,
#       status 4. Left as they were, the figures would let that much cost come back
#       unseen.
#
#   scripts/instructions.sh pin [figures]
#       builds the plain release benchmark and writes the figures, the least a line
#       over the eight places gone over twice, with the toolchain and the system they
#       were taken on. Look at the diff before committing it.
#
# Why: a check added to the reader's record read once cost an array list's read by
# index 26% more instructions and a hash map's put 7%, by leaving a call where the
# optimiser had compiled the read into the descents, and nothing in the gate said so.
# The benchmark's lines in memory are short enough that such a change shows in them
# by per cents. They are counted and not timed: taken as `measure` below takes it, the
# processor's count of instructions repeats within a tenth of a per cent, on a busy
# machine too, where a time needs a machine with nothing else on it.
#
# The figures belong to one compiler on one kind of system: another Swift, another
# processor or another major version of macOS moves them with no line of the package
# changed. On another of those the check compares nothing and says so, naming both;
# take the figures again there. A point update of the system, or another build of it,
# is compared, and the check says aloud that the figures were taken on another one: a
# line that such an update moves then fails here, where the figures are taken, which
# is where to learn of it. (The update from 27.2 to 27.2.1 moved no line by more than
# two tenths of an instruction, and under the rule before it the gate compared nothing
# for a day.) Only macOS gives a process this count; on Linux the check says that and
# passes.

set -euo pipefail
cd "$(dirname "$0")/.."

mode=${1:-}
figures=${2:-scripts/instructions.txt}
tolerance=1
workloads=(map_insert list_append linked_append sorted_insert)
compaction=map_compact
benchmark=.build/release/XitDBBenchmark

usage() {
    echo "usage: scripts/instructions.sh check [figures]" >&2
    echo "       scripts/instructions.sh pin [figures]" >&2
    exit 2
}
[ "$mode" = check ] || [ "$mode" = pin ] || usage

if [ "$(uname -s)" != Darwin ]; then
    echo "skipped: another system, not compared"
    echo "  the figures were taken on macOS, which gives a process the count of its instructions;"
    echo "  this is $(uname -s) $(uname -r), where the benchmark has no such count"
    exit 0
fi

toolchain=$(swift --version 2>&1 | head -1)
system="macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(sysctl -n machdep.cpu.brand_string)"

# "workload phase instructions-an-operation", a line for each phase of each collection:
# the least over several runs of the benchmark, each with its stack at another place.
#
# One run is not the work alone. The count moves with where the process's memory lies,
# with no line of the code changed: a hash map's get takes 2,177 instructions or 2,183
# (0.3% apart), its walk 1,822 or 1,828, a linked array list's append 30,303 or 30,435
# (0.4%), by where the stack starts, which is the size of the environment; and a hash
# map's put takes 3,406 or 3,510 (3%) by where the stack and the map's memory lie. An
# array list's lines and the others do not move at all. Nothing makes a run take fewer
# instructions than the work needs, so the least over a few places is the work: it
# repeats within a tenth of a per cent, and it is what was measured in a quiet hour
# with the two binaries alternated.
#
# So each run has an environment of its own making and nobody else's (`env -i`), with
# one variable whose length moves the stack's start by sixteen bytes a run, over eight
# places; the caller's environment, which differs between a terminal, a worktree and a
# runner, has no part in it. `measure <rounds>` goes over the eight places that many
# times.
#
# The thirteenth line is `map_compact write`: a map written by two thousand
# transactions, compacted from a database in memory into one in memory, an instruction
# count for each transaction's worth. Why it is held: a change to the file storages
# alone (2c69872) made that compaction 2.6% longer, because the optimiser compiled the
# storages' read into the compactor another way, and no line here counted a compaction
# at all; the twelve above moved by less than their per cent. Its count moves with the
# stack as a hash map's put does (49.0, 49.3 or 50.7 million for one binary), and its least
# over the eight places repeats within a hundredth of a per cent. The workload's read
# and walk are those of a map, which the twelve hold, and are left out.
places=8
measure() {
    local round place
    for round in $(seq "$1"); do
        for place in $(seq 0 $((places - 1))); do
            env -i P="$(printf '%*s' $((place * 16)) '' | tr ' ' x)" \
                "$benchmark" --kind memory "${workloads[@]}"
            env -i P="$(printf '%*s' $((place * 16)) '' | tr ' ' x)" \
                "$benchmark" --kind memory "$compaction"
        done
    done \
        | sed -E -n 's/.*"workload": "([a-z_]+)", "phase": "([a-z]+)", "kind": "memory", "n": ([0-9]+),.*"instructions": ([0-9]+),.*/\1 \2 \3 \4/p' \
        | awk -v compaction="$compaction" '
            $1 == compaction && $2 != "write" { next }
            { key = $1 " " $2; each = $4 / $3
              if (!(key in least)) { order[++lines] = key; least[key] = each }
              else if (each < least[key]) least[key] = each }
            END { for (line = 1; line <= lines; line++) printf "%s %.1f\n", order[line], least[order[line]] }'
}

# "mapped_<workload> read instructions-an-operation" for three reads through a mapped
# file: a hash map read by hash, an array list read by index, and typed reads of a
# number and a text by key (the benchmark's read-path mode, at a tenth of its size, on a
# file storage that reads through its memory map). The least over `measure_mapped
# <runs>` runs.
#
# Why these are held: a read through a mapped storage once made a run-time check of
# exclusive access for every read of the storage (one for each of the seven a list's
# read by index makes), and a system call for every byte array, and neither showed in
# the lines in memory (brief 36). Their read phases make no system call once the file
# is mapped, and repeat within three tenths of a per cent with the stack wherever it is,
# so they need no eight places. They need a temporary folder on a volume the library
# maps: where it is not, the benchmark says so and the lines are missing, which fails
# the check.
mapped=(map_insert list_append map_typed)
measure_mapped() {
    local run
    for run in $(seq "$1"); do
        env -i "$benchmark" --read-path --mapped --kind mapped_file --divide 10 "${mapped[@]}"
    done \
        | sed -E -n 's/.*"workload": "([a-z_]+)", "phase": "read", "kind": "mapped_file", "n": ([0-9]+),.*"instructions": ([0-9]+),.*/mapped_\1 read \2 \3/p' \
        | awk '
            { key = $1 " " $2; each = $4 / $3
              if (!(key in least)) { order[++lines] = key; least[key] = each }
              else if (each < least[key]) least[key] = each }
            END { for (line = 1; line <= lines; line++) printf "%s %.1f\n", order[line], least[order[line]] }'
}

# "snapshot_mapped_list_append read instructions-an-operation" and "snapshot_list_append
# read ...": an array list read by index through a snapshot of a database in a mapped
# file, and through a snapshot of a database in memory (the read-path mode's
# `--snapshot`, at a tenth of its size). The least over `measure_snapshot <runs>` runs.
#
# Why these are held: a snapshot's read goes through a type of its own, which no line
# above reaches, and a snapshot is what a program reads through on its other threads.
# That read stands between each of the engine's reads and the bytes as a call, where a
# storage's own read is compiled into its caller: a list's read by index takes a fifth
# more instructions through a snapshot of a mapped file than through the file's storage,
# and about a tenth more in memory. Compiling it in was tried and put back, because it
# took two of the lines in memory over their per cent (brief 36); until these two lines
# nothing in the gate counted a read through a snapshot at all, and whoever takes that
# up again is held by them. An array list's lines do not move with the stack, so these
# need no eight places either.
measure_snapshot() {
    local run
    for run in $(seq "$1"); do
        env -i "$benchmark" --read-path --mapped --snapshot --kind mapped_file --divide 10 list_append
        env -i "$benchmark" --read-path --snapshot --kind memory --divide 10 list_append
    done \
        | sed -E -n \
            -e 's/.*"workload": "([a-z_]+)", "phase": "read", "kind": "mapped_file", "n": ([0-9]+),.*"instructions": ([0-9]+),.*/snapshot_mapped_\1 read \2 \3/p' \
            -e 's/.*"workload": "([a-z_]+)", "phase": "read", "kind": "memory", "n": ([0-9]+),.*"instructions": ([0-9]+),.*/snapshot_\1 read \2 \3/p' \
        | awk '
            { key = $1 " " $2; each = $4 / $3
              if (!(key in least)) { order[++lines] = key; least[key] = each }
              else if (each < least[key]) least[key] = each }
            END { for (line = 1; line <= lines; line++) printf "%s %.1f\n", order[line], least[order[line]] }'
}

if [ "$mode" = pin ]; then
    swift build -c release --product XitDBBenchmark -Xswiftc -warnings-as-errors >/dev/null
    measured=$(
        measure 2
        measure_mapped 3
        measure_snapshot 3
    )
    [ "$(echo "$measured" | grep -c .)" -eq 18 ] || {
        echo "error: the benchmark printed $(echo "$measured" | grep -c .) lines with instructions, not eighteen" >&2
        exit 1
    }
    {
        echo "# The instructions an operation takes, by the benchmark's own count: what"
        echo "# scripts/instructions.sh holds the gate's plain release build to, within a per cent."
        echo "# Thirteen lines in memory, a map's compaction the last of them, the least a line"
        echo "# over eight places of the stack, twice;"
        echo "# three reads through a mapped file (\`mapped_\`) and a list's read by index through"
        echo "# a snapshot of a mapped file and of a database in memory (\`snapshot_\`), the least"
        echo "# of three runs. Taken with \`scripts/instructions.sh pin\`; take them again on"
        echo "# another toolchain, processor or major version of the system."
        echo "toolchain: $toolchain"
        echo "system: $system"
        echo "$measured"
    } >"$figures"
    echo "eighteen figures in $figures"
    exit 0
fi

[ -f "$figures" ] || {
    echo "error: no figures at $figures: take them with scripts/instructions.sh pin" >&2
    exit 1
}
[ -x "$benchmark" ] || {
    echo "error: no release build of the benchmark at $benchmark" >&2
    exit 1
}
pinned_toolchain=$(sed -n 's/^toolchain: //p' "$figures")
pinned_system=$(sed -n 's/^system: //p' "$figures")
# What of a system the figures go by: its major version, the first number after
# "macOS", and its processor, what follows the comma.
major() { sed -E 's/^macOS ([0-9]+).*/\1/' <<<"$1"; }
processor() { sed -E 's/^[^,]*, //' <<<"$1"; }
if [ "$pinned_toolchain" != "$toolchain" ] \
    || [ "$(processor "$pinned_system")" != "$(processor "$system")" ] \
    || [ "$(major "$pinned_system")" != "$(major "$system")" ]; then
    echo "skipped: another toolchain, processor or major version of the system, not compared"
    echo "  the figures were taken with: $pinned_toolchain"
    echo "                           on: $pinned_system"
    echo "  this is:                     $toolchain"
    echo "                           on: $system"
    echo "  take them again here with scripts/instructions.sh pin"
    exit 0
fi
if [ "$pinned_system" != "$system" ]; then
    echo "the figures were taken on ${pinned_system%%,*}; this is ${system%%,*}:"
    echo "  the same toolchain, processor and major version, so compared"
fi

measured=$(
    measure 1
    measure_mapped 3
    measure_snapshot 3
)
# Each line beside its figure; the status says whether any rose or fell past the tolerance.
status=0
echo "$measured" | awk -v figures="$figures" -v tolerance="$tolerance" '
    BEGIN {
        while ((getline line < figures) > 0) {
            if (line ~ /^[a-z_]+ [a-z]+ [0-9.]+$/) {
                split(line, part, " ")
                pinned[part[1] " " part[2]] = part[3]
                expected++
            }
        }
    }
    {
        key = $1 " " $2
        seen++
        if (!(key in pinned)) { printf "  %-27s %-8s %10.1f  has no figure\n", $1, $2, $3; missing++; next }
        change = ($3 - pinned[key]) / pinned[key] * 100
        mark = ""
        if (change > tolerance) { mark = "  ROSE"; rose = rose (rose ? ", " : "") $1 " " $2 }
        if (change < -tolerance) { mark = "  FELL"; fell = fell (fell ? ", " : "") $1 " " $2 }
        printf "  %-27s %-8s %10.1f  figure %10.1f  %+6.2f%%%s\n", $1, $2, $3, pinned[key], change, mark
    }
    END {
        if (missing || seen != expected) { printf "error: %d lines measured against %d figures\n", seen, expected; exit 3 }
        if (rose) printf "error: ROSE, more than %s%% more instructions than the figures: %s\n", tolerance, rose
        if (fell) {
            printf "error: FELL, more than %s%% fewer instructions than the figures: %s\n", tolerance, fell
            printf "       the figures must be taken again, and committed: scripts/instructions.sh pin\n"
        }
        if (rose) exit 1
        if (fell) exit 4
        printf "the %d are within %s%% of their figures\n", seen, tolerance
    }' || status=$?
exit "$status"
