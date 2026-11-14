import SwiftUI

struct ConnectionView: View {
    @Bindable var controller: GlassesController

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
                VStack(alignment: .leading, spacing: 8) {
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
                    if controller.status.backgroundSamples > 0 {
                        statusRow("Background data", value: "\(controller.status.backgroundSamples) samples received", color: .green)
                    }
                    HStack {
                        Text("Queued: \(controller.deliveryStatus.pending)")
                        Spacer()
                        Text("Sent: \(controller.deliveryStatus.delivered)")
                    }.font(.footnote).foregroundStyle(.secondary)
                }.padding(22).background(.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
                if controller.status.latePackets > 0 {
                    Text("Input timing needs attention: \(controller.status.latePackets) late packets.").font(.footnote).foregroundStyle(.orange)
                }
                if let error = controller.error { Text(error).font(.footnote).foregroundStyle(.red) }
                Text("\(controller.cameraPolicy.title) · Sound and vibration off").font(.footnote).foregroundStyle(.secondary)
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
