import Foundation
import CoreMedia
import MWDATCore
import MWDATCamera
import FallCaptureCore

/// SDK lifecycle runs outside the UI actor. Callbacks retain bounded RAM and
/// enqueue diagnostics; encoding and disk writes happen later.
actor FallCameraStream {
    private let session: DeviceSession
    private let recorder: BufferedVideoRecorder
    private let codec: CameraCodec
    private let root: URL
    private let monitoringSessionID: String
    private var camera: MWDATCamera.Camera?
    private var stoppingCamera: MWDATCamera.Camera?
    var isActive: Bool { camera != nil || stoppingCamera != nil }
    private let tokens = ListenerTokenBag()
    private var trace: CameraTrace?
    private var activeTraceID: String?
    private var frameGate: CameraFrameGate?
    private(set) var failure: CameraStreamFailure?
    var error: String? { failure?.message }
    private var shutdown: Task<Void, Error>?
    private var shutdownID: UUID?
    private(set) var commandUptimeNs: UInt64?
    private(set) var traceID: String?

    init(session: DeviceSession, monitoringSessionID: String, recorder: BufferedVideoRecorder, codec: CameraCodec, root: URL) {
        self.session = session; self.recorder = recorder; self.codec = codec; self.root = root
        self.monitoringSessionID = monitoringSessionID
    }

    func start(reason: String, requestedNs: UInt64) async throws {
        if let shutdown {
            let id = shutdownID
            try await shutdown.value
            if id == shutdownID { self.shutdown = nil; shutdownID = nil; stoppingCamera = nil }
        }
        if let camera {
            let recentStart = commandUptimeNs.map { DispatchTime.now().uptimeNanoseconds - $0 < 500_000_000 } ?? false
            switch CameraReuseDecision.evaluate(hasCamera: true, cameraState: String(describing: camera.state),
                streamState: String(describing: camera.stream.state), hasError: failure != nil, startPending: recentStart) {
            case .reuse: return
            case .waitForResume:
                throw CameraStreamFailure(code: "paused", message: "Glasses stream paused; resume on the glasses", retryable: false)
            case .recreate:
                await stop()
                return try await start(reason: reason, requestedNs: requestedNs)
            }
        }
        guard session.state == .started else { throw RecordingFailure.message("Glasses session unavailable for capture") }
        failure = nil
        let id = UUID().uuidString
        let trace = try CameraTrace(root: root, id: id)
        self.trace = trace; traceID = id; activeTraceID = id
        trace.record("camera_start_requested", at: requestedNs, fields: ["reason": reason])
        trace.record("camera_attach_begin", fields: ["codec": codec.rawValue, "frameRate": String(FrameBurstConfiguration.framesPerSecond), "sessionId": monitoringSessionID])
        commandUptimeNs = DispatchTime.now().uptimeNanoseconds
        do {
            let configuration = StreamConfiguration(videoCodec: codec == .hevc ? .hvc1 : .raw, audioCodec: nil,
                                                    resolution: .low, frameRate: FrameBurstConfiguration.framesPerSecond)
            guard let added = try session.addCamera(config: configuration) else { throw CocoaError(.featureUnsupported) }
            camera = added
            trace.record("camera_attach_end")
            added.statePublisher.listen { state in trace.record("camera_state", fields: ["state": String(describing: state)]) }.store(in: tokens)
            added.stream.statePublisher.listen { [weak self] state in
                trace.record("stream_state", fields: ["state": String(describing: state)])
                if state == .stopped || state == .stopping { Task { await self?.ended(id: id) } }
            }.store(in: tokens)
            added.stream.errorPublisher.listen { [weak self] error in
                let message = error.localizedDescription
                let failure = Self.classify(error)
                trace.record("stream_error", fields: ["message": message, "sdkError": failure.code,
                    "retryable": String(failure.retryable), "audioEnabled": "false"])
                Task { await self?.failed(failure, id: id) }
            }.store(in: tokens)
            let recorder = recorder
            let gate = CameraFrameGate()
            frameGate = gate
            added.stream.videoFramePublisher.listen { frame in
                gate.accept {
                    let receipt = DispatchTime.now().uptimeNanoseconds
                    recorder.append(frame.sampleBuffer, receipt: receipt)
                    let pts = CMSampleBufferGetPresentationTimeStamp(frame.sampleBuffer)
                    trace.record("frame", at: receipt, fields: ["mediaValue": String(pts.value), "mediaTimescale": String(pts.timescale),
                        "callbackEndNs": String(DispatchTime.now().uptimeNanoseconds)])
                }
            }.store(in: tokens)
            trace.record("stream_start_begin")
            added.stream.start()
            trace.record("stream_start_return")
        } catch {
            let classified: CameraStreamFailure
            if let failure = error as? CameraStreamFailure { classified = failure }
            else if let error = error as? DeviceSessionError { classified = Self.classify(error) }
            else { classified = CameraStreamFailure(code: "attachFailed", message: error.localizedDescription, retryable: false) }
            failure = classified
            trace.record("start_error", fields: ["message": error.localizedDescription])
            await stop()
            throw classified
        }
    }

    func mark(_ kind: String, fields: [String: String] = [:]) { trace?.record(kind, fields: fields) }

    @discardableResult
    func stop(discardBuffer: Bool = true) async -> Bool {
        if camera == nil {
            if discardBuffer { recorder.reset() }
            let unused = trace; trace = nil; activeTraceID = nil
            if let unused { unused.record("camera_stop"); await unused.finish() }
            if let shutdown {
                do {
                    try await shutdown.value
                    stoppingCamera = nil
                } catch {
                    if stoppingCamera?.state == .stopped { stoppingCamera = nil }
                    else { failure = error as? CameraStreamFailure; return false }
                }
            }
            return stoppingCamera == nil
        }
        frameGate?.close(); frameGate = nil
        let previousCamera = camera; camera = nil; activeTraceID = nil
        stoppingCamera = previousCamera
        tokens.clear(); previousCamera?.stop()
        let previous = trace; trace = nil
        previous?.record("camera_stop")
        if discardBuffer { recorder.reset() }
        let id = UUID(); shutdownID = id
        let task = Task.detached(priority: .userInitiated) {
            let stopped = try await CameraStopConfirmation.wait {
                previousCamera == nil || previousCamera?.state == .stopped
            }
            previous?.record("camera_detached", fields: ["stopped": String(stopped)])
            if let previous { await previous.finish() }
            guard stopped else { throw CameraStreamFailure(code: "stopTimeout", message: "Camera did not stop; reconnect glasses", retryable: false) }
        }
        shutdown = task
        do {
            try await task.value
            if shutdownID == id { stoppingCamera = nil }
            return true
        } catch {
            failure = error as? CameraStreamFailure
            return false
        }
    }

    private func failed(_ error: CameraStreamFailure, id: String) {
        guard activeTraceID == id else { return }
        failure = error; frameGate?.close()
    }

    private func ended(id: String) {
        guard activeTraceID == id, let camera, camera.stream.state == .stopped || camera.stream.state == .stopping else { return }
        if camera.stream.state == .stopped, let commandUptimeNs,
           DispatchTime.now().uptimeNanoseconds - commandUptimeNs < 500_000_000 { return }
        if failure == nil { failure = CameraStreamFailure(code: "streamEnded", message: "Glasses camera stream ended", retryable: true) }
        frameGate?.close()
    }

    private nonisolated static func classify(_ error: StreamError) -> CameraStreamFailure {
        let code: String
        let retryable: Bool
        switch error {
        case .internalError: code = "internalError"; retryable = true
        case .timeout: code = "timeout"; retryable = true
        case .videoStreamingError: code = "videoStreamingError"; retryable = true
        case .audioStreamingError: code = "audioStreamingError"; retryable = false
        case .deviceNotFound: code = "deviceNotFound"; retryable = false
        case .deviceNotConnected: code = "deviceNotConnected"; retryable = false
        case .permissionDenied: code = "permissionDenied"; retryable = false
        case .hingesClosed: code = "hingesClosed"; retryable = false
        case .thermalHot: code = "thermalHot"; retryable = false
        case .batteryLow: code = "batteryLow"; retryable = false
        case .peakPowerLimit: code = "peakPowerLimit"; retryable = false
        case .photoCaptureFailed: code = "photoCaptureFailed"; retryable = false
        @unknown default: code = "unknown"; retryable = false
        }
        return CameraStreamFailure(code: code, message: error.localizedDescription, retryable: retryable)
    }

    private nonisolated static func classify(_ error: DeviceSessionError) -> CameraStreamFailure {
        let code: String
        let retryable: Bool
        switch error {
        case .capabilityAlreadyActive: code = "capabilityAlreadyActive"; retryable = true
        case .unexpectedError: code = "unexpectedError"; retryable = true
        case .dwaUnavailable: code = "dwaUnavailable"; retryable = true
        case .thermalCritical: code = "thermalCritical"; retryable = false
        case .thermalEmergency: code = "thermalEmergency"; retryable = false
        case .peakPowerShutdown: code = "peakPowerShutdown"; retryable = false
        case .batteryCritical: code = "batteryCritical"; retryable = false
        case .noEligibleDevice: code = "noEligibleDevice"; retryable = false
        case .sessionAlreadyStopped: code = "sessionAlreadyStopped"; retryable = false
        case .sessionAlreadyExists: code = "sessionAlreadyExists"; retryable = false
        case .sessionIdle: code = "sessionIdle"; retryable = false
        case .capabilityNotFound: code = "capabilityNotFound"; retryable = false
        case .datAppOnTheGlassesUpdateRequired: code = "glassesUpdateRequired"; retryable = false
        case .insufficientSDKVersion: code = "insufficientSDKVersion"; retryable = false
        case .dwaOutOfStuRange: code = "dwaOutOfStuRange"; retryable = false
        @unknown default: code = "unknownSessionError"; retryable = false
        }
        return CameraStreamFailure(code: code, message: error.localizedDescription, retryable: retryable)
    }
}

