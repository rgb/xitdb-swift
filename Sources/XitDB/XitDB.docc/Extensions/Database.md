# ``XitDB/Database``

## Topics

### Opening and creating

- ``init(opening:hashSize:)``
- ``init(creating:hashSize:hashID:fileID:)``
- ``header``

### Reading and writing

Everything starts at the root cursor, and a transaction groups writes. See <doc:Transactions>.

- ``rootCursor``
- ``withTransaction(_:)``
- ``freeze()``
- ``committedSize``

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
