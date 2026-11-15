import Foundation
import Observation
import MWDATCore
import MWDATMotion
import MonitoringRuntime
import ModalTransport
import FallCaptureCore
import CoreBluetooth

@MainActor @Observable
final class GlassesController {
    private(set) var connection = "Not connected"
    private(set) var motionState = "Waiting for glasses"
    private(set) var error: String?
    private(set) var status = MonitoringStatus()
    private(set) var deliveryStatus = DeliveryStatus()
    private(set) var connected = false
    private(set) var busy = false
    private(set) var wantsMonitoring = false
    private(set) var startingVoiceTest = false
    let preferences = MonitoringPreferences()
    let disconnectionAlerts = DisconnectionAlerts()
    var showMonitoringConsent = false
    private(set) var phoneBackgrounded = false
    var cameraPolicy: CameraStartPolicy = .onMovement
    var cameraCodec: CameraCodec = .hevc
    var canEditCaptureSettings: Bool { session == nil && !busy && !cleaningUp }
    var hasMonitoringSession: Bool { session != nil }
    private let wearables: any WearablesInterface
    private let selector: AutoDeviceSelector
    private let root: URL
    private let delivery: ModalDelivery
    let capture: FallCapture
    let checkIn: FallCheckIn
    let diagnostics: ConnectionDiagnostics
    let lensDisplay = LensDisplayController()
    private var lastDiagnosticRefreshNs: UInt64 = 0
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var motion: MWDATMotion.Motion?
    @ObservationIgnored private var runtime: MonitoringSession?
    @ObservationIgnored private var sessionTokens = ListenerTokenBag()
    @ObservationIgnored private var motionTokens = ListenerTokenBag()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var motionInbox: MotionInbox?
    private(set) var monitoringHealthy = true
    @ObservationIgnored private var startingMotion = false
    @ObservationIgnored private var cleaningUp = false
    @ObservationIgnored private var monitoringContexts: [String: (name: String, startedAt: Date)] = [:]

    init(startupError: String?) {
        wearables = Wearables.shared
        selector = AutoDeviceSelector(wearables: Wearables.shared)
        root = URL.documentsDirectory.appendingPathComponent("FallApp", isDirectory: true)
        diagnostics = ConnectionDiagnostics(root: root)
        let setup = ModalSettings.configured()
        delivery = ModalDelivery(root: root, settings: setup.settings, configurationMessage: setup.message)
        capture = FallCapture(root: root, delivery: delivery)
        checkIn = FallCheckIn(root: root, delivery: delivery)
        wantsMonitoring = preferences.monitoringRequested
        showMonitoringConsent = !preferences.agreed
        error = startupError
        diagnostics.record("app_start", "Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")")
        lensDisplay.onDiagnostic = { [weak self] event, detail in self?.diagnostics.record(event, detail) }
        checkIn.onLensPresentation = { [weak self] screen in self?.lensDisplay.present(screen) }
        checkIn.onAudioDiagnostic = { [weak self] event, detail in self?.diagnostics.record(event, detail) }
        checkIn.setCameraSuspended = { [weak self] value in try await self?.capture.suspendForCheckIn(value) }
        checkIn.onFinished = { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.connectIfReady()
            }
        }
        guard startupError == nil else { diagnostics.record("startup_error", startupError ?? ""); return }
        tasks.append(Task { [weak self, wearables] in
            for await state in wearables.registrationStateStream() {
                self?.diagnostics.record("meta_registration", state.description)
                self?.connectIfReady()
            }
        })
        tasks.append(Task { [weak self, selector] in
            for await device in selector.activeDeviceStream() {
                self?.diagnostics.record("glasses_selection", device == nil ? "No eligible glasses" : "Glasses available")
                self?.connectIfReady()
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    if let runtime = self.runtime { self.status = try await runtime.refresh() }
                    self.deliveryStatus = try await self.delivery.snapshot()
                    self.checkIn.update(self.deliveryStatus)
                    await self.capture.updateFeedback()
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now >= self.lastDiagnosticRefreshNs, now - self.lastDiagnosticRefreshNs >= 1_000_000_000 {
                        self.lastDiagnosticRefreshNs = now
                        self.refreshDiagnosticSnapshot()
                    }
                } catch { await self.inputFailed(error.localizedDescription) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        })
        tasks.append(Task { [weak self, delivery] in
            while !Task.isCancelled {
                do {
                    if self?.preferences.agreed == true {
                        try await delivery.flush()
                        if self?.wantsMonitoring == true { await delivery.keepConnectionWarm() }
                    }
                }
                catch { self?.error = error.localizedDescription }
                try? await Task.sleep(for: .seconds(5))
            }
        })
        tasks.append(Task { [weak self, delivery] in
            for await assessment in delivery.assessments {
                guard let self, self.wantsMonitoring,
                      let context = self.monitoringContexts[String(assessment.eventId.prefix(36))] else { continue }
                await self.checkIn.handle(assessment, glassesName: context.name)
            }
        })
    }

