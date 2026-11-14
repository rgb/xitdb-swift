# Sourced by scripts/check.sh and scripts/docs-site.sh, which both build documentation.
#
# The documentation is built from symbol graphs, which the build keeps in its folder,
# one folder for each module, from one run to the next. Nothing removes a graph that a
# later tree no longer makes, and on Linux the graph of a module that re-exports
# another carries that other one's comments and is not written again when only those
# comments change. Documentation built from such a folder is built from an earlier
# tree: the gate passed on comments that would fail and failed on comments that had
# been put right, and a site would show comments that are no longer in the sources.
#
# So the folders are removed before documentation is built, and every graph is
# extracted from the sources as they are. Extracting them takes seconds: nothing is
# compiled again. If a symbol graph is left anywhere it would be read from, that is an
# error: this function no longer knows where the build keeps them.

remove_kept_symbol_graphs() {
    [ -d .build ] || return 0
    find .build -type d \( -name '*.symbolgraphs' -o -name 'extracted-symbols' \) -prune -exec rm -rf {} +
    local kept
    kept=$(find .build -name '*.symbols.json' -not -path '.build/xcodebuild*' -not -path '.build/index-build/*')
    if [ -n "$kept" ]; then
        echo "error: symbol graphs of an earlier run are kept where they are not removed:"
        echo "$kept"
        return 1
    fi
}
