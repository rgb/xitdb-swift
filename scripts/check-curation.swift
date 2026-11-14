// The check that the ten curation files are kept up.
//
// Each file in Sources/XitDB/XitDB.docc/Extensions lists a type's members by
// task on the type's reference page. A public member that no file names is not
// an error to DocC: it lands in a group DocC makes itself ("Instance Methods",
// "Initializers"), and the page reads as if it had never been curated. This
// script reads the archive the documentation step has just built and fails if
// any member of a curated type sits in such a group, naming the type, the
// member and the file its line belongs in. The protocols' default
// implementations are the one group DocC makes that is left to it.
//
// The rule it enforces: a public member added to one of the curated types is
// curated in that type's file, in the same commit.
//
// Run from the package's root, after `swift package generate-documentation
// --target XitDB`, as scripts/check.sh does:
//
//     swift scripts/check-curation.swift
//
// It reads JSON and nothing else, so it runs the same on macOS and on Linux.

import Foundation

let extensions = "Sources/XitDB/XitDB.docc/Extensions"
let archive = ".build/plugins/Swift-DocC/outputs/XitDB.doccarchive/data/documentation/xitdb"
let manager = FileManager.default

func fail(_ message: String) -> Never {
    print("error: \(message)")
    exit(1)
}

guard manager.fileExists(atPath: archive) else {
    fail(
        "no documentation archive at \(archive): "
            + "build it first with `swift package generate-documentation --target XitDB`")
}
let files = ((try? manager.contentsOfDirectory(atPath: extensions)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
guard !files.isEmpty else { fail("no curation files in \(extensions)") }

var problems: [String] = []
var membersChecked = 0
for file in files {
    let path = "\(extensions)/\(file)"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
        let first = text.split(separator: "\n", maxSplits: 1).first,
        first.hasPrefix("# ``XitDB/"), first.hasSuffix("``")
    else {
        problems.append("\(path) does not begin with the line # ``XitDB/<Type>``")
        continue
    }
    let type = String(first.dropFirst("# ``XitDB/".count).dropLast(2))
    let page = "\(archive)/\(type.lowercased()).json"
    guard let data = manager.contents(atPath: page),
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
        problems.append("\(type): no page \(page) in the archive, for \(path)")
        continue
    }
    let references = json["references"] as? [String: Any] ?? [:]
    let sections = json["topicSections"] as? [[String: Any]] ?? []
    guard sections.contains(where: { ($0["generated"] as? Bool) != true }) else {
        problems.append("\(type): its page has no group from \(path); the file is not read as its curation")
        continue
    }
    for section in sections {
        let identifiers = section["identifiers"] as? [String] ?? []
        membersChecked += identifiers.count
        guard section["generated"] as? Bool == true else { continue }
        let title = section["title"] as? String ?? "(untitled)"
        if title == "Default Implementations" { continue }
        for identifier in identifiers {
            let reference = references[identifier] as? [String: Any]
            let name = reference?["title"] as? String ?? identifier
            let url = reference?["url"] as? String ?? identifier
            problems.append("\(type): \(name) (\(url)) is in a group DocC made, \"\(title)\": curate it in \(path)")
        }
    }
}

if !problems.isEmpty {
    for problem in problems { print("error: \(problem)") }
    exit(1)
}
print("ok: \(membersChecked) members of \(files.count) curated types, each in a group of its file")
