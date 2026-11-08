#!/usr/bin/env bash
#
# Builds the documentation as a static site, for any web server.
#
#   scripts/docs-site.sh [hosting-base-path] [output-directory]
#
# hosting-base-path: the path the site is served from, such as xitdb-swift for
#   https://example.com/xitdb-swift/. Leave it out for a site at the root of its
#   server, which is also what previews it locally:
#     python3 -m http.server --directory .build/docs-site
#     open http://localhost:8000/documentation/xitdb/
# output-directory: where the site goes, by default .build/docs-site.
#
# Warnings are errors here too, as in the gate, so a site is never built from
# documentation with a broken link in it.

set -euo pipefail
cd "$(dirname "$0")/.."

base_path="${1:-}"
output="${2:-.build/docs-site}"

options=(--target XitDB --warnings-as-errors --disable-indexing --transform-for-static-hosting --output-path "$output")
if [[ -n "$base_path" && "$base_path" != "/" ]]; then
    options+=(--hosting-base-path "$base_path")
fi

mkdir -p "$output"
swift package --allow-writing-to-directory "$output" generate-documentation "${options[@]}"

echo "The site is in $output"
