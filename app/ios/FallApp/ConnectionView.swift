import SwiftUI
import UIKit

struct ConnectionView: View {
    @Bindable var controller: GlassesController
    @State private var showConnectionLog = true

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image("MetaLogo").renderingMode(.original).resizable().scaledToFit().frame(width: 190, height: 60)
                    .accessibilityLabel("Meta")
                VStack(spacing: 8) {
                    Text("Connect your glasses").font(.title2.bold())
                    Text("Fall monitoring starts automatically when connected.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("\(controller.cameraPolicy.title). Confirmed falls send every frame from a one-second capture, targeting 7 fps. No MP4 is created.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                DisclosureGroup("Capture test settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Camera starts", selection: $controller.cameraPolicy) {
                            ForEach(CameraStartPolicy.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Video format", selection: $controller.cameraCodec) {
                            ForEach(CameraCodec.allCases) { Text($0.title).tag($0) }
                        }
                        if controller.cameraPolicy == .continuous {
                            Text("Camera streams throughout monitoring; capture LED remains active. Only confirmed fall frames are saved and sent.")
                                .font(.footnote).foregroundStyle(.orange)
                        } else {
                            Text("Early movement starts camera before the fall warning. Without a confirmed fall, it stays warm for up to 12 seconds after movement. After a confirmed fall, camera stops once the one-second burst is collected, before saving and sending.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 10).disabled(!controller.canEditCaptureSettings)
                }.font(.subheadline)
                Button {
                    if controller.hasMonitoringSession { controller.disconnect() } else { controller.connect() }
                } label: {
                    HStack {
                        if controller.busy { ProgressView().tint(.white) }
                        Text(controller.hasMonitoringSession ? "Disconnect" : "Connect glasses").fontWeight(.semibold)
                    }.frame(maxWidth: .infinity).padding(.vertical, 9)
                }.buttonStyle(.borderedProminent).tint(.blue).disabled(controller.busy)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Connection: \(controller.connection)").font(.subheadline.bold())
                    Text(controller.diagnostics.snapshot["appAudio"] ?? "Voice audio is inactive")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = controller.error { Text(error).font(.caption).foregroundStyle(.red) }
                    DisclosureGroup("Live connection log", isExpanded: $showConnectionLog) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(controller.diagnostics.entries.suffix(30))) { entry in
                                    Text(entry.line).font(.system(size: 11, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.textSelection(.enabled)
                        }.frame(height: 180)
                        Button("Copy connection diagnostics") { UIPasteboard.general.string = controller.diagnostics.text }
                            .font(.footnote)
                    }
                    if let issue = controller.diagnostics.persistenceError { Text(issue).font(.caption).foregroundStyle(.orange) }
                }.padding(14).background(.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Spoken fall check-in", isOn: Binding(
                        get: { controller.checkIn.enabled },
                        set: { value in Task { await controller.checkIn.setEnabled(value) } }))
                    Text("After a confirmed fall, the glasses ask how you feel, then ask before emailing your emergency contact. Two unanswered questions send an email automatically. A separate question offers a phone call, which requires iPhone confirmation. Microphone audio is not saved.")
                        .font(.footnote).foregroundStyle(.secondary)
                    #if DEBUG
                    Button("Test confirmed fall · start voice check-in") {
                        Task { await controller.testConfirmedFall() }
                    }.buttonStyle(.bordered)
                        .disabled(!controller.connected || !controller.checkIn.enabled || controller.checkIn.busy || controller.capture.busy || controller.startingVoiceTest)
                    Text("Test bypasses camera and Claude vision once. The normal voice/email flow runs; test emails are marked [TEST].")
                        .font(.footnote).foregroundStyle(.secondary)
                    #endif
                    Text("Speech recognition uses Apple’s service if on-device recognition is unavailable. Glasses must be selected as the Bluetooth audio route.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("Check-in language", selection: Binding(get: { controller.checkIn.language }, set: { controller.checkIn.language = $0 })) {
                        Text("English").tag("en"); Text("Italian").tag("it")
                    }.disabled(controller.checkIn.busy)
                    Picker("Time to start replying", selection: Binding(get: { controller.checkIn.listenSeconds }, set: { controller.checkIn.listenSeconds = $0 })) {
                        Text("10 seconds").tag(10.0); Text("15 seconds").tag(15.0); Text("20 seconds").tag(20.0); Text("30 seconds").tag(30.0)
                    }.disabled(controller.checkIn.busy)
                    Text("Each question repeats once after silence. An audio error does not count as no response.")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField("Your name for email alerts", text: Binding(get: { controller.checkIn.personName }, set: { controller.checkIn.personName = $0 }))
                        .textContentType(.name).disabled(controller.checkIn.busy)
                    TextField("Emergency contact phone (+country code)", text: Binding(get: { controller.checkIn.contactPhone }, set: { controller.checkIn.contactPhone = $0 }))
                        .keyboardType(.phonePad).textContentType(.telephoneNumber).disabled(controller.checkIn.busy)
                    Button("Enable / refresh phone location for alerts") { controller.checkIn.location.requestPermissionAndLocation() }
                    Text(controller.checkIn.location.status).font(.footnote).foregroundStyle(.secondary)
                    Text("Alerts use a timestamped phone location when available. The email recipient is configured on the server; this phone number is used only for calls.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("Disconnection notifications", isOn: Binding(
                        get: { controller.disconnectionAlerts.enabled },
                        set: { enabled in Task { await controller.disconnectionAlerts.setEnabled(enabled) } }))
                        .disabled(!controller.preferences.agreed)
                    Text(controller.disconnectionAlerts.message).font(.footnote).foregroundStyle(.secondary)
                    if controller.disconnectionAlerts.permissionDenied {
                        Link("Open iPhone Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    }
                    Button("Review monitoring agreement") { controller.showMonitoringConsent = true }
                        .font(.footnote)
                }
                VStack(spacing: 18) {
                    statusRow("Connection", value: controller.connection, color: controller.connected ? .green : .orange)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let recent = freshData
                        statusRow("Sensor data", value: recent ? "Receiving · \(controller.status.received) samples" : controller.motionState,
                                  color: recent ? .green : .orange)
                    }
                    statusRow("Fall detector", value: detectorDescription, color: detectorColor)
                    statusRow("Fall camera", value: controller.capture.status, color: controller.capture.cameraStopFailed ? .red : (controller.capture.needsPermission ? .orange : (controller.capture.cameraActive ? .blue : .gray)))
                    if controller.capture.needsPermission {
                        Button("Allow fall camera") {
                            Task { await controller.capture.requestPermission() }
                        }.buttonStyle(.bordered)
                    }
                    statusRow("Modal", value: controller.deliveryStatus.message, color: controller.deliveryStatus.authenticated ? .green : .orange)
                    statusRow("Visual result", value: controller.checkIn.modelResult, color: .blue)
                    statusRow("Spoken check-in", value: controller.checkIn.status, color: controller.checkIn.busy ? .blue : .gray)
                    if controller.checkIn.pendingCallEvent != nil {
                        Text("Call requested. Open and unlock iPhone to confirm; call audio can use the glasses over Bluetooth.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Call emergency contact") { Task { await controller.checkIn.callEmergencyContact() } }
                            .buttonStyle(.borderedProminent).disabled(!controller.checkIn.canCall)
                        Button("Dismiss call request") { controller.checkIn.dismissCallRequest() }.font(.footnote)
                    }
                    if controller.status.backgroundSamples > 0 {
                        statusRow("Background data", value: "\(controller.status.backgroundSamples) samples received", color: .green)
                    }
                    if !controller.deliveryStatus.captureQueueMessage.isEmpty {
                        Text("Capture issues: " + controller.deliveryStatus.captureQueueMessage)
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if controller.deliveryStatus.blockedCaptures > 0 {
                        Text("Capture failed: \(controller.deliveryStatus.blockedCaptures) · logs retained locally")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    HStack {
                        Text("Pending upload: \(controller.deliveryStatus.pending)")
                        Spacer()
                        Text("Sent: \(controller.deliveryStatus.delivered)")
                    }.font(.footnote).foregroundStyle(.secondary)
                }.padding(22).background(.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
                if controller.status.latePackets > 0 {
                    Text("Input timing needs attention: \(controller.status.latePackets) late packets.").font(.footnote).foregroundStyle(.orange)
                }
                if let error = controller.error { Text(error).font(.footnote).foregroundStyle(.red) }
                Text("\(controller.cameraPolicy.title) · Vibration off · Voice only after a confirmed fall").font(.footnote).foregroundStyle(.secondary)
            }.padding(28).padding(.top, 32)
        }.background(.white)
            .task { await controller.disconnectionAlerts.refreshPermission() }
            .sheet(isPresented: $controller.showMonitoringConsent) {
                MonitoringConsentView(controller: controller)
            }
    }

    private var freshData: Bool {
        guard controller.connected, controller.monitoringHealthy, let receipt = controller.status.lastReceiptUptimeNs else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= receipt && now - receipt < 1_000_000_000
    }

    private var detectorDescription: String {
        guard freshData else { return "Waiting for sensor data" }
        switch controller.status.state {
        case "TRIGGERED", "COOLDOWN": return "Fall detected · \(controller.status.fallCount) this session"
        case "SUSPICIOUS_MOVEMENT", "VERIFYING", "FALL_SUSPECTED": return "Checking movement"
        default: return "Monitoring"
        }
    }

    private var detectorColor: Color {
        guard freshData else { return .gray }
        switch controller.status.state {
        case "TRIGGERED", "COOLDOWN": return .red
        case "SUSPICIOUS_MOVEMENT", "VERIFYING", "FALL_SUSPECTED": return .orange
        default: return .green
        }
    }

    private func statusRow(_ title: String, value: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(color).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.bold())
                Text(value).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.accessibilityElement(children: .combine)
    }
}
