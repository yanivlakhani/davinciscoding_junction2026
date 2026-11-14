import Foundation
import FallCore
import SelectedDetector

public struct MonitoringStatus: Sendable {
    public var received = 0
    public var processed = 0
    public var latePackets = 0
    public var buffered = 0
    public var backgroundSamples = 0
    public var fallCount = 0
    public var state = "IDLE"
    public var lastReceiptUptimeNs: UInt64?
    public init() {}
}

/// Draft local event format. Final Modal request mapping awaits its API contract.
public struct FallNotice: Codable, Sendable {
    public let schemaVersion: Int
    public let eventId: String
    public let sessionId: String
    public let modelId: String
    public let type: String
    public let detectedAtUTC: String
    public let sourceTimestampNs: String
    public let phoneDecisionUptimeNs: String
    public let evidence: DetectionEvidence
}

public struct DetectorStateChange: Sendable {
    public let sessionId: String
    public let sequence: Int
    public let state: String
    public let sourceTimestampNs: String
    public let phoneUptimeNs: UInt64
}

/// Inference runs on this actor; acquisition and disk writes run independently.
public actor MonitoringSession {
    public nonisolated let id: String
    public nonisolated let directory: URL
    private struct Packet {
        let sample: IMUSample
        let data: Data
        let receipt: UInt64
        let entered: UInt64
        let sequence: Int
    }
    private var detector: FallDetector
    private var cameraGate: EarlyCameraGate
    private var status = MonitoringStatus()
    private var pending: [Packet] = []
    private var highTimestamp: Int64 = 0
    private var lastProcessed: Int64?
    private var backgrounded = false
    private var closed = false
    private var acquisitionFailure: String?
    private let logs: SessionLogs
    private let outbox: URL
    private let onFallQueued: (@Sendable (FallNotice) -> Void)?
    private let onStateChanged: (@Sendable (DetectorStateChange) -> Void)?
    private let onCameraWarmup: (@Sendable (CameraWarmupCue) -> Void)?
    private let cameraEnabled: Bool
    private let encoder = JSONEncoder()

    public init(root: URL, id: String = UUID().uuidString, cameraEnabled: Bool = false,
                runtimeOptions: [String: String] = [:],
                onCameraWarmup: (@Sendable (CameraWarmupCue) -> Void)? = nil,
                onStateChanged: (@Sendable (DetectorStateChange) -> Void)? = nil,
                onFallQueued: (@Sendable (FallNotice) -> Void)? = nil) throws {
        self.id = id
        self.onFallQueued = onFallQueued
        self.onStateChanged = onStateChanged
        self.onCameraWarmup = onCameraWarmup
        self.cameraEnabled = cameraEnabled
        let sessionDirectory = root.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        directory = sessionDirectory
        outbox = root.appendingPathComponent("outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: outbox.path)
        #endif
        let metadata: [String: Any] = ["session_id": id, "acquisition": "hardware", "producer": "fallapp-ios",
            "model_id": SelectedDetector.modelID, "automatic_camera_enabled": cameraEnabled,
            "runtime_options": runtimeOptions,
            "clock_domain": "glasses_monotonic", "sampling_rate_hz": 30,
            "units": ["accelerometer": "m/s^2 (includes gravity)", "gyroscope": "rad/s"]]
        let data = try JSONSerialization.data(withJSONObject: metadata)
        let modelMetadata = try JSONDecoder().decode(RecordingMetadata.self, from: data)
        let units = try SensorUnits(metadata: modelMetadata)
        detector = try SelectedDetector.make(sessionID: id, units: units)
        cameraGate = EarlyCameraGate(accelerationScale: units.accelerationScale, gyroscopeScale: units.gyroscopeScale)
        try data.write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        try JSONEncoder().encode(detector.configuration).write(to: directory.appendingPathComponent("rule-configuration.json"), options: .atomic)
        logs = try SessionLogs(directory: directory)
    }

    public func receive(_ data: Data, receiptUptimeNs: UInt64) throws {
        guard !closed else { throw RecordingError.invalid("Monitoring session already closed") }
        let entered = DispatchTime.now().uptimeNanoseconds
        try logs.check()
        let sample = try JSONDecoder().decode(IMUSample.self, from: data)
        try logs.append(data, to: "motion.jsonl")
        guard sample.source == "GLASSES" else { return }
        if cameraEnabled, cameraGate.consume(sample), let onCameraWarmup {
            let cue = CameraWarmupCue(sessionId: id, sourceTimestampNs: String(sample.timestampNs),
                                      phoneUptimeNs: DispatchTime.now().uptimeNanoseconds)
            onCameraWarmup(cue)
            let row = ["kind": "early_camera_cue", "sourceTimestampNs": cue.sourceTimestampNs,
                       "phoneUptimeNs": String(cue.phoneUptimeNs)]
            try logs.append(JSONSerialization.data(withJSONObject: row), to: "events.jsonl")
        }
        status.received += 1
        status.lastReceiptUptimeNs = receiptUptimeNs
        if backgrounded { status.backgroundSamples += 1 }
        highTimestamp = max(highTimestamp, sample.timestampNs)
        pending.append(Packet(sample: sample, data: data, receipt: receiptUptimeNs, entered: entered, sequence: status.received))
        try release(now: receiptUptimeNs, force: pending.count >= 512)
    }

    public func refresh(now: UInt64 = DispatchTime.now().uptimeNanoseconds) throws -> MonitoringStatus {
        if !closed { try logs.check(); try release(now: now, force: false) }
        return status
    }

    public func inputFailed(_ message: String) {
        acquisitionFailure = message
        status.state = "INPUT_ERROR"
        let row = ["kind": "input_failure", "message": message,
                   "phoneUptimeNs": String(DispatchTime.now().uptimeNanoseconds)]
        if let data = try? JSONSerialization.data(withJSONObject: row) { try? logs.append(data, to: "events.jsonl") }
    }

    public func setBackgrounded(_ value: Bool) throws {
        guard !closed else { return }
        backgrounded = value
        let event: [String: Any] = ["kind": "phone_lifecycle", "backgrounded": value,
                                  "phoneUptimeNs": String(DispatchTime.now().uptimeNanoseconds)]
        try logs.append(JSONSerialization.data(withJSONObject: event), to: "events.jsonl")
    }

    public func stop() async throws {
        guard !closed else { return }
        // Mark closed before suspension so no new input races the final log drain.
        closed = true
        var stopError: Error?
        do {
            if acquisitionFailure == nil { try release(now: DispatchTime.now().uptimeNanoseconds, force: true) }
            let eventCount = detector.events.count
            detector.finish()
            for event in detector.events.dropFirst(eventCount) { try logs.append(encoder.encode(event), to: "events.jsonl") }
        } catch { stopError = error }
        let result: [String: Any] = ["status": "completed", "modelId": SelectedDetector.modelID,
            "received": status.received, "processed": status.processed, "latePackets": status.latePackets,
            "backgroundSamples": status.backgroundSamples, "falls": status.fallCount,
            "cameraEnabled": cameraEnabled, "soundEnabled": false, "vibrationEnabled": false]
        do { try await logs.finish() } catch { stopError = stopError ?? error }
        var final = result
        if let acquisitionFailure { final["status"] = "failed"; final["error"] = acquisitionFailure }
        if let stopError { final["status"] = "failed"; final["error"] = stopError.localizedDescription }
        try JSONSerialization.data(withJSONObject: final).write(to: directory.appendingPathComponent("session-end.json"), options: .atomic)
        if let stopError { throw stopError }
    }

    private func release(now: UInt64, force: Bool) throws {
        pending.sort { $0.sample.timestampNs == $1.sample.timestampNs ? $0.sequence < $1.sequence : $0.sample.timestampNs < $1.sample.timestampNs }
        let expiry = pending.filter { now >= $0.receipt && now - $0.receipt >= 100_000_000 }.map(\.sample.timestampNs).max()
        let watermark = max(highTimestamp - 100_000_000, expiry ?? Int64.min)
        while let packet = pending.first, force || packet.sample.timestampNs <= watermark {
            pending.removeFirst()
            if let previous = lastProcessed, packet.sample.timestampNs <= previous {
                status.latePackets += 1
                let detail: [String: Any] = ["kind": "unrecovered_timestamp", "timestampNs": String(packet.sample.timestampNs)]
                try logs.append(JSONSerialization.data(withJSONObject: detail), to: "events.jsonl")
                continue
            }
            lastProcessed = packet.sample.timestampNs
            try logs.append(packet.data, to: "ordered-motion.jsonl")
            status.processed += 1
            let processingStart = DispatchTime.now().uptimeNanoseconds
            let update = detector.consume(packet.sample)
            let detectorEnd = DispatchTime.now().uptimeNanoseconds
            if let update {
                let decisionTime = detectorEnd
                status.state = detector.state.rawValue
                for event in update.newEvents {
                    onStateChanged?(DetectorStateChange(sessionId: id, sequence: event.id, state: event.state.rawValue,
                        sourceTimestampNs: String(event.timestampNs), phoneUptimeNs: decisionTime))
                    try logs.append(encoder.encode(event), to: "events.jsonl")
                }
                if let trigger = update.trigger {
                    let notice = FallNotice(schemaVersion: 1, eventId: id + "-" + String(trigger.id), sessionId: id,
                        modelId: SelectedDetector.modelID, type: "fall_detected",
                        detectedAtUTC: ISO8601DateFormatter().string(from: Date()),
                        sourceTimestampNs: String(trigger.emittedTimestampNs),
                        phoneDecisionUptimeNs: String(decisionTime), evidence: trigger.evidence)
                    try encoder.encode(notice).write(to: outbox.appendingPathComponent(notice.eventId + ".json"), options: .atomic)
                    status.fallCount += 1
                    onFallQueued?(notice) // Dispatch capture immediately; never await camera/networking in inference.
                }
            }
            let timing: [String: Any] = ["kind": "motion_processing", "sourceTimestampNs": String(packet.sample.timestampNs),
                "phoneReceiptNs": String(packet.receipt), "actorEntryNs": String(packet.entered),
                "processingStartNs": String(processingStart), "detectorEndNs": String(detectorEnd),
                "processingEndNs": String(DispatchTime.now().uptimeNanoseconds)]
            try logs.append(JSONSerialization.data(withJSONObject: timing), to: "latency.jsonl")
        }
        status.buffered = pending.count
    }
}
