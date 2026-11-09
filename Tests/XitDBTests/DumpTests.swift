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
        #expect(fixtures.count == 248)
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
        #expect(damaged == 14)
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
        #expect(truncated.verification?.bytesPastLastCommit == UInt64(whole.count - 10 - 62))
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
    @Test func verifiedCommitsMatchTheSidecars() throws {
        let folder = try Self.resources().appendingPathComponent("fixtures/valid")
        var checked = 0
        for sidecar in try Self.files("fixtures/valid", suffix: ".db.sidecar.json") {
            let name = sidecar.lastPathComponent.replacing(".db.sidecar.json", with: "")
            let document = try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any],
                Comment(rawValue: name))
            let ops = try #require(document["ops"] as? [[String: Any]], Comment(rawValue: name))
            var recorded = ["\(try #require(document["initial_size"] as? UInt64)):0000000000000000"]
            for op in ops {
                guard let id = op["commit_id"] as? String, let end = op["committed_size"] as? UInt64 else { continue }
                recorded.append("\(end):\(id)")
            }
            let bytes = try Self.bytes(folder.appendingPathComponent("\(name).db"))
            let commits = try Database.verifiedCommits(in: MemoryStorage(bytes: bytes))
            let scanned = commits.map { "\($0.end):\(Dumper.hex(bigEndian: $0.commitID))" }
            var remaining = recorded[...]
            var inOrder = true
            for commit in scanned {
                guard let index = remaining.firstIndex(of: commit) else {
                    inOrder = false
                    break
                }
                remaining = remaining[(index + 1)...]
            }
            #expect(inOrder, "\(name): scan \(scanned) is not in the sidecar's order \(recorded)")
            #expect(commits.last.map { $0.end <= UInt64(bytes.count) } == true, Comment(rawValue: name))
            #expect(commits.count >= 2, Comment(rawValue: name))
            checked += 1
        }
        #expect(checked == 131, "every fixture with a sidecar")
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
            if let hex = object["hex"] as? String { node.text = "0x" + hex }
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
