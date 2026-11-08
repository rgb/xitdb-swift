import Foundation
import Testing

@testable import XitDB

/// One call of the loop that caps each `pread` and `pwrite`: the bytes
/// moved before it, the bytes it was asked for, and its offset in the file.
private struct Call: Equatable {
    var done: Int
    var wanted: Int
    var offset: off_t

    init(_ done: Int, _ wanted: Int, _ offset: off_t) {
        self.done = done
        self.wanted = wanted
        self.offset = offset
    }
}

/// Every `pread` and `pwrite` is asked for at most 1 GiB: a call for more
/// than `INT_MAX` bytes is `EINVAL` on Apple platforms. The loop is tested
/// with a recording call in place of the system's, and then the real
/// functions with a cap of three bytes on a real file.
@Suite struct CappedCallTests {
    @Test func theCapIsOneGibibyte() {
        #expect(Platform.maximumCallSize == 1 << 30)
        #expect(Platform.maximumCallSize <= Int(Int32.max))
    }

    @Test func aReadIsMadeInCallsOfAtMostTheCap() throws {
        var calls: [Call] = []
        let total = try Platform.transfer(.read, count: 10, at: 100, callLimit: 3) { done, wanted, offset in
            calls.append(Call(done, wanted, offset))
            return wanted
        }
        #expect(total == 10)
        #expect(calls == [Call(0, 3, 100), Call(3, 3, 103), Call(6, 3, 106), Call(9, 1, 109)])

        // a count within the cap is one call, and nothing is no call
        calls = []
        #expect(
            try Platform.transfer(.read, count: 3, at: 0, callLimit: 3) {
                calls.append(Call($0, $1, $2))
                return $1
            } == 3)
        #expect(calls == [Call(0, 3, 0)])
        #expect(
            try Platform.transfer(.read, count: 0, at: 0, callLimit: 3) { _, _, _ in
                Issue.record("called")
                return 0
            } == 0)
    }

    /// A call that moves exactly the cap is not a short read, so the loop
    /// goes on; a call that moves less is the end of the file, so it stops
    /// without asking again.
    @Test func aReadStopsAtAShortCallAndNotAtAFullOne() throws {
        var calls: [Call] = []
        // the file holds 6 bytes from the offset on
        let total = try Platform.transfer(.read, count: 10, at: 0, callLimit: 4) { done, wanted, offset in
            calls.append(Call(done, wanted, offset))
            return min(wanted, 6 - done)
        }
        #expect(total == 6)
        #expect(calls == [Call(0, 4, 0), Call(4, 4, 4)])

        // the file ends exactly at a cap boundary: the loop learns that
        // from a call that moves nothing
        calls = []
        let exact = try Platform.transfer(.read, count: 10, at: 0, callLimit: 4) { done, wanted, offset in
            calls.append(Call(done, wanted, offset))
            return min(wanted, 8 - done)
        }
        #expect(exact == 8)
        #expect(calls == [Call(0, 4, 0), Call(4, 4, 4), Call(8, 2, 8)])
    }

    @Test func aWriteIsMadeInCallsOfAtMostTheCapAndGoesOnAfterAPartialOne() throws {
        var calls: [Call] = []
        let total = try Platform.transfer(.write, count: 10, at: 50, callLimit: 3) { done, wanted, offset in
            calls.append(Call(done, wanted, offset))
            // the first call writes less than it was asked for
            return done == 0 ? 2 : wanted
        }
        #expect(total == 10)
        #expect(calls == [Call(0, 3, 50), Call(2, 3, 52), Call(5, 3, 55), Call(8, 2, 58)])
    }

    @Test func aCallThatFailsIsReportedAndAnInterruptedOneIsMadeAgain() throws {
        var calls: [Call] = []
        for direction in [Platform.TransferDirection.read, .write] {
            calls = []
            #expect(throws: XitDBError.storageFailure(errno: EIO)) {
                try Platform.transfer(direction, count: 10, at: 0, callLimit: 4) { done, wanted, offset in
                    calls.append(Call(done, wanted, offset))
                    if done == 4 {
                        errno = EIO
                        return -1
                    }
                    return wanted
                }
            }
            #expect(calls == [Call(0, 4, 0), Call(4, 4, 4)])

            calls = []
            let total = try Platform.transfer(direction, count: 10, at: 0, callLimit: 4) { done, wanted, offset in
                calls.append(Call(done, wanted, offset))
                if calls.count == 2 {
                    errno = EINTR
                    return -1
                }
                return wanted
            }
            #expect(total == 10)
            #expect(calls == [Call(0, 4, 0), Call(4, 4, 4), Call(4, 4, 4), Call(8, 2, 8)])
        }
    }

    /// A write that makes no progress would loop forever: it is `EIO`. A
    /// read that makes none has reached the end.
    @Test func aCallThatMovesNothingEndsAReadAndFailsAWrite() throws {
        var calls = 0
        #expect(
            try Platform.transfer(.read, count: 10, at: 0, callLimit: 4) { _, _, _ in
                calls += 1
                return 0
            } == 0)
        #expect(calls == 1)
        calls = 0
        #expect(throws: XitDBError.storageFailure(errno: EIO)) {
            try Platform.transfer(.write, count: 10, at: 0, callLimit: 4) { _, _, _ in
                calls += 1
                return 0
            }
        }
        #expect(calls == 1)
    }

    /// Past the largest offset the system has, a read has nothing to read
    /// and a write nowhere to write; neither makes a call there. A transfer
    /// that starts below it and reaches it stops or fails at the boundary,
    /// and a read is never asked to reach past it: Linux refuses such a call
    /// with `EINVAL` where Apple platforms read nothing, so the call is cut
    /// to end at the largest offset, and the byte there, which would end
    /// past it, is not asked for.
    @Test func anOffsetTheSystemCannotExpressMakesNoCall() throws {
        let edge = UInt64(off_t.max)
        for offset in [UInt64.max, edge + 1] {
            #expect(
                try Platform.transfer(.read, count: 4, at: offset, callLimit: 4) { _, _, _ in
                    Issue.record("called")
                    return 0
                } == 0)
            #expect(throws: XitDBError.storageFailure(errno: EFBIG)) {
                try Platform.transfer(.write, count: 4, at: offset, callLimit: 4) { _, _, _ in
                    Issue.record("called")
                    return 0
                }
            }
        }

        var calls: [Call] = []
        #expect(
            try Platform.transfer(.read, count: 4, at: edge - 1, callLimit: 1) {
                calls.append(Call($0, $1, $2))
                return $1
            } == 1)
        #expect(calls == [Call(0, 1, off_t.max - 1)])
        calls = []
        #expect(
            try Platform.transfer(.read, count: 4, at: edge - 3, callLimit: 4) {
                calls.append(Call($0, $1, $2))
                return $1
            } == 3)
        #expect(calls == [Call(0, 3, off_t.max - 3)])
        calls = []
        #expect(throws: XitDBError.storageFailure(errno: EFBIG)) {
            try Platform.transfer(.write, count: 4, at: edge - 1, callLimit: 1) {
                calls.append(Call($0, $1, $2))
                return $1
            }
        }
        #expect(calls == [Call(0, 1, off_t.max - 1), Call(1, 1, off_t.max)])
    }

    /// The real `pread` and `pwrite` loops, through the file storage's
    /// replaceable calls with a cap of three bytes. A loop that took a call
    /// for the whole cap as a short read would move three bytes of fifty.
    @Test func theRealCallsMoveEverythingThroughASmallCap() throws {
        let directory = try TemporaryDirectory()
        let storage = try FileStorage(path: directory.path(), access: .create, durability: .none)
        storage.calls.read = {
            (descriptor: Int32, buffer: inout MutableSpan<UInt8>, range: Range<Int>, offset: UInt64)
                throws(XitDBError) -> Int in
            try Platform.readFile(descriptor, into: &buffer, range: range, at: offset, callLimit: 3)
        }
        storage.calls.write = { (descriptor: Int32, bytes: Span<UInt8>, offset: UInt64) throws(XitDBError) in
            try Platform.writeFile(descriptor, bytes, at: offset, callLimit: 3)
        }

        let bytes = (0..<50).map { UInt8($0) }
        try writeBytes(storage, bytes, at: 0)
        #expect(try directory.contents() == bytes)
        try writeBytes(storage, [100, 101, 102, 103], at: 10)
        #expect(try directory.contents() == Array(bytes[..<10]) + [100, 101, 102, 103] + Array(bytes[14...]))
        try writeBytes(storage, bytes, at: 0)

        // whole, past the end after many full calls, ending inside a call
        #expect(try readBytes(storage, at: 0, count: 50) == bytes)
        #expect(try readBytes(storage, at: 0, count: 100) == bytes)
        #expect(try readBytes(storage, at: 45, count: 10) == Array(bytes[45...]))
        #expect(try readBytes(storage, at: 48, count: 3) == [48, 49])
        #expect(try readBytes(storage, at: 50, count: 3) == [])
        #expect(try readBytes(storage, at: 7, count: 2) == [7, 8])

        // a ranged read lands in its range, in several calls
        var buffer = [UInt8](repeating: 0xEE, count: 20)
        var span = buffer.mutableSpan
        #expect(try storage.read(into: &span, range: 5..<12, at: 10) == 7)
        #expect(
            buffer == [UInt8](repeating: 0xEE, count: 5) + [10, 11, 12, 13, 14, 15, 16]
                + [UInt8](repeating: 0xEE, count: 8))
    }
}
