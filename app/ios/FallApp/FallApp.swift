import SwiftUI
import MWDATCore
import ModalTransport

@main
struct FallApp: App {
    @State private var controller: GlassesController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        var message: String?
        #if DEBUG
        // Development-only, explicitly requested queue cleanup. Execute before
        // controller construction so capture/upload tasks cannot race deletion.
        if let token = ProcessInfo.processInfo.environment["FALLAPP_CLEAR_PENDING"],
           UUID(uuidString: token) != nil,
           UserDefaults.standard.string(forKey: "lastQueueCleanupToken") != token {
            UserDefaults.standard.set(false, forKey: "monitoringRequested")
            UserDefaults.standard.removeObject(forKey: "pendingEmergencyCallEvent")
            do {
                let root = URL.documentsDirectory.appendingPathComponent("FallApp", isDirectory: true)
                let cleared = try ModalQueueMaintenance.clearPending(root: root)
                UserDefaults.standard.set(token, forKey: "lastQueueCleanupToken")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try JSONEncoder().encode(cleared).write(to: root.appendingPathComponent("queue-cleanup.json"), options: .atomic)
            } catch { message = "Queue cleanup failed: \(error.localizedDescription)" }
        }
        #endif
        do { try Wearables.configure() }
        catch { message = error.localizedDescription }
        _controller = State(initialValue: GlassesController(startupError: message))
    }

    var body: some Scene {
        WindowGroup {
            ConnectionView(controller: controller)
                .preferredColorScheme(.light)
                .onOpenURL { url in Task { await controller.handleURL(url) } }
                .onChange(of: scenePhase) { _, phase in
                    guard phase != .inactive else { return }
                    Task { await controller.backgroundChanged(phase == .background) }
                }
        }
    }
}
