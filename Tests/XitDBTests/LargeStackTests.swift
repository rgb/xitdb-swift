import Foundation
import Testing

@testable import XitDB

/// The thread with a large stack that the conformance scripts run on: it
/// runs what it is given and hands back what that throws, and when no
/// thread can be made the call fails. It does not wait for a thread that
/// is not there.
@Suite struct LargeStackTests {
    private struct Thrown: Error {}

    /// A recursion that needs `depth` frames of about a kilobyte each.
    private static func descend(_ depth: Int) -> Int {
        var frame = InlineArray<1024, UInt8>(repeating: UInt8(truncatingIfNeeded: depth))
        frame[depth % 1024] = 1
        return depth == 0 ? Int(frame[0]) : descend(depth - 1) + Int(frame[1023] & 0)
    }

    #if canImport(Darwin)
        /// The size of the stack of the thread that asks. Darwin answers
        /// this; glibc's way of asking, `pthread_getattr_np`, is not among
        /// the calls Swift is shown on Linux.
        private static func stackSizeOfThisThread() -> Int {
            pthread_get_stacksize_np(pthread_self())
        }
    #endif

    /// The body runs on the thread made for it, and a recursion sixteen
    /// thousand calls deep with a kilobyte of locals in each, which in a
    /// debug build is more stack than a thread is given unasked (half a
    /// megabyte on macOS, eight on Linux), returns. Where the system says
    /// how large a thread's stack is, the thread has the size asked for,
    /// 64 MiB unless said otherwise.
    @Test func theBodyRunsOnTheLargeStack() throws {
        final class Seen: @unchecked Sendable {
            var stackSize = -1
            var reached = -1
        }
        let seen = Seen()
        try onLargeStack {
            #if canImport(Darwin)
                seen.stackSize = Self.stackSizeOfThisThread()
            #endif
            seen.reached = Self.descend(16 << 10)
        }
        #expect(seen.reached == 1)
        #if canImport(Darwin)
            #expect(seen.stackSize >= 64 << 20)
            try onLargeStack(stackSize: 4 << 20) { seen.stackSize = Self.stackSizeOfThisThread() }
            #expect(seen.stackSize >= 4 << 20)
            #expect(seen.stackSize < 64 << 20)
        #endif
    }

    /// What the body throws comes out of the call.
    @Test func theBodysErrorComesOut() {
        #expect(throws: Thrown.self) {
            try onLargeStack { throw Thrown() }
        }
    }

    /// When no thread can be made, the call fails and names the call that
    /// refused: here a stack larger than any memory, which `pthread_create`
    /// cannot give, and one too small to be a stack, which the attribute
    /// refuses. Nothing waits for a thread that was never made.
    @Test func noThreadIsAFailureAndNotAWait() {
        let ran = #expect(throws: NoThreadForALargeStack.self) {
            try onLargeStack(stackSize: 1 << 60) {}
        }
        #expect(ran?.call == "pthread_create")
        #expect(ran?.code != 0)
        let refused = #expect(throws: NoThreadForALargeStack.self) {
            try onLargeStack(stackSize: 1) {}
        }
        #expect(refused?.call == "pthread_attr_setstacksize")
    }
}
