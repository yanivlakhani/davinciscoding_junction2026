// FallVoiceManager.swift
// Domanda vocale "Stai bene?" sugli occhiali Meta + ascolto della risposta (HFP).
// iOS 17+. Usa il routing audio Bluetooth del sistema (AVAudioSession), non un'API DAT.
//
// Info.plist:
//   NSMicrophoneUsageDescription        -> "Serve per sentire la tua risposta dopo una caduta"
//   NSSpeechRecognitionUsageDescription -> "Serve per capire la tua risposta dopo una caduta"
//   UIBackgroundModes                   -> audio   (da testare a schermo bloccato)
//
// Ordine al trigger (doc Meta): prepareHFP() PRIMA di avviare lo stream camera DAT,
// altrimenti il route audio può fallire in silenzio.

import AVFoundation
import Speech

enum FallAnswer: String {
    case fine        // "sto bene" -> annulla
    case help        // aiuto / dolore -> allarme subito
    case confused    // risposta non classificabile -> avvisa contatto
    case silence     // nessuna risposta dopo le ripetizioni -> allarme
}

enum VoiceError: Error {
    case micDenied, speechDenied, recognizerUnavailable, hfpRouteNotActive
}

final class FallVoiceManager: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {

    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let synth = AVSpeechSynthesizer()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "it-IT"))

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?   // protetto da lock
    private var task: SFSpeechRecognitionTask?
    private var speakContinuation: CheckedContinuation<Void, Never>?
    private var configObserver: NSObjectProtocol?

    override init() {
        super.init()
        synth.delegate = self
        synth.usesApplicationAudioSession = true
    }

    // MARK: - 1. Setup HFP (chiamare al trigger, prima della camera)

    func prepareHFP() async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw VoiceError.micDenied }
        guard await Self.requestSpeechAuth() else { throw VoiceError.speechDenied }
        guard recognizer?.isAvailable == true else { throw VoiceError.recognizerUnavailable }

        // Su SDK precedenti a iOS 26 l'opzione si chiama .allowBluetooth
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        try session.setActive(true)
        if let hfp = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try session.setPreferredInput(hfp)
        }

        installTap()
        engine.prepare()
        try engine.start()

        // il route HFP impiega ~2 s a stabilizzarsi
        try await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
        guard session.currentRoute.inputs.contains(where: { $0.portType == .bluetoothHFP }) else {
            teardown()
            throw VoiceError.hfpRouteNotActive
        }

        // se il route cambia, il motore si ferma: reinstallare tap e ripartire
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.installTap()
            try? self.engine.start()
        }
    }

    private func installTap() {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock(); let req = self.request; self.lock.unlock()
            req?.append(buffer)   // nil mentre parla la voce sintetica: niente eco della domanda
        }
    }

    // MARK: - 2. Domanda + risposta

    /// Fa la domanda, ascolta, ripete una volta. Ritorna la classificazione della risposta.
    func askAreYouOK(listenSeconds: TimeInterval = 25, repeats: Int = 1) async -> FallAnswer {
        let prompts = ["Sei caduto. Stai bene? Rispondi sì oppure chiedi aiuto.",
                       "Rispondi se puoi. Stai bene?"]
        for attempt in 0...repeats {
            await speak(prompts[min(attempt, prompts.count - 1)])
            let text = await listen(seconds: listenSeconds)
            if let answer = Self.classify(text) { return answer }
        }
        return .silence
    }

    func speak(_ text: String) async {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "it-IT")
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        u.volume = 1.0
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            speakContinuation = c
            synth.speak(u)
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        speakContinuation?.resume(); speakContinuation = nil
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        speakContinuation?.resume(); speakContinuation = nil
    }

    /// Ascolta fino a `seconds` o finché sente una parola chiave. Ritorna il testo riconosciuto.
    private func listen(seconds: TimeInterval) async -> String {
        guard let recognizer else { return "" }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true } // funziona offline

        lock.lock(); request = req; lock.unlock()

        let text: String = await withCheckedContinuation { cont in
            var done = false
            var last = ""
            let finish: (String) -> Void = { t in
                guard !done else { return }
                done = true
                cont.resume(returning: t)
            }
            task = recognizer.recognitionTask(with: req) { result, error in
                if let result {
                    last = result.bestTranscription.formattedString
                    // esci subito se c'è già una risposta chiara
                    if Self.classify(last).map({ $0 != .confused }) == true || result.isFinal {
                        DispatchQueue.main.async { finish(last) }
                    }
                }
                if error != nil { DispatchQueue.main.async { finish(last) } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish(last) }
        }

        lock.lock(); request = nil; lock.unlock()
        req.endAudio()
        task?.cancel(); task = nil
        return text
    }

    // MARK: - Classificazione semplice (sostituibile con un LLM)

    static func classify(_ raw: String) -> FallAnswer? {
        let t = raw.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "it_IT"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        let words = Set(t.split(whereSeparator: { !$0.isLetter }).map(String.init))
        // frasi: cercate come sottostringa; parole brevi: solo come parola intera ("no" non deve scattare su "sono")
        let helpPhrases = ["aiuto", "male", "dolore", "non riesco", "non sto bene", "chiama", "ambulanza", "sangue"]
        let helpWords: Set<String> = ["no"]
        let finePhrases = ["sto bene", "tutto ok", "tutto bene", "annulla", "niente"]
        let fineWords: Set<String> = ["si", "ok", "okay"]
        if helpPhrases.contains(where: { t.contains($0) }) || !words.isDisjoint(with: helpWords) { return .help }
        if finePhrases.contains(where: { t.contains($0) }) || !words.isDisjoint(with: fineWords) { return .fine }
        return .confused
    }

    // MARK: - Teardown

    func teardown() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        lock.lock(); request?.endAudio(); request = nil; lock.unlock()
        task?.cancel(); task = nil
        synth.stopSpeaking(at: .immediate)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func requestSpeechAuth() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }
}

// MARK: - Esempio d'uso nella pipeline
//
// let voice = FallVoiceManager()
//
// func onFallConfirmed() async {
//     do {
//         try await voice.prepareHFP()          // 1. audio HFP (~2 s)
//     } catch {
//         // HFP non disponibile: decidere senza voce (display / allarme)
//     }
//     startCameraStream()                       // 2. solo dopo HFP pronto
//     let answer = await voice.askAreYouOK()    // 3. domanda + risposta
//     voice.teardown()
//     switch answer {
//     case .fine:     cancelEvent()
//     case .help:     sendAlarm(level: 3)
//     case .confused: sendAlarm(level: 2)
//     case .silence:  sendAlarm(level: 3)
//     }
// }
