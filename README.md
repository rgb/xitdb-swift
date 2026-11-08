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
- The port reads and writes the same files as the original, byte for byte. Given the same operations and the
  same IDs, the two produce identical files, apart from the few operations the port deliberately does
  differently, which the article "Where the port differs from the original" lists.
- It is pure Swift with no run-time dependencies, down to the system's file calls.

Immutability has a cost: the file only grows until you compact it. The design leaves two jobs to you as well: you
hash your own keys, and you keep your own indexes. If you want queries or a schema, use SQLite.

## Status

The port reached parity with the original on 2026-11-07: every operation of the original, checked by
conformance scripts. On 2026-11-08 it added the checks that turn misuse the original allows into a clear error,
such as a cursor kept for a later transaction, a handle held across a freeze, or a write after a failure in the same
one, and explicit recovery of a file whose root header or last trailer is damaged. There are now PLACEHOLDER-ALL scripts. In PLACEHOLDER-PASS of them the file must match
byte for byte what the original writes, or, where the port deliberately does otherwise, what the original writes
when it is made to do the same. The other PLACEHOLDER-FAIL must fail, as they do with the original: they check that a runner
catches what is wrong, such as an expectation the database does not meet or an error nobody handles. It has not
been released yet.

Not there yet, and being worked on in this order:

- read snapshots that can be shared between threads and tasks;
- a hashing target and a more Swift-flavoured layer over the API shown here (string keys, typed values);
- iOS testing on a simulator, and Linux. It builds for macOS 26 and iOS 26 and is tested on macOS.

## Adding the dependency

The package needs Swift 6.4 and macOS 26 or iOS 26. It has not been published, so for now it is added by path:

```swift manifest
dependencies: [
    .package(path: "../xitdb-swift")
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

## Credit

This package is a port of the original xitdb at <https://github.com/xit-vcs/xitdb>, which was made for the
[xit version control system](https://github.com/xit-vcs/xit). The file format and the design are the work of
its authors.

## Licence

MIT, the same as the original. See [LICENSE](LICENSE).
