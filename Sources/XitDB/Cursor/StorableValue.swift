/// A value that writes itself to a slot and reads itself back from one.
///
/// The typed calls take any conformer: ``Cursor/read(_:)`` and
/// ``Cursor/write(_:)-(StorableValue)``, `value(forKey:as:)` and
/// `put(_:forKey:)` on the maps, `value(at:as:)`, `append(_:)` and
/// `put(_:at:)` on the lists. They add no bytes of their own: a value is
/// written as the slot the format has for it, which a program in any
/// language reads back.
///
/// **A typed write is one write.** Inside a transaction it is part of
/// the transaction, as any write is. Through the root cursor or a
/// collection at the root, where every write is a transaction of its own,
/// a typed write is one transaction however much the value writes: a
/// record is committed whole, and one whose writing fails leaves the
/// database as it was.
///
/// | Type | Written as |
/// |---|---|
/// | `UInt64` | an unsigned integer |
/// | `Int64` | a signed integer |
/// | `Double` | a float, bit for bit |
/// | `String` | a byte array, its UTF-8, without a format tag |
/// | `[UInt8]` | a byte array without a format tag |
/// | ``Bytes`` | a byte array with its format tag, if it has one |
///
/// **A number's kind is always spelled**, as in the original. The format
/// keeps unsigned integers, signed integers and floats apart, and a reader
/// asks for one of them, so the writer says which it writes: `UInt64(25)`,
/// `25 as Int64`, or ``WritableData/uint(_:)`` and
/// ``WritableData/int(_:)``. `Int` is not a value: `put(25, forKey: "age")`
/// does not compile, and the compiler's message says what to write. A
/// literal with a fraction is a `Double`, which is the format's float.
///
/// **A read is strict about the kind, as the original's reads are.** A
/// typed read is the cursor's read of that kind: a number is never read
/// from another kind, and bytes are read from bytes or from nothing.
/// Reading a `UInt64` from a signed integer, any number from bytes, or a
/// `String` from a number or a collection throws
/// ``XitDBError/unexpectedTag``. A slot set to nothing is no number, and
/// read as a `String`, a `[UInt8]` or ``Bytes`` it is empty, which is what
/// ``Cursor/readBytes(maxCount:)`` gives for it: to tell an empty string
/// from a value that was set to nothing, look at the slot. A `String` or a
/// `[UInt8]` reads a byte array whatever its format tag; ``Bytes`` gives
/// the tag. A `String` read from bytes that are not valid UTF-8 throws
/// ``XitDBError/invalidUTF8``; `[UInt8]` reads any bytes.
///
/// A type of your own conforms by saying how it is written, and then goes
/// wherever a value goes. A record is usually a map of its fields. The
/// conformance is in an extension, which leaves the struct the initialiser
/// Swift gives it. This one clears its slot first, so that it takes the place of whatever was
/// there, a value of another kind included; without that line it would
/// write into a map that is there already and keep the fields it does not
/// write, and be refused by a slot that holds a number:
///
/// ```swift
/// struct Person {
///     var name: String
///     var age: UInt64
/// }
///
/// extension Person: StorableValue {
///     init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
///         let fields = try HashMap<ReadOnly>(cursor)
///         guard let name = try fields.value(forKey: "name", as: String.self),
///             let age = try fields.value(forKey: "age", as: UInt64.self)
///         else { throw .keyNotFound }
///         self.init(name: name, age: age)
///     }
///
///     func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
///         try cursor.write(.slot(nil))
///         let fields = try HashMap<ReadWrite>(cursor)
///         try fields.put(name, forKey: "name")
///         try fields.put(age, forKey: "age")
///     }
/// }
///
/// try people.append(Person(name: "Alice", age: 25))
/// let first = try people.value(at: 0, as: Person.self)
/// ```
///
/// Neither `Bool` nor `Optional` is a value: the format has no boolean and
/// no convention for one, and the typed reads give `nil` themselves where
/// a key or an index has no entry. A program that wants either writes the
/// conformance with its own convention.
public protocol StorableValue {
    /// Reads the value from the slot a cursor is at.
    ///
    /// - Parameter cursor: A cursor at the slot. The typed calls give
    ///   `nil` themselves where a key or an index has no entry, so the
    ///   slot is one that was written, though it may have been set to
    ///   nothing.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds another
    ///   kind than the type is written as, and for a conformer of your own
    ///   whatever error says the slot does not hold one.
    init(reading cursor: Cursor<ReadOnly>) throws(XitDBError)

