// The collections a handle's place can be read and written as.

extension Handle {
    /// The place as a hash map keyed by `K` with values of type `V`; made
    /// on the first write.
    public func map<K: KeyRepresentable, V: StorableValue>(_: K.Type, _: V.Type) -> Map<K, V> {
        Map(handle: self)
    }

    /// The place as an array list of `V`; made on the first write.
    public func list<V: StorableValue>(_: V.Type) -> List<V> {
        List(handle: self)
    }

    /// The place as a linked array list of `V`; made on the first write.
    public func linkedList<V: StorableValue>(_: V.Type) -> LinkedList<V> {
        LinkedList(handle: self)
    }

    /// The place as a sorted map keyed by `K` with values of type `V`; made
    /// on the first write.
    public func sortedMap<K: KeyRepresentable, V: StorableValue>(_: K.Type, _: V.Type) -> SortedMap<K, V> {
        SortedMap(handle: self)
    }

    /// The place as a sorted set of `K`; made on the first insertion.
    public func sortedSet<K: KeyRepresentable>(_: K.Type) -> SortedSet<K> {
        SortedSet(handle: self)
    }

    /// The place as a hash set of keys of type `K`; made on the first
    /// insertion.
    public func keySet<K: KeyRepresentable>(_: K.Type) -> KeySet<K> {
        KeySet(handle: self)
    }

    /// The place as a counted hash map keyed by `K` with values of type `V`;
    /// made on the first write.
    public func countedMap<K: KeyRepresentable, V: StorableValue>(_: K.Type, _: V.Type) -> CountedMap<K, V> {
        CountedMap(handle: self)
    }

    /// The place as a counted hash set of keys of type `K`; made on the
    /// first insertion.
    public func countedKeySet<K: KeyRepresentable>(_: K.Type) -> CountedKeySet<K> {
        CountedKeySet(handle: self)
    }
}
