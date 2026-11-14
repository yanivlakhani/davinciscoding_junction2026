import AVFoundation
import Speech
import ModalTransport

enum CheckInAudioError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let message) = self { return message }; return nil }
}

/// Bounded HFP prompt/listen session, separate from DAT camera and sensor tasks.
@MainActor
final class CheckInAudio: NSObject, AVAudioPlayerDelegate {
    private let audio = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let input = SpeechInput()
    private var player: AVAudioPlayer?
    private var playback: CheckedContinuation<Void, Error>?
    private var recognition: SFSpeechRecognitionTask?
    private var listener: CheckedContinuation<String?, Error>?
    private var timeout: Task<Void, Never>?
    private var silence: Task<Void, Never>?
    private var lastText = ""
    private var tapInstalled = false
    private var routeToken: NSObjectProtocol?
    private var interruptionToken: NSObjectProtocol?
    private var inputUID: String?
    private var recognitionID: UUID?

    var permitted: Bool {
        AVAudioApplication.shared.recordPermission == .granted && SFSpeechRecognizer.authorizationStatus() == .authorized
    }
    var partialTranscript: String? { lastText.isEmpty ? nil : lastText }
    func clearTranscript() { lastText = "" }

    func requestPermissions() async -> Bool {
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard microphone else { return false }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return microphone && speech
    }

