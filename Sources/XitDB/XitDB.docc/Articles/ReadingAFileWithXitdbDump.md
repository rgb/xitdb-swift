# Reading a file with xitdb-dump

Print any xitdb file as it is on disk: its header, its history of moments, and every slot under one of them.

## Overview

`xitdb-dump` is an executable product of the package. It reads a file, never writes it, and prints one line for each
thing it finds, indented by nesting:

```sh
swift run xitdb-dump path/to/file.db
```

```
xitdb file: 438 bytes; hash size 20, hash id "sha1", file id 0011223344556677; 1 moment
moment 0: map (1 entry)
  "foo" 0beec7b5ea3f0fdb: uint 42
```

The first line is the header: the file's size, and its committed size where the two differ, the hash size, the
four-byte hash ID as its creator wrote it, in quotes when it is text and as hex otherwise, the file ID, and how many
moments the history holds. Then comes the last moment, or the one `--moment N` names, negative from the end, or every
moment with `--all-moments`.

Each line is a label, a colon, and what the slot holds. A map entry's label is its hash, the first eight bytes unless
`--full-hashes`, with the key's name before it in quotes when the file stores the name or `--keys FILE` supplies it,
a list element's is its `#index`, a sorted map's or set's is its key as text or as `0x` hex. The slot is `uint 42`,
`int -1`, `float 1.5`, `bytes 5 "apple"` for text and `bytes 70 0x…` otherwise, cut after sixty-four with the length,
`empty` for a slot never written and `nothing` for one written as nothing, or a collection with its kind and its
count: `list (2)`, `linked (4)`, `counted map (3)`, `sorted set (2)`; a plain `map` or `set` keeps no count, so the
number is of the entries shown. A collection seen before in the same dump is `shared with moment 0/fruits`, the place
it was first shown, since sharing blocks between moments is how the format keeps its history small; a collection that
contains itself is `cycle back to …` and is not followed.

## Options

| Option | What it does |
|---|---|
| `--moment N` | The moment to show, negative from the end; the last by default. |
| `--all-moments` | Every moment, with sharing between them marked. |
| `--depth D` | How deep to descend; two hundred levels otherwise. |
| `--path k1/k2/#3` | Start under the moment's root: a key by name, by hex hash, or an element by `#index`. |
| `--json` | The same tree as one JSON document with its keys in a fixed order, for tools. |
| `--keys FILE` | Key names, one per line, hashed to label entries that store no name. |
| `--hash NAME` | The hash for `--keys` and named path steps: `sha256` (default), `sha1` or `siphash128`. |
| `--verify` | Walk the file's commits by their trailers and checksums, and report them. |
| `--offsets` | Each record's position in the file, and its size where the format fixes it. |
| `--full-hashes` | Whole hashes instead of their first eight bytes. |
| `--limit N` | The most elements one collection shows; 100000 otherwise. |

With `--verify` the dump lists every commit whose trailer verifies, in order, with where it ends, its commit ID and
the root it left, and says whether the last one ends at the file's end:

```
verify: 2 commits verify, the last ending at the file's end
  commit 0: ends at 62, id 0000000000000000, root none
  commit 1: ends at 438, id ef6921133a4e92a8, root arrayList
```

## Damage

A damaged file never stops the tool. What cannot be read is printed as `unreadable:` with the reason, and the dump goes
on with the rest. When the root header cannot be trusted, the dump is of what ``Database/recover(_:)`` would open,
the bytes up to the last commit that verifies, and a note says so. A collection with more than `--limit` elements,
which a damaged count can claim, shows that many and a line that says how many more there are; a dump of more than a
million nodes stops with a note. The exit code is 0 for a sound file, 1 for a damaged one that was partly dumped, and
2 for a file that is not xitdb at all.

The tests hold the tool to its format: the dump of every conformance fixture is a text in the test resources, and
`scripts/pin-dumps.sh` writes those texts anew when the format or the fixtures change.

## Topics

- ``Database/recover(_:)``
- ``Database/committedSize``