    /// Writes the value to the slot a cursor is at, in place of what was
    /// there.
    ///
    /// The slot may hold an earlier value. One write of a number or of
    /// bytes takes its place. A conformer that makes a collection from the
    /// cursor writes into the collection that is there, if one of that
    /// kind is, and is refused where the slot holds another kind, unless
    /// it clears the slot first with `cursor.write(.slot(nil))`.
    ///
    /// The typed calls run this inside a transaction, their own when none
    /// is running, so everything written here is committed or dropped
    /// together. If it fails after it has written, the transaction it
    /// wrote in is poisoned: every later write in it and its commit fail
    /// with ``XitDBError/poisonedTransaction``, since a typed write is one
    /// thing to its caller and half of one must not be committed. If it
    /// fails before it has written anything, nothing of the value is in
    /// the transaction, which goes on, unless the collection it was
    /// written to had already made room for it, as an append always has.
    ///
    /// - Parameter cursor: A cursor at the slot. After the write it need
    ///   not be at what was written: the typed call that asked for the
    ///   write sees to that.
    /// - Throws: What the writes it makes throw.
    func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError)
}

extension UInt64: StorableValue {
    /// The unsigned integer at the cursor.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot does not hold an
    ///   unsigned integer, a signed one included.
    public init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        self = try cursor.readUInt64()
    }

    /// Writes an unsigned integer.
    public func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.uint(self))
    }
}

extension Int64: StorableValue {
    /// The signed integer at the cursor.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot does not hold a
    ///   signed integer, an unsigned one included.
    public init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        self = try cursor.readInt64()
    }

    /// Writes a signed integer.
    public func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.int(self))
    }
}

extension Double: StorableValue {
    /// The float at the cursor, bit for bit.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot does not hold a
    ///   float, an integer included.
    public init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        self = try cursor.readDouble()
    }

    /// Writes a float, bit for bit.
    public func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.double(self))
    }
}

extension String: StorableValue {
    /// The byte array at the cursor as UTF-8, whatever its format tag.
    ///
    /// A slot set to nothing reads as the empty string.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds a number
    ///   or a collection, and ``XitDBError/invalidUTF8`` if its bytes are
    ///   not valid UTF-8. Nothing is repaired: read such bytes as
    ///   `[UInt8]`.
    public init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        guard let string = String(validating: try cursor.readBytes(), as: UTF8.self) else { throw .invalidUTF8 }
        self = string
    }

    /// Writes the string's UTF-8 as a byte array without a format tag.
    public func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.bytes(Array(utf8)))
    }
}

extension [UInt8]: StorableValue {
    /// The byte array at the cursor, whatever its format tag. A slot set
    /// to nothing reads as the empty array.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds a number
    ///   or a collection.
    public init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        self = try cursor.readBytes()
    }

    /// Writes a byte array without a format tag.
    public func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.bytes(self))
    }
}

extension Bytes: StorableValue {
    /// The byte array at the cursor, with its format tag if it has one. A
    /// slot set to nothing reads as empty bytes without a tag.
    ///
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds a number
    ///   or a collection.
    public init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        self = try cursor.readBytesWithFormatTag()
    }

    /// Writes a byte array, with the format tag if there is one.
    public func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        try cursor.write(.bytes(value, formatTag: formatTag))
    }
}

/// `Int` is not a value, and says so when the program is compiled: an
/// integer literal would otherwise be taken for a `Double` and written as
/// a float, since that is the one literal type left among the values.
///
/// The compiler refuses every use, so nothing it accepts reaches the two
/// members. A value cast to `any StorableValue` while the program runs
/// can, and gets an error, not a trap.
@available(*, unavailable, message: "an integer's kind is spelled: UInt64 or Int64, or .uint(25) and .int(25)")
extension Int: StorableValue {
    /// Never reads: `Int` is not a value.
    ///
    /// - Throws: ``XitDBError/unexpectedTag``, always.
    public init(reading cursor: Cursor<ReadOnly>) throws(XitDBError) {
        throw .unexpectedTag
    }

    /// Never writes: `Int` is not a value.
    ///
    /// - Throws: ``XitDBError/unexpectedTag``, always.
    public func write(to cursor: inout Cursor<ReadWrite>) throws(XitDBError) {
        throw .unexpectedTag
    }
}

