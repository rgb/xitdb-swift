# What the original reads from the fixtures

`SHA256SUMS` has, for every `.db` under `fixtures/valid` and `fixtures/inputs`, the SHA-256 of the listing that the
conformance repository's `dump` prints for it through the Zig original: the database's content, moment by moment, in a
text that does not depend on where anything is in the file. `OriginalListingTests` prints the same listing through the
port and holds its digest to the one here, so what the port reads from each of these files is what the original reads.
The listings themselves are eleven megabytes, so they are not kept.

One file has no line: `valid/recovery-cut-during-creation-read-only.db` is a single byte, for which the tool prints no
listing. Six listings say that something could not be read, by the original's name for the error, and are here like
the others.

They were made with `dump` built from the conformance repository at cfbc254, whose `src/dump.zig` is the one at
4d26fbd, the commit the fixtures are copied from, against the original at 89da8e7, with Zig 0.17.1. The four listings
that the fixtures carry, under `fixtures/samples/haxy`, come out of the same build byte for byte. To make them again,
from `Resources`:

    for f in fixtures/inputs/*.db fixtures/valid/*.db; do
        dump "$f" > listing.txt 2> /dev/null
        [ -s listing.txt ] && echo "$(shasum -a 256 < listing.txt | cut -d' ' -f1)  ${f#fixtures/}"
    done > listings/SHA256SUMS

The fixtures' expected files change when the fixtures follow another commit of the original, and this file with them.
