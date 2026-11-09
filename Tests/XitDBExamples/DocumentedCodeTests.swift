import Foundation
import Testing

/// The documentation's code is the code in this target.
///
/// DocC and a README cannot include a file, so the code they show is written
/// out twice: here, where it is compiled and run, and there, where it is
/// read. This suite is what stops the two from drifting apart: every fenced
/// `swift` block of the README and of every module's articles and tutorials,
/// and every tutorial step file, must appear in this target's sources line for
/// line.
///
/// A block marked ` ```swift manifest ` is a package manifest and not a use of
/// the library, and is not checked; that is the only exception.
///
/// The comparison ignores what the documentation has no reason to show:
/// indentation, blank lines, `import` lines, and in the sources `#expect`
/// lines and the scratch directory around a file's name. A block may therefore
/// run across the checks between its lines, but it cannot skip code.
@Suite("Documented code") struct DocumentedCodeTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The catalogue of every module: `Sources/<module>/<module>.docc`.
    private static let catalogues: [URL] = {
        let sources = packageRoot.appendingPathComponent("Sources")
        let modules = (try? FileManager.default.contentsOfDirectory(atPath: sources.path)) ?? []
        return modules.sorted().map { sources.appendingPathComponent("\($0)/\($0).docc") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }()

    /// A piece of code the documentation shows, and where.
    private struct ShownCode: CustomTestStringConvertible {
        let place: String
        let lines: [String]

        var testDescription: String { place }
    }

    /// The files below a directory, as URLs that begin with the directory's
    /// own path. The walk gives paths relative to the directory, which are
    /// appended to it: a walk by URL resolves symbolic links in the
    /// directory's path, `/tmp` to `/private/tmp` say, and its URLs would not
    /// begin with the package root that ``relative(_:)`` takes off.
    private static func files(in directory: URL, withExtensions extensions: Set<String>) -> [URL] {
        guard let walker = FileManager.default.enumerator(atPath: directory.path) else { return [] }
        return walker.compactMap { $0 as? String }
            .map { directory.appendingPathComponent($0) }
            .filter { extensions.contains($0.pathExtension) }
            .sorted { $0.path < $1.path }
    }

    private static func relative(_ url: URL) -> String {
        String(url.path.dropFirst(packageRoot.path.count + 1))
    }

    /// The lines of a piece of code as they are compared.
    private static func normalised(_ lines: some Sequence<String>) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("import ") }
    }

    /// The fenced `swift` blocks of a document.
    private static func fencedBlocks(in url: URL) throws -> [ShownCode] {
        var blocks: [ShownCode] = []
        var current: [String]?
        var start = 0
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let block = current {
                if trimmed == "```" {
                    blocks.append(ShownCode(place: "\(relative(url)):\(start)", lines: normalised(block)))
                    current = nil
                } else {
                    current = block + [line]
                }
            } else if trimmed == "```swift" {
                current = []
                start = index + 1
            }
        }
        #expect(current == nil, "\(relative(url)) has a code block that does not end")
        return blocks
    }

    /// Everything the documentation shows: its fenced blocks and the step
    /// files of its tutorials.
    private static func shownCode() throws -> [ShownCode] {
        var shown = try fencedBlocks(in: packageRoot.appendingPathComponent("README.md"))
        for catalogue in catalogues {
            for url in files(in: catalogue, withExtensions: ["md", "tutorial"]) {
                shown += try fencedBlocks(in: url)
            }
            for url in files(in: catalogue, withExtensions: ["swift"]) {
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                shown.append(ShownCode(place: relative(url), lines: normalised(lines)))
            }
        }
        return shown
    }

    /// The compiled code, one line per element, with what the documentation
    /// does not show taken out, each file between line ends so that a block
    /// matches whole lines only.
    private static func compiledCode() throws -> [String] {
        let sources = files(in: packageRoot.appendingPathComponent("Tests/XitDBExamples"), withExtensions: ["swift"])
        return try sources.filter { $0.lastPathComponent != "DocumentedCodeTests.swift" }.map { url in
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            let kept = normalised(lines)
                .filter { !$0.hasPrefix("#expect(") }
                .map { $0.replacing(/scratch\.path\(("[^"]*")\)/) { String($0.1) } }
            return "\n" + kept.joined(separator: "\n") + "\n"
        }
    }

    @Test func theDocumentationIsChecked() throws {
        let shown = try Self.shownCode()
        #expect(shown.count > 0)
        #expect(shown.contains { $0.place.hasPrefix("README.md") })
        #expect(shown.contains { $0.place.contains(".docc/Articles/") })
        #expect(shown.contains { $0.place.contains(".docc/Resources/") })
        for module in ["XitDB", "XitDBHashing", "XitDBStore"] {
            #expect(shown.contains { $0.place.hasPrefix("Sources/\(module)/\(module).docc/") }, "\(module)'s catalogue")
        }
    }

    @Test func everyShownLineIsCompiled() throws {
        let compiled = try Self.compiledCode()
        for code in try Self.shownCode() {
            let wanted = "\n" + code.lines.joined(separator: "\n") + "\n"
            guard !compiled.contains(where: { $0.contains(wanted) }) else { continue }
            // The longest run of the block's first lines that is there says
            // where it departs from the code.
            var matched = 0
            while matched < code.lines.count {
                let prefix = "\n" + code.lines[...matched].joined(separator: "\n") + "\n"
                guard compiled.contains(where: { $0.contains(prefix) }) else { break }
                matched += 1
            }
            let departure = matched < code.lines.count ? code.lines[matched] : "(the block as a whole)"
            Issue.record("\(code.place): not in Tests/XitDBExamples, from this line: \(departure)")
        }
    }

    /// A dump the documentation shows, and the pinned dump it is taken from.
    private struct ShownDump: CustomTestStringConvertible {
        let place: String
        let pinned: String
        /// The block's lines, in runs between the lines that are a lone "…".
        let runs: [[String]]

        var testDescription: String { place }
    }

    /// Every block that follows a comment `<!-- Pinned: … -->` naming a file
    /// under `Tests/XitDBTests/Resources/dumps`, which `DumpTests` holds
    /// `xitdb-dump` to.
    private static func shownDumps() throws -> [ShownDump] {
        var dumps: [ShownDump] = []
        for catalogue in catalogues {
            for url in files(in: catalogue, withExtensions: ["md"]) {
                var pinned: String?
                var block: [String]?
                var start = 0
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if let current = block, let file = pinned {
                        if trimmed == "```" {
                            let runs = current.split(separator: "…", omittingEmptySubsequences: false).map(Array.init)
                            dumps.append(ShownDump(place: "\(relative(url)):\(start)", pinned: file, runs: runs))
                            block = nil
                            pinned = nil
                        } else {
                            block = current + [line]
                        }
                    } else if trimmed.hasPrefix("<!-- Pinned:"),
                        let match = trimmed.firstMatch(of: /Tests\/XitDBTests\/Resources\/dumps\/[^ ,]+\.txt/)
                    {
                        pinned = String(match.output)
                    } else if pinned != nil, trimmed.hasPrefix("```") {
                        block = []
                        start = index + 1
                    }
                }
                #expect(pinned == nil, "\(relative(url)) has a pinned comment with no block after it")
            }
        }
        return dumps
    }

    /// Each run of a shown dump's lines is in its pinned dump as it is, the
    /// runs in order: the documentation shows what the tool prints.
    @Test func everyShownDumpIsPinned() throws {
        let dumps = try Self.shownDumps()
        #expect(dumps.count > 0)
        for dump in dumps {
            let file = Self.packageRoot.appendingPathComponent(dump.pinned)
            let pinned = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            var from = 0
            for run in dump.runs {
                let found =
                    run.isEmpty
                    ? nil
                    : (from..<pinned.count).first { at in
                        at + run.count <= pinned.count && Array(pinned[at..<(at + run.count)]) == run
                    }
                guard let found else {
                    Issue.record("\(dump.place): not in \(dump.pinned) from here: \(run.first ?? "(an empty run)")")
                    break
                }
                from = found + run.count
            }
        }
    }
}
