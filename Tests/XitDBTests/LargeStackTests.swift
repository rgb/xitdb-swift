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

    /// The size of the stack of the thread that asks.
    private static func stackSizeOfThisThread() -> Int {
        #if canImport(Darwin)
            return pthread_get_stacksize_np(pthread_self())
        #else
            var attributes = pthread_attr_t()
            guard pthread_getattr_np(pthread_self(), &attributes) == 0 else { return -1 }
            defer { _ = pthread_attr_destroy(&attributes) }
            var size = 0
            guard pthread_attr_getstacksize(&attributes, &size) == 0 else { return -1 }
            return size
        #endif
    }

    /// The body runs on a thread whose stack is of the size asked for, 64
    /// MiB unless said otherwise, and a recursion of sixteen thousand
    /// frames of a kilobyte and more, which a thread's stack of half a
    /// megabyte (macOS) or eight (Linux) does not hold, returns.
    @Test func theBodyRunsOnTheLargeStack() throws {
        final class Seen: @unchecked Sendable {
            var stackSize = -1
            var reached = -1
        }
        let seen = Seen()
        try onLargeStack {
            seen.stackSize = Self.stackSizeOfThisThread()
            seen.reached = Self.descend(16 << 10)
        }
        #expect(seen.stackSize >= 64 << 20)
        #expect(seen.reached == 1)

        try onLargeStack(stackSize: 4 << 20) { seen.stackSize = Self.stackSizeOfThisThread() }
        #expect(seen.stackSize >= 4 << 20)
        #expect(seen.stackSize < 64 << 20)
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
