// What must not compile, third file: the calls that take a closure of the
// caller's, made bare where the library's error is declared.
//
// Four calls of the library run a closure of the caller's and pass on
// whatever it throws, as it was thrown, so they throw `any Error`: a
// transaction, the append of each kind of list that takes a body, and a
// cursor's `writeBytes`. A function that declares `throws(XitDBError)`
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
