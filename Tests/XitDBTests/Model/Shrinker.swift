// On a failure, the shortest sequence that still fails, printed as a
// conformance-style script for the conformance session.

/// Cuts a failing sequence of transactions down.
enum ModelShrinker {
    /// The shortest failing prefix, with the operations its last
    /// transaction does not need taken out, and then every earlier
    /// transaction the failure does not need.
    static func shrink(_ transactions: [ModelTransaction], fails: ([ModelTransaction]) -> Bool) -> [ModelTransaction] {
        var length = transactions.count
        for prefix in 1...transactions.count where fails(Array(transactions.prefix(prefix))) {
            length = prefix
            break
        }
        var kept = Array(transactions.prefix(length))
        // The last transaction's operations, one by one.
        if var last = kept.last {
            var index = 0
            while index < last.operations.count {
                var candidate = last
                candidate.operations.remove(at: index)
                var trial = kept
                trial[trial.count - 1] = candidate
                if !candidate.operations.isEmpty, fails(trial) {
                    last = candidate
                    kept = trial
                } else {
                    index += 1
                }
            }
        }
        // Earlier transactions, whole.
        var index = 0
        while index < kept.count - 1 {
            var trial = kept
            trial.remove(at: index)
            if fails(trial) { kept = trial } else { index += 1 }
        }
        return kept
    }
}

/// Writes transactions as the conformance scripts write them, one op per
/// line, replaying the model to pick each path's init parts.
enum ModelScriptPrinter {
    static func script(_ transactions: [ModelTransaction]) -> String {
        var lines: [String] = []
        lines.append(
            "{\"format\": \"xitdb-script/1\", \"hash_size\": \(ModelRunner.hashSize), \"hash_id\": null, \"file_id\": \"0000000000000007\", \"ops\": ["
        )
        var model: ModelValue = .map(ModelMap())
        for (number, transaction) in transactions.enumerated() {
            var inner: [String] = []
            var working = model
            for operation in transaction.operations {
                inner += ops(for: operation, in: working)
                ModelApplier.apply(operation, to: &working)
            }
            if transaction.rollsBack { inner.append("{\"op\": \"fail\"}") }
            let last = number == 0 ? "null" : "{\"var\": \"last\"}"
            if number > 0 {
                lines.append(
                    "  {\"op\": \"read_path_slot\", \"on\": \"root\", \"path\": [{\"array_list_get\": -1}], \"as\": \"last\"},"
                )
            }
            var line =
                "  {\"op\": \"write_path\", \"on\": \"root\", \"path\": [\"array_list_init\", \"array_list_append\", {\"write\": {\"slot\": \(last)}}, {\"ctx\": {\"as\": \"m\", \"ops\": [\n"
            line += inner.map { "    " + $0 }.joined(separator: ",\n")
            line += "\n  ]}}]" + (transaction.rollsBack ? ", \"expect_error\": \"ScriptAbort\"" : "") + "}"
            lines.append(line + (number + 1 < transactions.count ? "," : ""))
            if !transaction.rollsBack { model = working }
        }
        lines.append("]}")
        return lines.joined(separator: "\n")
    }

