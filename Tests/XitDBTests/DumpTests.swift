import Foundation
import Testing
import XitDB
import XitDBDumpKit

/// `xitdb-dump` through its kit: every fixture dumps as pinned, the
/// damaged files dump without a trap, the JSON is the text's tree, paths
/// and key names work, verify reports the commits and the damage, and a
/// file that is not xitdb says so.
@Suite struct DumpTests {
    static func resources() throws -> URL { try #require(Bundle.module.resourceURL) }

    static func files(_ folder: String, suffix: String) throws -> [URL] {
        let folder = try resources().appendingPathComponent(folder)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(suffix) }
        return names.sorted().map { folder.appendingPathComponent($0) }
    }

    static func bytes(_ url: URL) throws -> [UInt8] { Array(try Data(contentsOf: url)) }

    static func dump(_ bytes: [UInt8], _ options: DumpOptions) -> Dump {
        var dumper = Dumper(options: options)
        return dumper.dump(MemoryStorage(bytes: bytes))
    }

    static func text(_ bytes: [UInt8], _ options: DumpOptions) -> String {
        TextRenderer.render(dump(bytes, options), options: options)
    }

    static var verifying: DumpOptions {
        var options = DumpOptions()
        options.verify = true
        return options
    }

    static func sha1(_ name: String) -> [UInt8] {
        var options = DumpOptions()
        options.hash = .sha1
        return options.hash.hash(Array(name.utf8))
    }

    /// The format is pinned: every fixture's dump is the text in
    /// `Resources/dumps`, which `scripts/pin-dumps.sh` writes.
    @Test func everyFixtureDumpsAsPinned() throws {
        let fixtures = try Self.files("fixtures/valid", suffix: ".db")
        #expect(fixtures.count == 294)
        let dumps = try Self.resources().appendingPathComponent("dumps")
        for fixture in fixtures {
            let name = fixture.deletingPathExtension().lastPathComponent
            let expected = String(decoding: try Self.bytes(dumps.appendingPathComponent("\(name).txt")), as: UTF8.self)
            let actual = Self.text(try Self.bytes(fixture), Self.verifying)
            if actual != expected {
                let actualLines = actual.split(separator: "\n", omittingEmptySubsequences: false)
                let expectedLines = expected.split(separator: "\n", omittingEmptySubsequences: false)
                let first = zip(actualLines, expectedLines).enumerated().first { $0.element.0 != $0.element.1 }
                let place =
                    first.map { "line \($0.offset + 1): got \($0.element.0) / pinned \($0.element.1)" }
                    ?? "lengths \(actualLines.count) and \(expectedLines.count)"
                Issue.record("\(name): \(place)")
            }
        }
    }

    /// Every file that once trapped the library dumps, says what it could
    /// not read, and exits with 1 or 2; so does every truncation and every
    /// flipped byte of two fixtures.
    @Test func damagedFilesDumpWithoutATrap() throws {
        var damaged = 0
        for file in try Self.files("damaged", suffix: ".db") {
            let dump = Self.dump(try Self.bytes(file), Self.verifying)
            #expect(dump.exitCode == 1 || dump.exitCode == 2, Comment(rawValue: file.lastPathComponent))
            _ = TextRenderer.render(dump, options: Self.verifying)
            _ = JSONRenderer.render(dump, options: Self.verifying)
            damaged += 1
        }
        #expect(damaged == 15)
        let fixtures = try Self.resources().appendingPathComponent("fixtures/valid")
        for name in ["worked-example", "every-construct-linked--port"] {
            let whole = try Self.bytes(fixtures.appendingPathComponent("\(name).db"))
            var cut = 1
            while cut < whole.count {
                let dump = Self.dump(Array(whole.prefix(cut)), Self.verifying)
                #expect(dump.exitCode != 0 || cut == whole.count, "\(name) cut at \(cut)")
                cut += 37
            }
            var generator = SeededGenerator(seed: 11)
            for _ in 0..<40 {
                var flipped = whole
                let index = Int.random(in: 0..<flipped.count, using: &generator)
                flipped[index] ^= UInt8.random(in: 1...255, using: &generator)
                let dump = Self.dump(flipped, Self.verifying)
                _ = TextRenderer.render(dump, options: Self.verifying)
            }
        }
    }

