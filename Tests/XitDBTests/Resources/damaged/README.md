# Fuzzer regression inputs

These live among the test resources so that `xitdb-dump`'s tests reach them on every platform; the gate's
fuzzer step and `scripts/fuzz.sh` read them here.

The fourteen damaged files that trapped the library when the corruption fuzzer
(`Sources/XitDBFuzz`) first ran, before the guards branch fixed them. Each is the
fuzzer's sample database with the one to three changes of one seed:

- hash size 32, targeted: 35923, 40086, 45226, 69998, 70758, 76394, 76395, 85577;
- hash size 2, targeted: 13263, 35923, 40086, 45226;
- hash size 65, targeted: 13263, 35923.

They were made with `XitDBFuzz save <hashSize> <seed> targeted <path>` and are
named `h<hashSize>-targeted-<seed>.db`. The sample is built with a fixed file ID
and with commit IDs from the fuzzer's own generator at a fixed seed, so a seed
names the same bytes on every machine, and `save` gives each of these files again
byte for byte for as long as the library lays the sample out as it does now. The
files, not the seeds, are the regression inputs all the same: a change to the
layout would move a seed's damage elsewhere and lose the crash the file stands
for. The first set of these files, saved while the sample's commit IDs were still
drawn at random, differed from this one only in the commit ID and checksum of each
trailer.

Each file was checked twice when it was saved: it passes on the current library,
and it traps with SIGTRAP (exit status 133) on the library before commit 3675d55,
which fixed the line of `compact` all fourteen trapped at. `scripts/fuzz.sh
regressions` runs them all through the battery, and so does the gate; a trap or a
hang on any of them fails it.

## The fifteenth

`v1-untargeted-4811.db` is a version 1 file: the conformance fixtures' input `v1-history`, which is the fuzzer's
version 1 sample, with the two changes of seed 4811 placed anywhere in the file and not near a harvested position
(`XitDBFuzz save v1 4811 <path>`). One of them makes the header's hash size 4,116 where it was 20. Opening without a
stated hash size takes the header's word, and `compact` trapped on the first key-value pair it met: it kept each
block it copied in room sized for a tree's largest block, 418 bytes, and a pair is its hash and 18 bytes more. A
damaged header was not needed: compacting any database created with a hash size above 400 trapped the same way, in
0.2.0 and 0.2.1. The file passes on the library from the commit that added it, and traps on the one before.
