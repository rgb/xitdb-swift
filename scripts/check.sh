#!/usr/bin/env bash
#
# The gate. Run it from anywhere; it must pass at every commit offered for review.
#
#   1. debug build and tests, what must not compile, and the conformance suite's test
#      of two processes with the port's reader, where the suite is beside the package
#   2. release build and tests, the instructions of the in-memory lines against their
#      figures (compared on macOS, on the toolchain, the processor and the major
#      version of the system the figures were taken on), a smoke run of the benchmark
#      and the corruption fuzzer
#      Every run of the tests has a time limit (scripts/limit.sh), and the limit is
#      tried on a test planted to sleep.
#   3. import check for Sources/XitDB, that only the tests' own target for it
#      starts a process, and that no test is marked as a known failure
#   4. formatting check
#   5. documentation build
#   6. compile-only build for iOS, and the tests on an iOS simulator (on macOS)
#
# It runs on macOS and on Linux and stops at the first failure and exits non-zero.

set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/symbol-graphs.sh

step() { printf '\n==> %s\n' "$*"; }

# Warnings are errors in every build we run. The flag is passed here and not set in
# Package.swift, where it would also apply when a client uses the package through a
# path dependency (see the comment there).
strict=(-Xswiftc -warnings-as-errors)

# On macOS the gate runs on one compiler, Xcode's, which `.swift-version` selects for
# every clone and worktree; a scratch copy elsewhere may pick up another toolchain and
# measure or build something else. The version is checked, not only printed: two builds
# compared across toolchains once showed differences that were the compilers', not the
# code's. On Linux the toolchain is the one the runner has, any Swift 6.4.x: the open
# source releases and Xcode's need not share a patch number, and the version printed is
# the record of which one ran.
expected_swift="6.4.2"
platform=$(uname -s)
source scripts/limit.sh

# The limits of the test runs, in seconds: some ten times what each run takes on this
# machine with other work beside it, so that only a run that does not end reaches one.
# Measured: the debug tests 50 to 150 seconds here and 37 to 44 in the container; the
# snapshot suite under the thread sanitizer under 5; the release tests, with the
# snapshot proof, 20; the simulator's two runs, which build as they go, 100 to 230
# together.
debug_limit=900
sanitizer_limit=300
release_limit=600
simulator_limit=1800
# The suite's test of two processes takes 8 seconds here with the port's six kinds and
# the suite's own two; the suite itself ends a reader that stops answering.
two_processes_limit=300

step "Toolchain"
swift --version
case "$platform" in
Darwin)
    swift --version 2>&1 | grep -q "Swift version $expected_swift " || {
        echo "error: the gate needs Swift $expected_swift, Xcode's toolchain (.swift-version selects it)"
        exit 1
    }
    ;;
Linux)
    swift --version 2>&1 | grep -q -E "Swift version 6\.4(\.[0-9]+)? " || {
        echo "error: the gate needs a Swift 6.4.x toolchain on Linux"
        exit 1
    }
    ;;
*)
    echo "error: the gate runs on macOS and Linux, not on $platform"
    exit 1
    ;;
esac

# The snapshot proof over the fixtures (SnapshotProofTests) costs many times the
# replay in a debug build; it runs in the release tests below.
step "Debug build and tests"
# A file is read through a memory map only on a volume of this machine's own, and a
# storage that was asked for the map and is not given it says so only through a
# property. The tests of the mapped kinds therefore fail where their files are not
# mapped, naming the file; on Linux, where the rule goes by the kind of file system,
# this line says which kind the tests' files were on.
if [ "$platform" = Linux ]; then
    tests_folder=${TMPDIR:-/tmp}
    echo "the tests' files are in $tests_folder, on a $(df --output=fstype "$tests_folder" | tail -1) file system"
fi
swift build "${strict[@]}"
swift build --build-tests "${strict[@]}"
limited "$debug_limit" swift test --skip-build --skip SnapshotProofTests "${strict[@]}"

# The limit itself, tried: a test that sleeps for an hour when the gate's variable is
# set (GatePlantTests) is run with a limit of ten seconds. The gate has to end it, show
# what its test process was doing, and leave no test process behind.
step "A run of the tests that does not end is ended"
if limited 10 env XITDB_GATE_PLANT_A_TEST_WITHOUT_END=1 swift test --skip-build \
    --filter aTestThatDoesNotEnd "${strict[@]}" >.build/without-end.txt 2>&1; then
    echo "error: a test that sleeps for an hour was let run to its end"
    exit 1
