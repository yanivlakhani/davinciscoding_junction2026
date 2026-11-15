import Foundation

/// Presentation only. Neither a screen nor its dismissal authorizes any action.
public struct LensScreen: Sendable, Equatable {
    public enum Style: String, Sendable { case checkingIn, escalated, alertSent, cancelled }
    public enum Activity: Sendable { case asking, listening(seconds: Double), speaking }
    public static let resultSeconds: Double = 1.5
    public let eventID: String
    public let style: Style
    public let title: String
    public let detail: String
    public let expiresAfter: Double?
    public let listeningDeadlineNs: UInt64?
    public var isTest: Bool { eventID.hasPrefix("test-") }

    private init(_ id: String, _ style: Style, _ title: String, _ detail: String,
                 terminal: Bool = false, deadline: UInt64? = nil) {
        eventID = id; self.style = style; self.title = title; self.detail = detail
        expiresAfter = terminal ? Self.resultSeconds : nil; listeningDeadlineNs = deadline
    }
    public static func confirmed(_ assessment: ServerAssessment, now: Date = Date()) -> Self? {
        guard assessment.fallDetected == true, now.timeIntervalSince(assessment.triggeredAt) < 60 else { return nil }
        return Self(assessment.eventId, .checkingIn, "Are you okay?", "Preparing voice check-in")
    }
    public static func question(_ id: String, stage: CheckInSubmission.Stage, activity: Activity,
                                language: String = "en", nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Self {
        let italian = language == "it"
        let title: String
        switch stage {
        case .initial: title = italian ? "Stai bene?" : "Are you okay?"
        case .contact, .contactRetry: title = italian ? "Inviare un'email?" : "Email your contact?"
        case .decline, .declineRetry: title = italian ? "Confermi nessuna email?" : "Confirm no email?"
        case .call: title = italian ? "Chiamare il contatto?" : "Call your contact?"
        }
        switch activity {
        case .asking: return Self(id, .checkingIn, title, italian ? "Ascolta la domanda" : "Listen to the question")
        case .speaking: return Self(id, .checkingIn, title, italian ? "Ti ascolto · prenditi tempo" : "Listening · take your time")
        case .listening(let seconds):
            let bounded = max(0, min(seconds, 30))
            return Self(id, .checkingIn, title, italian ? "Rispondi a voce" : "Reply aloud",
                        deadline: nowNs + UInt64(bounded * 1_000_000_000))
        }
    }
    public static func processing(_ id: String) -> Self {
        Self(id, .escalated, "Understanding reply", "Please wait")
    }
    public static func receipt(_ id: String, status: String, locationIncluded: Bool) -> Self {
        status == "submitted"
            ? Self(id, .alertSent, "Email submitted", locationIncluded ? "Emergency contact · location included" : "Emergency contact", terminal: true)
            : Self(id, .escalated, "Email not confirmed", "Check the app", terminal: true)
    }
    public static func cancelled(_ id: String) -> Self {
        Self(id, .cancelled, "Contact cancelled", "Monitoring continues", terminal: true)
    }
    public static func interrupted(_ id: String, pending: Bool = false) -> Self {
        Self(id, .escalated, pending ? "Follow-up pending" : "Check-in interrupted", "Check the app", terminal: true)
    }
    public static func completed(_ id: String, emailStatus: String?) -> Self {
        emailStatus == "submitted"
            ? Self(id, .alertSent, "Check-in complete", "Email submitted", terminal: true)
            : Self(id, .escalated, "Check-in complete", "Email not confirmed", terminal: true)
    }
    public static func callHandoff(_ id: String) -> Self {
        Self(id, .checkingIn, "Confirm on iPhone", "Call connection not confirmed", terminal: true)
    }
    public static func displayTest(_ id: String) -> Self {
        Self(id, .checkingIn, "Display connected", "Lens test · no alert sent", terminal: true)
    }
    public func remainingReplySeconds(nowNs: UInt64) -> Int? {
        guard let deadline = listeningDeadlineNs else { return nil }
        return deadline <= nowNs ? 0 : Int(ceil(Double(deadline - nowNs) / 1_000_000_000))
    }
}

/// A stale completion timer must never erase a newer question or event.
public struct LensPresentationState: Sendable {
    public private(set) var screen: LensScreen?
    public private(set) var revision: UInt64 = 0
    public init() {}
    @discardableResult public mutating func show(_ screen: LensScreen?) -> UInt64 {
        revision &+= 1; self.screen = screen; return revision
    }
    @discardableResult public mutating func expire(revision expected: UInt64) -> Bool {
        guard revision == expected, screen?.expiresAfter != nil else { return false }
        show(nil); return true
    }
}
