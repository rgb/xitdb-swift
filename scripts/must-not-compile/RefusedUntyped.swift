// What must not compile, third file: the calls that take a closure of the
// caller's, made bare where the library's error is declared.
//
// The calls of the library that run a closure of the caller's pass on
// whatever it throws, as it was thrown, so they throw `any Error`: a
// transaction, the append of each kind of list that takes a body, a
// cursor's `writeBytes`, and every collection's walk to the end,
// `forEachEntry` on a map or a set and `forEachElement` on a list, with the
// lists' second, which reads each element as a type. A function that declares
// `throws(XitDBError)`
// cannot make them bare, and that is as it should be: the compiler says at
// the call that something other than the library's error can come out of
// it. `scripts/must-not-compile.sh` type-checks this file against the built
// library: each marked line must be refused with the compiler's own words
// for it, and nothing else may be refused.
//
// The same calls through `XitDBError.carrying`, which is what such a
// function writes, are in `Accepted.swift`.

import XitDB

func refusedBare(
    database: Database, list: ArrayList<ReadWrite>, linked: LinkedArrayList<ReadWrite>, cursor: inout Cursor<ReadWrite>
) throws(XitDBError) {
    try database.withTransaction { root in _ = root }  // must not compile: untyped
    try list.append(.uint(1)) { element in _ = element }  // must not compile: untyped
    try linked.append(.uint(1)) { element in _ = element }  // must not compile: untyped
    try cursor.writeBytes { writer in try writer.write([1, 2, 3]) }  // must not compile: untyped
}

func refusedBareWalks(
    list: ArrayList<ReadOnly>, linked: LinkedArrayList<ReadOnly>,
    map: HashMap<ReadOnly>, set: HashSet<ReadOnly>,
    countedMap: CountedHashMap<ReadOnly>, countedSet: CountedHashSet<ReadOnly>,
    sortedMap: SortedMap<ReadOnly>, sortedSet: SortedSet<ReadOnly>
) throws(XitDBError) {
    try list.forEachElement { element in _ = element }  // must not compile: untyped
    try list.forEachElement(as: UInt64.self) { element in _ = element }  // must not compile: untyped
    try linked.forEachElement { element in _ = element }  // must not compile: untyped
    try linked.forEachElement(as: UInt64.self) { element in _ = element }  // must not compile: untyped
    try map.forEachEntry { entry in _ = entry }  // must not compile: untyped
    try set.forEachEntry { entry in _ = entry }  // must not compile: untyped
    try countedMap.forEachEntry { entry in _ = entry }  // must not compile: untyped
    try countedSet.forEachEntry { entry in _ = entry }  // must not compile: untyped
    try sortedMap.forEachEntry { entry in _ = entry }  // must not compile: untyped
    try sortedSet.forEachEntry { entry in _ = entry }  // must not compile: untyped
}
