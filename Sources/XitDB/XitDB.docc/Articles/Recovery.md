# Recovery

What opening does with a root header it cannot trust, what recovering does, and what it can lose.

## Overview

A file starts with a header of 20 bytes and then the root header, which holds the committed size: eight bytes that every
commit rewrites last, at offset 24 in a version 2 file and at 29 in a version 1 file (see <doc:Storage>). Every commit ends
with a trailer of 25 bytes, whose checksum covers the file's ID, the trailer's own position, the root slot and the commit's
ID. So a trailer that verifies is the end of a commit of this file, written where it is.

Opening reads the header, then the root header, and checks that the committed size ends at a trailer that verifies. It writes
nothing. A root header that fails the check is refused, and ``Database/recover(_:)`` is the one call that does anything about
it. That call cuts a database back to an earlier commit of its own, which can lose the commits after it.

### What a root header can be

The examples are a history of three moments. Its commits end at 57 bytes (the new database), 251 (the empty history),
and 639, 1,027 and 1,415 (one moment each).

- **Sound.** The committed size is inside the file and ends at a trailer that verifies. The file opens. Bytes past the committed
  size, if there are any, are what an unfinished transaction left, and the next transaction discards them.
- **Damaged in its size.** The size is past the end of the file, smaller than a database can be, or not at a trailer that verifies,
  as when the root header's own write was torn. Opening throws ``XitDBError/untrustedRootHeader(lastVerified:)``, and
  `lastVerified` is where the last trailer that verifies ends: 1,415 here, as nothing else is wrong. A size of zero in a file
  longer than a new database is not refused: that is what a full copy that did not finish leaves, and it opens, as the last
  section says.
- **Pointing at a damaged trailer**, or past the end of a file that was cut short. Opening throws the same error, and
  `lastVerified` is the end of the commit before: 1,027.
- **In a file with no commit to go back to.** If the file does not start with a database's header, or no trailer in it verifies,
  opening throws ``XitDBError/invalidDatabase``, as there is nothing to recover to. A damaged file ID in the header does that too,
  since every trailer's checksum covers it, even with every commit intact. A file too short for its headers throws
  ``XitDBError/endOfStream``, and an empty one ``XitDBError/invalidDatabase``.

The trailers are checksummed and the data is not. A changed byte in a value, with the root header and the trailers intact, opens
without an error and reads back wrong. Recovery does not help there, and nothing detects it: see <doc:Errors>.

### Recovering

``Database/recover(_:)`` scans the storage back from its end for the last trailer that verifies, cuts the storage off after it,
writes that commit's end as the committed size, syncs, and opens the database:

```swift
func openOrRecover(_ storage: any WritableStorage) throws(XitDBError) -> Database {
    do {
        return try Database(opening: storage)
    } catch .untrustedRootHeader(let lastVerified) {
        // Copy the file first if what lies past lastVerified might be wanted.
        print("cutting the file back to \(lastVerified) bytes")
        return try Database.recover(storage)
    }
}
```

On the file cut short by one byte, that gives a database of two moments and 1,027 bytes. The third commit is gone, because its
trailer was. From there the database goes on as any other.

What to know before calling it:

- **It can lose a commit.** Everything after the last trailer that verifies is discarded: a commit whose trailer was damaged, and
  whatever followed. If those bytes might be wanted, copy the file first. Opening never drops anything; the bytes stay as they
  are until you call this.
- **It goes by the trailers, not the root header.** Called on a file whose root header is sound, it still cuts to the last trailer
  that verifies. Usually that is the one the root header names. But a process that died after a transaction's trailer and before
  its root header leaves a complete transaction past the committed size, and recovering commits it: a file that opens with two
  moments recovers to three. So call it only after opening has refused the file.
- **It needs to write.** On a storage opened read-only it fails with ``XitDBError/storageFailure(errno:)``, `EBADF`, at the write
  of the root header, and the file is as it was.
- **It refuses a file with no commit to go back to**, with ``XitDBError/invalidDatabase``, or ``XitDBError/endOfStream`` if the
  storage is too short for a header, and leaves the storage as it was.

### What a power loss can leave

A commit writes its data and its trailer, syncs, rewrites the root header, and syncs again. At ``Durability/full`` and
``Durability/ordered``, the first sync keeps the data ahead of the root header, so after a power loss the root header names a
commit that reached the disk, or an earlier one. What can still happen is a root header whose own write was torn, which opening
refuses and recovering repairs, keeping the commit whose trailer made it.

Without that order, the root header can reach the disk ahead of the commit it names. That is ``Durability/none``, and a volume
on which the storage has to settle for plain `fsync` on macOS. If the trailer it names did not arrive, opening refuses the file,
and recovering takes it back to the last commit whose trailer did. The original does not open such a file at all. If the trailer
arrived and some of the data before it did not, opening accepts the file, and the missing bytes read as whatever is there.

Recovering checks trailers and nothing else. Where writes are not kept in order, a trailer can reach the disk before some of the
data it ends, and recovering keeps that commit with whatever the missing bytes read as. Use ``Durability/ordered`` or
``Durability/full`` for a file that has to survive a power loss: see <doc:Transactions>.

### A replica after a failed sync at 0

A sync at 0 reads and checks the source's database header before it touches the replica, and one that fails there leaves the
replica as it was. After that it empties the replica and writes the source's file from its start, so one that fails partway
leaves the start of the source's file: a database without a first commit, whose committed size is zero. If that is longer
than a new database, it opens, and there are two ways on. Its ``Database/replicaState`` is a size of zero and a checksum of
zero, to which the source answers 0, so the next sync replaces it whole. Or, if what arrived reaches past the end of one of
the source's commits, it holds that commit whole, and recovering keeps the last such commit. The source can then send only
the rest:

```swift
// What arrived holds the source's earlier commits. Keep the last of them.
replica = try Database.recover(replicaStorage)
let start = try source.replicationStart(for: try replica.replicaState)
let end = try source.committedSize
let bytes = try source.readCommitted(from: start, to: end)
try replica.applyReplicated(at: start, bytes: bytes)
```

With the history above as the source, a connection that drops after 1,100 bytes recovers to 1,027, and the sync sends the last
388. If the sync failed before the source's first commit, its first 57 bytes, arrived, there is nothing to recover: recovering
throws, and opening refuses what is left, as it refuses a creation that did not finish. The database that ran the sync can
still take the next one from 0, and after a restart so can a database created over what is left. See <doc:Replication>.

## See Also

- ``Database/recover(_:)``
- ``XitDBError/untrustedRootHeader(lastVerified:)``
- <doc:Errors>
- <doc:Storage>
- <doc:Replication>