fi
grep -q "^error: the run did not end within 10 seconds" .build/without-end.txt || {
    tail -5 .build/without-end.txt
    echo "error: the run was not ended by its limit"
    exit 1
}
grep -q "^---- the test process" .build/without-end.txt || {
    tail -5 .build/without-end.txt
    echo "error: the run was ended without a look at its test process"
    exit 1
}
# what the look itself shows, between its two rules: the sleeping test in the sample,
# or a thread with its state
sed -n '/^---- the test process/,/^----$/p' .build/without-end.txt \
    | grep -q "aTestThatDoesNotEnd\|sleepForTimeInterval\|^ *[0-9][0-9]* .* [RSD]$" || {
    echo "error: the look at the test process shows nothing of it"
    exit 1
}
sleep 1
left=$(test_processes_left)
[ -z "$left" ] || {
    echo "error: test processes were left behind when the run was ended: $left"
    exit 1
}
echo "ended at its limit, its test process looked at ($(grep -c . .build/without-end.txt) lines), none left behind"

# On macOS the package is built for an iOS simulator now, and only run at the gate's end.
# The simulator's tests build every target, the tools with the libraries, so a source
# that does not compile for iOS, a tool's as much as a library's, would otherwise fail
# the gate in its last step, after everything else had passed: a call that iOS's SDK
# lacks, in the benchmark, once did. Built here it stops the gate in its first minutes.
# The products stay in the derived data the last step uses, which finds them built and
# runs them, so a passing gate builds them once.
#
# xcodebuild always uses the compiler that ships with Xcode. The workspace selects the
# same one for `swift`, so the whole gate runs on one compiler; its version is printed
# here so that a mismatch with the "Toolchain" step above would show.
if [ "$platform" = Darwin ]; then
    # xcodebuild keeps the package's resource bundles in its derived data and
    # does not refresh them when Package.swift declares a new resource folder:
    # a gate once passed every step and then failed on the simulator, whose
    # test bundle lacked a folder the commit had added. The derived data is
    # removed when Package.swift or the set of resource files differs from
    # what the last passing gate saw, which a stamp records; a cold simulator
    # step costs minutes more than a warm one, so it is not removed every time.
    # POSIX tools only: a Mac with GNU coreutils first on its PATH, as the
    # Actions runner has, reads `stat -f` as a file system query, and `cksum`
    # prints the same on both.
    stamp=.build/xcodebuild-stamp
    current=$({
        cat Package.swift
        find Sources Tests -path '*/Resources/*' -type f -exec cksum {} + | LC_ALL=C sort
    } | cksum | cut -d' ' -f1,2)
    if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$current" ]; then
        echo "Package.swift or the resources changed since the last passing gate: xcodebuild starts clean"
        rm -rf .build/xcodebuild .build/xcodebuild-ios .build/xcodebuild-ios-tsan
    fi

    step "iOS simulator build"
    xcrun swiftc --version
    xcrun swiftc --version 2>&1 | grep -q "Swift version $expected_swift " || {
        echo "error: xcodebuild would use another compiler than the gate: Swift $expected_swift expected"
        exit 1
    }
    # `|| true` because the script runs under `set -e -o pipefail`: where no iPhone is
    # listed, grep's status 1 is the pipeline's, the assignment fails with it, and the gate
    # stopped here with nothing said instead of skipping. It also covers simctl failing.
    simulator=$(xcrun simctl list devices available 2>/dev/null \
        | grep -E '^ +iPhone [0-9]+ \(' | head -1 | sed -E 's/^ *(iPhone [0-9]+) .*/\1/') || true
    # xcodebuild prints every compiler call; only the test summaries and the failures
    # are kept (pipefail carries xcodebuild's own status through the pipe).
    summary() { grep -E "Test run with|TEST (BUILD )?(SUCCEEDED|FAILED)|error:|✘ Test " || true; }
    if [ -z "$simulator" ]; then
        echo "skipped: no iPhone simulator is available on this machine"
    else
        echo "simulator: $simulator, $(xcrun simctl list runtimes 2>/dev/null | grep -E '^iOS' | head -1 | cut -d' ' -f1-2)"
        xcodebuild build-for-testing \
            -scheme xitdb-swift-Package \
            -destination "platform=iOS Simulator,name=$simulator" \
            -derivedDataPath .build/xcodebuild-ios \
            -configuration Release \
            ENABLE_TESTABILITY=YES \
            SWIFT_TREAT_WARNINGS_AS_ERRORS=YES 2>&1 | summary
        echo "ok"
    fi
