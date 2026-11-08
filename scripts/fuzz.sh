#!/usr/bin/env bash
#
# The corruption fuzzer's driver: R23, a damaged file gives an error and never a
# trap or a hang. It builds the tool, then runs it one of two ways.
#
#   scripts/fuzz.sh regressions
#       runs every file in scripts/fuzz-regressions/ through the battery, as the
#       gate does. A trap or a hang fails it.
#
#   scripts/fuzz.sh run <hashSize> <from> <to> [targeted]
#       the long run: the seeds from..<to on the sample database of that hash
#       size, restarting the tool after each crash and going on from the next
#       seed. Each crash is a line `seed=N exit=CODE :: message` in
#       .build/fuzz/<tag>.log, where 133 is SIGTRAP; the tool's output is in
#       .build/fuzz/<tag>.out and .build/fuzz/<tag>.err, and the seed being run
#       in .build/fuzz/<tag>.progress. At the end it prints the crashes grouped
#       by exit status and message, most frequent first. To run one seed again,
#       or to keep its file:
#           .build/release/XitDBFuzz run 32 35923 35924 targeted
#           .build/release/XitDBFuzz save 32 35923 targeted damaged.db

set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    echo "usage: scripts/fuzz.sh regressions" >&2
    echo "       scripts/fuzz.sh run <hashSize> <from> <to> [targeted]" >&2
    exit 2
}

swift build -c release --product XitDBFuzz -Xswiftc -warnings-as-errors
bin=.build/release/XitDBFuzz

case "${1:-}" in
regressions)
    [[ $# -eq 1 ]] || usage
    "$bin" check scripts/fuzz-regressions/*.db
    ;;
run)
    [[ $# -eq 4 || ($# -eq 5 && $5 == targeted) ]] || usage
    hash_size=$2
    from=$3
    to=$4
    targeted="${5:-}"
    tag="h${hash_size}${targeted:+-targeted}"
    mkdir -p .build/fuzz
    log=.build/fuzz/$tag.log
    progress=.build/fuzz/$tag.progress
    : > "$log"
    rm -f "$progress"
    current=$from
    while [[ $current -lt $to ]]; do
        code=0
        # shellcheck disable=SC2086
        "$bin" run "$hash_size" "$current" "$to" $targeted --progress "$progress" \
            > ".build/fuzz/$tag.out" 2> ".build/fuzz/$tag.err" || code=$?
        # the tool refused to start, before any seed ran
        if [[ ! -f $progress ]]; then
            cat ".build/fuzz/$tag.err" >&2
            exit "$code"
        fi
        last=$(cat "$progress")
        if [[ $last == done ]]; then
            echo "finished at $to" >> "$log"
            break
        fi
        message=$(grep -m1 -E 'Fatal|fatal|Illegal|overflow|out of bounds|failure|error' \
            ".build/fuzz/$tag.err" | cut -c1-200 || true)
        echo "seed=$last exit=$code :: $message" >> "$log"
        current=$((last + 1))
    done
    echo "log: $log"
    sort -t: -k3 "$log" | cut -d' ' -f2- | sort | uniq -c | sort -rn | head -40
    ;;
*)
    usage
    ;;
esac
