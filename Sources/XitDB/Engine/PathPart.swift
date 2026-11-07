/// Which slot of a hash map entry a path is after.
package enum HashMapSlotKind: Sendable {
    /// The slot in the map's trie that points at the entry.
    case kvPair
    /// The entry's key slot.
    case key
    /// The entry's value slot.
    case value
}

/// One step of a path through a database, Zig's `PathPart`.
///
/// A path starts at a cursor's slot. Each part takes the slot the path has
/// arrived at and moves to another one: into a collection, to one of its
/// elements, or nowhere, when it writes the slot it is at.
///
/// This is the engine's own interface. It does not protect committed data:
/// a path that writes into a collection without first running the
/// collection's init part changes the collection in place, in every moment
/// that shares it. The collection types built on top always run it.
///
/// Every collection's parts are here.
package enum PathPart: Sendable {
    /// Makes the slot an array list, or copies the list's header and root
    /// block into the transaction if it is one already.
    case arrayListInit

    /// Moves to an element of an array list. A negative index counts from
    /// the end.
    case arrayListGet(Int64)

    /// Appends an empty element to an array list and moves to it.
    case arrayListAppend

    /// Cuts an array list down to its first `size` elements. The path stays
    /// at the list.
    case arrayListSlice(size: UInt64)

    /// Makes the slot a hash map of the given kind, or copies the map's root
    /// block into the transaction if it is one already.
    case hashMapInit(counted: Bool = false, set: Bool = false)

    /// Moves to the entry for a hash, creating it in a write path.
    case hashMapGet(HashMapSlotKind, KeyHash)

    /// Removes the entry for a hash. This ends the path: any parts after it
    /// are ignored, as they are in Zig.
    case hashMapRemove(KeyHash)

    /// Makes the slot a linked array list, or copies the list's header into
    /// the transaction if it is one already.
    case linkedArrayListInit

    /// Moves to an element of a linked array list. A negative index counts
    /// from the end.
    case linkedArrayListGet(Int64)

    /// Appends an element to a linked array list and moves to it.
    case linkedArrayListAppend

    /// Keeps `size` elements of a linked array list from `offset` on. The
    /// path stays at the list.
    case linkedArrayListSlice(offset: UInt64, size: UInt64)

    /// Appends every element of another linked array list, given by its
    /// slot, to this one. The path stays at the list.
    ///
    /// The result shares its nodes with both lists, so the transaction's
    /// start is moved to the end of the storage first, as Zig does: later
    /// writes copy what was written before, instead of changing it in place.
    case linkedArrayListConcat(Slot)

    /// Inserts an element before the one at an index and moves to it. A
    /// negative index counts from the end. The index must name an element:
    /// to add at the end, append.
    case linkedArrayListInsert(Int64)

    /// Removes the element at an index. A negative index counts from the
    /// end. The path stays at the list.
    case linkedArrayListRemove(Int64)

    /// Makes the slot a sorted map, or a sorted set, or copies the map's
    /// header into the transaction if it is one already. A map becomes a
    /// set and back by the tag asked for, as with hash maps.
    case sortedMapInit(set: Bool = false)

    /// Moves to the entry for a key: in a read path if it exists, in a write
    /// path making it if not. Only the value can be written through; the
    /// key and the entry come with no position, since moving a key would
    /// leave the entry out of order. In a sorted set, asking for the key
    /// of a new entry stores the key on its own; asking for its value or
    /// the pair makes a pair.
    case sortedMapGet(HashMapSlotKind, SortedKey)

    /// Moves to the entry at an index, in a read path only. A negative
    /// index counts from the end.
    case sortedMapGetIndex(Int64)

    /// Removes the entry for a key. This ends the path, as the hash map's
    /// remove does. The emptied place in the leaf is left in the tree.
    case sortedMapRemove(SortedKey)

    /// Writes a value to the slot.
    case write(WriteableData)

    /// Runs the path's callback with a cursor at the slot. Zig's `ctx`.
    ///
    /// The callback itself is given to the call that takes the path. This
    /// part says where in the path it stands, which must be at the end.
    case ctx

    /// The collection tag that this part gives a slot, if it is an init
    /// part.
    var initTag: Tag? {
        switch self {
        case .arrayListInit:
            .arrayList
        case .linkedArrayListInit:
            .linkedArrayList
        case .sortedMapInit(let set):
            set ? .sortedSet : .sortedMap
        case .hashMapInit(let counted, let set):
            if counted {
                set ? .countedHashSet : .countedHashMap
            } else {
                set ? .hashSet : .hashMap
            }
        default:
            nil
        }
    }

    /// The init part for a collection tag, or `nil` for a tag that is not a
    /// collection's.
    static func initPart(for tag: Tag) -> PathPart? {
        switch tag {
        case .arrayList: .arrayListInit
        case .linkedArrayList: .linkedArrayListInit
        case .hashMap: .hashMapInit(counted: false, set: false)
        case .hashSet: .hashMapInit(counted: false, set: true)
        case .countedHashMap: .hashMapInit(counted: true, set: false)
        case .countedHashSet: .hashMapInit(counted: true, set: true)
        case .sortedMap: .sortedMapInit(set: false)
        case .sortedSet: .sortedMapInit(set: true)
        case .none, .index, .kvPair, .bytes, .shortBytes, .uint, .int, .float, .sortedKvPair: nil
        }
    }
}
