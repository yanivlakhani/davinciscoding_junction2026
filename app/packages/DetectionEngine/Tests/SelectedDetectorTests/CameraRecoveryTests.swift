import XCTest
import Foundation
import FallCore
import FallCaptureCore
import MonitoringRuntime

final class CameraRecoveryTests: XCTestCase {
    func testStopCommandAloneDoesNotConfirmCameraStopped() async throws {
        let stopped = try await CameraStopConfirmation.wait(timeout: .milliseconds(40)) { false }
        XCTAssertFalse(stopped, "Timeout must remain an unconfirmed stop, not an off indicator")
    }

    func testShutdownWaitsForDeviceAcknowledgement() async throws {
        let acknowledgeAt = ContinuousClock.now + .milliseconds(40)
        let stopped = try await CameraStopConfirmation.wait(timeout: .seconds(1)) {
            ContinuousClock.now >= acknowledgeAt
        }
        XCTAssertTrue(stopped)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now, acknowledgeAt)
    }

    private func sample(_ ns: Int64, acceleration: Double = 9.81, gyro: Double = 0, source: String = "GLASSES") throws -> IMUSample {
        let data = try JSONSerialization.data(withJSONObject: ["timestamp_ns": ns, "source": source,
            "accelerometer": ["x": acceleration, "y": 0, "z": 0], "gyroscope": ["x": gyro, "y": 0, "z": 0]])
        return try JSONDecoder().decode(IMUSample.self, from: data)
    }

    func testEarlyCueDebouncesModerateMotionWithoutChangingFallDecision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cue = expectation(description: "Camera cue before reorder release")
        let session = try MonitoringSession(root: root, cameraEnabled: true, onCameraWarmup: { _ in cue.fulfill() })
        for (index, acc) in [15.5, 16].enumerated() {
            let row = try sample(1_000_000_000 + Int64(index) * 33_333_333, acceleration: acc)
            try await session.receive(JSONEncoder().encode(row), receiptUptimeNs: 1_000_000_000 + UInt64(index) * 33_333_333)
        }
        await fulfillment(of: [cue], timeout: 1)
        let status = try await session.refresh(now: 1_033_333_333)
        XCTAssertEqual(status.processed, 0)
        XCTAssertEqual(status.fallCount, 0)
        try await session.stop()
        let outbox = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("outbox").path)
        XCTAssertTrue(outbox.isEmpty)
    }

    func testQuietMotionSingleSpikeDuplicateAndLongGapDoNotWarmCamera() throws {
        var gate = EarlyCameraGate()
        XCTAssertFalse(gate.consume(try sample(1_000_000_000)))
        XCTAssertFalse(gate.consume(try sample(1_033_333_333, acceleration: 18)))
        XCTAssertFalse(gate.consume(try sample(1_033_333_333, acceleration: 18)))
        XCTAssertFalse(gate.consume(try sample(1_066_666_666)))
        XCTAssertFalse(gate.consume(try sample(1_100_000_000, gyro: 4)))
        XCTAssertFalse(gate.consume(try sample(2_000_000_000, gyro: 4)))
        XCTAssertTrue(gate.consume(try sample(2_033_333_333, gyro: 4)))
        XCTAssertFalse(gate.consume(try sample(2_066_666_666, gyro: 4)))
        XCTAssertFalse(gate.consume(try sample(3_000_000_000, gyro: 4, source: "NEURAL_BAND")))
    }

    func testEarlyCueHonorsUnitScalesAndLowGravity() throws {
        var gate = EarlyCameraGate(accelerationScale: 9.80665, gyroscopeScale: .pi / 180)
        XCTAssertFalse(gate.consume(try sample(1_000_000_000, acceleration: 1, gyro: 180)))
        XCTAssertTrue(gate.consume(try sample(1_033_333_333, acceleration: 1, gyro: 180)))
        var lowGravity = EarlyCameraGate()
        XCTAssertFalse(lowGravity.consume(try sample(1_000_000_000, acceleration: 2)))
        XCTAssertTrue(lowGravity.consume(try sample(1_033_333_333, acceleration: 2)))
    }

    func testFailedRetainedCameraIsRecreatedAndPausedCameraIsNotRestarted() {
        XCTAssertEqual(CameraReuseDecision.evaluate(hasCamera: true, cameraState: "started", streamState: "streaming", hasError: false), .reuse)
        XCTAssertEqual(CameraReuseDecision.evaluate(hasCamera: true, cameraState: "started", streamState: "streaming", hasError: true), .recreate)
        XCTAssertEqual(CameraReuseDecision.evaluate(hasCamera: true, cameraState: "stopped", streamState: "stopped", hasError: false), .recreate)
        XCTAssertEqual(CameraReuseDecision.evaluate(hasCamera: true, cameraState: "started", streamState: "paused", hasError: false), .waitForResume)
        XCTAssertEqual(CameraReuseDecision.evaluate(hasCamera: true, cameraState: "starting", streamState: "stopped", hasError: false, startPending: true), .reuse)
    }

    func testRetryIsBoundedAndDoesNotJoinPartialClipsAcrossRestarts() {
        let transient = CameraStreamFailure(code: "videoStreamingError", message: "Critical error", retryable: true)
        XCTAssertTrue(transient.allowsRetry(attempt: 1, hasFrames: false))
        XCTAssertFalse(transient.allowsRetry(attempt: 2, hasFrames: false))
        XCTAssertFalse(transient.allowsRetry(attempt: 1, hasFrames: true))
        XCTAssertFalse(CameraStreamFailure(code: "permissionDenied", message: "Denied", retryable: false).allowsRetry(attempt: 1, hasFrames: false))
    }
}
