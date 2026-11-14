import XCTest
import MonitoringRuntime

final class ConnectionAlertGateTests: XCTestCase {
    func testNoAlertBeforeFirstConnectionOrAfterIntentionalStop() {
        var gate = ConnectionAlertGate()
        XCTAssertFalse(gate.interruption())
        gate.connected(); gate.stoppedByUser()
        XCTAssertFalse(gate.interruption())
    }
    func testPausedThenStoppedIsOneOutageAndRecoveryRearms() {
        var gate = ConnectionAlertGate()
        gate.connected()
        XCTAssertTrue(gate.interruption())
        XCTAssertFalse(gate.interruption())
        gate.connected()
        XCTAssertTrue(gate.interruption())
    }
}
