# Pinned dumps

One text per conformance fixture: what `xitdb-dump FILE --verify` prints for it. `DumpTests` dumps every
fixture again and compares, so that the tool's format is pinned; `scripts/pin-dumps.sh` writes them anew
after the fixtures are copied again or the format changes, and the diff shows what moved.