private final class CameraFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    func accept(_ work: () -> Void) { lock.withLock { if open { work() } } }
    func close() { lock.withLock { open = false } }
}

private final class CameraTrace: @unchecked Sendable {
    private let queue = DispatchQueue(label: "FallApp.camera-trace", qos: .utility)
    private let lock = NSLock()
    private let handle: FileHandle
    private var queued = 0
    private var lost = 0
    private var closed = false

    init(root: URL, id: String) throws {
        let directory = root.appendingPathComponent("camera-streams").appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("timeline.jsonl")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: file)
    }

    func record(_ kind: String, at now: UInt64 = DispatchTime.now().uptimeNanoseconds, fields: [String: String] = [:]) {
        lock.lock()
        guard !closed, queued < 512 else { lost += 1; lock.unlock(); return }
        queued += 1; lock.unlock()
        var row = fields; row["kind"] = kind; row["phoneUptimeNs"] = String(now)
        let value = row
        queue.async { [self] in
            defer { lock.lock(); queued -= 1; lock.unlock() }
            do { var data = try JSONSerialization.data(withJSONObject: value); data.append(10); try handle.write(contentsOf: data) }
            catch { lock.lock(); lost += 1; lock.unlock() }
        }
    }

    func finish() async {
        lock.withLock { closed = true }
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let count = lock.withLock { lost }
                if let data = try? JSONSerialization.data(withJSONObject: ["kind": "trace_end", "lostRows": String(count)]) {
                    var line = data; line.append(10); try? handle.write(contentsOf: line)
                }
                try? handle.synchronize(); try? handle.close(); continuation.resume()
            }
        }
    }
}
