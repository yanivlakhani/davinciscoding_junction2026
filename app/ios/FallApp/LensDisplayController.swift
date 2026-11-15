import Foundation
import Observation
import SwiftUI
import MWDATCore
import MWDATDisplay
import ModalTransport

/// Independent presentation task: never waits on the motion/inference path.
@MainActor @Observable
final class LensDisplayController {
    private(set) var status = "Blank · event screens only"
    private(set) var currentScreen: LensScreen?
    var onDiagnostic: ((String, String) -> Void)?
    private var session: DeviceSession?
    private var display: MWDATDisplay.Display?
    private var tokens = ListenerTokenBag()
    private var state = LensPresentationState()
    private var queuedScreen: LensScreen?
    private var epoch: UInt64 = 0
    private var dirty = false
    private var writer: Task<Void, Never>?
    private var writerID: UUID?
    private var expiry: Task<Void, Never>?
    private var countdown: Task<Void, Never>?

    func attach(_ session: DeviceSession) {
        guard self.session !== session else { scheduleWrite(); return }
        detach()
        self.session = session
        status = session.device?.supportsDisplay() == true ? "Blank · event screens only" : "Display unavailable on this device"
    }

    func detach() {
        epoch &+= 1
        expiry?.cancel(); countdown?.cancel(); writer?.cancel()
        expiry = nil; countdown = nil; writer = nil; writerID = nil
        state.show(nil); currentScreen = nil; queuedScreen = nil; dirty = false
        display?.stop(); display = nil; tokens.clear(); session = nil
        status = "Blank · no glasses display session"
    }

    func suspend() {
        expiry?.cancel(); countdown?.cancel(); writer?.cancel()
        expiry = nil; countdown = nil; writer = nil; writerID = nil; dirty = false
        state.show(nil); currentScreen = nil; queuedScreen = nil
        // Keep this capability: SDK 1.0.1 has addDisplay but no removeDisplay.
        display?.stop()
        status = "Blank · glasses session paused"
    }

    func present(_ screen: LensScreen?) {
        // Complete a result's 1.5-second hold before showing the next question.
        // A new event or explicit stop always takes precedence.
        if let screen, let current = state.screen,
           current.expiresAfter != nil, screen.expiresAfter == nil, current.eventID == screen.eventID {
            queuedScreen = screen; return
        }
        expiry?.cancel(); expiry = nil; countdown?.cancel(); countdown = nil
        queuedScreen = nil
        state.show(screen); currentScreen = screen
        scheduleWrite()
    }

    private func scheduleWrite() {
        dirty = true
        guard writer == nil else { return }
        let id = UUID(); writerID = id
        writer = Task { [weak self] in
            guard let self else { return }
            defer { if self.writerID == id { self.writer = nil; self.writerID = nil } }
            while self.dirty, !Task.isCancelled {
                self.dirty = false
                await self.writeLatest()
            }
        }
    }

    private func writeLatest() async {
        let expectedEpoch = epoch, revision = state.revision
        let screen = state.screen
        guard let session, session.state == .started else {
            if screen != nil { status = "Display unavailable · glasses session is not active" }
            return
        }
        do {
            guard let screen else {
                if let display, display.state == .started { try await display.clearDisplay() }
                guard expectedEpoch == epoch, revision == state.revision else { return }
                status = "Blank · event screens only"
                onDiagnostic?("lens_clear", "Lens cleared")
                return
            }
            guard session.device?.supportsDisplay() == true else {
                status = "Display unavailable on this device"; return
            }
            let target: MWDATDisplay.Display
            if let display { target = display }
            else {
                target = try session.addDisplay(); display = target
                target.statePublisher.listen { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.epoch == expectedEpoch else { return }
                        self.onDiagnostic?("lens_state", String(describing: value))
                    }
                }.store(in: tokens)
            }
            if target.state == .stopped { status = "Starting lens display"; target.start() }
            let deadline = ContinuousClock.now + .seconds(5)
            while target.state != .started, ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard epoch == expectedEpoch else { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard target.state == .started else { throw LensFailure.notStarted }
            guard expectedEpoch == epoch, revision == state.revision else { return }
            let renderer = ImageRenderer(content: LensArtwork(screen: screen, nowNs: DispatchTime.now().uptimeNanoseconds))
            renderer.scale = 1
            guard let image = renderer.uiImage else { throw LensFailure.rendering }
            let view = MWDATDisplay.FlexBox(alignment: .center, crossAlignment: .center) {
                MWDATDisplay.Image(image: image, sizePreset: .fill)
            }
            try await target.send(view)
            guard expectedEpoch == epoch, revision == state.revision else { return }
            status = "Showing · \(screen.title)"
            onDiagnostic?("lens_screen", "eventID=\(screen.eventID) · style=\(screen.style.rawValue)")
            if let seconds = screen.expiresAfter, expiry == nil {
                // Start the visibility window after the SDK accepted the image.
                expiry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    guard let self, self.epoch == expectedEpoch,
                          self.state.expire(revision: revision) else { return }
                    self.expiry = nil
                    let next = self.queuedScreen; self.queuedScreen = nil
                    if let next { self.present(next) }
                    else { self.currentScreen = nil; self.scheduleWrite() }
                }
            }
            if screen.listeningDeadlineNs != nil, countdown == nil {
                countdown = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        guard let self, self.epoch == expectedEpoch, self.state.revision == revision else { return }
                        self.scheduleWrite()
                        if screen.remainingReplySeconds(nowNs: DispatchTime.now().uptimeNanoseconds) == 0 { return }
                    }
                }
            }
        } catch is CancellationError { }
        catch {
            guard expectedEpoch == epoch, revision == state.revision else { return }
            expiry?.cancel(); countdown?.cancel(); expiry = nil; countdown = nil
            state.show(nil); currentScreen = nil; queuedScreen = nil
            status = "Display unavailable · \(error.localizedDescription)"
            onDiagnostic?("lens_error", "Display update failed; motion monitoring continues")
            // Do not leave a question visible after a failed transition.
            display?.stop()
        }
    }
    private enum LensFailure: LocalizedError {
        case notStarted, rendering
        var errorDescription: String? {
            switch self {
            case .notStarted: "Display did not start; reconnect glasses"
            case .rendering: "Unable to render lens content"
            }
        }
    }
}
