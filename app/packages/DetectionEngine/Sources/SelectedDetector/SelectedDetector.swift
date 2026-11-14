import Foundation
import FallCore

/// Explicit product selection. UI, wearables and remote services are adapters.
public enum SelectedDetector {
    public static let modelID = "deterministic-baseline-v1"

    private struct Settings: Decodable {
        let selectedModel: String
        let inferenceLocation: String
        let ruleConfiguration: DetectorConfiguration
    }

    public static func configuration() throws -> DetectorConfiguration {
        guard let url = Bundle.module.url(forResource: "product-configuration", withExtension: "json") else {
            throw RecordingError.invalid("Product model configuration is missing")
        }
        let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
        guard settings.selectedModel == modelID, settings.inferenceLocation == "phone" else {
            throw RecordingError.invalid("Unsupported product model or execution policy")
        }
        try settings.ruleConfiguration.validate()
        return settings.ruleConfiguration
    }

    public static func make(sessionID: String, units: SensorUnits) throws -> FallDetector {
        try FallDetector(recordingID: sessionID, units: units, configuration: configuration())
    }
}
