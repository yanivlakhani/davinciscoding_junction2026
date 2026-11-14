import Foundation
import Observation
import UserNotifications
import MonitoringRuntime

@MainActor @Observable
final class DisconnectionAlerts: NSObject, UNUserNotificationCenterDelegate {
    private(set) var enabled = UserDefaults.standard.bool(forKey: "disconnectionAlertsEnabled")
    private(set) var message = "Optional · off"
    private(set) var permissionDenied = false
    private let center = UNUserNotificationCenter.current()
    private var gate = ConnectionAlertGate()
    private var pendingID: String?

    override init() {
        super.init()
        center.delegate = self
        if enabled { message = "Checking notification permission" }
    }

    func setEnabled(_ value: Bool) async {
        enabled = value
        UserDefaults.standard.set(value, forKey: "disconnectionAlertsEnabled")
        if !value { cancelPending(); message = "Optional · off"; return }
        do { _ = try await center.requestAuthorization(options: [.alert]) }
        catch { message = "Notification permission could not be requested" }
        await refreshPermission()
    }

    func refreshPermission() async {
        let settings = await center.notificationSettings()
        permissionDenied = settings.authorizationStatus == .denied
        guard enabled else { message = "Optional · off"; return }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: message = "On · silent disconnection alerts"
        case .denied: message = "Blocked in iPhone Settings"
        default: message = "Notification permission not granted"
        }
    }

    func connected() { gate.connected(); cancelPending() }
    func stoppedByUser() { gate.stoppedByUser(); cancelPending() }

    func interrupted(_ reason: String) {
        guard gate.interruption(), enabled else { return }
        let id = "monitoring-interrupted-" + UUID().uuidString
        pendingID = id
        Task { [weak self] in
            guard let self else { return }
            let settings = await self.center.notificationSettings()
            guard self.enabled, self.pendingID == id,
                  [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
            let content = UNMutableNotificationContent()
            content.title = "Fall monitoring interrupted"
            content.body = reason + " Open FallApp to check or reconnect your glasses."
            content.sound = nil
            let request = UNNotificationRequest(identifier: id, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false))
            do {
                try await self.center.add(request)
                if !self.enabled || self.pendingID != id {
                    self.center.removePendingNotificationRequests(withIdentifiers: [id])
                    self.center.removeDeliveredNotifications(withIdentifiers: [id])
                }
            } catch { self.message = "Could not schedule disconnection alert" }
        }
    }

    private func cancelPending() {
        if let pendingID { center.removePendingNotificationRequests(withIdentifiers: [pendingID]) }
        pendingID = nil
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