    func prepare(glassesName: String) async throws {
        guard permitted else { throw CheckInAudioError.unavailable("Enable microphone and speech recognition before a live test") }
        let bluetooth: AVAudioSession.CategoryOptions
        bluetooth = .allowBluetoothHFP
        try audio.setCategory(.playAndRecord, mode: .default, options: [bluetooth])
        try audio.setActive(true)
        let candidates = audio.availableInputs?.filter { $0.portType == .bluetoothHFP } ?? []
        let name = Self.normalize(glassesName)
        let matches = candidates.filter {
            let port = Self.normalize($0.portName)
            return !name.isEmpty && (port == name || port.contains(name) || name.contains(port))
        }
        guard matches.count == 1, let selected = matches.first else {
            stop()
            throw CheckInAudioError.unavailable("Select the connected glasses as Bluetooth audio; no matching glasses microphone found")
        }
        inputUID = selected.uid
        try audio.setPreferredInput(selected)
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { stop(); throw CheckInAudioError.unavailable("Glasses microphone format unavailable") }
        let bridge = input
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in bridge.append(buffer) }
        tapInstalled = true
        engine.prepare(); try engine.start()
        let deadline = ContinuousClock.now + .seconds(4)
        while !routeReady, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        guard routeReady else { stop(); throw CheckInAudioError.unavailable("Glasses speaker/microphone route did not become ready") }
        routeToken = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: audio, queue: .main) { @Sendable [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.routeReady else { return }
                    self.fail(CheckInAudioError.unavailable("Glasses audio disconnected"))
                }
            }
        interruptionToken = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: audio, queue: .main) { @Sendable [weak self] notification in
                let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
                if began { Task { @MainActor in self?.fail(CheckInAudioError.unavailable("Audio interrupted")) } }
            }
    }

    func play(_ data: Data) async throws {
        guard routeReady, engine.isRunning else { throw CheckInAudioError.unavailable("Glasses audio route unavailable") }
        let value = try AVAudioPlayer(data: data)
        player = value; value.delegate = self
        guard value.duration > 0, value.duration <= 15 else { throw CheckInAudioError.unavailable("Invalid check-in question audio") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                playback = continuation
                guard value.play() else { finishPlayback(.failure(CheckInAudioError.unavailable("Cannot play question"))); return }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(value.duration + 2)) } catch { return }
                    guard let self, self.playback != nil, self.player === value else { return }
                    self.fail(CheckInAudioError.unavailable("Question playback did not finish"))
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.stop() } }
    }

    func listen(language: String, seconds: Double) async throws -> String? {
        guard routeReady, engine.isRunning,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language == "it" ? "it-IT" : "en-US")),
              recognizer.isAvailable else { throw CheckInAudioError.unavailable("Speech recognition unavailable") }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        lastText = ""
        let listenStarted = ContinuousClock.now
        let id = UUID(); recognitionID = id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                listener = continuation
                input.set(request)
                recognition = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                    let text = result?.bestTranscription.formattedString
                    let final = result?.isFinal == true
                    let failure = error?.localizedDescription
                    let noSpeech = (error as NSError?)?.domain == "kAFAssistantErrorDomain" && (error as NSError?)?.code == 1110
                    Task { @MainActor in
                        guard let self, self.listener != nil, self.recognitionID == id else { return }
                        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            if text != self.lastText {
                                if self.lastText.isEmpty {
                                    // Ten seconds is the window to START speaking, not a cutoff mid-answer.
                                    self.timeout?.cancel()
                                    self.timeout = Task { [weak self] in
                                        do { try await Task.sleep(for: .seconds(CheckInTiming.maximumReplySeconds)) } catch { return }
                                        guard let self, self.recognitionID == id else { return }
                                        self.finishListening(.success(self.lastText.isEmpty ? nil : self.lastText))
                                    }
                                }
                                self.lastText = text
                                self.silence?.cancel()
                                self.silence = Task { [weak self] in
                                    do { try await Task.sleep(for: .milliseconds(2500)) } catch { return }
                                    guard self?.recognitionID == id else { return }
                                    self?.finishListening(.success(self?.lastText))
                                }
                            }
                            if final { self.finishListening(.success(text)); return }
                        }
                        if noSpeech, self.lastText.isEmpty, self.routeReady, self.engine.isRunning, self.input.capturedFrames > 0 {
                            guard ContinuousClock.now - listenStarted >= .seconds(seconds) else {
                                self.finishListening(.failure(CheckInAudioError.unavailable("Speech recognition ended before the full reply window"))); return
                            }
                            self.finishListening(.success(nil)); return
                        }
                        if let failure { self.finishListening(.failure(CheckInAudioError.unavailable(failure))) }
                    }
                }
                // Starts only after ElevenLabs playback completed. Never finish on a keyword.
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    guard let self, self.recognitionID == id else { return }
                    guard self.routeReady, self.engine.isRunning, self.input.capturedFrames > 0 else {
                        self.finishListening(.failure(CheckInAudioError.unavailable("Microphone delivered no audio or stopped before reply deadline"))); return
                    }
                    self.finishListening(.success(self.lastText.isEmpty ? nil : self.lastText))
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.stop() } }
    }

    func stop() {
        finishPlayback(.failure(CancellationError()))
        finishListening(.failure(CancellationError()))
        player?.stop(); player = nil
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop(); inputUID = nil
        if let routeToken { NotificationCenter.default.removeObserver(routeToken) }; routeToken = nil
        if let interruptionToken { NotificationCenter.default.removeObserver(interruptionToken) }; interruptionToken = nil
        try? audio.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private var routeReady: Bool {
        guard let inputUID else { return false }
        return audio.currentRoute.inputs.contains { $0.uid == inputUID && $0.portType == .bluetoothHFP }
            && audio.currentRoute.outputs.contains { $0.portType == .bluetoothHFP }
    }
    private static func normalize(_ text: String) -> String { String(text.lowercased().filter { $0.isLetter || $0.isNumber }) }
    private func fail(_ error: Error) {
        finishPlayback(.failure(error)); finishListening(.failure(error)); stop()
    }
    private func finishPlayback(_ result: Result<Void, Error>) {
        guard let continuation = playback else { return }
        playback = nil; timeout?.cancel(); timeout = nil
        continuation.resume(with: result)
    }
    private func finishListening(_ result: Result<String?, Error>) {
        guard let continuation = listener else { return }
        listener = nil; recognitionID = nil; input.set(nil)
        timeout?.cancel(); silence?.cancel(); timeout = nil; silence = nil
        recognition?.cancel(); recognition = nil
        continuation.resume(with: result)
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == identity else { return }
            self.finishPlayback(flag ? .success(()) : .failure(CheckInAudioError.unavailable("Question playback failed")))
        }
    }
}

private final class SpeechInput: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var frames: UInt64 = 0
    var capturedFrames: UInt64 { lock.withLock { frames } }
    func set(_ value: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock { request?.endAudio(); request = value; if value != nil { frames = 0 } }
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { if let request { frames += UInt64(buffer.frameLength); request.append(buffer) } }
    }
}
