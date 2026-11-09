#!/usr/bin/env bash
#
# Writes the dump of every conformance fixture, as xitdb-dump prints it with
# --verify, to Tests/XitDBTests/Resources/dumps/<fixture>.txt, where DumpTests
# holds the tool to it. Run it after the fixtures are copied again or the
# dump's format changes, and look at the diff before committing it.

set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product xitdb-dump > /dev/null
dump=.build/debug/xitdb-dump
output=Tests/XitDBTests/Resources/dumps
mkdir -p "$output"
count=0
for file in Tests/XitDBTests/Resources/fixtures/valid/*.db; do
    name=$(basename "$file" .db)
    # A fixture that is damaged by design dumps with exit code 1; the text is what is pinned.
    "$dump" "$file" --verify > "$output/$name.txt" || true
    count=$((count + 1))
done
echo "$count dumps in $output"
