// The other half of `Refused.swift`: the same calls with the number's kind
// spelled, which must compile. `scripts/must-not-compile.sh` type-checks
// this file in the same way, so that a library that was not found, or a
// wrong flag, fails the step and cannot pass for a refusal.

import XitDB

func accepted(
    map: HashMap<ReadWrite>, counted: CountedHashMap<ReadWrite>, sorted: SortedMap<ReadWrite>,
    list: ArrayList<ReadWrite>, linked: LinkedArrayList<ReadWrite>, cursor: inout Cursor<ReadWrite>
) throws {
    // The kind spelled by the type.
    try map.put(UInt64(25), forKey: "age")
    try map.put(25 as Int64, forKey: "age")
    try map.put(-3 as Int64, forKey: "delta")
    let age: UInt64 = 25
    try map.put(age, forKey: "age")
    try counted.put(UInt64(25), forKey: "age")
    try sorted.put(UInt64(25), forKey: "age")
    try sorted.put(Int64(25), forKey: [UInt8]([1, 2]))
    try list.append(UInt64(25))
    try list.put(Int64(25), at: 0)
    try linked.append(UInt64(25))
    try linked.put(UInt64(25), at: 0)
    try linked.insert(Int64(25), at: 0)
    try cursor.write(UInt64(25))

    // The kind spelled by the case.
    try map.put(.uint(25), forKey: "age")
    try map.put(.int(-3), forKey: "delta")
    try list.append(.uint(25))
    try cursor.write(.int(25))

    // A literal with a fraction is the format's float, and so is a
    // `Double` made from an integer literal with the type spelled.
    try map.put(2.5, forKey: "ratio")
    try list.append(2.5)
    let ratio: Double = 25
    try map.put(ratio, forKey: "ratio")

    // An `Int` converted, which says the kind.
    let count = [1, 2, 3].count
    try map.put(UInt64(count), forKey: "count")
    try list.append(Int64(count))

    // Reading as the kinds the format has.
    _ = try map.value(forKey: "age", as: UInt64.self)
    _ = try map.value(forKey: "delta", as: Int64.self)
    _ = try map.value(forKey: "ratio", as: Double.self)
    _ = try sorted.value(forKey: "age", as: UInt64.self)
    _ = try list.value(at: 0, as: Int64.self)
    _ = try linked.value(at: 0, as: UInt64.self)
    _ = try cursor.read(UInt64.self)
    let inferred: UInt64? = try map.value(forKey: "age")
    _ = inferred

    // The other values.
    try map.put("Alice", forKey: "name")
    try list.append([UInt8]([1, 2, 3]))
    try cursor.write(Bytes([1, 2], formatTag: "tg"))
    _ = try map.value(forKey: "name", as: String.self)
}
