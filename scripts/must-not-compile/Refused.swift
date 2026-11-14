// What must not compile (decision D35, item 4): `Int` is not a value, so an
// integer whose kind is not spelled is refused by the compiler, with the
// message of the unavailable conformance. `scripts/must-not-compile.sh`
// type-checks this file against the built library and requires that message
// on every line marked below, and nowhere else.
//
// One marked line, one refusal. A line that compiles, or that is refused
// for another reason, fails the gate.

import XitDB

func refused(
    map: HashMap<ReadWrite>, counted: CountedHashMap<ReadWrite>, sorted: SortedMap<ReadWrite>,
    list: ArrayList<ReadWrite>, linked: LinkedArrayList<ReadWrite>, cursor: inout Cursor<ReadWrite>
) throws {
    // An integer literal: without the refusal it would be taken for a
    // `Double` and written as a float.
    try map.put(25, forKey: "age")  // must not compile
    try map.put(-3, forKey: "delta")  // must not compile
    try counted.put(25, forKey: "age")  // must not compile
    try sorted.put(25, forKey: "age")  // must not compile
    try sorted.put(25, forKey: [UInt8]([1, 2]))  // must not compile
    try list.append(25)  // must not compile
    try list.put(25, at: 0)  // must not compile
    try linked.append(25)  // must not compile
    try linked.put(25, at: 0)  // must not compile
    try linked.insert(25, at: 0)  // must not compile
    try cursor.write(25)  // must not compile

    // An `Int` that is no literal.
    let count = [1, 2, 3].count
    try map.put(count, forKey: "count")  // must not compile
    try list.append(count)  // must not compile

    // Reading as `Int`.
    _ = try map.value(forKey: "age", as: Int.self)  // must not compile
    _ = try sorted.value(forKey: "age", as: Int.self)  // must not compile
    _ = try list.value(at: 0, as: Int.self)  // must not compile
    _ = try linked.value(at: 0, as: Int.self)  // must not compile
    _ = try cursor.read(Int.self)  // must not compile
    let inferred: Int? = try map.value(forKey: "age")  // must not compile
    _ = inferred
}
