import Foundation
import Testing

/// What the gate plants to try itself. Each does nothing in a run of the
/// tests: it acts only when the gate's own variable is in the environment.
@Suite struct GatePlantTests {
    /// A test that does not end, for the gate's time limit to end
    /// (`scripts/check.sh`, "A run of the tests that does not end is
    /// ended"): with the gate's variable set it sleeps for an hour, and the
    /// gate has to end the run, show what the test process was doing, and
    /// leave no test process behind.
    @Test func aTestThatDoesNotEnd() {
        guard ProcessInfo.processInfo.environment["XITDB_GATE_PLANT_A_TEST_WITHOUT_END"] != nil else { return }
        Thread.sleep(forTimeInterval: 3600)
    }
}
