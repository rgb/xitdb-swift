# Bytes from the Zig original

Each `.db` here is what the Zig original (commit 6b93af1) writes for the script beside it, produced with the
conformance runner: `conformance/zig-out/bin/run <script> <db> --kind memory`. The sidecar records the commit IDs
the run drew, which the test hands the engine as its random source. They hold the engine to the original where the
fixtures have no script yet: the write-first paths through the transaction body's own cursor after a freeze and
after a join (D24 item 3 as refined on 2026-11-09), in `BodyCursorWriteTests`.