    /// `--json` is the same tree: parsed back, it equals the dump's.
    @Test func jsonIsTheSameTree() throws {
        let fixtures = try Self.resources().appendingPathComponent("fixtures/valid")
        for name in [
            "worked-example", "every-construct-linked--port", "reads-sorted-root", "deep-callbacks",
            "write-if-empty-emptied-slot",
        ] {
            var options = Self.verifying
            options.allMoments = true
            options.offsets = true
            let dump = Self.dump(try Self.bytes(fixtures.appendingPathComponent("\(name).db")), options)
            let json = JSONRenderer.render(dump, options: options)
            let parsed = try #require(
                try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], Comment(rawValue: name))
            let file = try #require(parsed["file"] as? [String: Any], Comment(rawValue: name))
            #expect(file["bytes"] as? UInt64 == dump.header?.fileSize, Comment(rawValue: name))
            #expect(file["hashSize"] as? Int == dump.header?.hashSize, Comment(rawValue: name))
            #expect(parsed["exitCode"] as? Int32 == dump.exitCode, Comment(rawValue: name))
            #expect(parsed["notes"] as? [String] == dump.notes, Comment(rawValue: name))
            let moments = try #require(parsed["moments"] as? [[String: Any]], Comment(rawValue: name))
            #expect(moments.count == dump.moments.count, Comment(rawValue: name))
            for (parsedMoment, moment) in zip(moments, dump.moments) {
                #expect(parsedMoment["index"] as? Int == moment.index, Comment(rawValue: name))
                let root = try #require(JSONTree.node(parsedMoment["root"]), Comment(rawValue: name))
                #expect(root == moment.root, "\(name) moment \(moment.index)")
            }
        }
    }

    /// A key name from `--keys` labels its entry, a path descends by name,
    /// by hash and by index, and a miss says where it stopped.
    @Test func pathsAndKeysLabel() throws {
        let bytes = try Self.bytes(
            try Self.resources().appendingPathComponent("fixtures/valid/every-construct-linked--port.db"))
        var options = DumpOptions()
        options.hash = .sha1
        options.keys = ["linked-a", "linked-b", "unused"]
        let text = Self.text(bytes, options)
        #expect(text.contains("\"linked-a\" "))
        #expect(text.contains("\"linked-b\" "))
        #expect(!text.contains("unused"))

        options.path = [.key("linked-a"), .index(2)]
        #expect(Self.dump(bytes, options).moments.first?.root == Node(.uint, text: "45"))
        options.path = [.hash(Self.sha1("linked-a")), .index(-1)]
        #expect(Self.dump(bytes, options).moments.first?.root == Node(.uint, text: "50"))
        options.path = [.key("linked-b"), .index(9)]
        let missing = Self.dump(bytes, options)
        #expect(missing.moments.first?.root.kind == .unreadable)
        #expect(missing.exitCode == 1)
        options.path = [.key("nothing-here")]
        #expect(Self.dump(bytes, options).moments.first?.root.kind == .unreadable)
    }

    /// `--verify` lists the commits; a truncated file shows what recovery
    /// would open and says so; `--moment` picks a moment; `--limit` cuts.
    @Test func verifyReportsTheCommitsAndTheDamage() throws {
        let fixtures = try Self.resources().appendingPathComponent("fixtures/valid")
        let whole = try Self.bytes(fixtures.appendingPathComponent("worked-example.db"))
        let sound = Self.dump(whole, Self.verifying)
        let verification = try #require(sound.verification)
        #expect(verification.commits.count == 2)
        #expect(verification.commits.last?.end == UInt64(whole.count))
        #expect(verification.bytesPastLastCommit == nil)
        #expect(sound.exitCode == 0)

        let truncated = Self.dump(Array(whole.dropLast(10)), Self.verifying)
        #expect(truncated.exitCode == 1)
        // cut inside its second commit, it is left with the first: a new
        // version 2 database, 57 bytes
        #expect(truncated.verification?.bytesPastLastCommit == UInt64(whole.count - 10 - 57))
        #expect(truncated.notes.contains { $0.contains("what follows is what recovery would open") })
        #expect(truncated.moments.isEmpty || truncated.header?.momentCount == 0)

        var options = Self.verifying
        options.moment = 7
        let missing = Self.dump(whole, options)
        #expect(missing.moments.isEmpty)
        #expect(missing.notes.contains { $0.contains("no moment 7") })
        #expect(missing.exitCode == 1)

        let linked = try Self.bytes(fixtures.appendingPathComponent("every-construct-linked--port.db"))
        var limited = DumpOptions()
        limited.limit = 1
        limited.hash = .sha1
        limited.path = [.key("linked-a")]
        let list = Self.dump(linked, limited).moments[0].root
        #expect(list.kind == .linked)
        #expect(list.count == 4)
        #expect(list.children.count == 2)
        #expect(list.children.first?.node == Node(.uint, text: "3"))
        #expect(list.children.last?.node.kind == .truncated)
        #expect(list.children.last?.node.text?.contains("--limit") == true)
        limited.path = []
        let cutMap = Self.dump(linked, limited).moments[0].root
        #expect(cutMap.children.count == 2)
        #expect(cutMap.children.last?.node.kind == .truncated)
    }

    /// The engine's forward scan of the trailers agrees with every fixture's
    /// sidecar, which the conformance runner wrote as the commits happened:
    /// the file's commits, ends and IDs alike, are the sidecar's in order,
    /// a subsequence of them where the script committed to other databases
    /// too. Three fixtures end in bytes past their last commit by design,
    /// a rolled-back or interrupted write's leftovers, which the scan shows
    /// as such.
    ///
    /// A script whose own database starts from an input, a version 1 file
    /// the original wrote at `6b93af1`, has that input's commits before its
    /// own: they were made before the script began, and the scan finds
    /// them, or as many as the script left. One of those ends on a file of
    /// one byte, which has no header to scan by.
    @Test func verifiedCommitsMatchTheSidecars() throws {
        let folder = try Self.resources().appendingPathComponent("fixtures/valid")
        var checked = 0
        var fromInputs: [String] = []
        var withOneCommit: [String] = []
        for sidecar in try Self.files("fixtures/valid", suffix: ".db.sidecar.json") {
            let name = sidecar.lastPathComponent.replacing(".db.sidecar.json", with: "")
            let comment = Comment(rawValue: name)
            let document = try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any], comment)
            let ops = try #require(document["ops"] as? [[String: Any]], comment)
            var recorded = ["\(try #require(document["initial_size"] as? UInt64)):0000000000000000"]
            for op in ops {
                guard let id = op["commit_id"] as? String, let end = op["committed_size"] as? UInt64 else { continue }
                recorded.append("\(end):\(id)")
            }
            // the commits of the inputs the script's own database was loaded with
            var before: [String] = []
            for input in try Self.inputsOfTheMainDatabase(folder.appendingPathComponent("\(name).json")) {
                let bytes = try Self.bytes(try Self.resources().appendingPathComponent("fixtures/inputs/\(input).db"))
                before += try Database.verifiedCommits(in: MemoryStorage(bytes: bytes)).map(Self.text)
            }
            if !before.isEmpty { fromInputs.append(name) }
            let bytes = try Self.bytes(folder.appendingPathComponent("\(name).db"))
            if name == "recovery-cut-during-creation-read-only" {
                #expect(bytes.count == 1)
                #expect(throws: XitDBError.endOfStream) {
                    try Database.verifiedCommits(in: MemoryStorage(bytes: bytes))
                }
                continue
            }
            let commits = try Database.verifiedCommits(in: MemoryStorage(bytes: bytes))
            let scanned = commits.map(Self.text)
            var remaining = (before + recorded)[...]
            var inOrder = true
            for commit in scanned {
                guard let index = remaining.firstIndex(of: commit) else {
                    inOrder = false
                    break
                }
                remaining = remaining[(index + 1)...]
            }
            #expect(inOrder, "\(name): scan \(scanned) is not in the order of \(before) and then \(recorded)")
            #expect(commits.last.map { $0.end <= UInt64(bytes.count) } == true, comment)
            #expect(commits.count >= 1, comment)
            if commits.count == 1 { withOneCommit.append(name) }
            checked += 1
        }
        #expect(checked == 145, "every fixture with a sidecar but the one that ends on one byte")
        #expect(
            fromInputs.sorted() == [
                "recovery-cut-during-creation", "recovery-cut-during-creation-read-only",
                "recovery-lost-commit-version-1", "recovery-open-errors-version-1--port", "recovery-torn-root-slot",
                "replicate-version-1", "version-1-lists", "version-1-read", "version-1-write",
            ])
        // Every other script commits after its database's first commit.
        // These two end on a database that has only that one: a recovery
        // that cut back to it, and a version 1 input cut during creation.
        #expect(withOneCommit.sorted() == ["recover-without-first-commit--port", "recovery-cut-during-creation"])

        // Three of them, as their scripts leave them.
        func commits(_ name: String) throws -> [VerifiedCommit] {
            try Database.verifiedCommits(
                in: MemoryStorage(bytes: try Self.bytes(folder.appendingPathComponent("\(name).db"))))
        }
        // the new version 1 database of the input, its committed size
        // zeroed and a byte added: the input's first trailer still verifies
        let cut = try commits("recovery-cut-during-creation")
        #expect(cut.map(\.end) == [62])
        #expect(cut.map(\.commitID) == [0])
        // the input's three commits, and the one the script made
        let torn = try commits("recovery-torn-root-slot")
        #expect(torn.map(\.end) == [62, 839, 1215, 1591])
        // the input's three, and the script's, still where version 1 puts them
        let written = try commits("version-1-write")
        #expect(Array(written.map(\.end).prefix(3)) == [62, 839, 1215])
        #expect(written.count > 3)
    }

    /// A commit as the sidecars have it: where it ends and its ID.
    private static func text(_ commit: VerifiedCommit) -> String {
        "\(commit.end):\(Dumper.hex(bigEndian: commit.commitID))"
    }

    /// The inputs a script loads into its own database, the one called
    /// `main`, in the order of their first load.
    private static func inputsOfTheMainDatabase(_ script: URL) throws -> [String] {
        let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: script)) as? [String: Any])
        var current = "main"
        var inputs: [String] = []
        for op in try #require(document["ops"] as? [[String: Any]]) {
            switch op["op"] as? String {
            case "use": current = try #require(op["name"] as? String)
            case "raw_load":
                let input = try #require(op["input"] as? String)
                if current == "main", !inputs.contains(input) { inputs.append(input) }
            default: break
            }
        }
        return inputs
    }

    /// Bytes of at most 64 that are valid UTF-8 print as text, unless they
    /// hold a control character other than a line feed, a carriage return
    /// and a tab. Those three print as `\n`, `\r` and `\t`, and the
    /// backslash and the double quote with a backslash before them, so
    /// that a value stays on its line and what is between the quotes says
    /// exactly which bytes are there. Everything else is hex, and so is
    /// anything longer than 64 bytes. A key follows the same rule, and the
    /// JSON has the text itself, escaped as JSON escapes it.
    @Test func bytesPrintAsTextWithLineBreaksEscaped() throws {
        let values: [(bytes: [UInt8], shown: String)] = [
            (utf8("Line one\nLine two"), #"bytes 17 "Line one\nLine two""#),
            (utf8("a\tb"), #"bytes 3 "a\tb""#),
            (utf8("cr\r\nlf"), #"bytes 6 "cr\r\nlf""#),
            (utf8(#"back\slash "quoted""#), #"bytes 19 "back\\slash \"quoted\"""#),
            // a backslash and an n, which is not a line feed
            (utf8(#"\n"#), #"bytes 2 "\\n""#),
            // text that looks like the tool's hex
            (utf8("0xab"), #"bytes 4 "0xab""#),
            (utf8("é ✓"), "bytes 6 \"é ✓\""),
            ([], #"bytes 0 """#),
            (
                utf8(String(repeating: "x", count: 63) + "\n"),
                "bytes 64 \"" + String(repeating: "x", count: 63) + #"\n""#
            ),
            // a NUL, an escape sequence, a delete
            ([0x61, 0x00], "bytes 2 0x6100"),
            ([0x1B, 0x5B, 0x6D], "bytes 3 0x1b5b6d"),
            ([0x61, 0x7F], "bytes 2 0x617f"),
            // U+0085 and U+009B, controls of the second range, and U+00A0,
            // the first scalar after it
            ([0xC2, 0x85], "bytes 2 0xc285"),
            ([0xC2, 0x9B, 0x6D], "bytes 3 0xc29b6d"),
            ([0xC2, 0xA0], "bytes 2 \"\u{A0}\""),
            // not UTF-8
            ([0xFF, 0x61], "bytes 2 0xff61"),
            // a byte too long to be shown as text
            (
                utf8(String(repeating: "x", count: 65)),
                "bytes 65 0x" + String(repeating: "78", count: 64) + "… (64 of 65)"
            ),
        ]
        let keys: [(bytes: [UInt8], label: String)] = [
            (utf8("k\n1"), #""k\n1""#), (utf8("tab\tkey"), #""tab\tkey""#), (utf8(#"q"k\"#), #""q\"k\\""#),
            ([0x00, 0x01], "0x0001"),
        ]

        let storage = MemoryStorage()
        let database = try Database(creating: storage, hashSize: 20)
        let history = try ArrayList<ReadWrite>(database.rootCursor)
        try history.append(.slot(try history.slot(at: -1))) { cursor in
            let moment = try HashMap<ReadWrite>(cursor)
            let list = try ArrayList<ReadWrite>(try moment.putCursor(forHash: Self.sha1("values")))
            for value in values {
                try list.append(.bytes(value.bytes))
            }
            let sorted = try SortedMap<ReadWrite>(try moment.putCursor(forHash: Self.sha1("sorted")))
            for (index, key) in keys.enumerated() {
                try sorted.put(.uint(UInt64(index)), forKey: key.bytes)
            }
            // a hash map's entry whose stored key is text with a line feed
            try moment.putKey(.bytes(utf8("named\nkey")), forHash: Self.sha1("named"))
            try moment.put(.uint(7), forHash: Self.sha1("named"))
        }

        var options = DumpOptions()
        options.hash = .sha1
        let text = Self.text(storage.bytes, options)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, value) in values.enumerated() {
            #expect(lines.contains { $0.hasSuffix("#\(index): \(value.shown)") }, "value \(index): \(value.shown)")
        }
        for (index, key) in keys.enumerated() {
            #expect(lines.contains { $0.hasSuffix("\(key.label): uint \(index)") }, "key \(index): \(key.label)")
        }
        #expect(lines.contains { $0.contains(#""named\nkey" "#) && $0.hasSuffix(": uint 7") })
        // nothing but the line ends is a control character in what is printed
        #expect(!text.unicodeScalars.contains { $0 != "\n" && ($0.value < 0x20 || (0x7F..<0xA0).contains($0.value)) })
        // one line for each value, each key and the named entry, and no more
        // lines than the tree has nodes
        #expect(lines.filter { $0.contains("#") }.count == values.count)

        // the JSON has the text, and reads back as the same tree
        let dump = Self.dump(storage.bytes, options)
        let json = JSONRenderer.render(dump, options: options)
        #expect(json.contains(#""utf8": "Line one\nLine two""#) || json.contains(#""utf8":"Line one\nLine two""#))
        #expect(json.contains(#""0xab""#))
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let moments = try #require(parsed["moments"] as? [[String: Any]])
        #expect(try #require(JSONTree.node(moments.first?["root"])) == dump.moments.first?.root)
    }

    /// Floats print from their bits, the same on every machine: the two
    /// patterns the first Actions run of 0.2.1 printed differently on the
    /// runner Mac, and the rest of the forms.
    @Test func floatsPrintFromTheirBits() {
        #expect(Dumper.float(bits: 0x7FF0_0000_0000_0001) == "snan(0x1)")
        #expect(Dumper.float(bits: 0x7FF8_2804_7692_A8CB) == "nan(0x28047692a8cb)")
        #expect(
            Dumper.float(bits: 0x7FF4_0000_0000_0001) == "snan(0x4000000000001)", "the bit below the quiet bit shows")
        #expect(Dumper.float(bits: 0x7FF8_0000_0000_0000) == "nan")
        #expect(Dumper.float(bits: 0xFFF8_0000_0000_0000) == "nan")
        #expect(Dumper.float(bits: 0x7FF0_0000_0000_0000) == "inf")
        #expect(Dumper.float(bits: 0xFFF0_0000_0000_0000) == "-inf")
        #expect(Dumper.float(bits: (2.0).bitPattern) == "2.0")
        #expect(Dumper.float(bits: (-0.0).bitPattern) == "-0.0")
        #expect(Dumper.float(bits: (0.0).bitPattern) == "0.0")
        #expect(Dumper.float(bits: (1.5).bitPattern) == "1.5")
        #expect(Dumper.float(bits: (-3.25).bitPattern) == "-3.25")
        #expect(Dumper.float(bits: (1e300).bitPattern) == "1e+300")
        #expect(Dumper.float(bits: Double.pi.bitPattern) == "3.141592653589793")
    }

    /// The first line names the file's format version, and `--verify`
    /// walks the commits of either: a version 1 input, whose first commit
    /// ends at 62, and a version 2 fixture, whose first ends at 57.
    @Test func theHeaderNamesTheVersionAndVerifyWalksBoth() throws {
        let resources = try Self.resources()
        let one = try Self.bytes(resources.appendingPathComponent("fixtures/inputs/v1-history.db"))
        let two = try Self.bytes(resources.appendingPathComponent("fixtures/valid/01-list-root-hash-map.db"))
        for (bytes, version, first) in [(one, 1, UInt64(62)), (two, 2, UInt64(57))] {
            let dump = Self.dump(bytes, Self.verifying)
            #expect(dump.exitCode == 0)
            #expect(dump.header?.version == version)
            let verification = try #require(dump.verification)
            #expect(verification.commits.count == 3)
            #expect(verification.commits.first?.end == first)
            #expect(verification.commits.last?.end == UInt64(bytes.count))
            #expect(verification.bytesPastLastCommit == nil)

            let text = TextRenderer.render(dump, options: Self.verifying)
            let firstLine = try #require(text.split(separator: "\n").first)
            #expect(firstLine.hasPrefix("xitdb file: \(bytes.count) bytes; version \(version), hash size 20, "))
            var json = Self.verifying
            json.json = true
            let document = try #require(
                try JSONSerialization.jsonObject(with: Data(JSONRenderer.render(dump, options: json).utf8))
                    as? [String: Any])
            let file = try #require(document["file"] as? [String: Any])
            #expect(file["version"] as? Int == version)
        }
        // the same two moments in both, five bytes apart
        #expect(one.count == two.count + 5)
    }

    /// A file without a first commit, as a full copy that did not finish
    /// leaves it, opens but holds nothing that reads. The dump says what it
    /// is and shows what recovery would open: the last commit that arrived
    /// whole, from a copy in memory. Where no commit arrived whole it
    /// shows the header and says so. Either way it exits with 1.
    @Test func aFileWithoutAFirstCommitIsDumpedAsRecoveryWouldOpenIt() throws {
        let resources = try Self.resources()
        let whole = try Self.bytes(resources.appendingPathComponent("fixtures/valid/01-list-root-hash-map.db"))
        let commits = try Database.verifiedCommits(in: MemoryStorage(bytes: whole))
        try #require(commits.count == 3)

        // the copy stopped ten bytes into the last commit; its committed
        // size, at 24, was never written
        var unfinished = Array(whole[..<(Int(commits[1].end) + 10)])
        unfinished.replaceSubrange(24..<32, with: [UInt8](repeating: 0, count: 8))
        let dump = Self.dump(unfinished, Self.verifying)
        #expect(dump.exitCode == 1)
        #expect(dump.header?.version == 2)
        #expect(dump.header?.fileSize == UInt64(unfinished.count))
        #expect(dump.header?.committedSize == commits[1].end)
        #expect(dump.header?.momentCount == 1)
        #expect(dump.moments.count == 1)
        #expect(dump.verification?.commits.count == 2)
        #expect(dump.verification?.bytesPastLastCommit == 10)
        let note = try #require(dump.notes.first { $0.contains("no first commit") })
        #expect(note.contains("ends at byte \(commits[1].end) of \(unfinished.count)"))
        #expect(note.contains("what follows is what recovery would open"))
        // the moment shown is the first moment of the whole file
        var first = DumpOptions()
        first.moment = 0
        #expect(dump.moments.first?.root == Self.dump(whole, first).moments.first?.root)
        let text = TextRenderer.render(dump, options: Self.verifying)
        #expect(!text.contains("unreadable"))

        // nothing arrived whole: the headers and bytes that are no commit
        let nothing = Array(unfinished[..<32]) + [UInt8](repeating: 0xAA, count: 100)
        let empty = Self.dump(nothing, Self.verifying)
        #expect(empty.exitCode == 1)
        #expect(empty.header?.version == 2)
        #expect(empty.header?.committedSize == 0)
        #expect(empty.moments.isEmpty)
        #expect(empty.verification?.commits.isEmpty == true)
        #expect(empty.notes.contains { $0.contains("no first commit") && $0.contains("nothing to show") })
        let emptyText = TextRenderer.render(empty, options: Self.verifying)
        #expect(emptyText.hasPrefix("xitdb file: 132 bytes, 0 committed; version 2, hash size 20, "))
        _ = JSONRenderer.render(empty, options: Self.verifying)
    }

    /// A file that is not xitdb exits with 2 and says why.
    @Test func filesThatAreNotXitdb() throws {
        for bytes in [[UInt8](), Array("hello, not a database".utf8), [UInt8](repeating: 0, count: 100)] {
            let dump = Self.dump(bytes, Self.verifying)
            #expect(dump.exitCode == 2)
            #expect(dump.moments.isEmpty)
            #expect(!dump.notes.isEmpty)
            #expect(TextRenderer.render(dump, options: Self.verifying).contains("note:"))
        }
    }
}

/// Reads the dump's JSON back into its tree.
enum JSONTree {
    static func node(_ any: Any?) -> Node? {
        guard let object = any as? [String: Any], let kindName = object["kind"] as? String,
            let kind = Node.Kind(rawValue: kindName)
        else { return nil }
        var node = Node(kind)
        switch kind {
        case .uint:
            if let number = object["value"] as? NSNumber { node.text = String(number.uint64Value) }
        case .int:
            if let number = object["value"] as? NSNumber { node.text = String(number.int64Value) }
        case .float:
            if let text = object["value"] as? String {
                node.text = text
            } else if let number = object["value"] as? NSNumber {
                node.text = Dumper.float(bits: number.doubleValue.bitPattern)
            }
        case .bytes:
            if let utf8 = object["utf8"] as? String { node.text = utf8 }
            if let hex = object["hex"] as? String { node.hex = hex }
            if let length = object["length"] as? NSNumber { node.length = length.uint64Value }
            node.formatTag = object["formatTag"] as? String
        case .shared, .cycle, .truncated, .unreadable:
            node.text = object["note"] as? String
        case .empty, .nothing:
            break
        case .map, .set, .countedMap, .countedSet, .list, .linked, .sortedMap, .sortedSet:
            if let count = object["count"] as? NSNumber { node.count = count.uint64Value }
            if let elements = object["elements"] as? [Any] {
                for (index, element) in elements.enumerated() {
                    guard let child = self.node(element) else { return nil }
                    node.children.append(Node.Child(index: child.kind == .truncated ? nil : index, node: child))
                }
            }
            if let entries = object["entries"] as? [[String: Any]] {
                for entry in entries {
                    guard let value = self.node(entry["value"]) else { return nil }
                    var child = Node.Child(node: value)
                    if let hash = entry["hash"] as? String { child.hash = bytes(hex: hash) }
                    child.name = entry["key"] as? String
                    child.keyHex = entry["keyHex"] as? String
                    node.children.append(child)
                }
            }
        }
        if let position = object["position"] as? NSNumber { node.position = position.uint64Value }
        if let size = object["size"] as? NSNumber { node.size = size.uint64Value }
        return node
    }

    private static func bytes(hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var text = Substring(hex)
        while text.count >= 2 {
            bytes.append(UInt8(text.prefix(2), radix: 16) ?? 0)
            text = text.dropFirst(2)
        }
        return bytes
    }
}
