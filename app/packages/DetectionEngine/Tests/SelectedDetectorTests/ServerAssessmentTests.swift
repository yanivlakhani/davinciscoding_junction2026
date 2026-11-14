import XCTest
import Foundation
import ModalTransport

final class ServerAssessmentTests: XCTestCase {
    func testThreeSecondDelayIncludesPreparationTimeRatherThanAddingItAgain() {
        XCTAssertEqual(CheckInTiming.remainingQuestionDelay(confirmedAt: 1_000_000_000, now: 2_000_000_000), 2_000_000_000)
        XCTAssertEqual(CheckInTiming.remainingQuestionDelay(confirmedAt: 1_000_000_000, now: 4_000_000_000), 0)
        XCTAssertEqual(CheckInTiming.remainingQuestionDelay(confirmedAt: 1_000_000_000, now: 6_000_000_000), 0)
    }
    private func parse(_ fields: [String: Any]) throws -> ServerAssessment {
        var value = fields; value["event_id"] = "test-1"
        return try .parse(JSONSerialization.data(withJSONObject: value), expectedEventId: "test-1")
    }
    func testSIAndNOAndExplicitBooleansHaveExactMeanings() throws {
        XCTAssertEqual(try parse(["vision": ["caduta": "SI"]]).fallDetected, true)
        XCTAssertEqual(try parse(["vision": ["caduta": "NO"]]).fallDetected, false)
        XCTAssertEqual(try parse(["fall_detected": true]).fallDetected, true)
        XCTAssertEqual(try parse(["fall_detected": false]).fallDetected, false)
    }
    func testFailedOrUnusableAnalysisIsNeverFalse() throws {
        XCTAssertNil(try parse(["vision": ["caduta": NSNull()]]).fallDetected)
        XCTAssertNil(try parse(["vision": ["caduta": "MAYBE"]]).fallDetected)
        XCTAssertNil(try parse(["fall_detected": 1]).fallDetected)
        XCTAssertNil(try parse(["fall_detected": false, "vision_error": "timeout"]).fallDetected)
        XCTAssertNil(try parse(["vision": ["caduta": "SI"], "vision_error": "timeout"]).fallDetected)
    }
    func testQualityRejectionExplainsUnknownAndCannotBecomeNegative() throws {
        let result = try parse(["status": "analysis_unavailable", "fall_detected": false,
            "vision_error": NSNull(), "quality": [["usable": false], ["usable": false]]])
        XCTAssertNil(result.fallDetected)
        XCTAssertTrue(result.reason.contains("All 2 frames rejected"))
        XCTAssertNil(try parse(["status": "analysis_unavailable", "fall_detected": false]).fallDetected)
        XCTAssertEqual(try parse(["fall_detected": false, "quality": [["usable": true]]]).fallDetected, false)
    }
    func testDarkFramesAnalyzedByClaudeKeepItsVerdict() throws {
        for fall in [true, false] {
            let result = try parse(["fall_detected": fall, "vision": ["usable_frames": 7, "reason": "Model assessment"],
                "quality": Array(repeating: ["usable": false], count: 7)])
            XCTAssertEqual(result.fallDetected, fall)
            XCTAssertEqual(result.reason, "Model assessment")
        }
    }
    func testMismatchedEventCannotTriggerAnotherPersonsCheckIn() throws {
        let data = Data("{\"event_id\":\"other\",\"vision\":{\"caduta\":\"SI\"}}".utf8)
        XCTAssertThrowsError(try ServerAssessment.parse(data, expectedEventId: "test-1"))
    }
    func testJournalClaimsOnceAcrossInstancesAndKeepsTranscriptSeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assessment = try parse(["vision": ["caduta": "SI"]])
        let journal = CheckInJournal(root: root)
        let first = try await journal.claim(assessment)
        let second = try await journal.claim(assessment)
        XCTAssertTrue(first); XCTAssertFalse(second)
        try await journal.save(assessment, state: "reply_queued", transcript: "Yes, but my arm hurts")
        let relaunched = CheckInJournal(root: root)
        let replay = try await relaunched.claim(assessment)
        XCTAssertFalse(replay)
        let file = root.appendingPathComponent("check-ins/test-1.json")
        let row = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(row["transcript"] as? String, "Yes, but my arm hurts")
    }
    func testResponseAndSilencePayloadsCannotBeConfused() throws {
        XCTAssertNoThrow(try CheckInSubmission(eventId: "test-1", outcome: .response,
            transcript: "Yes, but I think I broke something", language: "en").validate())
        XCTAssertNoThrow(try CheckInSubmission(eventId: "test-1", outcome: .noResponse, transcript: nil, language: "en").validate())
        XCTAssertThrowsError(try CheckInSubmission(eventId: "test-1", outcome: .response, transcript: " ", language: "en").validate())
        XCTAssertThrowsError(try CheckInSubmission(eventId: "test-1", outcome: .noResponse, transcript: "I need help", language: "en").validate())
        XCTAssertThrowsError(try CheckInSubmission(eventId: "../bad", outcome: .response, transcript: "yes", language: "en").validate())
    }
    func testInvalidReplyAnalysisCannotBeAcceptedAsComplete() throws {
        let data = Data("{\"event_id\":\"test-1\",\"status\":\"analyzed\",\"analysis\":{\"answer_status\":\"fine\",\"summary\":\"fixture\",\"confidence\":2}}".utf8)
        let reply = try JSONDecoder().decode(CheckInReply.self, from: data)
        let submission = CheckInSubmission(eventId: "test-1", outcome: .response, transcript: "I am okay", language: "en")
        XCTAssertThrowsError(try reply.validate(for: submission))
    }
}
