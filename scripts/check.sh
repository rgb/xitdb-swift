#!/usr/bin/env bash
#
# The gate. Run it from anywhere; it must pass at every commit offered for review.
#
#   1. debug build and tests
#   2. release build and tests
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

# Sources/XitDB may import the standard library, Synchronization and the platform C
# library, and nothing else. The platform C library may be imported in one file only.
# The documentation catalogue is not code of the library: the tutorials' step files in
# it are what a client writes, and import what a client imports.
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
        if (libcCount > 1) {
            printf "error: the platform C library is imported in %d files, but only one may:%s\n", libcCount, libcList
            failed = 1
        }
        exit failed
    }
' {} +
echo "ok"

step "Formatting check"
swift format lint --strict --recursive --parallel Package.swift Sources Tests
echo "ok"

# The DocC documentation for the library, built through swift-docc-plugin. With
# warnings as errors a link to a symbol that does not exist fails the gate.
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