fi

# D35, item 4: an integer whose kind is not spelled does not compile, since `Int` is
# not a value. A test target cannot hold code the compiler has to refuse, so two files
# are type-checked against the library the debug build made: one that must compile,
# and one that must be refused on each marked line with the library's own message.
step "What must not compile"
scripts/must-not-compile.sh

# The conformance suite holds what the port's first client rests on, and what no script
# of its fixtures can: the original commits to a file while a reader in another process,
# with no lock and one database object, is asked what it sees, through 300 commits each
# followed by a question, 300 more with questions answered while it commits, and then a
# compaction into a new file renamed over the old name and 50 commits to the new one.
# Every answer has to be a committed state, none going back and none an error, and the
# reader that kept the old file has to go on answering the old file's last state.
#
# The reader is the port's (Sources/XitDBConformanceReader), the one the debug build
# made, on each of its six kinds of file storage: the two storages, each read by file
# calls and through a memory map in either of its two ways. The writer and the rule are
# the suite's (its two-processes.sh, section 15 of its SCRIPT-FORMAT.md), so the step
# runs where the suite and its built driver are beside the package, or where
# XITDB_CONFORMANCE names them, and says aloud where they are not, as in a container
# that holds the package alone: there nothing is held, and the step does not pretend.
# The suite's script takes its writer and its own reader from TWO_PROCESSES_DRIVER and
# TWO_PROCESSES_OWN_READER where they are set, as they are for a run on Linux with the
# suite mounted (its linux-two-processes.sh builds them for Linux); the step looks for
# the ones the script will use.
# The suite writes its files where TWO_PROCESSES_OUT says, which is under this
# package's build folder: nothing is written into the suite's.
step "Conformance: a reader in another process"
suite=${XITDB_CONFORMANCE:-../conformance}
suite_driver=${TWO_PROCESSES_DRIVER:-$suite/zig-out/bin/two-processes}
suite_reader=${TWO_PROCESSES_OWN_READER:-$suite/zig-out/bin/reader}
if [ -f "$suite/two-processes.sh" ] && [ -x "$suite_driver" ] && [ -x "$suite_reader" ]; then
    reader="$(swift build --show-bin-path)/XitDBConformanceReader"
    [ -x "$reader" ] || {
        echo "error: the debug build left no reader at $reader"
        exit 1
    }
    suite_commit=$(git -C "$suite" rev-parse --short HEAD 2>/dev/null || echo "no commit to name")
    if [ -n "$(git -C "$suite" status --porcelain 2>/dev/null)" ]; then
        suite_commit="$suite_commit, with changes that are not committed"
    fi
    echo "the suite at $suite: $suite_commit"
    rm -rf .build/two-processes
    TWO_PROCESSES_OUT="$PWD/.build/two-processes" limited "$two_processes_limit" sh "$suite/two-processes.sh" "$reader"
else
    echo "skipped: the conformance suite's script, its writer or its own reader is not there:"
    echo "  $suite/two-processes.sh, $suite_driver, $suite_reader"
    echo "  the port's reader is not held against a writer in another process in this run"
fi

# The snapshot concurrency suite under the thread sanitizer, in a build of its
# own: a race in a snapshot's read half would be a wrong read that no plain run
# shows. The sanitizer slows the suite a great deal, so only that suite runs.
#
# On macOS the sanitizer is told not to put names to the addresses of a report.
# Left to do so it hangs: with a race planted in this suite the step printed
# nothing and never ended, at no load, so a real race would have been a gate
# that does not finish. With symbolize=0 the same race is three reports and a
# failed step in seconds. A report then gives places as offsets in the test
# binary, such as (XitDBTests:arm64+0xc4bd68), which atos names:
#     atos -o .build/tsan/out/Products/Debug/XitDBTests.xctest/Contents/MacOS/XitDBTests \
#         -arch arm64 -l 0x0 0xc4bd68
# On Linux the sanitizer names the places itself and ends, and so does the
# simulator's sanitizer run further down, which fails by itself on a race:
# both are left as they are.
step "Thread sanitizer: snapshot concurrency"
swift build --build-tests --sanitize=thread --scratch-path .build/tsan "${strict[@]}"
sanitized=(
    swift test --skip-build --sanitize=thread --scratch-path .build/tsan
    --filter "SnapshotConcurrencyTests|tasksReadOneSnapshotWhileTheWriterCommits" "${strict[@]}"
)
if [ "$platform" = Darwin ]; then
    limited "$sanitizer_limit" env TSAN_OPTIONS="${TSAN_OPTIONS:+$TSAN_OPTIONS }symbolize=0" "${sanitized[@]}"