    isolated deinit {
        checkIn.stop()
        lensDisplay.detach()
        for task in tasks { task.cancel() }
        sampleTask?.cancel(); processingTask?.cancel(); motionInbox?.finish(); motion?.stop(); session?.stop()
        motionTokens.clear(); sessionTokens.clear()
    }

    func connect() {
        diagnostics.record("connect_tapped", "User requested connection")
        guard preferences.agreed else { showMonitoringConsent = true; return }
        preferences.requestMonitoring(true)
        wantsMonitoring = true
        guard !busy else { diagnostics.record("connect_waiting", "Another connection action is in progress"); return }
        error = nil
        if wearables.registrationState == .registered { connectIfReady(); return }
        busy = true
        Task { [weak self, wearables] in
            do {
                self?.diagnostics.record("meta_authorization_start", "Opening Meta AI for app registration")
                try await wearables.startRegistration()
            }
            catch { self?.error = error.localizedDescription; self?.diagnostics.record("meta_authorization_error", error.localizedDescription) }
            self?.busy = false
            self?.connectIfReady()
        }
    }

    func testConfirmedFall() async {
        guard preferences.agreed, connected, checkIn.enabled, !checkIn.busy,
              !capture.busy, !startingVoiceTest else { return }
        startingVoiceTest = true; defer { startingVoiceTest = false }
        let name = session?.device?.name ?? ""
        diagnostics.record("voice_test_start", "Explicit simulated confirmation; normal vision unchanged")
        do {
            let assessment = try await delivery.confirmedFallTest()
            guard connected, wantsMonitoring else { return }
            await checkIn.handle(assessment, glassesName: name)
        } catch {
            self.error = "Voice test unavailable · \(error.localizedDescription)"
            diagnostics.record("voice_test_error", "Could not create confirmed test event")
        }
    }

    func testLensDisplay() async {
        guard connected, !checkIn.busy, !capture.busy, !startingVoiceTest else { return }
        startingVoiceTest = true; defer { startingVoiceTest = false }
        do {
            let assessment = try await delivery.confirmedFallTest()
            guard connected, wantsMonitoring else { return }
            lensDisplay.present(.displayTest(assessment.eventId))
        } catch { self.error = "Lens test unavailable · \(error.localizedDescription)" }
    }

    func disconnect() {
        diagnostics.record("disconnect_tapped", "User stopped monitoring")
        checkIn.stop()
        lensDisplay.present(nil)
        monitoringContexts.removeAll()
        preferences.requestMonitoring(false)
        wantsMonitoring = false
        disconnectionAlerts.stoppedByUser()
        session?.stop()
        Task { await cleanup() }
    }

    func acceptMonitoringConsent(notifications: Bool) {
        preferences.accept()
        showMonitoringConsent = false
        Task {
            if notifications != disconnectionAlerts.enabled { await disconnectionAlerts.setEnabled(notifications) }
            connect()
        }
    }

