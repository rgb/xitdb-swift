#!/usr/bin/env bash
#
# What must not compile. A test target cannot hold code the compiler has to
# refuse, so this type-checks two files against the library the debug build
# made:
#
#   scripts/must-not-compile/Accepted.swift   must type-check
#   scripts/must-not-compile/Refused.swift    must be refused on every line
#                                             marked "// must not compile",
#                                             with the library's own message,
#                                             and have no other error
#
# The message is the one the library gives its unavailable `Int: StorableValue`,
# read from the source, so that the check follows the text if it is reworded;
# the compiler's framing around it is not matched. `Accepted.swift` goes first
# and the same way: if the library is not found or a flag is wrong, that fails
# the step, and nothing is taken for a refusal.
#
# Run it after `swift build` (the gate does). It type-checks and builds nothing.

set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
    echo "error: $*"
    exit 1
}

bin=$(swift build --show-bin-path)
# SwiftPM's two build systems keep the modules in the products folder or in a
# Modules folder inside it.
flags=(-typecheck -swift-version 6 -I "$bin" -I "$bin/Modules")

message=$(sed -n 's/^@available(\*, unavailable, message: "\(.*\)")$/\1/p' Sources/XitDB/Cursor/StorableValue.swift)
[ -n "$message" ] || fail "the message of the unavailable Int conformance was not found in StorableValue.swift"

accepted=scripts/must-not-compile/Accepted.swift
refused=scripts/must-not-compile/Refused.swift

if ! output=$(swiftc "${flags[@]}" "$accepted" 2>&1); then
    echo "$output"
    fail "$accepted must compile, and does not"
fi

if output=$(swiftc "${flags[@]}" "$refused" 2>&1); then
    fail "$refused compiled: the compiler refused nothing in it"
fi

# The lines the compiler refused with the library's message, and every other
# error it gave.
ours=$(printf '%s\n' "$output" | grep -F "$message" | sed -n 's/^[^:]*Refused\.swift:\([0-9]*\):[0-9]*: error: .*/\1/p' | sort -n -u)
others=$(printf '%s\n' "$output" | grep -E 'Refused\.swift:[0-9]+:[0-9]+: error: ' | grep -v -F "$message" || true)
marked=$(grep -n '// must not compile$' "$refused" | cut -d: -f1 | sort -n -u)

[ -n "$marked" ] || fail "$refused marks no line"
if [ -n "$others" ]; then
    echo "$others"
    fail "$refused is refused for another reason than the one it is here for"
fi
if [ "$ours" != "$marked" ]; then
    echo "marked:  $(echo $marked)"
    echo "refused: $(echo $ours)"
    fail "the lines marked in $refused are not the lines the compiler refused with \"$message\""
fi
echo "ok: $(echo "$marked" | wc -l | tr -d ' ') lines refused with \"$message\""
