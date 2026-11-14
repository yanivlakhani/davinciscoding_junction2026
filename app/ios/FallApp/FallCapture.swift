import Foundation
import Observation
import MWDATCore
import MonitoringRuntime
import ModalTransport
import FallCaptureCore

@MainActor @Observable
final class FallCapture {
    private(set) var status = "Waiting for glasses"
    private(set) var needsPermission = false
    private(set) var busy = false
    private(set) var cameraActive = false
    private(set) var cameraStopFailed = false
    private(set) var policy: CameraStartPolicy = .onMovement
    private(set) var codec: CameraCodec = .hevc
    @ObservationIgnored private var stream: FallCameraStream?
    @ObservationIgnored private var recorder = BufferedVideoRecorder()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var warmTask: Task<Void, Never>?
    @ObservationIgnored private var idleStopTask: Task<Void, Never>?
    @ObservationIgnored private var pending: [FallNotice] = []
    @ObservationIgnored private var candidateActive = false
    @ObservationIgnored private var yellowDecisionNs: UInt64?
    @ObservationIgnored private var latestStateSequence = -1
    @ObservationIgnored private var warmExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var warmUntil: ContinuousClock.Instant?
    @ObservationIgnored private var earlyCueNs: UInt64?
    private let root: URL
    private let delivery: ModalDelivery

    init(root: URL, delivery: ModalDelivery) { self.root = root; self.delivery = delivery }

    func arm(on session: DeviceSession, monitoringSessionID: String, policy: CameraStartPolicy, codec: CameraCodec) async {
        self.policy = policy; self.codec = codec
        latestStateSequence = -1; candidateActive = false; yellowDecisionNs = nil
        recorder = BufferedVideoRecorder()
        stream = FallCameraStream(session: session, monitoringSessionID: monitoringSessionID, recorder: recorder, codec: codec, root: root)
        guard policy != .disabled else { needsPermission = false; status = armedMessage; return }
        do {
            needsPermission = try await Wearables.shared.checkPermissionStatus(.camera) != .granted
            status = needsPermission ? "Camera permission required" : armedMessage
            if policy == .continuous, !needsPermission { warm() }
        } catch { status = "Cannot check camera permission"; needsPermission = true }
    }

    func requestPermission() async {
        do {
            needsPermission = try await Wearables.shared.requestPermission(.camera) != .granted
            status = needsPermission ? "Camera permission denied" : armedMessage
            if policy == .continuous, !needsPermission { warm() }
        } catch { status = error.localizedDescription; needsPermission = true }
    }

    func detectorChanged(_ change: DetectorStateChange) {
        guard change.sequence > latestStateSequence else { return }
        latestStateSequence = change.sequence
        switch change.state {
        case "SUSPICIOUS_MOVEMENT", "VERIFYING":
            candidateActive = true
            if change.state == "SUSPICIOUS_MOVEMENT" { yellowDecisionNs = change.phoneUptimeNs }
            if !busy, policy == .onYellow || policy == .onMovement { extendWarmWindow(); warm() }
        case "MONITORING":
            candidateActive = false
            yellowDecisionNs = nil
            scheduleWarmExpiry()
        default: break
        }
    }

    func earlyMotion(_ cue: CameraWarmupCue) {
        guard policy == .onMovement, !busy else { return }
        earlyCueNs = cue.phoneUptimeNs
        extendWarmWindow(); warm()
    }

    func updateFeedback() async {
        guard let stream, policy != .disabled else { return }
        cameraActive = await stream.isActive
        cameraStopFailed = await stream.failure?.code == "stopTimeout" && cameraActive
        guard !busy, warmTask == nil else { return }
        if cameraStopFailed { status = "Camera stop unconfirmed · LED may remain on · reconnect glasses"; return }
        if cameraActive, let failure = await stream.failure {
            status = "Camera unavailable · \(failure.code)"
        } else if cameraActive, recorder.snapshot.bufferedFrames > 0 {
            status = "Camera ready · buffered frames · capture LED active"
        }
    }

    func capture(_ notice: FallNotice) {
        guard policy != .disabled else { return }
        pending.append(notice); busy = true; warmExpiryTask?.cancel()
        warmUntil = nil
        guard task == nil else { return }
        task = Task { [self] in
            defer { task = nil; busy = false; scheduleWarmExpiry() }
            while !pending.isEmpty, !Task.isCancelled {
                await record(pending.removeFirst())
            }
        }
    }