else
    limited "$sanitizer_limit" "${sanitized[@]}"
fi

# The plain release build is what a client compiles.
step "Release build"
swift build -c release "${strict[@]}"

# What a write, a read and a walk cost in memory, in instructions, against the figures
# in scripts/instructions.txt: a line that takes more than a per cent more fails the
# gate, here, on the build a client compiles and before the tests' build replaces it.
# The script says why it is there, and what it does on another toolchain or system, and
# on Linux, where a process is given no such count: it compares nothing, and says so.
step "Instructions in memory"
scripts/instructions.sh check

# The build of the tests rebuilds the library with testing enabled, so that the tests
# can reach internal declarations. Only `swift test` builds a release that way (its
# `--enable-testable-imports`, which `swift build` does not have: built by `swift build
# -c release --build-tests`, the tests' `@testable import` finds no module it can use,
# and the gate failed here). So the build is `swift test list`, which builds the tests
# as `swift test` does and runs none; its output, a line a test, is shown only if it
# fails.
step "Release tests"
swift test list -c release "${strict[@]}" >.build/release-tests-build.txt 2>&1 || {
    cat .build/release-tests-build.txt
    echo "error: the release tests did not build"
    exit 1
}
limited "$release_limit" swift test -c release --skip-build "${strict[@]}"

# The benchmark, built above as the release build's second product, runs every
# workload on every kind at a hundredth of its size: that it runs is the check, not
# its numbers. It prints one line per phase; a workload that fails exits non-zero. So
# does its measure of what a hash costs, which checks every hash it computes. On macOS
# its map of a phase over the stack positions of a page runs too: it fails when its
# recursion no longer reaches every position, which a compiler that lays the frames out
# differently would bring about. If it fails here, the library is not at fault: the two
# recursions in the benchmark (descend and descendByLongerFrames) need another look, so
# that one of them again moves the stack by an odd number of sixteen bytes a level.
#
# The second run is the same workloads on files read through a memory map, with the
# map's limit at each write and then at each commit. It fails where the temporary
# folder is on a volume the library does not map.
step "Benchmark smoke run"
.build/release/XitDBBenchmark --divide 100 > /dev/null
.build/release/XitDBBenchmark --divide 100 --mapped > /dev/null
.build/release/XitDBBenchmark --divide 100 --mapped --map-at-commits > /dev/null
.build/release/XitDBBenchmark --hash-cost --divide 100 > /dev/null
if [ "$platform" = Darwin ]; then
    .build/release/XitDBBenchmark --divide 100 --stack-sweep list_append memory iterate 1 > /dev/null
fi
echo "ok"

