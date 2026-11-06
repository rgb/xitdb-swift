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

## The gate

    scripts/check.sh

Debug and release build and tests with warnings as errors, the import check, the formatting check, and an
iOS compile check. "Tests pass" means this script ran and passed at the reported commit. To reformat:
`swift format --in-place --recursive Package.swift Sources Tests`.
