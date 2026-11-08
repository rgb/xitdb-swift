# xitdb-swift

A Swift port of [xitdb](https://github.com/xit-vcs/xitdb), an immutable database, written in Zig, that runs
inside your program and keeps its data in one file or in memory.

- Each transaction makes a new "copy" of the database, by copying what it changes and sharing the rest. Past
  copies stay readable, and can be returned to.
- There is no query language and no schema. You write data structures, lists and maps and sets, nested as
  deeply as you need, and a database reads and writes them a part at a time, so it can be larger than memory.
- There is no write-ahead log. A transaction appends to the file and then rewrites one small header, so a
  transaction that fails leaves the database as it was.
- Replicating a database is copying the bytes the other side lacks. Reclaiming space is compacting it into a
  new file.
- Readers on other threads and tasks get a snapshot: a `Sendable` value that reads one commit from any task
  while the writer goes on.
- The port reads and writes the same files as the original, byte for byte. Given the same operations and the
  same IDs, the two produce identical files, apart from the few operations the port deliberately does
  differently, which the article "Where the port differs from the original" lists.
- It is pure Swift with no run-time dependencies, down to the system's file calls.

Immutability has a cost: the file only grows until you compact it. The design leaves two jobs to you as well: you
hash your own keys, and you keep your own indexes. If you want queries or a schema, use SQLite.

## Status

The port does everything the original does. Beyond that, it refuses with an error most of the misuse that the original
lets through to damage data, such as a cursor kept for a later transaction, a handle held across a freeze, or a write
after a failure in the same transaction, and it recovers, when asked, a file whose root header or last trailer is
damaged, which the original cannot open. It also hands one commit to other threads and tasks as a read snapshot. Every
public symbol is documented, and the documentation has articles for the concepts and four tutorials. Its first
release is 0.1.0.

Not there yet, and planned in this order:

- a hashing target and a more Swift-flavoured layer over the API shown here (string keys, typed values);
- a tool that shows what a file holds, and tests that check random sequences of operations against Swift's own
  collections;
- testing on an iOS simulator;
- Linux.

It builds for macOS 26 and iOS 26, and is tested on macOS.

## How it is tested

- **Conformance scripts**, written from the original's source and the file format by a separate project that never
  reads the port. There are 226. In 128 of them the port must write the file the original writes, byte for byte, or,
  where the port deliberately does otherwise, the file the original writes when it is made to do the same. The other 98
  must fail, as they do with the original: they check that a runner catches what is wrong, such as an expectation the
  database does not meet or an error nobody handles. Each script runs on every kind of storage it can (the memory
  storage has no read-only mode), and each one that compacts runs with both kinds of offset map.
- **The original's own tests**, all eleven, on each kind of storage the original runs them on. They keep the original's
  assertions, except where the port deliberately does otherwise, and except for the positions of a memory storage's
  readers and writers, which the port's storage does not have.
- **The port's own tests**, for what the original does not test: damaged files, a storage that fails partway through a
  commit, the guards and recovery. A fuzzer damages files at random, then reads, compacts, replicates and writes them,
  and checks that the library never traps or hangs on one.
- **Every code example** in this README and in the documentation, compiled and run, apart from the package manifest.

`scripts/check.sh` runs all of them: the tests in debug and release builds with warnings as errors, and the fuzzer on the
files that once made it fail and on fresh damage from fixed seeds. It also checks the imports and the formatting, builds
the documentation, runs the benchmark briefly and compiles for iOS.

## Adding the dependency

The package needs Swift 6.4 and macOS 26 or iOS 26. In your `Package.swift`:

```swift manifest
dependencies: [
    .package(url: "https://github.com/rgb/xitdb-swift", from: "0.1.0")
],
targets: [
    .target(name: "MyTarget", dependencies: [.product(name: "XitDB", package: "xitdb-swift")])
]
```

## A first look

History as a list of moments, a map in each, a value written and read back:

```swift
import CryptoKit
import XitDB

// XitDB never hashes anything itself: the caller hashes each key.
func sha256(_ key: String) -> SHA256Digest {
    SHA256.hash(data: Array(key.utf8))
}

// Open the file, and create the database in it if it is new.
let storage = try BufferedFileStorage(path: "main.db", access: .create)
let database =
    try storage.length == 0
    ? Database(creating: storage, hashSize: 32, hashID: "sha2")
    : Database(opening: storage, hashSize: 32)

// The root is a list with one element for each transaction, so that
// every earlier state of the database stays readable: the history.
let history = try ArrayList<ReadWrite>(database.rootCursor)

// A transaction. The new element starts as the last one, and the body
// changes it. If the body throws, the database is as it was.
try history.append(.slot(try history.slot(at: -1))) { cursor in
    let moment = try HashMap<ReadWrite>(cursor)

    try moment.put(.bytes(Array("foo".utf8)), forHash: sha256("foo"))
    try moment.put(.bytes(Array("bar".utf8)), forHash: sha256("bar"))

    let fruits = try ArrayList<ReadWrite>(moment.putCursor(forHash: sha256("fruits")))
    try fruits.append(.bytes(Array("apple".utf8)))
    try fruits.append(.bytes(Array("pear".utf8)))
    try fruits.append(.bytes(Array("grape".utf8)))

    let people = try ArrayList<ReadWrite>(moment.putCursor(forHash: sha256("people")))

    let alice = try HashMap<ReadWrite>(people.appendCursor())
    try alice.put(.bytes(Array("Alice".utf8)), forHash: sha256("name"))
    try alice.put(.uint(25), forHash: sha256("age"))

    let bob = try HashMap<ReadWrite>(people.appendCursor())
    try bob.put(.bytes(Array("Bob".utf8)), forHash: sha256("name"))
    try bob.put(.uint(42), forHash: sha256("age"))
}

// The latest moment: -1 is the last element of a list.
let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)

let foo = try moment.cursor(forHash: sha256("foo"))!.readBytes()
print(String(decoding: foo, as: UTF8.self))  // foo

let fruits = try ArrayList<ReadOnly>(moment.cursor(forHash: sha256("fruits"))!)
let apple = try fruits.cursor(at: 0)!.readBytes()
print(String(decoding: apple, as: UTF8.self))  // apple
```

After this transaction the moment holds, if it were written as JSON:

```json
{"foo": "foo",
 "bar": "bar",
 "fruits": ["apple", "pear", "grape"],
 "people": [
   {"name": "Alice", "age": 25},
   {"name": "Bob", "age": 42}
 ]}
```

Run it twice and the second run opens the file, adds a second moment, and the first stays readable with
`history.cursor(at: 0)`.

Every block of code that uses the library, in this README and in the documentation, is compiled and run by the
`XitDBExamples` test target, which imports the library as you would. A test there fails if the two ever differ.

## Documentation

The full documentation is a DocC catalogue in
[`Sources/XitDB/XitDB.docc`](Sources/XitDB/XitDB.docc): a reference curated by task, articles for the
concepts, and step-by-step tutorials. It is best read through DocC: the articles are Markdown files, but as raw text
their links show their overloads, links between articles do not resolve, and the diagrams do not appear. Start with
the article "Moments and history".

To read it in a browser:

```sh
swift package --disable-sandbox preview-documentation --target XitDB
```

To build it as a static site, for hosting at a path of your choice, and to look at the result:

```sh
scripts/docs-site.sh xitdb-swift      # for hosting at /xitdb-swift
scripts/docs-site.sh                  # for hosting at the root, to preview:
python3 -m http.server --directory .build/docs-site
```

The preview is then at <http://localhost:8000/documentation/xitdb/>.

## Developing

`scripts/check.sh` is the gate: the debug and release builds and tests with warnings as errors, a smoke run of the
benchmark and of the corruption fuzzer, the import check, the formatting check, the documentation build and a
compile check for iOS. It runs on one toolchain, Xcode 27.2's Swift 6.4.2, and refuses any other.

Two GitHub Actions workflows run on self-hosted runners. `.github/workflows/gate.yml` runs the gate on the macOS
runner at every push and pull request; its job for the Linux runner is disabled until the package builds on Linux.
`.github/workflows/benchmark.yml` is started by hand: it builds the benchmark in release and the original's `bench`
from the conformance repository at a stated commit, runs the seven workloads at full size, three passes of each,
alternated, and writes the table of medians and ratios to the job's summary. It is a report, not a check.
A runner needs Xcode 27.2 for the gate, and Zig 0.17.1 on its PATH as well for the benchmark.
Pull requests from forks run on the same runners, so a public repository should be set to require approval for all
outside collaborators before their workflows run.
`scripts/bench-compare.py` runs the same comparison by hand.

Commits in this repository carry no `Co-Authored-By` trailer; `scripts/git-hooks/commit-msg` removes one from a
message. Git runs it once a clone has

```
git config core.hooksPath scripts/git-hooks
```

## Credit

This package is a port of the original xitdb at <https://github.com/xit-vcs/xitdb>, which was made for the
[xit version control system](https://github.com/xit-vcs/xit). The file format and the design are the work of
its authors.

## Licence

MIT, the same as the original. See [LICENSE](LICENSE).
