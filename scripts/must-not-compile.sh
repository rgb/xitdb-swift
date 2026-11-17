#!/usr/bin/env bash
#
# What must not compile. A test target cannot hold code the compiler has to
# refuse, so this type-checks four files against the library the debug build
# made:
#
#   scripts/must-not-compile/Accepted.swift   must type-check
#   scripts/must-not-compile/Refused.swift    must be refused on every line
#                                             marked "// must not compile",
#                                             with the library's own message,
#                                             and have no other error
#   scripts/must-not-compile/RefusedSendable.swift
#                                             must be refused on every line
#                                             marked "// must not compile: T",
#                                             with the message of T's
#                                             unavailable `Sendable`
#                                             conformance, and have no other
#                                             error; and the types it names
#                                             must be the ones the library
#                                             marks, no more and no fewer
#   scripts/must-not-compile/RefusedUntyped.swift
#                                             must be refused on every line
#                                             marked "// must not compile:
#                                             untyped", with the compiler's
#                                             words for an error that is not
#                                             the one declared, and have no
#                                             other error
#
# The message is the one the library gives its unavailable `Int: StorableValue`,
# read from the source, so that the check follows the text if it is reworded;
# the compiler's framing around it is not matched. `Accepted.swift` goes first
# and the same way: if the library is not found or a flag is wrong, that fails
# the step, and nothing is taken for a refusal. The third file's message is the
# compiler's own, since the library has none to give there: a compiler that
# words it otherwise fails the step, which is then the moment to read what it
# says.
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

# What stays with one thread must not be sent. Every type the library marks
# with an unavailable `Sendable` conformance, with its message, as "type<TAB>
# message": the attribute's line and the extension's line after it.
sendable=scripts/must-not-compile/RefusedSendable.swift
declared=$(grep -rh -A1 '^@available(\*, unavailable, message: ".*")$' Sources/XitDB --include='*.swift' | awk '
    /^@available/ { text = $0; sub(/^@available\(\*, unavailable, message: "/, "", text); sub(/"\)$/, "", text); next }
    /^extension [A-Za-z]+: Sendable \{\}$/ { name = $2; sub(/:$/, "", name); print name "\t" text }' | sort)
[ -n "$declared" ] || fail "no unavailable Sendable conformance was found in Sources/XitDB"

if output=$(swiftc "${flags[@]}" "$sendable" 2>&1); then
    fail "$sendable compiled: the compiler refused nothing in it"
fi
errors=$(printf '%s\n' "$output" | grep -E 'RefusedSendable\.swift:[0-9]+:[0-9]+: error: ' || true)
marked=$(grep -n '// must not compile: [A-Za-z]*$' "$sendable" | sed -E 's|^([0-9]+):.*// must not compile: ([A-Za-z]+)$|\1 \2|')
[ -n "$marked" ] || fail "$sendable marks no line"

# Each marked line is refused with its type's message.
while read -r line type; do
    text=$(printf '%s\n' "$declared" | awk -F '\t' -v type="$type" '$1 == type { print $2 }')
    [ -n "$text" ] || fail "$sendable:$line names $type, which the library does not mark as not to be sent"
    printf '%s\n' "$errors" | grep -E "RefusedSendable\.swift:$line:[0-9]+: error: " | grep -q -F "is unavailable: $text" \
        || fail "$sendable:$line is not refused with $type's message, \"$text\""
done <<<"$marked"

# Nothing else is refused: every error is on a marked line and is that
# line's message.
while read -r error; do
    [ -n "$error" ] || continue
    line=$(printf '%s\n' "$error" | sed -E 's/^.*RefusedSendable\.swift:([0-9]+):.*/\1/')
    type=$(printf '%s\n' "$marked" | awk -v line="$line" '$1 == line { print $2 }')
    text=$(printf '%s\n' "$declared" | awk -F '\t' -v type="$type" '$1 == type { print $2 }')
    if [ -z "$type" ] || ! printf '%s\n' "$error" | grep -q -F "is unavailable: $text"; then
        echo "$error"
        fail "$sendable is refused for another reason than the one it is here for"
    fi
done <<<"$errors"

# The types named are the types marked.
named=$(printf '%s\n' "$marked" | awk '{ print $2 }' | sort -u)
known=$(printf '%s\n' "$declared" | cut -f1 | sort -u)
if [ "$named" != "$known" ]; then
    echo "marked in the library: $(echo $known)"
    echo "sent in $sendable:     $(echo $named)"
    fail "the types $sendable sends are not the types the library marks as not to be sent"
fi
echo "ok: $(printf '%s\n' "$marked" | wc -l | tr -d ' ') lines refused, each with the message of its type, $(printf '%s\n' "$known" | wc -l | tr -d ' ') types that must not be sent"

# The calls that take a closure of the caller's throw `any Error`, and a
# function that declares the library's error cannot make them bare: each
# marked line is refused with the compiler's words for that, and nothing else
# is refused. The same calls through `XitDBError.carrying` are in the accepted
# file, which compiled above.
untyped=scripts/must-not-compile/RefusedUntyped.swift
words="thrown expression type 'any Error' cannot be converted to error type 'XitDBError'"
if output=$(swiftc "${flags[@]}" "$untyped" 2>&1); then
    fail "$untyped compiled: the compiler refused nothing in it"
fi
ours=$(printf '%s\n' "$output" | grep -F "$words" | sed -n 's/^[^:]*RefusedUntyped\.swift:\([0-9]*\):[0-9]*: error: .*/\1/p' | sort -n -u)
others=$(printf '%s\n' "$output" | grep -E 'RefusedUntyped\.swift:[0-9]+:[0-9]+: error: ' | grep -v -F "$words" || true)
marked=$(grep -n '// must not compile: untyped$' "$untyped" | cut -d: -f1 | sort -n -u)
[ -n "$marked" ] || fail "$untyped marks no line"
if [ -n "$others" ]; then
    echo "$others"
    fail "$untyped is refused for another reason than the one it is here for"
fi
if [ "$ours" != "$marked" ]; then
    echo "marked:  $(echo $marked)"
    echo "refused: $(echo $ours)"
    fail "the lines marked in $untyped are not the lines the compiler refused with \"$words\""
fi
grep -q 'XitDBError\.carrying' "$accepted" || fail "$accepted makes no call through XitDBError.carrying"
echo "ok: $(echo "$marked" | wc -l | tr -d ' ') calls that take a closure refused bare where the library's error is declared, and accepted through the adapter"
