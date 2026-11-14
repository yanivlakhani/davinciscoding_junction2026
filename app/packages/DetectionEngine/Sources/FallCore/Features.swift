import Foundation

public struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    public private(set) var count = 0
    public init(capacity: Int) { precondition(capacity > 0); storage = Array(repeating: nil, count: capacity) }
    public var elements: [Element] { (0..<count).compactMap { storage[(head + $0) % storage.count] } }
    public mutating func append(_ value: Element) {
        if count == storage.count { storage[head] = value; head = (head + 1) % storage.count }
        else { storage[(head + count) % storage.count] = value; count += 1 }
    }
    public mutating func removeFirst(while predicate: (Element) -> Bool) {
        while count > 0, let value = storage[head], predicate(value) {
            storage[head] = nil; head = (head + 1) % storage.count; count -= 1
        }
    }
    public mutating func clear() { storage = Array(repeating: nil, count: storage.count); head = 0; count = 0 }
}

public enum Statistics {
    public static func standardDeviation(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        return sqrt(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count))
    }
    public static func rms(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(values.count))
    }
    public static func coverage(_ timestamps: [Int64]) -> Double {
        guard let first = timestamps.first, let last = timestamps.last else { return 0 }
        return Double(last - first) / 1e9
    }
}

public struct WindowObservation: Sendable {
    public let timestampNs: Int64
    public let accelerationMagnitude: Double?
    public let angularSpeed: Double?
    public let orientation: Quaternion?
}

public struct FeatureFrame: Sendable {
    public let sample: IMUSample
    public let accelerationMagnitude: Double?
    public let angularSpeed: Double?
    public let smoothedAccelerationMagnitude: Double?
    public let magnitudeJerk: Double?
    public let orientationChangeDegrees: Double?
    public let historySeconds: Double
    public let gapBeforeSample: Bool
    public let window: [WindowObservation]
}

public struct FeatureExtractor {
    public private(set) var skippedTimestamps = 0
    public private(set) var gaps = 0
    private let units: SensorUnits
    private let windowSeconds: Double
    private let maxGapSeconds: Double
    private var ring = RingBuffer<WindowObservation>(capacity: 8192)
    private var previousTimestamp: Int64?
    private var previousMagnitude: Double?
    private var ema: Double?

    public init(units: SensorUnits, windowSeconds: Double = 1, maxGapSeconds: Double = 0.25) {
        self.units = units; self.windowSeconds = windowSeconds; self.maxGapSeconds = maxGapSeconds
    }
    public mutating func reset() {
        ring.clear(); previousTimestamp = nil; previousMagnitude = nil; ema = nil; skippedTimestamps = 0; gaps = 0
    }
    public mutating func consume(_ sample: IMUSample) -> FeatureFrame? {
        if let previousTimestamp, sample.timestampNs <= previousTimestamp { skippedTimestamps += 1; return nil }
        let dt = previousTimestamp.map { Double(sample.timestampNs - $0) / 1e9 }
        let gap = dt.map { $0 > maxGapSeconds } ?? false
        if gap { ring.clear(); previousMagnitude = nil; ema = nil; gaps += 1 }
        let acceleration = sample.accelerometer?.scaled(by: units.accelerationScale).magnitude
        let angular = sample.gyroscope?.scaled(by: units.gyroscopeScale).magnitude
        let jerk: Double?
        if let acceleration, let previousMagnitude, let dt, !gap, dt > 0 { jerk = abs(acceleration - previousMagnitude) / dt }
        else { jerk = nil }
        if let acceleration {
            if let previous = ema, let dt {
                let alpha = 1 - exp(-dt / 0.2)
                ema = previous + alpha * (acceleration - previous)
            } else { ema = acceleration }
        }
        let cutoff = sample.timestampNs - Int64(windowSeconds * 1e9)
        ring.removeFirst { $0.timestampNs < cutoff }
        ring.append(WindowObservation(timestampNs: sample.timestampNs, accelerationMagnitude: acceleration,
                                      angularSpeed: angular, orientation: sample.orientation))
        let window = ring.elements
        let reference = window.first { $0.orientation.map { $0.norm > 1e-8 } ?? false }?.orientation
        let angle = reference.flatMap { sample.orientation?.angularDistanceDegrees(to: $0) }
        let coverage = Statistics.coverage(window.filter { $0.accelerationMagnitude != nil }.map(\.timestampNs))
        previousTimestamp = sample.timestampNs; previousMagnitude = acceleration
        return FeatureFrame(sample: sample, accelerationMagnitude: acceleration, angularSpeed: angular,
                            smoothedAccelerationMagnitude: acceleration == nil ? nil : ema, magnitudeJerk: jerk,
                            orientationChangeDegrees: angle, historySeconds: coverage, gapBeforeSample: gap, window: window)
    }
}