    private static func ops(for operation: ModelOperation, in model: ModelValue) -> [String] {
        func path(_ steps: some Collection<ModelStep>, then tail: [String]) -> String {
            var parts: [String] = ["{\"hash_map_init\": {}}"]
            var node: ModelValue? = model
            for step in steps {
                switch step {
                case .key(let hash):
                    if case .countedMap? = node { parts[parts.count - 1] = "{\"hash_map_init\": {\"counted\": true}}" }
                    parts.append("{\"hash_map_get\": {\"value\": {\"hex\": \"\(hex(hash))\"}}}")
                case .index(let index):
                    parts.append("{\"array_list_get\": \(index)}")
                    if case .linked? = node { parts[parts.count - 1] = "{\"linked_array_list_get\": \(index)}" }
                case .sortedKey(let key):
                    parts.append("{\"sorted_map_get\": {\"value\": \(bytes(key))}}")
                }
                node = node?.value(at: [step][...])
                parts.append(initPart(for: node, after: step))
            }
            parts.removeLast()
            return "{\"op\": \"write_path\", \"on\": \"m\", \"path\": [" + (parts + tail).joined(separator: ", ") + "]}"
        }
        switch operation {
        case .put(let steps, let value):
            return [path(steps, then: ["{\"write\": \(data(value))}"])]
        case .remove(let steps):
            guard let last = steps.last else { return [] }
            let container = model.value(at: steps.dropLast()[...])
            let part: String
            switch last {
            case .key(let hash): part = "{\"hash_map_remove\": {\"hex\": \"\(hex(hash))\"}}"
            case .sortedKey(let key): part = "{\"sorted_map_remove\": \(bytes(key))}"
            case .index: return []
            }
            return [path(steps.dropLast(), then: [initPart(for: container, after: last), part])]
        case .putKey(let steps, let name):
            guard case .key(let hash)? = steps.last else { return [] }
            let container = model.value(at: steps.dropLast()[...])
            return [
                path(
                    steps.dropLast(),
                    then: [
                        initPart(for: container, after: .key(hash)),
                        "{\"hash_map_get\": {\"key\": {\"hex\": \"\(hex(hash))\"}}}",
                        "{\"write\": {\"bytes\": \(string(name))}}",
                    ])
            ]
        case .insert(let steps, let hash, let name):
            let container = model.value(at: steps[...])
            switch container {
            case .sortedSet?:
                return [
                    path(
                        steps,
                        then: [
                            "{\"sorted_map_init\": {\"set\": true}}", "{\"sorted_map_get\": {\"key\": \(bytes(hash))}}",
                        ])
                ]
            case .countedSet?:
                return [
                    path(
                        steps,
                        then: [
                            "{\"hash_map_init\": {\"counted\": true, \"set\": true}}",
                            "{\"hash_map_get\": {\"key\": {\"hex\": \"\(hex(hash))\"}}}",
                            "{\"write\": {\"bytes\": \(string(name))}}",
                        ])
                ]
            default:
                return [
                    path(
                        steps,
                        then: [
                            "{\"hash_map_init\": {\"set\": true}}",
                            "{\"hash_map_get\": {\"key\": {\"hex\": \"\(hex(hash))\"}}}",
                            "{\"write\": {\"bytes\": \(string(name))}}",
                        ])
                ]
            }
        case .make(let steps, let kind):
            return [path(steps, then: [initPart(for: kind.empty, after: .key([]))])]
        case .append(let steps, let value):
            let container = model.value(at: steps[...])
            let linked = { if case .linked? = container { return true } else { return false } }()
            var tail = [
                linked ? "\"linked_array_list_init\"" : "\"array_list_init\"",
                linked ? "\"linked_array_list_append\"" : "\"array_list_append\"",
            ]
            if let value { tail.append("{\"write\": \(data(value))}") }
            return [path(steps, then: tail)]
        case .truncate(let steps, let count):
            return [path(steps, then: ["\"array_list_init\"", "{\"array_list_slice\": {\"size\": \(count)}}"])]
        case .insertAt(let steps, let index, let value):
            return [
                path(
                    steps,
                    then: [
                        "\"linked_array_list_init\"", "{\"linked_array_list_insert\": \(index)}",
                        "{\"write\": \(data(value))}",
                    ])
            ]
        case .removeAt(let steps, let index):
            return [path(steps, then: ["\"linked_array_list_init\"", "{\"linked_array_list_remove\": \(index)}"])]
        case .slice(let steps, let offset, let count):
            return [
                path(
                    steps,
                    then: [
                        "\"linked_array_list_init\"",
                        "{\"linked_array_list_slice\": {\"offset\": \(offset), \"size\": \(count)}}",
                    ])
            ]
        case .join(let steps, let other):
            let read = path(other, then: ["\"linked_array_list_init\""]).replacing(
                "\"op\": \"write_path\"", with: "\"op\": \"read_path_slot\""
            ).replacing("]}", with: "], \"as\": \"other\"}")
            return [
                read,
                path(
                    steps,
                    then: [
                        "\"linked_array_list_init\"",
                        "{\"linked_array_list_concat\": {\"list\": {\"var\": \"other\"}}}",
                    ]),
            ]
        case .freeze:
            return ["{\"op\": \"db_freeze\"}"]
        }
    }

    private static func initPart(for node: ModelValue?, after step: ModelStep) -> String {
        switch node {
        case .countedMap?: "{\"hash_map_init\": {\"counted\": true}}"
        case .set?: "{\"hash_map_init\": {\"set\": true}}"
        case .countedSet?: "{\"hash_map_init\": {\"counted\": true, \"set\": true}}"
        case .list?: "\"array_list_init\""
        case .linked?: "\"linked_array_list_init\""
        case .sortedMap?: "{\"sorted_map_init\": {}}"
        case .sortedSet?: "{\"sorted_map_init\": {\"set\": true}}"
        default: "{\"hash_map_init\": {}}"
        }
    }

    private static func data(_ value: ModelValue) -> String {
        switch value {
        case .uint(let n): "{\"uint\": \(n)}"
        case .int(let n): "{\"int\": \(n)}"
        case .float(let bits):
            "{\"float\": \"\(String(repeating: "0", count: 16 - String(bits, radix: 16).count) + String(bits, radix: 16))\"}"
        case .bytes(let bytes): "{\"bytes\": \(self.bytes(bytes))}"
        default: "{\"slot\": null}"
        }
    }

    private static func bytes(_ bytes: [UInt8]) -> String {
        if let text = String(validating: bytes, as: UTF8.self),
            text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F && $0 != "\"" && $0 != "\\" })
        {
            return "\"\(text)\""
        }
        return "{\"hex\": \"\(hex(bytes))\"}"
    }

    private static func string(_ bytes: [UInt8]) -> String { self.bytes(bytes) }
}
