enum CameraStartPolicy: String, CaseIterable, Identifiable, Sendable {
    case onMovement, onYellow, onRed, continuous, disabled
    var id: String { rawValue }
    var title: String {
        switch self {
        case .onMovement: "Early movement"
        case .onYellow: "Yellow warning"
        case .onRed: "Confirmed fall only"
        case .continuous: "Continuous buffer test"
        case .disabled: "Motion only"
        }
    }
}

enum CameraCodec: String, CaseIterable, Identifiable, Sendable {
    case raw, hevc
    var id: String { rawValue }
    var title: String { self == .raw ? "Decoded frames" : "HEVC · background test" }
}

enum AppConfig {
    // Camera is now explicitly enabled by the user for the Modal image workflow.
    static let automaticFallVideoEnabled = true
    static let soundEnabled = false
    static let vibrationEnabled = false
}
