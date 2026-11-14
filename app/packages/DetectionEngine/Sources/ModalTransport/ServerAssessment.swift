import Foundation
import CoreFoundation

public enum CheckInTiming {
    public static let questionDelayNs: UInt64 = 3_000_000_000
    public static let replyStartSeconds: Double = 10
    public static let maximumReplySeconds: Double = 60
    public static func remainingQuestionDelay(confirmedAt: UInt64, now: UInt64) -> UInt64 {
        let elapsed = now >= confirmedAt ? now - confirmedAt : 0
        return elapsed >= questionDelayNs ? 0 : questionDelayNs - elapsed
    }
}

public enum CheckInError: LocalizedError {
    case voiceUnavailable
    public var errorDescription: String? { "ElevenLabs voice unavailable; configure its voice ID and key on Modal" }
}

public struct ServerAssessment: Codable, Sendable, Equatable {
    public let eventId: String
    public let fallDetected: Bool?
    public let reason: String
    public let receivedAt: Date
    public let triggeredAt: Date
    public let receivedUptimeNs: UInt64

    public static func parse(_ data: Data, expectedEventId: String, triggeredAt: Date? = nil) throws -> Self {
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              row["event_id"] as? String == expectedEventId else { throw DeliveryError.invalidResponse }
        let vision = row["vision"] as? [String: Any] ?? [:]
        let error = row["vision_error"]
        let quality = row["quality"] as? [[String: Any]] ?? []
        let rejectedFrames = (vision["usable_frames"] as? Int ?? 0) == 0 && !quality.isEmpty && quality.allSatisfy { ($0["usable"] as? Bool) == false }
        let failed = (error != nil && !(error is NSNull)) || row["status"] as? String == "analysis_unavailable" || rejectedFrames
        let verdict: Bool?
        if failed { verdict = nil }
        else if let value = row["fall_detected"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { verdict = value.boolValue }
        else {
            switch vision["caduta"] as? String {
            case "SI": verdict = true
            case "NO": verdict = false
            default: verdict = nil
            }
        }
        let reason: String
        if rejectedFrames {
            reason = "All \(quality.count) frames rejected by image-quality checks; check camera view and lighting"
        } else if failed {
            reason = "Server could not complete visual analysis"
        } else {
            reason = vision["reason"] as? String ?? ""
        }
        return Self(eventId: expectedEventId, fallDetected: verdict,
            reason: reason, receivedAt: Date(),
            triggeredAt: triggeredAt ?? (row["created"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date(),
            receivedUptimeNs: DispatchTime.now().uptimeNanoseconds)
    }
}

public struct CheckInSubmission: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable { case response, noResponse = "no_response" }
    public enum Stage: String, Codable, Sendable { case initial, contact, contactRetry = "contact_retry", decline, declineRetry = "decline_retry", call }
    public let eventId: String
    public let outcome: Outcome
    public let transcript: String?
    public let language: String
    public let stage: Stage?
    public let unansweredPrompts: Int?
    public let personName: String?
    public let location: AlertLocation?
    public var currentStage: Stage { stage ?? .initial }
    public var queueID: String { eventId + (currentStage == .initial ? "" : "-" + currentStage.rawValue) }
    public init(eventId: String, outcome: Outcome, transcript: String?, language: String,
                stage: Stage? = nil, unansweredPrompts: Int? = nil, personName: String? = nil, location: AlertLocation? = nil) {
        self.eventId = eventId; self.outcome = outcome; self.transcript = transcript; self.language = language
        self.stage = stage; self.unansweredPrompts = unansweredPrompts; self.personName = personName; self.location = location
    }
    enum CodingKeys: String, CodingKey {
        case eventId = "event_id", outcome, transcript, language, stage, location
        case unansweredPrompts = "unanswered_prompts", personName = "person_name"
    }
    public func validate() throws {
        let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard ModalRequest.validID(eventId), ["en", "it"].contains(language), text.count <= 4000,
              (0...2).contains(unansweredPrompts ?? 0), (personName?.count ?? 0) <= 120,
              (outcome == .response && !text.isEmpty) || (outcome == .noResponse && text.isEmpty) else { throw DeliveryError.invalidRequest }
        try location?.validate()
    }
}

public struct AlertLocation: Codable, Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let accuracy: Double
    public let captured_at: Double
    public init(latitude: Double, longitude: Double, accuracy: Double, capturedAt: Double) {
        self.latitude = latitude; self.longitude = longitude; self.accuracy = accuracy; self.captured_at = capturedAt
    }
    public func validate() throws {
        guard latitude.isFinite, longitude.isFinite, accuracy.isFinite, captured_at.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              (0...1000).contains(accuracy), captured_at > 0 else { throw DeliveryError.invalidRequest }
    }
}

public struct CheckInReply: Codable, Sendable {
    public let event_id: String
    public let status: String
    public let analysis: AnswerAnalysis?
    public let stage: String?
    public let decision: String?
    public let next_action: String?
    public let notification: NotificationReceipt?
    public struct NotificationReceipt: Codable, Sendable {
        public let channel: String
        public let status: String
    }
    public var displayMessage: String {
        if next_action == "phone_call_handoff" { return "Call requested · open the app to confirm on iPhone" }
        if let notification {
            switch notification.status {
            case "submitted": return "Email submitted · recipient reading not confirmed"
            case "not_configured": return "Email setup missing · alert not sent"
            case "failed": return "Email failed · contact not confirmed"
            default: return "Email delivery unconfirmed · check server status"
            }
        }
        switch next_action {
        case "ask_contact", "ask_contact_again": return "Waiting for email consent"
        case "ask_decline", "ask_decline_again": return "Waiting to confirm no contact"
        case "ask_call": return "Waiting for call preference"
        case "manual_review": return "Follow-up needs attention · no clear consent"
        case "expired": return "Old check-in retained · automatic alert not sent"
        case "done": return "Check-in complete"
        default: return "Reply retained · follow-up pending"
        }
    }
    public struct AnswerAnalysis: Codable, Sendable {
        public let answer_status: String
        public let summary: String
        public let confidence: Double
    }
    public func validate(for submission: CheckInSubmission) throws {
        guard event_id == submission.eventId else { throw DeliveryError.invalidResponse }
        if submission.currentStage != .initial, stage != submission.currentStage.rawValue { throw DeliveryError.invalidResponse }
        if let stage, stage != submission.currentStage.rawValue { throw DeliveryError.invalidResponse }
        if let next_action, !["ask_contact", "ask_contact_again", "ask_decline", "ask_decline_again", "ask_call",
            "phone_call_handoff", "done", "manual_review", "expired", "not_implemented"].contains(next_action) { throw DeliveryError.invalidResponse }
        if submission.outcome == .noResponse {
            guard status == "no_response", analysis == nil else { throw DeliveryError.invalidResponse }
        } else if submission.currentStage != .initial {
            guard status == "decided", analysis == nil, ["yes", "no", "uncertain"].contains(decision ?? "") else { throw DeliveryError.invalidResponse }
        } else {
            guard status == "analyzed", let analysis,
                  ["fine", "needs_help", "uncertain"].contains(analysis.answer_status),
                  analysis.confidence.isFinite, (0...1).contains(analysis.confidence) else { throw DeliveryError.invalidResponse }
        }
    }
}
