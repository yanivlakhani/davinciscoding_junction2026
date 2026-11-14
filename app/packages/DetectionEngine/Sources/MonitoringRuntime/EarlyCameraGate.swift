import Foundation
import FallCore

public struct CameraWarmupCue: Sendable {
    public let sessionId: String
    public let sourceTimestampNs: String
    public let phoneUptimeNs: UInt64
}

/// Capture readiness only: never changes detector states, thresholds or alerts.
/// Two consecutive strong-motion/low-gravity samples debounce the camera cue.
public struct EarlyCameraGate: Sendable {
    private var previous: Int64?
    private var consecutive = 0
    private var lastCue: Int64?
    private let accelerationScale: Double
    private let gyroscopeScale: Double

    public init(accelerationScale: Double = 1, gyroscopeScale: Double = 1) {
        self.accelerationScale = accelerationScale; self.gyroscopeScale = gyroscopeScale
    }

    public mutating func consume(_ sample: IMUSample) -> Bool {
        guard sample.source == "GLASSES" else { return false }
        if let previous, sample.timestampNs <= previous { return false }
        if let previous, sample.timestampNs - previous > 250_000_000 { consecutive = 0 }
        previous = sample.timestampNs
        let acceleration = sample.accelerometer.flatMap { $0.isFinite ? $0.magnitude * accelerationScale : nil }
        let angular = sample.gyroscope.flatMap { $0.isFinite ? $0.magnitude * gyroscopeScale : nil }
        let strong = acceleration.map { $0.isFinite && ($0 >= 15 || $0 < 3) } ?? false
        let rotation = angular.map { $0.isFinite && $0 >= 3 } ?? false
        consecutive = strong || rotation ? consecutive + 1 : 0
        guard consecutive >= 2 else { return false }
        if let lastCue, sample.timestampNs - lastCue < 2_000_000_000 { return false }
        lastCue = sample.timestampNs
        return true
    }
}
