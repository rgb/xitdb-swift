# Reading a file with xitdb-dump

Print a file as it is on disk: its header, its commits, and every slot of a moment.

## Overview

`xitdb-dump` is a command-line tool that comes with the package. It reads any xitdb file, whichever implementation
wrote it, never writes to it, and prints one line for each thing it finds, indented by nesting. In a clone of the
package:

```sh
swift run xitdb-dump path/to/file.db
```

Or build it once, with `swift build -c release --product xitdb-dump`, and run `.build/release/xitdb-dump`.

### A worked dump

The package's tests carry the conformance fixtures, files written by the original, and hold the tool to the dump of
each. This one is a history of two moments, each a map of ten entries, dumped with `--verify` as the tests pin it:

```sh
swift run xitdb-dump --verify \
    Tests/XitDBTests/Resources/fixtures/valid/01-list-root-hash-map.db
```

<!-- Pinned: every line of the block below is in Tests/XitDBTests/Resources/dumps/01-list-root-hash-map.txt, as DocumentedCodeTests checks. -->

```
xitdb file: 1210 bytes; version 2, hash size 20, hash id "sha1", file id c0f0000000000001; 2 moments
verify: 3 commits verify, the last ending at the file's end
  commit 0: ends at 57, id 0000000000000000, root none
  commit 1: ends at 834, id c457234f2286c2c3, root arrayList
  commit 2: ends at 1210, id 72fda3bb196347c0, root arrayList
moment 1: map (10 entries)
  0feca720e2c29daf: nothing
  fcdbc880c3d7454f: uint 18446744073709551615
  66df0bfa3d352c8d: bytes 3 0x610062
  46f8ab7c0cff9df7: int -9223372036854775808
  "short" a0f4ea7d91495df9: bytes 3 "bar"
  bd3027fa569ea15c: bytes 23 "longer than eight bytes"
  11e623a37e87cf79: float snan(0x4000000000001)
  685e80366130387c: float 3.141592653589793
  ee61df007a111389: bytes 3 tag st "foo"
  5af11e72f4daad4a: bytes 7 tag lt "seven b"
```

The first line is the header. It gives the file's size, and its committed size where the two differ, the hash size,
the hash ID, the file ID, and how many moments the history holds. The hash ID is the four bytes the file's creator
wrote, in quotes when they are printable text and as hex otherwise, such as `hash id 0x00000000`. The tool never names
an algorithm from it, since the format does not interpret it: see <doc:BringYourOwnHashes>.

`--verify` walks the file's commits by their trailers and checksums, and lists each one that verifies, with where it
ends, its commit ID and the kind of root it left. Commit 0 is the one that creating the database wrote: 62 bytes, with
nothing at the root. Commit 1 made the history and its first moment, and commit 2 added the second. The line above
them says whether the last ends at the file's end.

Then comes the last moment, `moment 1`. Each line is a label, a colon, and what the slot holds. An entry of a map is
labelled by the first eight bytes of its hash. Where the file stores the key's name beside the hash, as
``HashMap/putKey(_:forHash:)-(_,Sequence<UInt8>)`` does, and the `XitDBStore` module's `Codable` records do, the name
comes first, in quotes: `"short"`. The other entries here store hashes alone. A plain map or set keeps no count, so `map (10 entries)` counts the entries the dump found,
while a counted map, a sorted map or set and a list show the count they keep: `counted map (1)`, `list (2)`.

The values are the format's own:

- `uint`, `int` and `float` are the scalars, the largest unsigned and the smallest signed integer among them here. A
  float that is not a number shows its bits, `snan` for a signalling one and the rest of its mantissa in hex, so that the
  text is the same on every machine.
- `bytes 3 "bar"` is a byte array of three bytes, shown as text because it is printable text. `bytes 3 0x610062` is
  shown as hex because it is not. A byte array of more than 64 bytes is shown as hex, the first 64 of them and its
  length.
- `tag st` is a byte array's format tag.
- `nothing` is a slot that something wrote nothing to, as `cursor.write(.slot(nil))` does when it clears an entry.

A slot that was never written is `empty`. A set's member is a key with an empty value, as in this set at the root of
another fixture:

