// The stack a tree descent keeps its path on. A Swift array for it cost
// three heap allocations per insert into a linked array list or a sorted
// map (counted in a release build with malloc_logger, reached through
// dlsym, over ten thousand operations after a warm-up of as many: the
// array and its two growths as the depth passed one, two and four); the
// hash map's insert and every read made none. The first eight frames live
// inline, which is every tree the benchmarks reach (sixteen-way nodes make
// eight levels about four hundred million elements), and deeper trees
// spill to an array as before, so no bound changes and nothing is assumed
// about the depth: the descents keep their checks against BTree.maxHeight.

/// A value a ``FrameStack`` can hold: it gives a placeholder to fill the
/// inline storage with, since an inline array cannot be left uninitialised.
protocol FrameStackElement {
    /// Any value; it is never read.
    static var placeholder: Self { get }
}

/// The frames of one descent, the first eight inline and the rest, which a
/// tree of ordinary size never has, in an array. A random-access collection
/// from the root downwards, so that the ascent is `reversed()`.
struct FrameStack<Element: FrameStackElement>: RandomAccessCollection {
    /// How many frames are kept inline.
    static var inlineCapacity: Int { 8 }

    private var inline: InlineArray<8, Element>
    private var spilled: [Element]
    private(set) var count: Int

    init() {
        inline = InlineArray(repeating: Element.placeholder)
        spilled = []
        count = 0
    }

    var startIndex: Int { 0 }
    var endIndex: Int { count }

    @inline(__always)
    subscript(position: Int) -> Element {
        position < Self.inlineCapacity ? inline[position] : spilled[position - Self.inlineCapacity]
    }

    /// Pushes a frame.
    @inline(__always)
    mutating func append(_ element: Element) {
        if count < Self.inlineCapacity {
            inline[count] = element
        } else {
            spilled.append(element)
        }
        count += 1
    }

    /// Pops the deepest frame, or gives `nil` when the stack is empty.
    mutating func popLast() -> Element? {
        guard count > 0 else { return nil }
        count -= 1
        if count < Self.inlineCapacity {
            return inline[count]
        }
        return spilled.removeLast()
    }
}
