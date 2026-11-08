# ``XitDB/Database``

## Topics

### Opening and creating

See <doc:Storage>, and <doc:Recovery> for a file whose root header or last trailer is damaged.

- ``init(opening:hashSize:)``
- ``init(creating:hashSize:hashID:fileID:)``
- ``recover(_:)``
- ``header``

### Reading and writing

Everything starts at the root cursor, and a transaction groups writes. See <doc:Transactions>, and
<doc:CloningFreezeAndStaleHandles> for what a freeze does.

- ``rootCursor``
- ``withTransaction(_:)``
- ``freeze()``
- ``committedSize``

### Snapshots

A snapshot hands one commit to other threads and tasks, and a ``SnapshotDatabase`` reads it. See
<doc:ConcurrencyAndSnapshots>.

- ``snapshot()``

### Compacting

See <doc:Compaction>.

- ``compact(into:hashID:fileID:offsetMap:)``
- ``compact(into:offsetMap:)``

### Replicating

See <doc:Replication>.

- ``replicaState``
- ``replicationStart(for:)``
- ``readCommitted(from:to:into:)-(_,_,Sink)``
- ``readCommitted(from:to:into:)-(_,_,[UInt8])``
- ``readCommitted(from:to:)``
- ``applyReplicated(at:from:count:)``
- ``applyReplicated(at:bytes:)``
