// The dump as JSON: the same tree, one document, keys in a fixed order.

package enum JSONRenderer {
    package static func render(_ dump: Dump, options: DumpOptions) -> String {
        var out = ""
        object(into: &out, indent: 0) { fields in
            if let header = dump.header {
                fields.append(
                    (
                        "file",
                        { out, indent in
                            object(into: &out, indent: indent) { f in
                                f.append(("bytes", { o, _ in o += "\(header.fileSize)" }))
                                f.append(("committed", { o, _ in o += "\(header.committedSize)" }))
                                f.append(("version", { o, _ in o += "\(header.version)" }))
                                f.append(("hashSize", { o, _ in o += "\(header.hashSize)" }))
                                if let text = header.hashIDText {
                                    f.append(("hashId", { o, _ in o += string(text) }))
                                } else {
                                    f.append(("hashIdHex", { o, _ in o += string(header.hashIDHex) }))
                                }
                                f.append(("fileId", { o, _ in o += string(header.fileID) }))
                                f.append(("moments", { o, _ in o += header.momentCount.map { "\($0)" } ?? "null" }))
                            }
                        }
                    ))
            }
            if let verification = dump.verification {
                fields.append(
                    (
                        "verify",
                        { out, indent in
                            object(into: &out, indent: indent) { f in
                                f.append(
                                    (
                                        "commits",
                                        { o, i in
                                            array(into: &o, indent: i, verification.commits) { o, i, commit in
                                                object(into: &o, indent: i) { f in
                                                    f.append(("end", { o, _ in o += "\(commit.end)" }))
                                                    f.append(("id", { o, _ in o += string(commit.commitID) }))
                                                    f.append(("root", { o, _ in o += string(commit.rootTag) }))
                                                }
                                            }
                                        }
                                    ))
                                f.append(("fileSize", { o, _ in o += "\(verification.fileSize)" }))
                                f.append(
                                    (
                                        "bytesPastLastCommit",
                                        { o, _ in o += verification.bytesPastLastCommit.map { "\($0)" } ?? "null" }
                                    ))
                            }
                        }
                    ))
            }
            fields.append(
                ("notes", { o, i in array(into: &o, indent: i, dump.notes) { o, _, note in o += string(note) } }))
            fields.append(
                (
                    "moments",
                    { o, i in
                        array(into: &o, indent: i, dump.moments) { o, i, moment in
                            object(into: &o, indent: i) { f in
                                f.append(("index", { o, _ in o += "\(moment.index)" }))
                                f.append(("root", { o, i in node(moment.root, into: &o, indent: i, options: options) }))
                            }
                        }
                    }
                ))
            fields.append(("exitCode", { o, _ in o += "\(dump.exitCode)" }))
        }
        return out + "\n"
    }

    private static func node(_ node: Node, into out: inout String, indent: Int, options: DumpOptions) {
        object(into: &out, indent: indent) { f in
            f.append(("kind", { o, _ in o += string(node.kind.rawValue) }))
            switch node.kind {
            case .uint, .int:
                f.append(("value", { o, _ in o += node.text ?? "null" }))
            case .float:
                // JSON has no nan or inf: those go as text.
                f.append(
                    (
                        "value",
                        { o, _ in
                            if let text = node.text, Double(text)?.isFinite == true {
                                o += text
                            } else {
                                o += string(node.text ?? "")
                            }
                        }
                    ))
            case .bytes:
                if let length = node.length { f.append(("length", { o, _ in o += "\(length)" })) }
                if let tag = node.formatTag { f.append(("formatTag", { o, _ in o += string(tag) })) }
                if let text = node.text {
                    if text.hasPrefix("0x") {
                        f.append(("hex", { o, _ in o += string(String(text.dropFirst(2))) }))
                    } else {
                        f.append(("utf8", { o, _ in o += string(text) }))
                    }
                }
            case .shared, .cycle, .truncated, .unreadable:
                if let text = node.text { f.append(("note", { o, _ in o += string(text) })) }
            case .empty, .nothing:
                break
            case .map, .set, .countedMap, .countedSet, .list, .linked, .sortedMap, .sortedSet:
                if let count = node.count { f.append(("count", { o, _ in o += "\(count)" })) }
                let isList = node.kind == .list || node.kind == .linked
                f.append(
                    (
                        isList ? "elements" : "entries",
                        { o, i in
                            array(into: &o, indent: i, node.children) { o, i, child in
                                if isList {
                                    self.node(child.node, into: &o, indent: i, options: options)
                                } else {
                                    object(into: &o, indent: i) { f in
                                        if let hash = child.hash, hash.contains(where: { $0 != 0 }) {
                                            f.append(("hash", { o, _ in o += string(Dumper.hex(hash)) }))
                                        }
                                        if let name = child.name { f.append(("key", { o, _ in o += string(name) })) }
                                        if let hex = child.keyHex { f.append(("keyHex", { o, _ in o += string(hex) })) }
                                        f.append(
                                            (
                                                "value",
                                                { o, i in self.node(child.node, into: &o, indent: i, options: options) }
                                            ))
                                    }
                                }
                            }
                        }
                    ))
            }
            if let position = node.position { f.append(("position", { o, _ in o += "\(position)" })) }
            if let size = node.size { f.append(("size", { o, _ in o += "\(size)" })) }
        }
    }

    // MARK: Writing

    private typealias Field = (String, (inout String, Int) -> Void)

    private static func object(into out: inout String, indent: Int, _ build: (inout [Field]) -> Void) {
        var fields: [Field] = []
        build(&fields)
        if fields.isEmpty {
            out += "{}"
            return
        }
        out += "{\n"
        for (index, (name, write)) in fields.enumerated() {
            out += String(repeating: "  ", count: indent + 1) + string(name) + ": "
            write(&out, indent + 1)
            out += index + 1 < fields.count ? ",\n" : "\n"
        }
        out += String(repeating: "  ", count: indent) + "}"
    }

    private static func array<Element>(
        into out: inout String, indent: Int, _ elements: [Element], _ write: (inout String, Int, Element) -> Void
    ) {
        if elements.isEmpty {
            out += "[]"
            return
        }
        out += "[\n"
        for (index, element) in elements.enumerated() {
            out += String(repeating: "  ", count: indent + 1)
            write(&out, indent + 1, element)
            out += index + 1 < elements.count ? ",\n" : "\n"
        }
        out += String(repeating: "  ", count: indent) + "]"
    }

    package static func string(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let digits = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
