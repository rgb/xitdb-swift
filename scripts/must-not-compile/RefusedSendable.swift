// What must not compile, second file: sending what stays with one thread.
//
// Every public type of the library that is tied to one thread or task,
// because it holds or reaches a database, a cursor or a storage, says so to
// the compiler with an unavailable `Sendable` conformance, whose message
// says what to do in its place. `scripts/must-not-compile.sh` type-checks
// this file against the built library. Each marked line names the type
// whose conformance it asks for, and must be refused with that type's
// message, read from the library's source; nothing else may be refused; and
// the types named here must be exactly the ones the library marks, so that
// a type marked later and not sent here fails the gate.
//
// What is sent in their place, a snapshot, is in `Accepted.swift`.

import XitDB

func sent<Value: Sendable & ~Copyable>(_ value: borrowing Value) {}

func refused(
    database: Database, snapshotDatabase: SnapshotDatabase,
    memory: MemoryStorage, file: FileStorage, buffered: BufferedFileStorage,
    cursor: Cursor<ReadOnly>, writing: Cursor<ReadWrite>, entry: Entry,
    iterator: CollectionIterator, entries: EntryIterator, elements: ElementIterator<UInt64>,
    reader: ByteReader, writer: borrowing ByteWriter,
    list: ArrayList<ReadOnly>, linked: LinkedArrayList<ReadOnly>,
    map: HashMap<ReadOnly>, set: HashSet<ReadOnly>,
    countedMap: CountedHashMap<ReadOnly>, countedSet: CountedHashSet<ReadOnly>,
    sortedMap: SortedMap<ReadOnly>, sortedSet: SortedSet<ReadWrite>
) {
    sent(database)  // must not compile: Database
    sent(snapshotDatabase)  // must not compile: SnapshotDatabase
    sent(memory)  // must not compile: MemoryStorage
    sent(file)  // must not compile: FileStorage
    sent(buffered)  // must not compile: BufferedFileStorage
    sent(cursor)  // must not compile: Cursor
    sent(writing)  // must not compile: Cursor
    sent(entry)  // must not compile: Entry
    sent(iterator)  // must not compile: CollectionIterator
    sent(entries)  // must not compile: EntryIterator
    sent(elements)  // must not compile: ElementIterator
    sent(reader)  // must not compile: ByteReader
    sent(writer)  // must not compile: ByteWriter
    sent(list)  // must not compile: ArrayList
    sent(linked)  // must not compile: LinkedArrayList
    sent(map)  // must not compile: HashMap
    sent(set)  // must not compile: HashSet
    sent(countedMap)  // must not compile: CountedHashMap
    sent(countedSet)  // must not compile: CountedHashSet
    sent(sortedMap)  // must not compile: SortedMap
    sent(sortedSet)  // must not compile: SortedSet
}
