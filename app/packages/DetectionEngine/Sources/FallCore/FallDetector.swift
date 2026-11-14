import Foundation

public struct DetectorConfiguration: Codable, Equatable, Sendable {
    public var impactAcceleration = 22.0
    public var candidateAngularSpeed = 6.0
    public var verificationAngularSpeed = 3.5
    public var orientationChangeDegrees = 35.0
    public var minimumPrehistorySeconds = 0.25
    public var minimumVerificationSeconds = 0.8
    public var verificationTimeoutSeconds = 2.0
    public var postWindowSeconds = 0.6
    public var settlingDelaySeconds = 0.2
    public var inactivityAccelerationStd = 1.5
    public var inactivityGyroscopeRMS = 0.6
    public var requiredSensorCoverage = 0.85
    public var cooldownSeconds = 5.0
    public var featureWindowSeconds = 1.0
    public var maximumGapSeconds = 0.25
    public init() {}

    public func validate() throws {
        let positive = [impactAcceleration, candidateAngularSpeed, verificationAngularSpeed, orientationChangeDegrees,
                        minimumPrehistorySeconds, minimumVerificationSeconds, verificationTimeoutSeconds,
                        postWindowSeconds, settlingDelaySeconds, inactivityAccelerationStd, inactivityGyroscopeRMS,
                        requiredSensorCoverage, featureWindowSeconds, maximumGapSeconds]
        guard positive.allSatisfy({ $0.isFinite && $0 > 0 }), cooldownSeconds.isFinite, cooldownSeconds >= 0,
              requiredSensorCoverage <= 1, minimumVerificationSeconds <= verificationTimeoutSeconds,
              settlingDelaySeconds + postWindowSeconds <= verificationTimeoutSeconds,
              featureWindowSeconds >= postWindowSeconds, orientationChangeDegrees <= 180,
              minimumPrehistorySeconds <= featureWindowSeconds,
              [verificationTimeoutSeconds, cooldownSeconds, featureWindowSeconds].allSatisfy({ $0 < 3600 }) else {
            throw RecordingError.invalid("Invalid thresholds or time windows")
        }
    }
}

public enum DetectionState: String, Codable, Sendable {
    case idle = "IDLE", monitoring = "MONITORING", suspicious = "SUSPICIOUS_MOVEMENT"
    case verifying = "VERIFYING", fallSuspected = "FALL_SUSPECTED", triggered = "TRIGGERED", cooldown = "COOLDOWN"
}

public struct DetectionEvidence: Codable, Sendable {
    public var peakAcceleration: Double?
    public var peakAngularSpeed: Double?
    public var orientationChangeDegrees: Double?
    public var postAccelerationStd: Double?
    public var postGyroscopeRMS: Double?
    public var postCoverageSeconds = 0.0
    public var prehistorySeconds = 0.0
    public var impactPassed = false
    public var rotationPassed = false
    public var postMotionPassed = false
    public var prehistoryPassed = false
    public var reasons: [String] = []
}

public struct DetectionEvent: Codable, Identifiable, Sendable {
    public let id: Int
    public let timestampNs: Int64
    public let state: DetectionState
    public let message: String
}

public struct FallTrigger: Codable, Identifiable, Sendable {
    public let id: Int
    public let recordingID: String
    public let firstSuspiciousTimestampNs: Int64
    public let evidenceAvailableTimestampNs: Int64
    public let emittedTimestampNs: Int64
    public let detectionDelaySeconds: Double
    public let evidence: DetectionEvidence
    /// Context only; never read by the detector's rules.
    public let manualLabelAtEmission: Int?
}

public struct ProcessingUpdate: Sendable {
    public let frame: FeatureFrame
    public let newEvents: [DetectionEvent]
    public let trigger: FallTrigger?
}

