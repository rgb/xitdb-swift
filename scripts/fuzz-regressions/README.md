# Fuzzer regression inputs

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