    func dismissMonitoringConsent() { showMonitoringConsent = false }

    func handleURL(_ url: URL) async {
        guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true else { return }
        diagnostics.record("meta_callback_received", "Callback received; URL contents omitted")
        do {
            let handled = try await wearables.handleUrl(url)
            diagnostics.record("meta_callback_result", "handled=\(handled)")
            connectIfReady()
        }
        catch { self.error = error.localizedDescription; diagnostics.record("meta_callback_error", error.localizedDescription) }
    }

    func backgroundChanged(_ backgrounded: Bool) async {
        diagnostics.record(backgrounded ? "app_background" : "app_foreground")
        phoneBackgrounded = backgrounded
        // Keep an active motion session; do not inherit the camera sample's
        // deliberate stop-on-background behavior. Actual delivery is measured.
        do { try await runtime?.setBackgrounded(backgrounded) }
        catch { self.error = error.localizedDescription }
        if !backgrounded {
            await disconnectionAlerts.refreshPermission()
            connectIfReady()
            if preferences.agreed { try? await delivery.flush() }
        }
    }

    private func connectIfReady() {
        defer { refreshDiagnosticSnapshot() }
        guard preferences.agreed, wantsMonitoring, session == nil, !cleaningUp else { return }
        guard !checkIn.busy else { diagnostics.record("connect_waiting", "Voice check-in is active"); return }
        guard wearables.registrationState == .registered else {
            connection = "Connect with Meta AI"; diagnostics.record("connect_waiting", "Meta registration not complete"); return
        }
        guard selector.activeDevice != nil else {
            connection = "Waiting for glasses"; diagnostics.record("connect_waiting", "Meta SDK reports no eligible glasses"); return
        }
        do {
            diagnostics.record("session_create", "Creating Meta device session")
            let created = try wearables.createSession(deviceSelector: selector)
            session = created; busy = true; connection = "Connecting"
            created.statePublisher.listen { [weak self, weak created] state in
                Task { @MainActor in
                    guard let self, let created, self.session === created else { return }
                    await self.sessionChanged(state)
                }
            }.store(in: sessionTokens)
            created.errorPublisher.listen { [weak self] error in
                Task { @MainActor in
                    self?.error = error.localizedDescription
                    self?.diagnostics.record("session_error", error.localizedDescription)
                }
            }.store(in: sessionTokens)
            try created.start()
        } catch {
            self.error = error.localizedDescription; session = nil; busy = false; sessionTokens.clear()
            diagnostics.record("session_start_error", error.localizedDescription)
        }
    }

    private func refreshDiagnosticSnapshot() {
        let devices = wearables.devices.compactMap { wearables.deviceForIdentifier($0) }
        diagnostics.update([
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "registration": wearables.registrationState.description,
            "connection": connection,
            "session": session?.state.description ?? "none",
            "selectorAvailable": String(selector.activeDevice != nil),
            "bluetoothAuthorization": String(describing: CBManager.authorization),
            "devices": devices.map { "\($0.name): \($0.linkState), \($0.compatibility().displayString)" }.joined(separator: "; "),
            "samples": String(status.received),
            "motion": motionState,
            "camera": capture.status,
            "lens": lensDisplay.status,
            "voiceBusy": String(checkIn.busy),
            "appAudio": checkIn.audioDiagnostic,
            "error": error ?? ""
        ])
    }

    private func sessionChanged(_ state: DeviceSessionState) async {
        diagnostics.record("session_state", state.description)
        connection = state.description
        connected = state == .started
        if state == .started {
            if error != nil { diagnostics.record("connection_recovered", "Previous connection error cleared") }
            error = nil
        }
        busy = state == .starting || state == .stopping
        if state == .started, monitoringHealthy { disconnectionAlerts.connected() }
        if wantsMonitoring, state == .paused || state == .stopped {
            disconnectionAlerts.interrupted(state == .paused ? "The glasses session paused." : "The glasses connection ended.")
        }
        if state == .started, let session { lensDisplay.attach(session) }
        if state == .started, motion == nil, !startingMotion { await startMotion() }
        if state == .paused { lensDisplay.suspend(); motionState = "Session paused; motion unavailable" }
        if state == .stopped { await cleanup() }
    }