<!-- Pinned: in Tests/XitDBTests/Resources/dumps/compact-roots--port.s_set.txt. -->

```
moment 0: set (1 entry)
  "a" 86f7e437faa5a7fc: empty
```

### Sharing and cycles

A collection that the dump meets a second time is not shown again. The line says where it was first shown instead. In
the fixture `compact-shared.db`, two keys of the last moment hold the same list:

<!-- Pinned: in Tests/XitDBTests/Resources/dumps/compact-shared.txt, the lines between the gaps in order. -->

```
  73fc0ead30331005: list (1)
    #0: bytes 33 "the list's own long value is here"
…
  38b62be4bddaa566: shared with moment 5/73fc0ead30331005
```

With `--all-moments` the same shows across moments: a later moment that kept a collection of an earlier one shows it as
`shared with moment 0/…`, the place it was first shown. That sharing is how the format keeps a history small.

A collection can contain itself: writing a collection's slot into the collection, within one transaction, makes a
cycle that the format allows. The dump names the cycle and does not follow it:

<!-- Pinned: in Tests/XitDBTests/Resources/dumps/compact-disk-offsets.txt. -->

```
moment 0: map (6 entries)
  40380bc1d358a6f8: cycle back to moment 0
```

### Limits

A damaged count can claim more elements than a file holds, so the dump caps what it prints, and says where it stopped and
which option raises the cap: `--limit` elements or entries in one collection, 100,000 by default; 200 levels of nesting,
or `--depth`; and a million nodes in all, or ten times `--limit` if that is more.

### The options

| Option | What it does |
|---|---|
| `--moment N` | The moment to show, negative from the end; the last by default. |
| `--all-moments` | Every moment, with sharing between them marked. |
| `--depth D` | How deep to descend; 200 levels by default. |
| `--path k1/k2/#3` | Start below the moment's root: a key by its name, or by its whole hash in hex (`--full-hashes` shows it), and a list element by `#` and its index. |
| `--json` | The same tree as one JSON document, for tools. |
| `--keys FILE` | Key names, one per line, hashed to label the entries that store no name. |
| `--hash NAME` | The hash for `--keys` and for the names in `--path`: `sha256` by default, `sha1` or `siphash128`. |
| `--verify` | Walk the file's commits by their trailers and checksums, and list them. |
| `--offsets` | After each record, `@` its position in the file and `+` its size where the format fixes it. |
| `--full-hashes` | Whole hashes instead of their first eight bytes. |
| `--limit N` | The most elements or entries one collection shows; 100,000 by default. |

`--keys` and `--hash` name what a file left unnamed. The original stores no key names unless asked, so its files show
hashes. The names in the file `--keys` reads are hashed with the hash `--hash` names, which has to be the one the file's
keys were hashed with, and each labels the entry whose hash it matches. The fixture `worked-example.db` has one entry,
under the SHA-1 hash of `foo`. With a file that holds the line `foo`, `--keys names.txt --hash sha1` labels it
`"foo" 0beec7b5ea3f0fdb`.

`--json` prints the same tree as one JSON document, its keys in a fixed order, for a tool to read: `file`, with the
header's fields, `verify` with `--verify`, then `notes`, `moments`, each with its `index` and its `root`, and `exitCode`.
An entry there has its whole hash.

### Damage

A damaged file does not stop the tool. What cannot be read is a line that begins `unreadable:` and says why, and the
dump goes on with the rest. When the root header cannot be trusted, as when a file was cut short, the dump is of what
``Database/recover(_:)`` would open: the bytes up to the last commit that verifies. The header line then gives the
committed size beside the file's, `--verify` says how many bytes past the last good commit do not verify, and a note
says that what follows is what recovery would open.

The exit code says what the tool found:

| Code | Meaning |
|---|---|
| 0 | The file is sound. |
| 1 | The file is damaged, and what could be read was dumped. |
| 2 | The file is not xitdb, or the arguments are not understood. |

## See Also

- <doc:Recovery>
- <doc:MomentsAndHistory>
- ``Database/recover(_:)``
- ``Database/committedSize``
