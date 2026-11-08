#!/usr/bin/env bash
#
# The gate. Run it from anywhere; it must pass at every commit offered for review.
#
#   1. debug build and tests
#   2. release build and tests, a smoke run of the benchmark and the corruption fuzzer
#   3. import check for Sources/XitDB
#   4. formatting check
#   5. documentation build
#   6. compile-only build for iOS
#
# It stops at the first failure and exits non-zero.

set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n==> %s\n' "$*"; }

# Warnings are errors in every build we run. The flag is passed here and not set in
# Package.swift, where it would also apply when a client uses the package through a
# path dependency (see the comment there).
strict=(-Xswiftc -warnings-as-errors)

step "Toolchain"
swift --version

step "Debug build and tests"
swift build "${strict[@]}"
swift test "${strict[@]}"

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

# xcodebuild always uses the compiler that ships with Xcode. The workspace selects the
# same one for `swift`, so the whole gate runs on one compiler; its version is printed
# here so that a mismatch with the "Toolchain" step above would show.
step "iOS compile check"
xcrun swiftc --version
# The scheme is the library's. Xcode makes one scheme per product once a package has more
# than one, and none named after the package, which is what this used before the benchmark
# became the second product.
xcodebuild build -quiet \
    -scheme XitDB \
    -destination 'generic/platform=iOS' \
    -derivedDataPath .build/xcodebuild \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
echo "ok"

printf '\n==> Gate passed\n'
