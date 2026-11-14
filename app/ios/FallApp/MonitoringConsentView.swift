import SwiftUI

struct MonitoringConsentView: View {
    let controller: GlassesController
    @State private var understood = false
    @State private var notifyOnDisconnect = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Monitor with your glasses").font(.largeTitle.bold())
                    Text("After you connect, monitoring can continue while you use other apps or lock your phone. Keep Bluetooth on and your glasses connected.")
                    Text("If you swipe FallApp away in the app switcher, monitoring may stop. Reopen FallApp and check that your glasses are connected before relying on monitoring again.")
                    Text("Monitoring can also pause when the glasses disconnect or another glasses experience interrupts the session.")
                    Text("Your selected camera setting may activate the glasses camera and capture LED during movement. Confirmed falls capture one second at a target of 7 frames per second and send every captured frame to your configured server. JPEG images are saved for upload and retry; no MP4 video is created.")
                    Text("If you enable spoken check-in, your full transcribed replies go to the server. The app asks before emailing your emergency contact, except that two unanswered questions send an email automatically. Email includes your reported symptoms and timestamped phone location when permitted and available. Phone calls are a separate choice and still require iPhone confirmation.")
                    Toggle("Notify me if monitoring disconnects", isOn: $notifyOnDisconnect)
                    Text("Optional silent alerts. iPhone will ask for notification permission. A force-quit may prevent the app from detecting the interruption or sending an alert.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("I understand and agree to start monitoring", isOn: $understood)
                    Button("Agree and connect") {
                        controller.acceptMonitoringConsent(notifications: notifyOnDisconnect)
                    }.buttonStyle(.borderedProminent).disabled(!understood).frame(maxWidth: .infinity)
                    Button(controller.preferences.agreed ? "Close" : "Not now") { controller.dismissMonitoringConsent() }.frame(maxWidth: .infinity)
                }.padding(24)
            }.toolbar { ToolbarItem(placement: .principal) { Text("Background monitoring") } }
        }.interactiveDismissDisabled(!controller.preferences.agreed)
            .onAppear { notifyOnDisconnect = controller.disconnectionAlerts.enabled }
    }
}
