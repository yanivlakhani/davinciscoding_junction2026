import Foundation
import XCTest
import MonitoringRuntime

final class MonitoringSessionTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func packet(_ timestamp: Int64, receipt: UInt64) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["source": "GLASSES", "timestamp_ns": timestamp,
            "phone_receipt_ns": receipt, "accelerometer": ["x": 0, "y": 9.80665, "z": 0],
            "gyroscope": ["x": 0, "y": 0, "z": 0], "orientation": ["w": 1, "x": 0, "y": 0, "z": 0]])
    }

    func testLatePacketsRecoveredWithoutChangingRawLog() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try MonitoringSession(root: root)
        let times: [Int64] = [1_000_000_000, 1_066_000_000, 1_033_000_000]
        for (index, stamp) in times.enumerated() {
            let receipt = UInt64(1_000_000_000 + index * 10_000_000)
            try await session.receive(packet(stamp, receipt: receipt), receiptUptimeNs: receipt)
        }
        let status = try await session.refresh(now: 1_200_000_000)
        XCTAssertEqual(status.processed, 3); XCTAssertEqual(status.latePackets, 0)
        try await session.stop()
        func stamps(_ name: String) throws -> [Int64] {
            try String(contentsOf: session.directory.appendingPathComponent(name), encoding: .utf8).split(separator: "\n").map {
                let value = try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
                return (value["timestamp_ns"] as! NSNumber).int64Value
            }
        }
        XCTAssertEqual(try stamps("motion.jsonl"), times)
        XCTAssertEqual(try stamps("ordered-motion.jsonl"), times.sorted())
    }

    func testPacketBeyondRecoveryIsCountedAndLogged() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try MonitoringSession(root: root)
        for (timestamp, receipt) in [(Int64(1_000_000_000), UInt64(1_000_000_000)),
                                      (1_200_000_000, 1_100_000_000), (900_000_000, 1_200_000_000)] {
            try await session.receive(packet(timestamp, receipt: receipt), receiptUptimeNs: receipt)
        }
        let status = try await session.refresh(now: 1_500_000_000)
        XCTAssertEqual(status.received, 3); XCTAssertEqual(status.processed, 2); XCTAssertEqual(status.latePackets, 1)
        try await session.stop()
        let events = try String(contentsOf: session.directory.appendingPathComponent("events.jsonl"), encoding: .utf8)
        XCTAssertTrue(events.contains("unrecovered_timestamp"))
    }

    func testFallQueuesDurableEventWithoutRemoteConfiguration() async throws {
        guard let path = ProcessInfo.processInfo.environment["FALL_BASELINE_WORKSPACE"] else {
            throw XCTSkip("Private baseline workspace not supplied")
        }
        let source = URL(fileURLWithPath: path).appendingPathComponent("FallReplay/App/Resources/Recordings/45a239871df34489895cb9c03529720d.json")
        let recording = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as! [String: Any]
        let samples = (recording["samples"] as! [[String: Any]]).filter { $0["source"] as? String == "GLASSES" }.sorted {
            ($0["timestamp_ns"] as! NSNumber).int64Value < ($1["timestamp_ns"] as! NSNumber).int64Value
        }
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let queued = expectation(description: "Fall dispatch happens immediately after durable queue write")
        let yellow = expectation(description: "Yellow warning is dispatched directly from detector events")
        let session = try MonitoringSession(root: root, onStateChanged: { change in
            if change.state == "SUSPICIOUS_MOVEMENT" { yellow.fulfill() }
        }, onFallQueued: { _ in queued.fulfill() })
        try await session.setBackgrounded(true)
        for (index, row) in samples.enumerated() {
            let receipt = UInt64(1_000_000_000 + index * 33_333_333)
            try await session.receive(JSONSerialization.data(withJSONObject: row), receiptUptimeNs: receipt)
        }
        try await session.stop()
        await fulfillment(of: [yellow, queued], timeout: 1, enforceOrder: true)
        let status = try await session.refresh()
        XCTAssertEqual(status.backgroundSamples, samples.count)
        XCTAssertEqual(status.fallCount, 1)
        let outbox = root.appendingPathComponent("outbox")
        let files = try FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let notice = try JSONDecoder().decode(FallNotice.self, from: Data(contentsOf: XCTUnwrap(files.first)))
        XCTAssertEqual(notice.modelId, "deterministic-baseline-v1")
        XCTAssertEqual(notice.sourceTimestampNs, "7338366003400")
        XCTAssertEqual(notice.sessionId, session.id)
        // A new process/session must not erase already-persisted notifications.
        let next = try MonitoringSession(root: root)
        try await next.stop()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outbox.path).count, 1)
    }

    func testStoppedSessionRejectsNewInputAndStopIsIdempotent() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try MonitoringSession(root: root)
        try await session.stop(); try await session.stop()
        do {
            try await session.receive(packet(1, receipt: 1), receiptUptimeNs: 1)
            XCTFail("Input accepted after session close")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already closed"))
        }
    }

    func testInputFailurePersistsAsFailureInsteadOfSuccessfulSession() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try MonitoringSession(root: root)
        await session.inputFailed("Motion queue full")
        try await session.stop()
        let end = try JSONSerialization.jsonObject(with: Data(contentsOf: session.directory.appendingPathComponent("session-end.json"))) as! [String: Any]
        XCTAssertEqual(end["status"] as? String, "failed")
        XCTAssertEqual(end["error"] as? String, "Motion queue full")
        let events = try String(contentsOf: session.directory.appendingPathComponent("events.jsonl"), encoding: .utf8)
        XCTAssertTrue(events.contains("input_failure"))
    }
}