# R23: a damaged file gives an error, never a trap or a hang. The fuzzer, the
# release build's third product, runs the damaged files that once trapped and then
# fresh damage from fixed seed ranges, so that the gate is reproducible. It runs
# directly and not through the restarting driver, so that a trap fails the gate;
# each file has twenty seconds before the tool's alarm ends it.
#
# Targeted damage lands near a position taken from the sample's data and never in a
# header, so each sample also gets damage anywhere in the file: a header that claims
# another hash size is how compaction's trap on long hashes was found.
#
# The samples it builds are format version 2, as every new database is. The last runs
# are on its version 1 sample, whose bytes it keeps, since nothing creates version 1:
# they are the fixtures' input v1-history, and the comparison holds the two copies to
# each other.
#
# With --mapped the battery works on files read through a memory map, where a damaged
# pointer or count must give an error and never a read of a part of the file that is
# not there, which is a signal and ends the tool: the damaged files that once trapped,
# and the targeted and the anywhere damage of the first sample and of the version 1
# sample.
step "Corruption fuzzer"
.build/release/XitDBFuzz check Tests/XitDBTests/Resources/damaged/*.db
.build/release/XitDBFuzz run 32 1 2001 targeted
.build/release/XitDBFuzz run 2 1 1001 targeted
.build/release/XitDBFuzz run 65 1 501 targeted
.build/release/XitDBFuzz run 32 1 2001
.build/release/XitDBFuzz run 2 1 2001
.build/release/XitDBFuzz run 65 1 2001
.build/release/XitDBFuzz save v1 good .build/fuzz-v1-sample.db
cmp .build/fuzz-v1-sample.db Tests/XitDBTests/Resources/fixtures/inputs/v1-history.db
.build/release/XitDBFuzz run v1 1 2001 targeted
.build/release/XitDBFuzz run v1 1 2001
.build/release/XitDBFuzz check --mapped Tests/XitDBTests/Resources/damaged/*.db
.build/release/XitDBFuzz run 32 1 2001 targeted --mapped
.build/release/XitDBFuzz run 32 1 2001 --mapped
.build/release/XitDBFuzz run 2 1 1001 targeted --mapped
.build/release/XitDBFuzz run 65 1 501 targeted --mapped
.build/release/XitDBFuzz run v1 1 2001 targeted --mapped
.build/release/XitDBFuzz run v1 1 2001 --mapped

# R5: Sources/XitDB may import the standard library, Synchronization and the platform C
# library, and nothing else. The platform C library is imported in exactly one file,
# behind `#if canImport` for Darwin, Glibc, Musl and Android. The documentation catalogue
# holds no Swift file, so every Swift file under Sources/XitDB is the library's.
# The tests that start another process have a test target of their own,
# XitDBProcessTests, and so a process of their own to run in. While a process is being
# started it holds the open files of the one that starts it for a moment, a locked one
# among them, and a test beside it that closes a file and opens it again with its lock
# is refused the lock: with such a test among the others the suite failed once in eight
# runs, in a test that had nothing to do with it (Tests/XitDBProcessTests says how it
# was found). So no test outside that target may start a process, by any of the calls
# that do.
step "Tests that start a process"
if grep -rnE '(^|[^A-Za-z0-9_.])(Process\(\)|posix_spawnp?\(|fork\(\)|system\("|popen\()' Tests --include='*.swift' \
    | grep -v '^Tests/XitDBProcessTests/'; then
    echo "error: a test outside Tests/XitDBProcessTests starts a process"
    exit 1
fi
echo "ok: only Tests/XitDBProcessTests does"

# No test is let off. The standards have no skipped tests and no weakened assertions, and
# a test marked as a known failure is both: it runs, and what it expects is not held. Two
# harnesses of a full copy were written before the code they hold and carried such a mark
# until every file storage wrote the copy into a new file; the mark is gone, and this step
# keeps it and its kind from coming back: a known issue, an expected failure, a skip, a
# disabled test. A test that cannot run on a system says so with `.enabled(if:)` and the
# reason, which is not this.
step "No test is marked as a known failure"
if grep -rnE 'withKnownIssue|XCTExpectFailure|XCTSkip|\.disabled\(' Tests --include='*.swift'; then
    echo "error: a test is marked as a known failure, skipped or disabled"
    exit 1
fi
echo "ok: none is"

step "Import check"
find Sources/XitDB -name '*.swift' -exec awk '
    {
        line = $0
        sub(/^[ \t]+/, "", line)
        while (line ~ /^@[A-Za-z_]+(\([^)]*\))?[ \t]+/) {
            sub(/^@[A-Za-z_]+(\([^)]*\))?[ \t]+/, "", line)
        }
        sub(/^(public|package|internal|fileprivate|private)[ \t]+/, "", line)
        if (line !~ /^import[ \t]+/) next
        sub(/^import[ \t]+/, "", line)
        sub(/^(typealias|struct|class|enum|protocol|let|var|func)[ \t]+/, "", line)
        if (!match(line, /^[A-Za-z_][A-Za-z0-9_]*/)) next
        module = substr(line, RSTART, RLENGTH)

        if (module == "Swift" || module == "Synchronization") next
        if (module == "Darwin" || module == "Glibc" || module == "Musl" || module == "Android") {
            if (!(FILENAME in libcFiles)) {
                libcFiles[FILENAME] = 1
                libcList = libcList "\n  " FILENAME
                libcCount++
            }
            next
        }
        printf "%s:%d: error: import of %s is not allowed in Sources/XitDB\n", FILENAME, FNR, module
        failed = 1
    }
    END {
        if (libcCount != 1) {
            printf "error: the platform C library is imported in %d files, and exactly one must:%s\n", libcCount, libcList
            failed = 1
        }
        exit failed
    }