public struct FallDetector {
    private struct Candidate {
        let timestampNs: Int64
        let referenceOrientation: Quaternion?
        var evidence: DetectionEvidence
    }
    public let configuration: DetectorConfiguration
    public private(set) var state: DetectionState = .idle
    public private(set) var events: [DetectionEvent] = []
    public private(set) var triggers: [FallTrigger] = []
    public private(set) var currentEvidence: DetectionEvidence?
    public private(set) var candidateCount = 0
    public private(set) var rejectedCandidates = 0
    public private(set) var lastFrame: FeatureFrame?
    public var ignoredTimestampCount: Int { extractor.skippedTimestamps }
    public var gapCount: Int { extractor.gaps }
    private let recordingID: String
    private var extractor: FeatureExtractor
    private var candidate: Candidate?
    private var cooldownStartNs: Int64?

    public init(recordingID: String, units: SensorUnits, configuration: DetectorConfiguration = .init()) throws {
        try configuration.validate()
        self.recordingID = recordingID; self.configuration = configuration
        extractor = FeatureExtractor(units: units, windowSeconds: configuration.featureWindowSeconds,
                                     maxGapSeconds: configuration.maximumGapSeconds)
    }

    public mutating func reset() {
        extractor.reset(); state = .idle; events = []; triggers = []; candidate = nil
        currentEvidence = nil; cooldownStartNs = nil; lastFrame = nil; candidateCount = 0; rejectedCandidates = 0
    }

    private mutating func transition(_ next: DetectionState, at timestamp: Int64, _ message: String) {
        state = next
        events.append(DetectionEvent(id: events.count, timestampNs: timestamp, state: next, message: message))
    }

    private mutating func reject(at timestamp: Int64, reason: String) {
        rejectedCandidates += 1; candidate = nil
        transition(.monitoring, at: timestamp, "Candidate rejected: \(reason)")
    }

