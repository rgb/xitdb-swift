#!/usr/bin/env bash
#
# The gate. Run it from anywhere; it must pass at every commit offered for review.
#
#   1. debug build and tests
#   2. release build and tests, a smoke run of the benchmark and the corruption fuzzer
#   3. import check for Sources/XitDB
#   4. formatting check
#   5. documentation build
#   6. compile-only build for iOS, and the tests on an iOS simulator (on macOS)
#
# It runs on macOS and on Linux and stops at the first failure and exits non-zero.

set -euo pipefail
cd "$(dirname "$0")/.."

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
swift build "${strict[@]}"
swift test --skip SnapshotProofTests "${strict[@]}"

# The snapshot concurrency suite under the thread sanitizer, in a build of its
# own: a race in a snapshot's read half would be a wrong read that no plain run
# shows. The sanitizer slows the suite a great deal, so only that suite runs.
step "Thread sanitizer: snapshot concurrency"
swift test --sanitize=thread --scratch-path .build/tsan \
    --filter "SnapshotConcurrencyTests|tasksReadOneSnapshotWhileTheWriterCommits" "${strict[@]}"

# The plain release build is what a client compiles. `swift test` then rebuilds the
# library with testing enabled so that the tests can reach internal declarations.
step "Release build and tests"
swift build -c release "${strict[@]}"
swift test -c release "${strict[@]}"

# The benchmark, built above as the release build's second product, runs every
# workload on every kind at a hundredth of its size: that it runs is the check, not
# its numbers. It prints one line per phase; a workload that fails exits non-zero.
step "Benchmark smoke run"
.build/release/XitDBBenchmark --divide 100 > /dev/null
echo "ok"

# R23: a damaged file gives an error, never a trap or a hang. The fuzzer, the
# release build's third product, runs the damaged files that once trapped and then
# fresh damage from fixed seed ranges, so that the gate is reproducible. It runs
# directly and not through the restarting driver, so that a trap fails the gate;
# each file has twenty seconds before the tool's alarm ends it.
step "Corruption fuzzer"
.build/release/XitDBFuzz check scripts/fuzz-regressions/*.db
.build/release/XitDBFuzz run 32 1 2001 targeted
.build/release/XitDBFuzz run 2 1 1001 targeted
.build/release/XitDBFuzz run 65 1 501 targeted

# R5: Sources/XitDB may import the standard library, Synchronization and the platform C
# library, and nothing else. The platform C library is imported in exactly one file,
# behind `#if canImport` for Darwin, Glibc, Musl and Android. The documentation catalogue
# is not code of the library: the tutorials' step files in it are what a client writes,
# and import what a client imports.
step "Import check"
find Sources/XitDB -name '*.swift' -not -path '*.docc/*' -exec awk '
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
step "Documentation build"
swift package generate-documentation --target XitDB --warnings-as-errors
swift package generate-documentation --target XitDBHashing --warnings-as-errors
swift package generate-documentation --target XitDBStore --warnings-as-errors

# xcodebuild always uses the compiler that ships with Xcode. The workspace selects the
# same one for `swift`, so the whole gate runs on one compiler; its version is printed
# here so that a mismatch with the "Toolchain" step above would show. Only macOS has
# Xcode; the Linux gate ends with the documentation build.
if [ "$platform" = Darwin ]; then
    step "iOS compile check"
    xcrun swiftc --version
    xcrun swiftc --version 2>&1 | grep -q "Swift version $expected_swift " || {
        echo "error: xcodebuild would use another compiler than the gate: Swift $expected_swift expected"
        exit 1
    }
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
    step "iOS simulator tests"
    # `|| true` because the script runs under `set -e -o pipefail`: where no iPhone is
    # listed, grep's status 1 is the pipeline's, the assignment fails with it, and the gate
    # stopped here with nothing said instead of skipping. It also covers simctl failing.
    simulator=$(xcrun simctl list devices available 2>/dev/null \
        | grep -E '^ +iPhone [0-9]+ \(' | head -1 | sed -E 's/^ *(iPhone [0-9]+) .*/\1/') || true
    if [ -z "$simulator" ]; then
        echo "skipped: no iPhone simulator is available on this machine"
    else
        echo "simulator: $simulator, $(xcrun simctl list runtimes 2>/dev/null | grep -E '^iOS' | head -1 | cut -d' ' -f1-2)"
        # xcodebuild prints every compiler call; only the test summaries and the failures
        # are kept (pipefail carries xcodebuild's own status through the pipe).
        summary() { grep -E "Test run with|TEST (SUCCEEDED|FAILED)|error:|✘ Test " || true; }
        xcodebuild test \
            -scheme xitdb-swift-Package \
            -destination "platform=iOS Simulator,name=$simulator" \
            -derivedDataPath .build/xcodebuild-ios \
            -configuration Release \
            ENABLE_TESTABILITY=YES \
            SWIFT_TREAT_WARNINGS_AS_ERRORS=YES 2>&1 | summary
        xcodebuild test \
            -scheme xitdb-swift-Package \
            -destination "platform=iOS Simulator,name=$simulator" \
            -derivedDataPath .build/xcodebuild-ios-tsan \
            -enableThreadSanitizer YES \
            -only-testing:XitDBTests/SnapshotConcurrencyTests \
            '-only-testing:XitDBTests/SnapshotTests/tasksReadOneSnapshotWhileTheWriterCommits(kind:)' \
            SWIFT_TREAT_WARNINGS_AS_ERRORS=YES 2>&1 | summary
        echo "ok"
    fi
fi

printf '\n==> Gate passed\n'