    func stop() async {
        candidateActive = false
        warmUntil = nil; earlyCueNs = nil
        warmExpiryTask?.cancel(); warmExpiryTask = nil
        warmTask?.cancel(); task?.cancel()
        await task?.value; await warmTask?.value
        await idleStopTask?.value; idleStopTask = nil
        task = nil; warmTask = nil; pending = []
        let stopped = await stream?.stop() ?? true
        cameraActive = !stopped; cameraStopFailed = !stopped
        if stopped { stream = nil }
        recorder.reset(); busy = false
        status = stopped ? "Camera stopped" : "Camera stop unconfirmed · LED may remain on · reconnect glasses"
    }

    private var armedMessage: String {
        switch policy {
        case .onMovement: "Armed · early movement starts camera"
        case .onYellow: "Armed · camera starts at yellow"
        case .onRed: "Armed · camera starts at red"
        case .continuous: "Continuous buffer test · camera active"
        case .disabled: "Camera off · motion test"
        }
    }

    private func warm() {
        guard policy != .disabled, !needsPermission, !busy, warmTask == nil, let stream else { return }
        status = "Opening camera early · \(codec.title)"
        warmTask = Task { [weak self] in
            defer { self?.warmTask = nil }
            do {
                await self?.idleStopTask?.value
                try Task.checkCancellation()
                let reason = self?.policy == .continuous ? "continuous" : (self?.policy == .onMovement ? "early_motion" : "yellow")
                try await stream.start(reason: reason,
                    requestedNs: self?.earlyCueNs ?? self?.yellowDecisionNs ?? DispatchTime.now().uptimeNanoseconds)
                guard let self else { return }
                self.cameraActive = await stream.isActive
                if Task.isCancelled || (self.policy != .continuous && !self.busy
                    && (self.warmUntil == nil || self.warmUntil! <= ContinuousClock.now)) {
                    await self.stopCamera(stream); return
                }
                if !self.busy { self.status = self.recorder.snapshot.bufferedFrames > 0
                    ? "Camera ready · buffered frames · capture LED active" : "Camera starting · waiting for frames" }
                self.scheduleWarmExpiry()
            } catch { self?.status = "Camera startup failed · \(error.localizedDescription)" }
        }
    }

    private func extendWarmWindow() {
        warmUntil = ContinuousClock.now + .seconds(12)
        scheduleWarmExpiry()
    }

