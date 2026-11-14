#!/usr/bin/env bash
#
# Builds the documentation of the two library targets, XitDB and XitDBHashing,
# as one static site, for any web server.
#
#   scripts/docs-site.sh [hosting-base-path] [output-directory]
#
# hosting-base-path: the path the site is served from, such as xitdb-swift for
#   https://example.com/xitdb-swift/. Leave it out for a site at the root of its
#   server, which is also what previews it locally:
#     python3 -m http.server --directory .build/docs-site
#     open http://localhost:8000/documentation/xitdb/
#   The hashes' pages are under documentation/xitdbhashing/.
# output-directory: where the site goes, by default .build/docs-site.
#
# The two archives are combined into one, which DocC calls experimental:
# the site then resolves links between the modules, which the archives the
# gate builds one by one cannot. Warnings are errors here too, as in the
# gate, so a site is never built from documentation with a broken link in it.
# And as in the gate, the symbol graphs the build kept from earlier runs are
# removed first, so that the site shows the comments the sources have now.

set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/symbol-graphs.sh

base_path="${1:-}"
output="${2:-.build/docs-site}"

options=(
    --target XitDB --target XitDBHashing --enable-experimental-combined-documentation
    --warnings-as-errors --disable-indexing --transform-for-static-hosting --output-path "$output"
)
if [[ -n "$base_path" && "$base_path" != "/" ]]; then
    options+=(--hosting-base-path "$base_path")
fi

mkdir -p "$output"
remove_kept_symbol_graphs
swift package --allow-writing-to-directory "$output" generate-documentation "${options[@]}"

echo "The site is in $output"