' {} +
# The one file guards each import of the C library with `#if canImport`, for the four
# libraries R5 names, so that the package builds on each platform.
libc_file=$(grep -l -E '^[[:space:]]*(public |package |internal |private )?import[[:space:]]+(Darwin|Glibc|Musl|Android)' -r Sources/XitDB)
for library in Darwin Glibc Musl Android; do
    grep -q -E "^#(if|elseif) canImport\($library\)" "$libc_file" || {
        echo "error: $libc_file does not import $library behind #if canImport($library)"
        exit 1
    }
done
echo "ok"

step "Formatting check"
swift format lint --strict --recursive --parallel Package.swift Sources Tests
echo "ok"

# The DocC documentation for the library, built through swift-docc-plugin. With
# warnings as errors a link to a symbol that does not exist fails the gate. The
# plugin compiles the library once more for its symbol graph, without the compiler's
# warnings-as-errors flag: the debug and release builds above compile the same
# sources with it, so a compiler warning cannot reach this step unseen.
#
# The symbol graphs the build kept from earlier runs are removed first, so that the
# documentation is built from the sources as they are: scripts/symbol-graphs.sh says
# why, and what a step that read them got wrong.
step "Documentation build"
remove_kept_symbol_graphs
swift package generate-documentation --target XitDB --warnings-as-errors
swift package generate-documentation --target XitDBHashing --warnings-as-errors
swift scripts/check-curation.swift

# The rest needs Xcode, which only macOS has; the Linux gate ends with the documentation
# build.
if [ "$platform" = Darwin ]; then
    step "iOS compile check"
    # The scheme is the library's. Xcode makes one scheme per product once a package has more
    # than one, and none named after the package, which is what this used before the benchmark
    # became the second product.
    xcodebuild build -quiet \
        -scheme XitDB \
        -destination 'generic/platform=iOS' \
        -derivedDataPath .build/xcodebuild \
        SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
    echo "ok"

    # The tests on an iOS simulator: the release tests with the snapshot proof, as the
    # release step above runs them, and the snapshot concurrency suite under the thread
    # sanitizer, as the sanitizer step does. The simulator is the first plain iPhone that
    # the installed runtimes offer; a machine without one skips the step and says so. The
    # fixtures reach the simulator in the test bundle; the file storages write in the
    # simulator's temporary directory. The scheme is the package's, the one Xcode makes
    # with every target and test target in it, and testability is switched on for the
    # release configuration so that the tests reach internal declarations as they do under
    # `swift test -c release`.
    # The first of the two runs finds the scheme built: the simulator build above, early
    # in the gate, built it in this configuration and this derived data.
    step "iOS simulator tests"
    simulator_start=$(date +%s)
    if [ -z "$simulator" ]; then
        echo "skipped: no iPhone simulator is available on this machine"
    else
        # A simulator run under its limit: its output is kept and only its summary
        # shown, as before; a run that is ended shows what the limit printed, the look
        # at its test process with it.
        simulated() {
            local status=0
            limited "$simulator_limit" "$@" >.build/simulator-tests.txt 2>&1 || status=$?
            summary <.build/simulator-tests.txt
            if [ "$status" -eq 124 ]; then
                sed -n '/^error: the run did not end within/,$p' .build/simulator-tests.txt
            fi
            return "$status"
        }
        simulated xcodebuild test \
            -scheme xitdb-swift-Package \
            -destination "platform=iOS Simulator,name=$simulator" \
            -derivedDataPath .build/xcodebuild-ios \
            -configuration Release \
            ENABLE_TESTABILITY=YES \
            SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
        simulated xcodebuild test \
            -scheme xitdb-swift-Package \
            -destination "platform=iOS Simulator,name=$simulator" \
            -derivedDataPath .build/xcodebuild-ios-tsan \
            -enableThreadSanitizer YES \
            -only-testing:XitDBTests/SnapshotConcurrencyTests \
            '-only-testing:XitDBTests/SnapshotTests/tasksReadOneSnapshotWhileTheWriterCommits(kind:)' \
            SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
        echo "ok ($(( $(date +%s) - simulator_start )) s)"
    fi
    echo "$current" > "$stamp"
fi

printf '\n==> Gate passed\n'
