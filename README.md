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

Immutability has a cost: the file only grows until you compact it. The design leaves two jobs to you as well: you choose
the hash a database's keys are hashed with, and you keep your own indexes. If you want queries or a schema, use SQLite.

## Status

The port does everything the original does. It writes the original's file format version 2, and reads and writes
version 1 files, which stay version 1. Beyond that, it refuses with an error most of the misuse that the original lets
through to damage data, such as a cursor kept for a later transaction, a handle held across a freeze, or a write after
a failure in the same transaction, and it recovers, when asked, a file whose root header or last trailer is damaged,
which the original cannot open. It also hands one commit to other threads and tasks as a read snapshot.

Its collections take keys and typed values as well as the hashes and the format's own data that the original's calls
take. A keyed call hashes the key with the database's hasher and writes what the call by hash writes, so the files are
the same either way.

The package has three products. `XitDB` is the library. `XitDBHashing` has SHA-256 and SHA-1 under CryptoKit's names on
every platform, CryptoKit's own where it exists, to give a database as the hash of its keys. `xitdb-dump` is a tool that
prints a file as it is on disk.

It builds for macOS 26, iOS 26 and Linux, and is tested on macOS, on Linux and on an iOS simulator.

## How it is tested

- **Conformance scripts**, written from the original's source and the file format by a separate project that never
  reads the port. In 146 of the 244 the port must write the file the original writes, byte for byte, or, where the port
  deliberately does otherwise, the file the original writes when it is made to do the same. The other 98 must fail, as
  they do with the original: they check that a runner catches what is wrong, such as an error nobody handles.
- **The original's own tests**, all eleven, on each kind of storage the original runs them on.
- **The port's own tests**, for what the original does not test: damaged files, a storage that fails partway through a
  commit, the guards and recovery. A fuzzer damages files at random and checks that the library never traps or hangs on
  one, and model-based tests run random operations against plain Swift collections and a database side by side.
- **Every code example** in this README and in the documentation, compiled and run, apart from the package manifest.

## Adding the dependency

The package needs Swift 6.4 and macOS 26, iOS 26 or Linux. In your `Package.swift`:

```swift manifest
dependencies: [
    .package(url: "https://github.com/rgb/xitdb-swift", from: "0.4.0")
],
targets: [
    .target(
        name: "MyTarget",
        dependencies: [
            .product(name: "XitDB", package: "xitdb-swift"),
            .product(name: "XitDBHashing", package: "xitdb-swift"),
        ])
]
```

## A first look

History as a list of moments, a map in each, values written and read back, on the original's own example:

```swift
import XitDB
import XitDBHashing

// Open the file, and create the database in it if it is new. The database
// is given the hash its keys are hashed with.
let storage = try BufferedFileStorage(path: "main.db", access: .create)
let database =
    try storage.length == 0
    ? Database(creating: storage, hashing: SHA256.self, hashID: "sha2")
    : Database(opening: storage, hashing: SHA256.self)

// The root is a list with one element for each transaction, so that
// every earlier state of the database stays readable: the history.
// On a new database, making it is a small transaction of its own.
let history = try ArrayList<ReadWrite>(database.rootCursor)

// A transaction. The new element starts as the last one, and the body
// changes it. If the body throws, the database is as it was.
try history.append(.slot(try history.slot(at: -1))) { cursor in
    let moment = try HashMap<ReadWrite>(cursor)

    // A put hashes the key and stores the value under the hash.
    try moment.put("foo", forKey: "foo")
    try moment.put("bar", forKey: "bar")

    let fruits = try ArrayList<ReadWrite>(moment.putCursor(forKey: "fruits"))
    try fruits.append("apple")
    try fruits.append("pear")
    try fruits.append("grape")

    let people = try ArrayList<ReadWrite>(moment.putCursor(forKey: "people"))

    let alice = try HashMap<ReadWrite>(people.appendCursor())
    try alice.put("Alice", forKey: "name")
    try alice.put(UInt64(25), forKey: "age")

    let bob = try HashMap<ReadWrite>(people.appendCursor())
    try bob.put("Bob", forKey: "name")
    try bob.put(UInt64(42), forKey: "age")
}

// The latest moment: -1 is the last element of a list.
let moment = try HashMap<ReadOnly>(history.cursor(at: -1)!)

// A read names the type it reads, and gives nil where there is no value.
let foo = try moment.value(forKey: "foo", as: String.self)
print(foo ?? "none")  // foo

let fruits = try ArrayList<ReadOnly>(moment.cursor(forKey: "fruits")!)
let apple = try fruits.value(at: 0, as: String.self)
print(apple ?? "none")  // apple

// The map holds the hash of "foo" and the value, and not the key.
print(try moment.keyCursor(forKey: "foo") == nil)  // true
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

The names are there for the reader. In the file each value is under the SHA-256 hash of its name, and the names are not
stored, as in the original: a map of names that must be listed stores each with `putKey(_:)`. A number says which of the
format's kinds it is, as it does in the original: `UInt64(25)` is the unsigned integer, and `put(25, forKey: "age")`
does not compile. `"sha2"` is the label in the header that says which hash it is, for whoever reads the file next.

Run it twice and the second run opens the file, adds a second moment, and the first stays readable with
`history.cursor(at: 0)`.

## Documentation

The documentation is a DocC catalogue for each library: [`Sources/XitDB/XitDB.docc`](Sources/XitDB/XitDB.docc), a
reference curated by task and articles for the concepts, and
[`Sources/XitDBHashing/XitDBHashing.docc`](Sources/XitDBHashing/XitDBHashing.docc), a page for the hashes. Read it through
DocC, where the links between articles resolve and the diagrams appear. Start with the article "Moments and history". To
read it in a browser:

```sh
swift package --disable-sandbox preview-documentation --target XitDB
```

with `--target XitDBHashing` for the other.

To look at a file itself, `swift run xitdb-dump FILE` prints it as it is on disk: its header, the last moment or any
other, and with `--verify` its commits. Built once with `swift build -c release --product xitdb-dump`, it runs as
`.build/release/xitdb-dump FILE`. The article "Reading a file with xitdb-dump" works through a dump and lists the
options.

## Developing

`scripts/check.sh` is the gate: the debug and release builds and tests with warnings as errors, a smoke run of the
benchmark and of the corruption fuzzer, the import check, the formatting check, the documentation build and a
compile check for iOS and the tests on an iOS simulator. On macOS it runs on one toolchain, Xcode 27.2's Swift 6.4.2,
and refuses any other; on Linux it runs on any Swift 6.4.x and skips the iOS steps.

Issues are welcome: bug reports, questions about the conformance suite, requests. The repository does not take pull
requests, since every change goes through the gate and the conformance suite here; a reader with a fix opens an
issue.

## Credit

This package is a port of the original xitdb at <https://github.com/xit-vcs/xitdb>, which was made for the
[xit version control system](https://github.com/xit-vcs/xit). The file format and the design are the work of
its authors.

## Licence

MIT, the same as the original. See [LICENSE](LICENSE).
