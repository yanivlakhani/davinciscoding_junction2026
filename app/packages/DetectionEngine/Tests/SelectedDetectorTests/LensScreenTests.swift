import Foundation
import XCTest
import ModalTransport

final class LensScreenTests: XCTestCase {
    private func assessment(_ verdict: Any, triggeredAt: Date = Date()) throws -> ServerAssessment {
        try .parse(JSONSerialization.data(withJSONObject: ["event_id": "event-1", "fall_detected": verdict]),
                   expectedEventId: "event-1", triggeredAt: triggeredAt)
    }
    func testLensStaysBlankUnlessFreshVisionConfirmsFall() throws {
        XCTAssertNil(LensScreen.confirmed(try assessment(false)))
        XCTAssertNil(LensScreen.confirmed(try assessment(NSNull())))
        XCTAssertNil(LensScreen.confirmed(try assessment(true, triggeredAt: Date().addingTimeInterval(-90))))
        XCTAssertEqual(LensScreen.confirmed(try assessment(true))?.style, .checkingIn)
        XCTAssertNil(LensPresentationState().screen)
    }
    func testQuestionsMatchCurrentConsentStageAndKeepNegativePolarity() {
        let initial = LensScreen.question("event-1", stage: .initial, activity: .asking)
        let contact = LensScreen.question("event-1", stage: .contact, activity: .asking)
        let decline = LensScreen.question("event-1", stage: .declineRetry, activity: .asking)
        let call = LensScreen.question("event-1", stage: .call, activity: .asking)
        XCTAssertEqual(initial.title, "Are you okay?")
        XCTAssertEqual(contact.title, "Email your contact?")
        XCTAssertEqual(decline.title, "Confirm no email?")
        XCTAssertEqual(call.title, "Call your contact?")
        XCTAssertNil(initial.expiresAfter)
    }
    func testCountdownUsesActualListenStartAndStopsDuringFullReply() {
        let listening = LensScreen.question("event-1", stage: .initial, activity: .listening(seconds: 10), nowNs: 1_000_000_000)
        XCTAssertEqual(listening.remainingReplySeconds(nowNs: 1_000_000_000), 10)
        XCTAssertEqual(listening.remainingReplySeconds(nowNs: 3_100_000_000), 8)
        XCTAssertEqual(listening.remainingReplySeconds(nowNs: 11_100_000_000), 0)
        XCTAssertNil(LensScreen.question("event-1", stage: .initial, activity: .speaking).listeningDeadlineNs)
    }
    func testOnlyAcceptedEmailCanShowSuccessAndLocationClaim() {
        let accepted = LensScreen.receipt("event-1", status: "submitted", locationIncluded: true)
        XCTAssertEqual(accepted.style, .alertSent)
        XCTAssertEqual(accepted.title, "Email submitted")
        XCTAssertTrue(accepted.detail.contains("location included"))
        let noGPS = LensScreen.receipt("event-1", status: "submitted", locationIncluded: false)
        XCTAssertFalse(noGPS.detail.contains("location"))
        for status in ["failed", "delivery_unknown", "not_configured", "sending"] {
            XCTAssertEqual(LensScreen.receipt("event-1", status: status, locationIncluded: true).style, .escalated)
        }
        XCTAssertFalse(accepted.title.contains("Help is coming"))
    }
    func testOldExpiryCannotClearNewQuestionOrNewEvent() {
        var state = LensPresentationState()
        let old = state.show(.cancelled("old-event"))
        state.show(.question("new-event", stage: .call, activity: .asking))
        XCTAssertFalse(state.expire(revision: old))
        XCTAssertEqual(state.screen?.eventID, "new-event")
        XCTAssertFalse(state.expire(revision: state.revision))
        let terminal = state.show(.receipt("new-event", status: "submitted", locationIncluded: false))
        XCTAssertEqual(state.screen?.expiresAfter, 1.5)
        XCTAssertTrue(state.expire(revision: terminal))
        XCTAssertNil(state.screen)
    }
    func testCompletionAfterEmailDoesNotClaimEmailWasCancelledOrCallConnected() {
        let completed = LensScreen.completed("event-1", emailStatus: "submitted")
        XCTAssertEqual(completed.style, .alertSent)
        XCTAssertEqual(completed.title, "Check-in complete")
        XCTAssertEqual(completed.detail, "Email submitted")
        XCTAssertEqual(completed.expiresAfter, 1.5)
        XCTAssertEqual(LensScreen.callHandoff("event-1").title, "Confirm on iPhone")
        XCTAssertEqual(LensScreen.callHandoff("event-1").detail, "Call connection not confirmed")
        XCTAssertTrue(LensScreen.displayTest("test-event").isTest)
    }
}
