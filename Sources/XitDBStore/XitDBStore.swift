// The module re-exports the engine and the hashes: importing the store
// alone suffices.
//
// A store user needs the engine's types at every turn, the `Database` and
// its storages to make a store, `XitDBError` to catch, a `Snapshot` and its
// `SnapshotDatabase` to read on another thread, and `Cursor<ReadOnly>` and
// `Cursor<ReadWrite>` to conform a type to `StorableValue`; and a store is
// made with a hash, `SHA256.self` for most, which `XitDBHashing` holds.
// Under member import visibility a type alias names a type but not its
// members, so a re-export is the one way to give them all with one import
// (decision L8 of the store review, 2026-11-09); both are the package's own
// modules and the layer's substrate. The store's `SortedMap`, `SortedSet`
// and `Entry` share their names with engine types; a file that imports the
// store alone sees the store's, since a module's own declarations shadow
// those of a module it re-exports, and a file that imports both writes
// `XitDB.SortedMap` for the engine's.

@_exported import XitDB
@_exported import XitDBHashing
