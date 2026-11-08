# Fuzzer regression inputs

The fourteen damaged files that trapped the library when the corruption fuzzer
(`Sources/XitDBFuzz`) first ran, before the guards branch fixed them. Each is the
fuzzer's sample database with the one to three changes of one seed:

- hash size 32, targeted: 35923, 40086, 45226, 69998, 70758, 76394, 76395, 85577;
- hash size 2, targeted: 13263, 35923, 40086, 45226;
- hash size 65, targeted: 13263, 35923.

The files, not the seeds, are the regression inputs. A seed names the same damage
only while the library builds the same sample, and the sample's trailers carry
commit IDs the database draws at random, so two saves of one seed already differ
in those bytes.

They were made with `XitDBFuzz save <hashSize> <seed> targeted <path>`, built from
the guards branch, and are named `h<hashSize>-targeted-<seed>.db`.
`scripts/fuzz.sh regressions` runs them all through the battery, and so does the
gate; a trap or a hang on any of them fails it.
