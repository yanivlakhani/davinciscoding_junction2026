import SwiftUI
import MWDATCore

@main
struct FallApp: App {
    @State private var controller: GlassesController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        var message: String?
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