    private func startMotion() async {
        guard let session, session.state == .started, !startingMotion else { return }
        startingMotion = true; defer { startingMotion = false }
        diagnostics.record("motion_start", "Attaching glasses motion at 30 Hz")
        do {
            monitoringHealthy = true
            let runtime = try MonitoringSession(root: root, cameraEnabled: AppConfig.automaticFallVideoEnabled && cameraPolicy != .disabled,
                runtimeOptions: ["cameraPolicy": cameraPolicy.rawValue, "streamCodec": cameraCodec.rawValue, "frameRate": String(FrameBurstConfiguration.framesPerSecond),
                    "earlyAccelerationMS2": "15", "earlyLowAccelerationMS2": "3", "earlyAngularRadS": "3",
                    "earlyConsecutiveSamples": "2", "warmHoldSeconds": "12", "stopAfterClipCollection": String(cameraPolicy != .continuous),
                    "captureFormat": "jpeg_frames_only", "captureSeconds": "1", "maximumPreRollSeconds": "0.25"],
                onCameraWarmup: { [weak self] cue in
                    Task { @MainActor in
                        guard let self, self.connected, self.wantsMonitoring, self.monitoringHealthy,
                              self.runtime?.id == cue.sessionId else { return }
                        self.capture.earlyMotion(cue)
                    }
                },
                onStateChanged: { [weak self] change in
                    Task { @MainActor in
                        guard let self, self.connected, self.wantsMonitoring, self.monitoringHealthy,
                              self.runtime?.id == change.sessionId else { return }
                        self.capture.detectorChanged(change)
                    }
                }, onFallQueued: { [weak self] notice in
                Task { @MainActor in
                    guard let self, self.connected, self.wantsMonitoring, self.monitoringHealthy,
                          self.runtime?.id == notice.sessionId else { return }
                    self.capture.capture(notice)
                }
            })
            self.runtime = runtime
            monitoringContexts[runtime.id] = (session.device?.name ?? "", Date())
            if monitoringContexts.count > 8, let oldest = monitoringContexts.min(by: { $0.value.startedAt < $1.value.startedAt })?.key {
                monitoringContexts.removeValue(forKey: oldest)
            }
            status = MonitoringStatus()
            try await runtime.setBackgrounded(phoneBackgrounded)
            guard self.session === session, session.state == .started, wantsMonitoring else {
                try await runtime.stop(); self.runtime = nil; return
            }
            await capture.arm(on: session, monitoringSessionID: runtime.id, policy: cameraPolicy, codec: cameraCodec)
            guard self.session === session, session.state == .started, wantsMonitoring else {
                try await runtime.stop(); self.runtime = nil; return
            }
            guard let added = try session.addMotion(configuration: MotionConfiguration(samplingRate: .hz30)) else {
                throw CocoaError(.featureUnsupported)
            }
            motion = added
            added.statePublisher.listen { [weak self] state in
                Task { @MainActor in self?.motionState = state.description; self?.diagnostics.record("motion_state", state.description) }
            }.store(in: motionTokens)
            added.errorPublisher.listen { [weak self, weak added] error in
                Task { @MainActor in
                    guard let self, let added, self.motion === added else { return }
                    self.error = error.localizedDescription; self.motionState = "Motion unavailable"
                    self.diagnostics.record("motion_error", error.localizedDescription)
                    self.disconnectionAlerts.interrupted("Sensor data is unavailable.")
                }
            }.store(in: motionTokens)
            let samples = added.samples
            let inbox = MotionInbox()
            motionInbox = inbox
            processingTask = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    for await packet in inbox.packets {
                        guard !Task.isCancelled else { break }
                        try await runtime.receive(packet.data, receiptUptimeNs: packet.receiptUptimeNs)
                    }
                } catch {
                    inbox.finish()
                    await self?.inputFailed(error.localizedDescription)
                }
            }
            sampleTask = Task.detached(priority: .userInitiated) { [weak self] in
                defer { inbox.finish() }
                var loggedFirstPacket = false
                for await sample in samples {
                    guard !Task.isCancelled else { break }
                    let receipt = DispatchTime.now().uptimeNanoseconds
                    if !loggedFirstPacket {
                        loggedFirstPacket = true
                        Task { @MainActor [weak self] in self?.diagnostics.record("motion_first_packet", "Glasses are delivering sensor samples") }
                    }
                    do {
                        let data = try Self.encode(sample, receipt: receipt)
                        guard inbox.offer(ReceivedMotionPacket(data: data, receiptUptimeNs: receipt)) else {
                            await self?.inputFailed("Motion queue full or closed; monitoring stopped without silently dropping samples")
                            break
                        }
                    } catch {
                        await self?.inputFailed(error.localizedDescription)
                        break
                    }
                }
            }
            added.start()
        } catch {
            self.error = error.localizedDescription
            diagnostics.record("motion_start_error", error.localizedDescription)
            try? await runtime?.stop(); runtime = nil
            motion?.stop(); motion = nil; motionTokens.clear()
            try? session.removeMotion()
        }
    }

    private func inputFailed(_ message: String) async {
        diagnostics.record("monitoring_input_error", message)
        guard monitoringHealthy else { return }
        monitoringHealthy = false
        if wantsMonitoring { disconnectionAlerts.interrupted("Monitoring stopped because of an input or storage error.") }
        await runtime?.inputFailed(message)
        error = message
        motionState = "Monitoring stopped: input/storage error"
        motion?.stop()
        sampleTask?.cancel(); processingTask?.cancel(); motionInbox?.finish()
        await capture.stop()
    }

    private func cleanup() async {
        guard !cleaningUp else { return }
        cleaningUp = true; defer { cleaningUp = false }
        diagnostics.record("session_cleanup", "Releasing camera and motion resources")
        connected = false
        lensDisplay.detach()
        motion?.stop(); sampleTask?.cancel(); await sampleTask?.value; sampleTask = nil
        motionInbox?.finish()
        await processingTask?.value; processingTask = nil; motionInbox = nil
        motionTokens.clear()
        if motion != nil { try? session?.removeMotion() }
        motion = nil
        do { try await runtime?.stop() } catch { self.error = error.localizedDescription }
        await capture.stop()
        runtime = nil; sessionTokens.clear(); session = nil
        connected = false; busy = false; motionState = "Waiting for glasses"; connection = "Disconnected"
    }

    nonisolated private static func encode(_ sample: MotionSample, receipt: UInt64) throws -> Data {
        func vector(_ value: MWDATMotion.Vector3?) -> Any {
            value.map { ["x": Double($0.x), "y": Double($0.y), "z": Double($0.z)] } as Any? ?? NSNull()
        }
        let source: String
        switch sample.source { case .glasses: source = "GLASSES"; case .neuralBand: source = "NEURAL_BAND"; default: source = "UNKNOWN" }
        let row: [String: Any] = ["timestamp_ns": sample.timestampNs, "phone_receipt_ns": receipt, "source": source,
            "accelerometer": vector(sample.accelerometer), "gyroscope": vector(sample.gyroscope),
            "magnetometer": vector(sample.magnetometer),
            "orientation": sample.orientation.map { ["w": Double($0.w), "x": Double($0.x), "y": Double($0.y), "z": Double($0.z)] } as Any? ?? NSNull()]
        return try JSONSerialization.data(withJSONObject: row)
    }
}
