# xitdb-swift package

The Swift package of the xitdb port, built by the `xitdb-package` session. `xitdb-director` plans and
reviews; its documents are in `../director/` and are read-only from here.

## Read first

1. `../director/decisions.md`: decisions agreed with the user. Binding.
2. `../director/spec/working-agreement.md`: how work flows, standards, git.
3. `../director/spec/architecture.md`: requirements (R1...) and sketches.
4. `../director/spec/milestones.md`, and the current brief in `../director/briefs/package-*.md`.

The Zig original is at `../../xitdb/`, read-only. Where it and a director document disagree, the Zig source
wins and the director is told.

## Standards

- Write only inside this folder.
- Build exactly what the brief asks; report anything else as a suggestion.
- A question that affects a requirement or a decision goes to the director before the work.
- No stubs, skipped tests or weakened assertions. Say plainly what is not done or not verified.
- Warnings are errors. The gate passes at every commit offered for review.
- Every public symbol gets a documentation comment when it is written: what it does, what it throws and
  when, and anything a caller could get wrong, without restating the signature (decision D14).
- Subagents run on Opus at minimum, searches included; implementer subagents may run on Fable. Set the
  model explicitly.
- Work on a branch named after the brief. Nothing is pushed. A branch is merged to `main` only after the
  director accepts it.

## Layers

`Sources/XitDB` is one module, layered by folder in this order: `Format`, `Storage`, `Engine`, `Cursor`,
`Collections`, `Maintenance`. A file may use the layers before its own, never the ones after
(`architecture.md`, section 3).

`Sources/XitDB` imports only the standard library, `Synchronization` and the platform C library, the last
in one file only. No Foundation. Tests may import Foundation and CryptoKit.
`Sources/XitDBFoundation` is the one library target that imports Foundation. It holds only what needs Foundation
(`LocalizedError`, the `URL` and `FilePath` initialisers, `Data` as a value and a key) and nothing the library needs to
work; nothing in `Sources/XitDB` or `Sources/XitDBHashing` may depend on it.

## The gate

    scripts/check.sh

Warnings are errors throughout. In order: the debug build and tests; a test planted to sleep, which shows
that the time limit every run of the tests has does end a run; what must not compile; the conformance suite's
test of two processes with the port's reader, where the suite is beside the package; the snapshot
concurrency suite under the thread sanitizer; the release build; the instruction counts of the in-memory
lines against their figures (compared on macOS, on the toolchain the figures were taken on); the release
tests; a smoke run of the benchmark and the corruption fuzzer; the step that keeps tests that start a process
in their own target; the import check, which also holds the search for an error printed where a program reads
it; the formatting check; the documentation build (DocC); and on macOS a
compile-only build for iOS and the tests on an iOS simulator. It runs on macOS and on Linux, and stops at the
first failure. On macOS it needs Xcode's toolchain, which the workspace's `.swift-version` selects. From a Mac
the Linux side is `scripts/linux-gate.sh`: the gate in the gate's image on a fresh copy of the working tree, or
of a commit named to it, with the conformance suite mounted to be read only where it is beside the package with
its writer and reader built for Linux, so that the two-process step runs there too; where they are not, the
script and the step say so. "Tests pass" means this script ran and passed at the reported commit. To reformat:
`swift format --in-place --recursive Package.swift Sources Tests`.

## What Linux and the gate have taught

- Nothing is claimed for Linux that a container has not built and run. A piece's Linux half is seen from its
  first commit, not at the end.
- Swift is not shown some of the C library's calls on Linux (`statfs` and `fstatfs`, every extended attribute
  call and constant, `readahead`, `pthread_getattr_np`). Ask the compiler in the container, one name at a time,
  before designing on one.
- In a target that imports Foundation, a C structure's initializer or members can be refused on Linux for the
  lack of an import of whichever module the compiler takes the structure to belong to that time; importing that
  one moves the refusal to another. Tests and tools ask the library, Foundation, or a call that returns a
  number. The library itself imports the platform C library alone.
- A script that builds and then runs with the build skipped stops on the build's status. One that kept going
  once ran an older binary and printed that its tests had passed.
- Tests that start a process live in the `XitDBProcessTests` target, which runs in a process of its own: a lock
  asked for on a file the same process has just closed can be refused for a moment while a child is made.
- A figure is given with how it was taken. Instruction counts move with where the stack starts and with what
  the optimiser makes of code beside the path; `scripts/instructions.sh` takes a line's least over eight
  placements of the stack's start.
