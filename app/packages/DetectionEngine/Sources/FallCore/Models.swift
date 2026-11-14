import Foundation

public struct Vector3: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double
    public var magnitude: Double { hypot(x, hypot(y, z)) }
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
    public func scaled(by value: Double) -> Vector3 { Vector3(x: x * value, y: y * value, z: z * value) }
}

public struct Quaternion: Codable, Equatable, Sendable {
    public let w: Double
    public let x: Double
    public let y: Double
    public let z: Double
    public var norm: Double { hypot(hypot(w, x), hypot(y, z)) }
    public var isFinite: Bool { [w, x, y, z].allSatisfy(\.isFinite) }
    public func angularDistanceDegrees(to other: Quaternion) -> Double? {
        let a = norm, b = other.norm
        guard isFinite, other.isFinite, a.isFinite, b.isFinite, a > 1e-8, b > 1e-8 else { return nil }
        let dot = abs((w / a) * (other.w / b) + (x / a) * (other.x / b) + (y / a) * (other.y / b) + (z / a) * (other.z / b))
        return 2 * acos(min(1, max(0, dot))) * 180 / .pi
    }
}

public struct IMUSample: Codable, Equatable, Sendable {
    public let timestampNs: Int64
    public let phoneReceiptNs: Int64?
    public let source: String
    public let accelerometer: Vector3?
    public let gyroscope: Vector3?
    public let magnetometer: Vector3?
    public let orientation: Quaternion?
    public let falling: Int?
    public let fallIntervalID: String?

    enum CodingKeys: String, CodingKey {
        case timestampNs = "timestamp_ns", phoneReceiptNs = "phone_receipt_ns", source
        case accelerometer, gyroscope, magnetometer, orientation, falling
        case fallIntervalID = "fall_interval_id"
    }
}

public struct RecordingMetadata: Codable, Sendable {
    public let sessionID: String
    public let acquisition: String
    public let producer: String
    public let clockDomain: String
    public let samplingRateHz: Int?
    public let units: [String: String]
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", acquisition, producer, units
        case clockDomain = "clock_domain", samplingRateHz = "sampling_rate_hz"
    }
}

public struct ManualAnnotation: Codable, Sendable {
    public let name: String
    public let value: Int
    public let phoneReceiptNs: Int64
    public let reason: String?
    public let fallIntervalID: String?
    enum CodingKeys: String, CodingKey {
        case name, value, reason
        case phoneReceiptNs = "phone_receipt_ns", fallIntervalID = "fall_interval_id"
    }
}

/// Explicit external ground truth. Manual phone-button labels never populate this.
public struct VerifiedFall: Codable, Sendable {
    public let id: String
    public let onsetTimestampNs: Int64
    public let acceptableTriggerEndTimestampNs: Int64
}

public struct GroundTruth: Codable, Sendable {
    public let reliable: Bool
    public let completeCoverage: Bool
    public let verifiedNormalRecording: Bool
    public let events: [VerifiedFall]
}

public struct RecordingPackage: Codable, Sendable {
    public let metadata: RecordingMetadata
    public let samples: [IMUSample]
    public let annotations: [ManualAnnotation]?
    public let groundTruth: GroundTruth?
    enum CodingKeys: String, CodingKey { case metadata, samples, annotations; case groundTruth = "ground_truth" }
}

public struct SensorUnits: Codable, Sendable {
    public static let standardGravity = 9.80665
    public let accelerationScale: Double
    public let gyroscopeScale: Double
    public let accelerationDescription: String
    public let gyroscopeDescription: String

    public init(metadata: RecordingMetadata) throws {
        guard let acc = metadata.units["accelerometer"], let gyro = metadata.units["gyroscope"] else {
            throw RecordingError.invalid("Missing acceleration/gyroscope units in metadata")
        }
        accelerationDescription = acc; gyroscopeDescription = gyro
        switch acc.lowercased() {
        case "m/s^2 (includes gravity)", "m/s^2", "m/s²": accelerationScale = 1
        case "g", "g (includes gravity)": accelerationScale = Self.standardGravity
        default: throw RecordingError.invalid("Unsupported acceleration unit: \(acc)")
        }
        switch gyro.lowercased() {
        case "rad/s", "radians/s": gyroscopeScale = 1
        case "deg/s", "degrees/s", "°/s": gyroscopeScale = .pi / 180
        default: throw RecordingError.invalid("Unsupported gyroscope unit: \(gyro)")
        }
    }
}

public enum RecordingError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public struct DataQuality: Codable, Sendable {
    public let samples: Int
    public let duplicateTimestamps: Int
    public let backwardsInReceiptOrder: Int
    public let gapsOverTwiceMedian: Int
    public let medianIntervalSeconds: Double?
    public let maxIntervalSeconds: Double?
    public let measuredRateHz: Double?
    public let missingAcceleration: Int
    public let missingGyroscope: Int
    public let missingOrientation: Int
    public let unusableQuaternions: Int
}

public struct IMURecording: Sendable {
    public let metadata: RecordingMetadata
    /// Stable native-timestamp order. Original values are unchanged.
    public let samples: [IMUSample]
    public let annotations: [ManualAnnotation]
    public let groundTruth: GroundTruth?
    public let units: SensorUnits
    public let quality: DataQuality
    public let availableSources: [String]
    public var originNs: Int64 { samples.first?.timestampNs ?? 0 }
    public var durationSeconds: Double { Double((samples.last?.timestampNs ?? originNs) - originNs) / 1e9 }
    public var id: String { metadata.sessionID }
    public func elapsedSeconds(at timestampNs: Int64) -> Double { Double(timestampNs - originNs) / 1e9 }
}

public struct RecordingIndex: Codable, Sendable {
    public let recordings: [RecordingEntry]
}

public struct RecordingEntry: Codable, Identifiable, Sendable {
    public let id: String
    public let filename: String
    public let sampleCount: Int
    public let durationSeconds: Double
    public let manualPositiveSamples: Int
    enum CodingKeys: String, CodingKey {
        case id, filename
        case sampleCount = "sample_count", durationSeconds = "duration_seconds", manualPositiveSamples = "manual_positive_samples"
    }
}
