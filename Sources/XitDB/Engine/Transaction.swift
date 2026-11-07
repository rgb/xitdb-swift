// The frame around a write path: the transaction that a write from the root
// starts, and the point where a path's callback runs.
//
// The path parts themselves throw `XitDBError`. A callback may throw anything.
// The functions here are therefore generic over the error that leaves them:
// `XitDBError` when there is no callback, any error when there is one. `lift`
// turns an engine error into that type.

extension Database {
    /// Follows a write path from `start`: Zig's `readSlotPointer` in write
    /// mode.
    ///
    /// A path that starts at the root is a transaction. It works on a copy
    /// of the root slot appended to the storage, and commits when the whole
    /// path, callback included, has finished.
    ///
    /// - Parameters:
    ///   - callback: Run with the slot the path arrives at, if the path ends
    ///     in a `ctx` part. What it leaves in the slot pointer is the path's
    ///     result.
    func writeSlotPointer<Failure: Error>(
        _ path: Span<PathPart>,
        at start: SlotPointer,
        frozenAt: UInt64,
        lift: (XitDBError) -> Failure,
        callback: (inout SlotPointer) throws(Failure) -> Void
    ) throws(Failure) -> SlotPointer {
        if path.count == 0 { return start }
        if start.position == RootHeader.position {
            return try transaction(path, frozenAt: frozenAt, lift: lift, callback: callback)
        }
        return try runPath(path, at: start, frozenAt: frozenAt, lift: lift, callback: callback)
    }

    private func runPath<Failure: Error>(
        _ path: Span<PathPart>,
        at start: SlotPointer,
        frozenAt: UInt64,
        lift: (XitDBError) -> Failure,
        callback: (inout SlotPointer) throws(Failure) -> Void
    ) throws(Failure) -> SlotPointer {
        var pointer: SlotPointer
        let callbackDue: Bool
        do throws(XitDBError) {
            (pointer, callbackDue) = try runParts(path, at: start, frozenAt: frozenAt)
        } catch {
            throw lift(error)
        }
        if callbackDue {
            try callback(&pointer)
        }
        return pointer
    }

    private func transaction<Failure: Error>(
        _ path: Span<PathPart>,
        frozenAt: UInt64,
        lift: (XitDBError) -> Failure,
        callback: (inout SlotPointer) throws(Failure) -> Void
    ) throws(Failure) -> SlotPointer {
        let root: Slot
        let scratchPosition: UInt64
        do throws(XitDBError) {
            root = try reader.rootSlot()

            // Initialising a root that is already initialised is free, so
            // that a collection can be wrapped around a root cursor without
            // a transaction. Like starting one, it discards what an
            // unfinished transaction left.
            if path.count == 1, root.tag != .none, let tag = path[0].initTag, tag == root.tag {
                try truncate()
                return SlotPointer(position: RootHeader.position, slot: root)
            }

            // Discard what an unfinished transaction left, after a crash.
            try truncate()
            scratchPosition = try storage.length
        } catch {
            throw lift(error)
        }

        transactionStart = scratchPosition
        defer { transactionStart = nil }

        // The transaction works on a copy of the root slot.
        var rootPointer = SlotPointer(position: scratchPosition, slot: root)
        do throws(XitDBError) {
            try write(root, at: scratchPosition)

            // Every collection expects its init part to copy its header or
            // root block into the transaction before anything writes to it.
            // The root has no enclosing init part, so one is run here.
            if let initPart = PathPart.initPart(for: root.tag) {
                let single: InlineArray<1, PathPart> = [initPart]
                rootPointer = try runParts(single.span, at: rootPointer, frozenAt: frozenAt).pointer
            }
        } catch {
            throw lift(error)
        }

        var result = try runPath(path, at: rootPointer, frozenAt: frozenAt, lift: lift, callback: callback)

        do throws(XitDBError) {
            // The copy now holds the new root, so commit it.
            let nextRoot = try reader.slot(at: scratchPosition)
            try commitRoot(nextRoot, commitID: nextCommitID())

            // A path that ends at the root, such as an init or a write,
            // gives back a root cursor, which can be used for later
            // transactions.
            if result.position == scratchPosition {
                result = SlotPointer(position: RootHeader.position, slot: nextRoot)
            }
        } catch {
            throw lift(error)
        }
        return result
    }
}