extension Cursor {
    /// Reads the value at the cursor as a type.
    ///
    /// The type can be given or left to what the result is assigned to:
    /// `try cursor.read(String.self)`, or `let name: String = try
    /// cursor.read()`.
    ///
    /// - Parameter type: The type to read.
    /// - Returns: The value.
    /// - Throws: ``XitDBError/unexpectedTag`` if the slot holds another kind
    ///   than the type is written as, which for a number includes a slot
    ///   set to nothing, while the byte types read that as empty;
    ///   ``XitDBError/invalidUTF8`` for a `String` whose bytes are not valid
    ///   UTF-8; ``XitDBError/staleCursor`` if the cursor is from a
    ///   transaction that did not commit; an error of the storage or of a
    ///   damaged file; and what a conformer of your own throws.
    public func read<Value: StorableValue>(_ type: Value.Type = Value.self) throws(XitDBError) -> Value {
        try Value(reading: Cursor<ReadOnly>(viewing: self))
    }
}

extension Cursor where Access == ReadWrite {
    /// Writes a value at the cursor, in place of what was there.
    ///
    /// The value writes itself: one of the library's as the slot the format
    /// has for it, exactly as ``write(_:)-(WritableData)`` writes it, and
    /// one of your own as it says.
    ///
    /// Through the root cursor, with no transaction running, the whole
    /// value is one transaction: it is committed when the value has
    /// written itself, and if the value fails nothing of it is. Inside a
    /// transaction the value's writes are writes of the transaction, and
    /// the root cursor refuses them as it refuses any write then.
    ///
    /// Afterwards the cursor is at what was written, as after a write of
    /// ``WritableData``, whatever the value did: a record that makes a
    /// collection in the slot can be read back through this cursor.
    ///
    /// - Parameter value: The value.
    /// - Throws: What ``write(_:)-(WritableData)`` throws, and what a
    ///   conformer of your own throws. Through the root cursor the
    ///   transaction is then rolled back. Inside a transaction, a value
    ///   that fails after it has written poisons the transaction, as a
    ///   collection's typed write does: half a value cannot be committed.
    ///   One that fails before it has written anything leaves the
    ///   transaction as it was.
    public mutating func write(_ value: some StorableValue) throws(XitDBError) {
        // One of the library's own values is its data: one slot, written
        // as the write of that data writes it.
        if let data = WritableData(ownValue: value) {
            try write(data)
            return
        }
        if isRoot, engine.transactionStart == nil {
            // One transaction for all the value writes: a path that is the
            // callback alone, which is what a transaction's body is.
            let path: InlineArray<1, PathPart> = [.ctx]
            let written = try writePath(
                path.span,
                typed: { (cursor: inout Cursor<ReadWrite>) throws(XitDBError) in
                    try value.write(to: &cursor)
                })
            slotPointer = written.slotPointer
            return
        }
        // Inside a transaction the value writes through this cursor as it
        // is: after a freeze the transaction's own cursor goes on only
        // through a path that begins with a write or an init, which the
        // value's own writes do and a callback's path would not.
        let engine = self.engine
        let writesBefore = engine.writesIssued
        do throws(XitDBError) {
            try value.write(to: &self)
        } catch {
            // A typed write is one thing to its caller. What the value left
            // when it failed cannot be undone short of the whole
            // transaction, so the transaction can only roll back, as after
            // any operation that fails once it has written.
            if engine.writesIssued != writesBefore {
                engine.poison()
            }
            throw error
        }
        // The value may have written through a copy of the cursor, as a
        // record does when it makes its map, which leaves this cursor
        // remembering the slot as it was before: read it again.
        if !isRoot, let position = slotPointer.position {
            slotPointer.slot = try engine.reader.slot(at: position)
        }
    }
}

extension WritableData {
    /// The data one of the library's own values is written as, or `nil`
    /// for a conformer of the caller's, which writes itself.
    ///
    /// The six types are told by their type alone, so a type of the
    /// caller's that wraps one of them is the caller's: it writes what its
    /// own `write(to:)` says. With the data in hand a typed write takes the
    /// path the write of ``WritableData`` takes, in place of a callback
    /// and a second write, and leaves the same file by construction.
    init?(ownValue value: some StorableValue) {
        let type = type(of: value)
        if type == UInt64.self {
            self = .uint(value as! UInt64)
        } else if type == Int64.self {
            self = .int(value as! Int64)
        } else if type == Double.self {
            self = .double(value as! Double)
        } else if type == String.self {
            self = .bytes(Array((value as! String).utf8))
        } else if type == [UInt8].self {
            self = .bytes(value as! [UInt8])
        } else if type == Bytes.self {
            let bytes = value as! Bytes
            self = .bytes(bytes.value, formatTag: bytes.formatTag)
        } else {
            return nil
        }
    }
}