    public mutating func consume(_ sample: IMUSample) -> ProcessingUpdate? {
        guard let frame = extractor.consume(sample) else { return nil }
        let eventStart = events.count
        let triggerStart = triggers.count
        lastFrame = frame
        let timestamp = sample.timestampNs
        if state == .idle { transition(.monitoring, at: timestamp, "Monitoring started") }
        if frame.gapBeforeSample, candidate != nil { reject(at: timestamp, reason: "timestamp gap; verification cancelled") }
        if state == .cooldown, let start = cooldownStartNs {
            if Double(timestamp - start) / 1e9 >= configuration.cooldownSeconds {
                cooldownStartNs = nil
                transition(.monitoring, at: timestamp, "Cooldown completed")
            } else { return ProcessingUpdate(frame: frame, newEvents: Array(events[eventStart...]), trigger: nil) }
        }

        if state == .monitoring {
            let impact = frame.accelerationMagnitude.map { $0 >= configuration.impactAcceleration } ?? false
            let rotation = frame.angularSpeed.map { $0 >= configuration.candidateAngularSpeed } ?? false
            if impact || rotation {
                var evidence = DetectionEvidence()
                evidence.peakAcceleration = frame.accelerationMagnitude
                evidence.peakAngularSpeed = frame.window.compactMap(\.angularSpeed).max()
                evidence.prehistorySeconds = frame.historySeconds
                evidence.reasons = [impact ? "acceleration candidate threshold crossed" : "angular-speed candidate threshold crossed"]
                let reference = frame.window.first { Double(timestamp - $0.timestampNs) / 1e9 >= configuration.minimumPrehistorySeconds && $0.orientation != nil }?.orientation
                candidate = Candidate(timestampNs: timestamp, referenceOrientation: reference, evidence: evidence)
                currentEvidence = evidence; candidateCount += 1
                transition(.suspicious, at: timestamp, "Suspicious movement detected; candidate \(candidateCount)")
            }
        } else if var pending = candidate {
            if state == .suspicious { transition(.verifying, at: timestamp, "Temporal verification started") }
            if let value = frame.accelerationMagnitude { pending.evidence.peakAcceleration = max(pending.evidence.peakAcceleration ?? value, value) }
            if let value = frame.angularSpeed { pending.evidence.peakAngularSpeed = max(pending.evidence.peakAngularSpeed ?? value, value) }
            if let reference = pending.referenceOrientation, let value = frame.sample.orientation?.angularDistanceDegrees(to: reference) {
                pending.evidence.orientationChangeDegrees = max(pending.evidence.orientationChangeDegrees ?? value, value)
            }
            let elapsed = Double(timestamp - pending.timestampNs) / 1e9
            let postStart = max(pending.timestampNs + Int64(configuration.settlingDelaySeconds * 1e9), timestamp - Int64(configuration.postWindowSeconds * 1e9))
            let post = frame.window.filter { $0.timestampNs >= postStart }
            let accelerationRows = post.filter { $0.accelerationMagnitude != nil }
            let angularRows = post.filter { $0.angularSpeed != nil }
            pending.evidence.postAccelerationStd = Statistics.standardDeviation(accelerationRows.compactMap(\.accelerationMagnitude))
            pending.evidence.postGyroscopeRMS = Statistics.rms(angularRows.compactMap(\.angularSpeed))
            pending.evidence.postCoverageSeconds = min(Statistics.coverage(accelerationRows.map(\.timestampNs)), Statistics.coverage(angularRows.map(\.timestampNs)))
            pending.evidence.impactPassed = pending.evidence.peakAcceleration.map { $0 >= configuration.impactAcceleration } ?? false
            pending.evidence.rotationPassed = (pending.evidence.peakAngularSpeed.map { $0 >= configuration.verificationAngularSpeed } ?? false)
                || (pending.evidence.orientationChangeDegrees.map { $0 >= configuration.orientationChangeDegrees } ?? false)
            pending.evidence.prehistoryPassed = pending.evidence.prehistorySeconds >= configuration.minimumPrehistorySeconds
            let coverage = pending.evidence.postCoverageSeconds >= configuration.postWindowSeconds * configuration.requiredSensorCoverage
            pending.evidence.postMotionPassed = coverage && accelerationRows.count >= 3 && angularRows.count >= 3
                && (pending.evidence.postAccelerationStd.map { $0 <= configuration.inactivityAccelerationStd } ?? false)
                && (pending.evidence.postGyroscopeRMS.map { $0 <= configuration.inactivityGyroscopeRMS } ?? false)
            currentEvidence = pending.evidence; candidate = pending
            if elapsed <= configuration.verificationTimeoutSeconds, elapsed >= configuration.minimumVerificationSeconds,
               pending.evidence.impactPassed, pending.evidence.rotationPassed,
               pending.evidence.postMotionPassed, pending.evidence.prehistoryPassed {
                transition(.fallSuspected, at: timestamp, "Impact, rotation, prehistory and post-event stability satisfied")
                transition(.triggered, at: timestamp, "POSSIBLE FALL DETECTED")
                triggers.append(FallTrigger(id: triggers.count + 1, recordingID: recordingID,
                    firstSuspiciousTimestampNs: pending.timestampNs, evidenceAvailableTimestampNs: timestamp,
                    emittedTimestampNs: timestamp, detectionDelaySeconds: elapsed,
                    evidence: pending.evidence, manualLabelAtEmission: sample.falling))
                candidate = nil; cooldownStartNs = timestamp
                transition(.cooldown, at: timestamp, "Cooldown started")
            } else if elapsed >= configuration.verificationTimeoutSeconds {
                reject(at: timestamp, reason: "required multi-sensor/post-event evidence not established within timeout")
            }
        }
        return ProcessingUpdate(frame: frame, newEvents: Array(events.dropFirst(eventStart)),
                                trigger: triggers.count > triggerStart ? triggers.last : nil)
    }

    public mutating func finish() {
        if let lastFrame, candidate != nil { reject(at: lastFrame.sample.timestampNs, reason: "recording ended before verification completed") }
    }
}