    private func scheduleWarmExpiry() {
        warmExpiryTask?.cancel()
        guard policy == .onMovement || policy == .onYellow, !busy, let deadline = warmUntil else { return }
        warmExpiryTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard let self, !self.busy else { return }
            self.idleStopTask = Task { [weak self] in
                guard let self, !self.busy, let until = self.warmUntil, until <= ContinuousClock.now else { return }
                guard let stream = self.stream else { return }
                let stopped = await self.stopCamera(stream)
                if stopped, !self.busy, self.warmUntil == nil || self.warmUntil! <= ContinuousClock.now { self.status = self.armedMessage }
            }
        }
    }

    private func record(_ notice: FallNotice) async {
        guard ModalRequest.validID(notice.eventId), let stream else { status = "Invalid capture context"; return }
        let directory = root.appendingPathComponent("captures").appendingPathComponent(notice.eventId)
        let requestTime = DispatchTime.now().uptimeNanoseconds
        let cueAtRequest = earlyCueNs
        let yellowAtRequest = yellowDecisionNs
        let deadline = ContinuousClock.now + .seconds(20)
        do {
            guard !needsPermission else { throw RecordingFailure.message("Camera permission required; event remains queued") }
            await warmTask?.value
            await idleStopTask?.value; idleStopTask = nil
            try Task.checkCancellation()
            for attempt in 1...2 {
                do {
                    try await stream.start(reason: attempt == 1 ? "red" : "red_retry", requestedNs: requestTime)
                    try Task.checkCancellation()
                    try recorder.begin()
                    await stream.mark("fall_capture_begin", fields: ["eventId": notice.eventId, "decisionPhoneUptimeNs": notice.phoneDecisionUptimeNs,
                        "attempt": String(attempt)])
                    let trigger: [String: String] = ["eventId": notice.eventId, "captureRequestPhoneUptimeNs": String(requestTime),
                        "commandPhoneUptimeNs": String(await stream.commandUptimeNs ?? requestTime),
                        "sourceTriggerTimestampNs": notice.sourceTimestampNs, "decisionPhoneUptimeNs": notice.phoneDecisionUptimeNs,
                        "cameraPolicy": policy.rawValue, "streamCodec": codec.rawValue, "streamTraceID": await stream.traceID ?? "",
                        "yellowDecisionPhoneUptimeNs": yellowAtRequest.map(String.init) ?? "",
                        "lastEarlyCueBeforeCaptureNs": cueAtRequest.map(String.init) ?? "", "attempt": String(attempt)]
                    try await Task.detached {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
                        try JSONEncoder().encode(trigger).write(to: directory.appendingPathComponent("trigger.json"), options: .atomic)
                    }.value
                    while !recorder.snapshot.complete {
                        try Task.checkCancellation()
                        if let failure = await stream.failure { throw failure }
                        if let message = recorder.snapshot.error { throw RecordingFailure.message(message) }
                        guard ContinuousClock.now < deadline else { throw RecordingFailure.message("Timed out waiting for one second of camera frames") }
                        status = recorder.snapshot.firstReceipt == nil ? "Waiting for camera / HEVC keyframe" : "Collecting one-second frame burst"
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    break
                } catch {
                    let retry = (error as? CameraStreamFailure)?.allowsRetry(attempt: attempt,
                        hasFrames: recorder.snapshot.firstReceipt != nil) == true && ContinuousClock.now < deadline && !Task.isCancelled
                    let failure: [String: String] = ["attempt": String(attempt), "error": error.localizedDescription,
                        "sdkError": (error as? CameraStreamFailure)?.code ?? "captureError", "retryScheduled": String(retry),
                        "streamTraceID": await stream.traceID ?? "", "phoneUptimeNs": String(DispatchTime.now().uptimeNanoseconds)]
                    await Task.detached {
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try? JSONEncoder().encode(failure).write(to: directory.appendingPathComponent("attempt-\(attempt)-error.json"), options: .atomic)
                    }.value
                    guard retry else { throw error }
                    recorder.cancelClip(); await stream.stop()
                    status = "Recovering camera · one retry"
                    try await Task.sleep(for: .milliseconds(750))
                }
            }
            let snapshot = recorder.snapshot
            await stream.mark("clip_buffer_complete", fields: ["eventId": notice.eventId, "preRollSeconds": String(snapshot.preRollSeconds)])
            if policy != .continuous { await stopCamera(stream, discardBuffer: false) }
            status = "Encoding every frame as JPEG · \(cameraActive ? "camera active" : "camera off")"
            let bufferMetadata: [String: String] = ["preRollSeconds": String(snapshot.preRollSeconds),
                "firstBufferedReceiptNs": snapshot.firstReceipt.map(String.init) ?? "",
                "lastBufferedReceiptNs": snapshot.lastReceipt.map(String.init) ?? "",
                "bufferCompletePhoneUptimeNs": String(DispatchTime.now().uptimeNanoseconds)]
            try await Task.detached {
                try JSONEncoder().encode(bufferMetadata).write(to: directory.appendingPathComponent("buffer.json"), options: .atomic)
            }.value
            let result = try await recorder.export(to: directory)
            if policy != .continuous { recorder.reset() } else { recorder.cancelClip() }
            let manifest = CaptureManifest(eventId: notice.eventId, complete: true, frames: result.frames,
                                           durationSeconds: result.duration, error: nil)
            try await Task.detached {
                try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("capture.json"), options: .atomic)
            }.value
            status = cameraStopFailed ? "Frames saved · camera stop unconfirmed · reconnect glasses"
                : "Captured 1 s · \(result.frames.count) frames queued · \(cameraActive ? "camera active" : "camera off")"
            candidateActive = false
            Task { [delivery] in try? await delivery.flush() }
        } catch {
            recorder.cancelClip()
            if policy != .continuous { await stopCamera(stream) }
            let manifest = CaptureManifest(eventId: notice.eventId, complete: false, frames: [], durationSeconds: 0,
                                           error: error.localizedDescription)
            await Task.detached {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("capture.json"), options: .atomic)
            }.value
            status = cameraStopFailed ? "Capture incomplete · camera stop unconfirmed · reconnect glasses"
                : "Capture incomplete · \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func stopCamera(_ stream: FallCameraStream, discardBuffer: Bool = true) async -> Bool {
        status = "Stopping camera · waiting for glasses"
        let stopped = await stream.stop(discardBuffer: discardBuffer)
        cameraActive = !stopped
        cameraStopFailed = !stopped
        if !stopped { status = "Camera stop unconfirmed · LED may remain on · reconnect glasses" }
        return stopped
    }
}
