import Foundation
import Observation

@MainActor @Observable
final class MonitoringPreferences {
    static let consentVersion = 1
    private(set) var agreed: Bool
    private(set) var monitoringRequested: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let accepted = defaults.integer(forKey: "monitoringConsentVersion") == Self.consentVersion
        agreed = accepted
        monitoringRequested = accepted && defaults.bool(forKey: "monitoringRequested")
    }

    func accept() {
        defaults.set(Self.consentVersion, forKey: "monitoringConsentVersion")
        defaults.set(Date().timeIntervalSince1970, forKey: "monitoringConsentAcceptedAt")
        agreed = true
    }

    func requestMonitoring(_ value: Bool) {
        monitoringRequested = agreed && value
        defaults.set(monitoringRequested, forKey: "monitoringRequested")
    }
}
