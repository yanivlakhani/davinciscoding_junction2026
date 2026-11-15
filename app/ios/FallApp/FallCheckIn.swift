import Foundation
import Observation
import ModalTransport
import UIKit

@MainActor @Observable
final class FallCheckIn {
    private(set) var enabled = UserDefaults.standard.bool(forKey: "spokenCheckInEnabled")
    private(set) var busy = false
    private(set) var status = "Enable spoken check-in before a live test"
    private(set) var modelResult = "Waiting for server analysis"
    var language = UserDefaults.standard.string(forKey: "checkInLanguage") ?? "en" {
        didSet { UserDefaults.standard.set(language, forKey: "checkInLanguage"); startPromptWarmup() }
    }
    var listenSeconds: Double = (UserDefaults.standard.object(forKey: "checkInListenSeconds") as? Double) ?? CheckInTiming.replyStartSeconds {
        didSet { UserDefaults.standard.set(listenSeconds, forKey: "checkInListenSeconds") }
    }
    let location = AlertLocationProvider()
    var personName = UserDefaults.standard.string(forKey: "alertPersonName") ?? "" {
        didSet { UserDefaults.standard.set(personName, forKey: "alertPersonName") }
    }
    var contactPhone = UserDefaults.standard.string(forKey: "emergencyContactPhone") ?? "" {
        didSet { UserDefaults.standard.set(contactPhone, forKey: "emergencyContactPhone") }
    }
    private(set) var pendingCallEvent = UserDefaults.standard.string(forKey: "pendingEmergencyCallEvent")
    var canCall: Bool { phoneURL != nil && pendingCallEvent != nil && !busy }
    private var phoneURL: URL? {
        let trimmed = contactPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || "+ ()-".contains($0)) }) else { return nil }
        let number = trimmed.filter { $0.isNumber || $0 == "+" }
        let digits = number.filter(\.isNumber)
        guard (7...15).contains(digits.count), number.filter({ $0 == "+" }).count <= 1,
              !number.contains("+") || number.first == "+" else { return nil }
        return URL(string: "tel:" + number)
    }
    @ObservationIgnored var setCameraSuspended: ((Bool) async throws -> Void)?
    @ObservationIgnored var onFinished: (() -> Void)?
    @ObservationIgnored var onLensPresentation: ((LensScreen?) -> Void)?
    @ObservationIgnored var onAudioDiagnostic: ((String, String) -> Void)?
    var audioDiagnostic: String { audio.diagnosticStatus }
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    private let audio = CheckInAudio()
    private let delivery: ModalDelivery
    private let journal: CheckInJournal
    private var activeEvent: String?
    private var setupGeneration = 0
    private var lensGeneration = 0
    private var allowsLensPresentation = false
    private var lensStage = CheckInSubmission.Stage.initial
    private var lensReceiptShown = false
    private var promptWarmupTask: Task<Void, Never>?

    init(root: URL, delivery: ModalDelivery) {
        self.delivery = delivery; journal = CheckInJournal(root: root)
        audio.onDiagnostic = { [weak self] event, detail in self?.onAudioDiagnostic?(event, detail) }
        audio.onListeningStarted = { [weak self] seconds in
            guard let self, let id = self.activeEvent else { return }
            self.presentLens(.question(id, stage: self.lensStage, activity: .listening(seconds: seconds), language: self.language))
        }
        audio.onSpeechStarted = { [weak self] in
            guard let self, let id = self.activeEvent else { return }
            self.presentLens(.question(id, stage: self.lensStage, activity: .speaking, language: self.language))
        }
        if enabled { status = audio.permitted ? "Preparing spoken questions" : "Microphone/speech permission required"; startPromptWarmup() }
    }

    func setEnabled(_ value: Bool) async {
        setupGeneration += 1
        let generation = setupGeneration
        if !value {
            enabled = false; UserDefaults.standard.set(false, forKey: "spokenCheckInEnabled")
            promptWarmupTask?.cancel()
            stop(); await activeTask?.value
            guard setupGeneration == generation else { return }
            status = "Spoken check-in off"; return
        }
        let permitted = await audio.requestPermissions()
        guard setupGeneration == generation else { return }
        enabled = permitted
        UserDefaults.standard.set(enabled, forKey: "spokenCheckInEnabled")
        guard enabled else { status = "Microphone or speech permission denied"; return }
        startPromptWarmup()
    }

    private func startPromptWarmup() {
        promptWarmupTask?.cancel()
        guard enabled, audio.permitted else { return }
        let language = language
        let generation = setupGeneration
        promptWarmupTask = Task { [weak self, delivery] in
            guard let self else { return }
            if !self.busy { self.status = "Preparing spoken questions" }
            do {
                try await delivery.preloadCheckInPrompts(language: language)
                guard !Task.isCancelled, self.enabled, self.setupGeneration == generation, self.language == language else { return }
                if !self.busy, self.status == "Preparing spoken questions" { self.status = "Ready · spoken questions saved on phone" }
            } catch {
                guard !Task.isCancelled, self.enabled, self.setupGeneration == generation else { return }
                if !self.busy, self.status == "Preparing spoken questions" { self.status = "Voice preload pending · \(error.localizedDescription)" }
            }
        }
    }

    func handle(_ assessment: ServerAssessment, glassesName: String) async {
        let generation = lensGeneration
        do {
            guard try await journal.claim(assessment), generation == lensGeneration else { return }
            modelResult = assessment.fallDetected == true ? (assessment.eventId.hasPrefix("test-") ? "TEST · simulated fall confirmed" : "Fall confirmed") :
                (assessment.fallDetected == false ? "No fall · monitoring continues" : "Analysis unavailable · not a negative result")
            guard !busy else {
                try await journal.save(assessment, state: "another_check_in_active"); return
            }
            activeEvent = assessment.eventId
            guard let fall = assessment.fallDetected else {
                status = assessment.reason.isEmpty ? "Visual analysis unavailable · sensors monitoring" : assessment.reason
                try await journal.save(assessment, state: "analysis_unavailable"); return
            }
            if !fall {
                status = "No fall · event finished · sensors monitoring"
                try await journal.save(assessment, state: "no_fall"); return
            }
            guard let confirmed = LensScreen.confirmed(assessment) else {
                status = "Old result retained · no delayed spoken question"
                try await journal.save(assessment, state: "expired"); return
            }
            allowsLensPresentation = true; lensReceiptShown = false
            presentLens(confirmed)
            guard enabled, audio.permitted else {
                status = "Fall confirmed · enable microphone/speech for check-in"
                presentLens(.interrupted(assessment.eventId))
                try await journal.save(assessment, state: "voice_permission_required"); return
            }
            busy = true; activeEvent = assessment.eventId
            location.refreshIfAuthorized()
            activeTask = Task { [weak self] in await self?.run(assessment, glassesName: glassesName) }
        } catch {
            try? await setCameraSuspended?(false)
            status = "Check-in unavailable · \(error.localizedDescription)"
        }
    }

    func update(_ snapshot: DeliveryStatus) {
        guard !busy, let reply = snapshot.checkInReply, reply.event_id == activeEvent else { return }
        status = reply.displayMessage
    }

    func stop() {
        lensGeneration += 1; allowsLensPresentation = false
        onLensPresentation?(nil)
        activeTask?.cancel(); audio.stop()
    }

    private func presentLens(_ screen: LensScreen) {
        guard allowsLensPresentation, screen.eventID == activeEvent else { return }
        onLensPresentation?(screen)
    }

    func callEmergencyContact() async {
        guard canCall, let url = phoneURL else { status = "Add a valid emergency contact phone number first"; return }
        guard UIApplication.shared.applicationState == .active else {
            status = "Open and unlock iPhone to confirm the call"; return
        }
        audio.stop()
        let opened = await UIApplication.shared.open(url)
        status = opened ? "iPhone call confirmation opened · call connection unconfirmed" : "Could not open the iPhone call confirmation"
    }

    func dismissCallRequest() {
        pendingCallEvent = nil; UserDefaults.standard.removeObject(forKey: "pendingEmergencyCallEvent")
    }

    private func run(_ assessment: ServerAssessment, glassesName: String) async {
        var transcript: String?
        var acceptedLocation = false
        audio.clearTranscript()
        do {
            try await setCameraSuspended?(true)
            try Task.checkCancellation()
            status = "Loading ElevenLabs question"
            let prompt = try await delivery.checkInPrompt(language: language)
            try Task.checkCancellation()
            status = "Connecting glasses speaker and microphone"
            try await audio.prepare(glassesName: glassesName)
            let remaining = CheckInTiming.remainingQuestionDelay(confirmedAt: assessment.receivedUptimeNs,
                now: DispatchTime.now().uptimeNanoseconds)
            if remaining > 0 {
                status = "Waiting three seconds after confirmation"
                try await Task.sleep(nanoseconds: remaining)
            }
            var stage = CheckInSubmission.Stage.initial
            var question = prompt
            var emailAcknowledged = false
            for _ in 0..<7 {
                transcript = try await ask(question, stage: stage)
                try Task.checkCancellation()
                let submission = CheckInSubmission(eventId: assessment.eventId,
                    outcome: transcript == nil ? .noResponse : .response, transcript: transcript, language: language,
                    stage: stage, unansweredPrompts: transcript == nil ? 2 : 0,
                    personName: stage == .initial && !personName.isEmpty ? String(personName.prefix(120)) : nil,
                    location: stage == .initial ? location.sample : nil)
                try await journal.saveTurn(assessment, stage: stage, state: "upload_pending", transcript: transcript)
                try Task.checkCancellation()
                status = "Reply saved · waiting for server analysis"
                presentLens(.processing(assessment.eventId))
                var reply = try await delivery.queueCheckIn(submission)
                let deadline = ContinuousClock.now + .seconds(45)
                while reply == nil, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .seconds(1))
                    reply = try await delivery.queueCheckIn(submission)
                }
                try Task.checkCancellation()
                guard let reply else {
                    status = "Follow-up pending · reply retained for retry · no late question will replay"
                    presentLens(.interrupted(assessment.eventId, pending: true))
                    try await journal.save(assessment, state: "follow_up_pending", transcript: transcript)
                    break
                }
                status = reply.displayMessage
                if stage == .initial { acceptedLocation = submission.location != nil }
                try await journal.saveTurn(assessment, stage: stage, state: reply.next_action ?? "server_update_required", transcript: transcript)
                if let receipt = reply.notification, !emailAcknowledged {
                    emailAcknowledged = true; lensReceiptShown = true
                    presentLens(.receipt(assessment.eventId, status: receipt.status, locationIncluded: acceptedLocation))
                    let acknowledgment = try await delivery.checkInPrompt(language: language,
                        kind: receipt.status == "submitted" ? "email_submitted" : "email_failed")
                    try await audio.play(acknowledgment)
                }
                let nextKind: String
                switch reply.next_action {
                case "ask_contact": stage = .contact; nextKind = "contact"
                case "ask_contact_again": stage = .contactRetry; nextKind = "contact"
                case "ask_decline": stage = .decline; nextKind = "decline"
                case "ask_decline_again": stage = .declineRetry; nextKind = "decline"
                case "ask_call": stage = .call; nextKind = "call"
                case "phone_call_handoff":
                    presentLens(.callHandoff(assessment.eventId))
                    pendingCallEvent = assessment.eventId
                    UserDefaults.standard.set(assessment.eventId, forKey: "pendingEmergencyCallEvent")
                    let handoff = try await delivery.checkInPrompt(language: language, kind: "call_handoff")
                    try await audio.play(handoff)
                    try await journal.save(assessment, state: "phone_call_requested", transcript: transcript)
                    await finish()
                    if enabled, !Task.isCancelled, UIApplication.shared.applicationState == .active, phoneURL != nil { await callEmergencyContact() }
                    return
                default:
                    if reply.next_action == "done" {
                        if stage == .call { presentLens(.completed(assessment.eventId, emailStatus: reply.notification?.status)) }
                        else if !lensReceiptShown { presentLens(.cancelled(assessment.eventId)) }
                    } else { presentLens(.interrupted(assessment.eventId, pending: true)) }
                    try await journal.save(assessment, state: reply.next_action ?? "server_update_required", transcript: transcript)
                    return await finish()
                }
                question = try await delivery.checkInPrompt(language: language, kind: nextKind)
            }
            presentLens(.interrupted(assessment.eventId, pending: true))
        } catch is CancellationError {
            status = "Check-in cancelled"
            presentLens(.cancelled(assessment.eventId))
            try? await journal.save(assessment, state: "cancelled", transcript: transcript)
        } catch {
            status = "Check-in unavailable · \(error.localizedDescription)"
            presentLens(.interrupted(assessment.eventId))
            transcript = transcript ?? audio.partialTranscript
            try? await journal.save(assessment, state: "voice_error", transcript: transcript)
        }
        await finish()
    }

    private func ask(_ prompt: Data, stage: CheckInSubmission.Stage) async throws -> String? {
        lensStage = stage
        for attempt in 0..<2 {
            try Task.checkCancellation()
            if let id = activeEvent { presentLens(.question(id, stage: stage, activity: .asking, language: language)) }
            status = attempt == 0 ? "Asking through glasses" : "Repeating question once"
            try await audio.play(prompt)
            try Task.checkCancellation()
            status = "Listening for your full reply"
            if let transcript = try await audio.listen(language: language,
                seconds: [10, 15, 20, 30].contains(listenSeconds) ? listenSeconds : 10,
                endPauseSeconds: stage == .initial ? 2.5 : 1.5) { return transcript }
        }
        return nil
    }

    private func finish() async {
        audio.stop()
        try? await setCameraSuspended?(false)
        busy = false; activeTask = nil
        onFinished?()
    }
}
