// The dump as text: one structure per line, indented.

package enum TextRenderer {
    package static func render(_ dump: Dump, options: DumpOptions) -> String {
        var lines: [String] = []
        if let header = dump.header {
            var line = "xitdb file: \(header.fileSize) bytes"
            if header.committedSize != header.fileSize { line += ", \(header.committedSize) committed" }
            let hashID = header.hashIDText.map { "\"\($0)\"" } ?? "0x" + header.hashIDHex
            line += "; hash size \(header.hashSize), hash id \(hashID), file id \(header.fileID)"
            if let count = header.momentCount { line += "; \(count) moment\(count == 1 ? "" : "s")" }
            lines.append(line)
        }
        if let verification = dump.verification {
            let count = verification.commits.count
            var line = "verify: \(count) commit\(count == 1 ? "" : "s") verif\(count == 1 ? "ies" : "y")"
            if let past = verification.bytesPastLastCommit {
                line += "; \(past) bytes past the last do not"
            } else if count > 0 {
                line += ", the last ending at the file's end"
            }
            lines.append(line)
            for (index, commit) in verification.commits.enumerated() {
                lines.append("  commit \(index): ends at \(commit.end), id \(commit.commitID), root \(commit.rootTag)")
            }
        }
        for note in dump.notes {
            lines.append("note: \(note)")
        }
        for moment in dump.moments {
            var label = "moment \(moment.index)"
            if !options.path.isEmpty {
                label +=
                    "/"
                    + options.path.map { step in
                        switch step {
                        case .index(let index): "#\(index)"
                        case .key(let name): name
                        case .hash(let hash): Dumper.hex(hash)
                        }
                    }.joined(separator: "/")
            }
            render(moment.root, label: label, indent: 0, options: options, into: &lines)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func render(
        _ node: Node, label: String, indent: Int, options: DumpOptions, into lines: inout [String]
    ) {
        var line = String(repeating: "  ", count: indent) + label + ": " + describe(node, options: options)
        if options.offsets, let position = node.position {
            line += " @\(position)"
            if let size = node.size { line += "+\(size)" }
        }
        lines.append(line)
        for child in node.children {
            render(
                child.node, label: childLabel(child, options: options), indent: indent + 1, options: options,
                into: &lines)
        }
    }

    /// The node's own line: its kind and what it holds.
    package static func describe(_ node: Node, options: DumpOptions) -> String {
        switch node.kind {
        case .empty: return "empty"
        case .nothing: return "nothing"
        case .uint, .int, .float: return "\(node.kind.rawValue) \(node.text ?? "?")"
        case .bytes:
            var text = "bytes"
            if let length = node.length { text += " \(length)" }
            if let tag = node.formatTag { text += " tag \(tag)" }
            if let shown = node.text {
                if shown.hasPrefix("0x") {
                    text += " \(shown)"
                    if let length = node.length, length > 64 { text += "… (64 of \(length))" }
                } else {
                    text += " \"\(shown.replacing("\"", with: "\\\""))\""
                }
            }
            return text
        case .map, .set, .countedMap, .countedSet, .list, .linked, .sortedMap, .sortedSet:
            if let count = node.count {
                if node.kind == .map || node.kind == .set {
                    // These keep no count: the number is of the entries shown.
                    return "\(node.kind.rawValue) (\(count) \(count == 1 ? "entry" : "entries"))"
                }
                return "\(node.kind.rawValue) (\(count))"
            }
            return node.kind.rawValue
        case .shared: return "shared with \(node.text ?? "?")"
        case .cycle: return "cycle back to \(node.text ?? "?")"
        case .truncated: return "… \(node.text ?? "")"
        case .unreadable: return "unreadable: \(node.text ?? "")"
        }
    }

    private static func childLabel(_ child: Node.Child, options: DumpOptions) -> String {
        if let index = child.index { return "#\(index)" }
        var parts: [String] = []
        if let name = child.name { parts.append("\"\(name.replacing("\"", with: "\\\""))\"") }
        if let hex = child.keyHex { parts.append("0x" + hex) }
        if let hash = child.hash, hash.contains(where: { $0 != 0 }) {
            parts.append(Dumper.hex(options.fullHashes ? hash : Array(hash.prefix(8))))
        }
        return parts.isEmpty ? "·" : parts.joined(separator: " ")
    }
}
