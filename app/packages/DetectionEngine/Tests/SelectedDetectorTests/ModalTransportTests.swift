import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ModalTransport

private final class MockState: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: @Sendable (URLRequest) -> (Int, String)] = [:]
    private var requests: [String: [URLRequest]] = [:]
    private var responseHeaders: [String: [String: String]] = [:]
    func set(_ host: String, headers: [String: String] = [:], handler: @escaping @Sendable (URLRequest) -> (Int, String)) {
        lock.lock(); defer { lock.unlock() }; handlers[host] = handler; requests[host] = []; responseHeaders[host] = headers
    }
    func headers(_ host: String) -> [String: String] { lock.lock(); defer { lock.unlock() }; return responseHeaders[host] ?? [:] }
    func respond(_ request: URLRequest) -> (Int, String) {
        lock.lock(); defer { lock.unlock() }
        let host = request.url!.host!
        requests[host, default: []].append(request)
        return handlers[host]!(request)
    }
    func recorded(_ host: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return requests[host] ?? []
    }
}

private final class MockServerProtocol: URLProtocol, @unchecked Sendable {
    static let state = MockState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        // URLSession may turn a body into a stream before URLProtocol receives it.
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        let result = Self.state.respond(captured)
        if result.0 < 0 {
            client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: result.0)))
            return
        }
        var headers = Self.state.headers(request.url!.host!)
        headers["Content-Type"] = request.url!.path == "/check-in/prompt" && result.0 == 200 ? "audio/mpeg" : "application/json"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: result.0,
            httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ModalTransportTests: XCTestCase {
    private let id = "session-test-1"
    private let image = Data([0xff, 0xd8, 1, 2, 3, 0xff, 0xd9]) // Transport fixture only; no live server requests.

    func testFixedQuestionIsCachedBeforeFallWithoutProviderKeyOnPhone() async throws {
        let (root, service, host) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        MockServerProtocol.state.set(host) { _ in (200, "offline-audio-transport-fixture") }
        let first = try await service.checkInPrompt(language: "en")
        let second = try await service.checkInPrompt(language: "en")
        XCTAssertEqual(first, second)
        let requests = MockServerProtocol.state.recorded(host)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.query, "language=en")
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "xi-api-key"))
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "x-api-key"), "test-only-key")
    }

    func testSpokenReplyUsesNewEndpointAndSendsCompleteTranscript() async throws {
        let (root, service, host) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        MockServerProtocol.state.set(host) { request in
            if request.url!.path.hasSuffix("/check-in") {
                return (200, "{\"event_id\":\"session-test-1\",\"status\":\"analyzed\",\"analysis\":{\"answer_status\":\"needs_help\",\"summary\":\"Reports pain\",\"confidence\":0.9}}")
            }
            return (404, "{\"detail\":\"unknown event\"}")
        }
        let text = "Yes, but I think I broke something"
        try await service.queueCheckIn(.init(eventId: id, outcome: .response, transcript: text, language: "en"))
        let requests = MockServerProtocol.state.recorded(host)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/event/session-test-1/check-in")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "x-api-key"), "test-only-key")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(requests.first?.httpBody)) as! [String: Any]
        XCTAssertEqual(body["transcript"] as? String, text)
        let status = try await service.snapshot()
        XCTAssertEqual(status.checkInReply?.analysis?.answer_status, "needs_help")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("check-in-outbox/session-test-1.json").path))
    }

    func testCheckInFailureKeepsTranscriptAndDoesNotImmediatelyRepeatRequest() async throws {
        let (root, service, host) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        MockServerProtocol.state.set(host) { _ in (503, "{\"detail\":\"reply_analysis_unavailable\"}") }
        let submission = CheckInSubmission(eventId: id, outcome: .response, transcript: "My arm hurts", language: "en")
        try await service.queueCheckIn(submission)
        try await service.queueCheckIn(submission)
        XCTAssertEqual(MockServerProtocol.state.recorded(host).count, 1)
        let file = root.appendingPathComponent("check-in-outbox/session-test-1.json")
        XCTAssertEqual(try JSONDecoder().decode(CheckInSubmission.self, from: Data(contentsOf: file)), submission)
    }

    func testLegacyNoResponsePostsNoAttestationOfTwoWindowsAndNoProviderCredentials() async throws {
        let (root, service, host) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        MockServerProtocol.state.set(host) { _ in (200, "{\"event_id\":\"session-test-1\",\"status\":\"no_response\",\"analysis\":null}") }
        try await service.queueCheckIn(.init(eventId: id, outcome: .noResponse, transcript: nil, language: "en"))
        let request = try XCTUnwrap(MockServerProtocol.state.recorded(host).first)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
        XCTAssertEqual(body["outcome"] as? String, "no_response")
        XCTAssertNil(body["unanswered_prompts"])
        XCTAssertTrue(body["transcript"] == nil || body["transcript"] is NSNull)
        XCTAssertNil(request.value(forHTTPHeaderField: "xi-api-key"))
        XCTAssertFalse(request.url!.path.hasSuffix("/answer"))
        XCTAssertFalse(request.url!.path.hasSuffix("/alarm"))
    }

    func testQuestionsHaveSeparateCachesAndRequireMatchingServerProtocol() async throws {
        let (root, service, host) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        MockServerProtocol.state.set(host, headers: ["X-Check-In-Protocol": "2"]) { request in
            (200, request.url?.query ?? "")
        }
        let initial = try await service.checkInPrompt(language: "en")
        let contact = try await service.checkInPrompt(language: "en", kind: "contact")
        _ = try await service.checkInPrompt(language: "en", kind: "contact")
        XCTAssertNotEqual(initial, contact)
        XCTAssertEqual(MockServerProtocol.state.recorded(host).count, 2)
        let (legacyRoot, legacy, oldHost) = try setup(); defer { try? FileManager.default.removeItem(at: legacyRoot) }
        MockServerProtocol.state.set(oldHost) { _ in (200, "old-question") }
        do { _ = try await legacy.checkInPrompt(language: "en", kind: "contact"); XCTFail("Old server cannot supply consent question") }
        catch { }
    }

    func testStagedRepliesStaySeparateAndReplayedConsentDoesNotPostAgain() async throws {
        let (root, service, host) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        MockServerProtocol.state.set(host) { request in
            let row = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            if row["stage"] as? String == "contact" {
                return (200, "{\"event_id\":\"session-test-1\",\"stage\":\"contact\",\"status\":\"decided\",\"decision\":\"yes\",\"next_action\":\"ask_call\",\"notification\":{\"channel\":\"email\",\"status\":\"submitted\"},\"transcript\":\"Yes\"}")
            }
            return (200, "{\"event_id\":\"session-test-1\",\"stage\":\"initial\",\"status\":\"analyzed\",\"next_action\":\"ask_contact\",\"analysis\":{\"answer_status\":\"needs_help\",\"summary\":\"Pain\",\"confidence\":0.9},\"transcript\":\"My leg hurts\"}")
        }
        let initial = CheckInSubmission(eventId: id, outcome: .response, transcript: "My leg hurts", language: "en", stage: .initial)
        let consent = CheckInSubmission(eventId: id, outcome: .response, transcript: "Yes", language: "en", stage: .contact)
        let first = try await service.queueCheckIn(initial)
        let second = try await service.queueCheckIn(consent)
        _ = try await service.queueCheckIn(consent)
        XCTAssertEqual(first?.next_action, "ask_contact")
        XCTAssertEqual(second?.notification?.status, "submitted")
        XCTAssertEqual(MockServerProtocol.state.recorded(host).count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("check-in-responses/\(id).json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("check-in-responses/\(id)-contact.json").path))
        do {
            _ = try await service.queueCheckIn(.init(eventId: id, outcome: .response, transcript: "No", language: "en", stage: .contact))
            XCTFail("Changed consent must not reuse a yes receipt")
        } catch { }
    }

    private func setup(post: Int = 200, exists: Bool = false, authorized: Bool = true, nullError: Bool = false) throws -> (URL, ModalDelivery, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = UUID().uuidString.lowercased() + ".invalid"
        MockServerProtocol.state.set(host) { request in
            if request.url!.path == "/health" { return (200, "{\"ok\":true}") }
            if !authorized { return (401, "{\"detail\":\"unauthorized\"}") }
            if request.url!.path.hasPrefix("/event/fallapp-connection-check-") { return (404, "{\"detail\":\"unknown event\"}") }
            if request.httpMethod == "GET" { return exists ? (200, "{\"event_id\":\"session-test-1\"}") : (404, "{\"detail\":\"unknown event\"}") }
            if post == 200, nullError { return (200, "{\"event_id\":\"session-test-1\",\"error\":null}") }
            return post == 200 ? (200, "{\"event_id\":\"session-test-1\",\"status\":\"accepted\"}") : (post, "{\"detail\":\"temporary error\"}")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockServerProtocol.self]
        let session = URLSession(configuration: configuration)
        let settings = ModalServerSettings(baseURL: URL(string: "https://" + host)!, apiKey: "test-only-key")
        return (root, ModalDelivery(root: root, settings: settings, session: session), host)
    }

    private func queue(_ root: URL, capture: Bool) throws {
        let outbox = root.appendingPathComponent("outbox")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        try Data("{\"eventId\":\"session-test-1\"}".utf8).write(to: outbox.appendingPathComponent(id + ".json"))
        if capture {
            let directory = root.appendingPathComponent("captures/" + id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try image.write(to: directory.appendingPathComponent("frame-0.jpg"))
            let manifest = CaptureManifest(eventId: id, complete: true, frames: ["frame-0.jpg"], durationSeconds: 2, error: nil)
            try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("capture.json"))
        }
    }

    func testMultipartUsesPublishedEndpointHeaderAndRealFrameFields() throws {
        let settings = ModalServerSettings(baseURL: URL(string: "https://example.invalid")!, apiKey: "test-only-key")
        let request = try ModalRequest.analyze(settings: settings, eventId: id,
            frames: [("one.jpg", image), ("two.jpg", image)], boundary: "test-boundary")
        XCTAssertEqual(request.url?.path, "/analyze")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-only-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertEqual(body.components(separatedBy: "name=\"frames\"").count - 1, 2)
        XCTAssertTrue(body.contains("name=\"event_id\"\r\n\r\n" + id))
        XCTAssertTrue(body.contains("name=\"imu_level\"\r\n\r\n1"))
        XCTAssertTrue(body.hasSuffix("--test-boundary--\r\n"))
        XCTAssertFalse(body.contains("test-only-key"))
    }

    func testEmptyFramesAndPathTraversalAreRejected() throws {
        let settings = ModalServerSettings(baseURL: URL(string: "https://example.invalid")!, apiKey: "test-only-key")
        XCTAssertThrowsError(try ModalRequest.analyze(settings: settings, eventId: id, frames: [], boundary: "test"))
        XCTAssertThrowsError(try ModalRequest.analyze(settings: settings, eventId: "../escape", frames: [("image.jpg", image)], boundary: "test"))
    }

    func testOneSecondSevenFrameBurstSendsEveryImageInOrder() async throws {
        let (root, service, host) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        try queue(root, capture: false)
        let directory = root.appendingPathComponent("captures/" + id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = (0..<7).map { "frame-\($0).jpg" }
        for (index, name) in names.enumerated() {
            try Data([0xff, 0xd8, UInt8(index), 0xff, 0xd9]).write(to: directory.appendingPathComponent(name))
        }
        let manifest = CaptureManifest(eventId: id, complete: true, frames: names, durationSeconds: 1, error: nil)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("capture.json"))
        try await service.flush()
        let request = try XCTUnwrap(MockServerProtocol.state.recorded(host).first { $0.httpMethod == "POST" })
        XCTAssertEqual(MockServerProtocol.state.recorded(host).filter { $0.httpMethod == "POST" }.count, 1)
        let body = try XCTUnwrap(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "name=\"frames\"").count - 1, 7)
        XCTAssertTrue(text.contains("name=\"duration_s\"\r\n\r\n1.0"))
        var offset = body.startIndex
        for index in 0..<7 {
            let marker = Data([0xff, 0xd8, UInt8(index), 0xff, 0xd9])
            let range = try XCTUnwrap(body.range(of: marker, in: offset..<body.endIndex))
            offset = range.upperBound
        }
        XCTAssertFalse(text.contains("video/mp4"))
        let status = try await service.snapshot()
        XCTAssertEqual(status.delivered, 1)
    }

    func testOlderOversizedBurstIsRetainedWithoutPostingOverServerLimit() async throws {
        let (root, service, host) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        try queue(root, capture: false)
        let directory = root.appendingPathComponent("captures/" + id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = CaptureManifest(eventId: id, complete: true,
            frames: (0..<30).map { "frame-\($0).jpg" }, durationSeconds: 1, error: nil)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("capture.json"))
        try await service.flush()
        XCTAssertFalse(MockServerProtocol.state.recorded(host).contains { $0.httpMethod == "POST" })
        let status = try await service.snapshot()
        XCTAssertEqual(status.pending, 0)
        XCTAssertEqual(status.blockedCaptures, 1)
        XCTAssertTrue(status.captureQueueMessage.contains("exceeds seven frames"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("capture.json").path))
        let settings = ModalServerSettings(baseURL: URL(string: "https://example.invalid")!, apiKey: "test-only-key")
        XCTAssertThrowsError(try ModalRequest.analyze(settings: settings, eventId: id,
            frames: (0..<8).map { ("frame-\($0).jpg", image) }, boundary: "test"))
    }

    func testAuthenticationUsesReadOnlyChecksAndNoCaptureIsNotUploaded() async throws {
        let (root, service, host) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        try queue(root, capture: false)
        try await service.flush()
        let status = try await service.snapshot()
        XCTAssertTrue(status.authenticated); XCTAssertEqual(status.pending, 1); XCTAssertEqual(status.delivered, 0)
        XCTAssertTrue(MockServerProtocol.state.recorded(host).allSatisfy { $0.httpMethod == "GET" })
    }

    func testRetainedIncompleteCaptureDoesNotReplaceSuccessfulDeliveryStatus() async throws {
        let (root, service, _) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        try queue(root, capture: true)
        let oldID = "old-incomplete"
        try Data("{}".utf8).write(to: root.appendingPathComponent("outbox/" + oldID + ".json"))
        let directory = root.appendingPathComponent("captures/" + oldID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = CaptureManifest(eventId: oldID, complete: false, frames: [], durationSeconds: 0, error: "Camera permission required")
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("capture.json"))
        try await service.flush()
        let first = try await service.snapshot()
        XCTAssertEqual(first.delivered, 1)
        XCTAssertEqual(first.pending, 0)
        XCTAssertEqual(first.blockedCaptures, 1)
        XCTAssertEqual(first.message, "Analysis unavailable · monitoring continues")
        XCTAssertTrue(first.captureQueueMessage.contains("Incomplete capture"))
        try await service.flush()
        let second = try await service.snapshot()
        XCTAssertEqual(second.message, first.message)
        XCTAssertEqual(second.captureQueueMessage, first.captureQueueMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("capture.json").path))
    }

    func testCaptureWithoutManifestBecomesBlockedButLateFramesRecover() async throws {
        let (root, service, host) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        try queue(root, capture: false)
        let notice = root.appendingPathComponent("outbox/" + id + ".json")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-180)], ofItemAtPath: notice.path)
        try await service.flush()
        let blocked = try await service.snapshot()
        XCTAssertEqual(blocked.pending, 0)
        XCTAssertEqual(blocked.blockedCaptures, 1)
        XCTAssertTrue(blocked.captureQueueMessage.contains("capture interrupted"))
        XCTAssertFalse(MockServerProtocol.state.recorded(host).contains { $0.httpMethod == "POST" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: notice.path))
        // A late capture is picked up automatically; its original notice is retained.
        try queue(root, capture: true)
        try await service.flush()
        let recovered = try await service.snapshot()
        XCTAssertEqual(recovered.delivered, 1)
        XCTAssertEqual(recovered.pending, 0)
        XCTAssertEqual(recovered.blockedCaptures, 0)
        XCTAssertEqual(recovered.captureQueueMessage, "")
    }

    func testNewestReadyCaptureIsSentBeforeOldUploadBacklog() async throws {
        let (root, service, host) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        try queue(root, capture: true)
        let oldID = "000-old-ready"
        try Data("{}".utf8).write(to: root.appendingPathComponent("outbox/" + oldID + ".json"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-180)],
            ofItemAtPath: root.appendingPathComponent("outbox/" + oldID + ".json").path)
        let directory = root.appendingPathComponent("captures/" + oldID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try image.write(to: directory.appendingPathComponent("frame-0.jpg"))
        try JSONEncoder().encode(CaptureManifest(eventId: oldID, complete: true, frames: ["frame-0.jpg"], durationSeconds: 1, error: nil))
            .write(to: directory.appendingPathComponent("capture.json"))
        MockServerProtocol.state.set(host) { request in
            if request.url!.path == "/health" { return (200, "{\"ok\":true}") }
            if request.httpMethod != "POST" { return (404, "{\"detail\":\"unknown event\"}") }
            let eventID = request.value(forHTTPHeaderField: "Idempotency-Key")!
            return (200, "{\"event_id\":\"\(eventID)\",\"fall_detected\":false}")
        }
        try await service.flush()
        let posts = MockServerProtocol.state.recorded(host).filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts.first?.value(forHTTPHeaderField: "Idempotency-Key"), id)
        let status = try await service.snapshot()
        XCTAssertEqual(status.delivered, 2)
    }

    func testExplicitCleanupDeletesPendingCapturesAndRepliesButKeepsHistory() throws {
        let (root, _, _) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        try queue(root, capture: true)
        for folder in ["check-in-outbox", "delivered", "server-responses", "captures/delivered-event", "sessions"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let preserved = ["delivered/delivered-event.json", "server-responses/delivered-event.json", "captures/delivered-event/frame.jpg", "sessions/motion.jsonl"]
        for file in preserved { try Data("keep".utf8).write(to: root.appendingPathComponent(file)) }
        // Duplicate queued notice must not remove its delivered image history.
        try Data("{}".utf8).write(to: root.appendingPathComponent("outbox/delivered-event.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("check-in-outbox/pending-reply.json"))
        let result = try ModalQueueMaintenance.clearPending(root: root)
        XCTAssertEqual(result.captureEvents, 2)
        XCTAssertEqual(result.checkInReplies, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("outbox").path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("check-in-outbox").path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("captures/" + id).path))
        for file in preserved { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(file)), Data("keep".utf8)) }
        let repeated = try ModalQueueMaintenance.clearPending(root: root)
        XCTAssertEqual(repeated.captureEvents, 0)
        XCTAssertEqual(repeated.checkInReplies, 0)
    }

    func testExplicitVoiceTestRequiresMarkedPositiveServerEvent() async throws {
        let (root, service, host) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        MockServerProtocol.state.set(host) { request in
            let id = request.url!.lastPathComponent
            return (200, "{\"event_id\":\"\(id)\",\"test_mode\":true,\"fall_detected\":true}")
        }
        let result = try await service.confirmedFallTest()
        XCTAssertEqual(result.fallDetected, true)
        XCTAssertTrue(result.eventId.hasPrefix("test-"))
        let request = try XCTUnwrap(MockServerProtocol.state.recorded(host).first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url!.path.hasPrefix("/test/confirmed-fall/test-"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-only-key")
        MockServerProtocol.state.set(host) { request in
            (200, "{\"event_id\":\"\(request.url!.lastPathComponent)\",\"fall_detected\":true}")
        }
        do { _ = try await service.confirmedFallTest(); XCTFail("Unmarked results cannot pass as test confirmations") }
        catch { }
    }

    func testFreshUploadSkipsLookupAndPersistsAttemptBeforeSending() async throws {
        let (root, service, host) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        try queue(root, capture: true)
        try await service.flush()
        let requests = MockServerProtocol.state.recorded(host)
        XCTAssertFalse(requests.contains { $0.url?.path == "/event/" + id })
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("captures/" + id + "/upload-attempt.json").path))
        let log = try String(contentsOf: root.appendingPathComponent("network.jsonl"), encoding: .utf8)
        XCTAssertTrue(log.contains("elapsedMs"))
        XCTAssertTrue(log.contains("analysis_timing"))
    }

    func testRestoredQueueChecksForAcceptedLegacyUploadWithoutMarker() async throws {
        let (root, _, host) = try setup(exists: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try queue(root, capture: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockServerProtocol.self]
        let restored = ModalDelivery(root: root,
            settings: ModalServerSettings(baseURL: URL(string: "https://" + host)!, apiKey: "test-only-key"),
            session: URLSession(configuration: config))
        try await restored.flush()
        let requests = MockServerProtocol.state.recorded(host)
        XCTAssertTrue(requests.contains { $0.url?.path == "/event/" + id })
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
        let status = try await restored.snapshot()
        XCTAssertEqual(status.delivered, 1)
    }

    func testKeepAliveReusesSessionAndThrottlesNormalIdlePings() async throws {
        let (root, service, host) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let connected = await service.verifyConnection()
        XCTAssertTrue(connected)
        await service.keepConnectionWarm(ifIdleFor: 0)
        await service.keepConnectionWarm()
        let requests = MockServerProtocol.state.recorded(host)
        XCTAssertEqual(requests.filter { $0.url?.path == "/health" }.count, 2)
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
        let log = try String(contentsOf: root.appendingPathComponent("network.jsonl"), encoding: .utf8)
        XCTAssertTrue(log.contains("keep_alive"))
    }

    func testVersionedFixedAudioSurvivesRelaunchAndRefreshesWhenVoiceChanges() async throws {
        let (root, first, host) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldRevision = String(repeating: "a", count: 64)
        let newRevision = String(repeating: "b", count: 64)
        func respond(_ revision: String, audio: String) {
            MockServerProtocol.state.set(host, headers: ["X-Check-In-Protocol": "2", "X-Check-In-Audio-Revision": revision]) { request in
                if request.url!.path == "/health" { return (200, "{\"ok\":true,\"voice_audio_revision\":\"\(revision)\"}") }
                if request.url!.path.hasPrefix("/event/") { return (404, "{\"detail\":\"unknown event\"}") }
                return (200, audio)
            }
        }
        func relaunched() -> ModalDelivery {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockServerProtocol.self]
            return ModalDelivery(root: root, settings: ModalServerSettings(baseURL: URL(string: "https://" + host)!, apiKey: "test-only-key"), session: URLSession(configuration: config))
        }
        respond(oldRevision, audio: "old-voice-fixture")
        _ = await first.verifyConnection()
        let original = try await first.checkInPrompt(language: "en", kind: "contact")
        let restarted = relaunched()
        _ = await restarted.verifyConnection()
        let before = MockServerProtocol.state.recorded(host).filter { $0.url!.path == "/check-in/prompt" }.count
        let cached = try await restarted.checkInPrompt(language: "en", kind: "contact")
        XCTAssertEqual(cached, original)
        XCTAssertEqual(MockServerProtocol.state.recorded(host).filter { $0.url!.path == "/check-in/prompt" }.count, before)
        respond(newRevision, audio: "new-voice-fixture")
        _ = await restarted.verifyConnection()
        let refreshed = try await restarted.checkInPrompt(language: "en", kind: "contact")
        XCTAssertNotEqual(refreshed, cached)
        XCTAssertEqual(MockServerProtocol.state.recorded(host).filter { $0.url!.path == "/check-in/prompt" }.count, 1)
    }

    func testConcurrentFixedPromptRequestsShareOneDownload() async throws {
        let (root, service, host) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        MockServerProtocol.state.set(host, headers: ["X-Check-In-Protocol": "2"]) { _ in (200, "shared-audio-fixture") }
        async let first = service.checkInPrompt(language: "en", kind: "call")
        async let second = service.checkInPrompt(language: "en", kind: "call")
        let values = try await (first, second)
        XCTAssertEqual(values.0, values.1)
        XCTAssertEqual(MockServerProtocol.state.recorded(host).count, 1)
    }

    func testCompleteCaptureMovesOnlyAfterAcceptedResponse() async throws {
        let (root, service, host) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        try queue(root, capture: true)
        try await service.flush()
        let status = try await service.snapshot()
        XCTAssertEqual(status.pending, 0); XCTAssertEqual(status.delivered, 1)
        XCTAssertEqual(MockServerProtocol.state.recorded(host).filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("server-responses/" + id + ".json").path))
    }

    func testServerFailurePreservesPendingEvent() async throws {
        let (root, service, _) = try setup(post: 500); defer { try? FileManager.default.removeItem(at: root) }
        try queue(root, capture: true)
        try await service.flush()
        let status = try await service.snapshot()
        XCTAssertEqual(status.pending, 1); XCTAssertEqual(status.delivered, 0)
        XCTAssertTrue(status.message.contains("500"))
    }

    func testExistingServerEventRecoversLostAcknowledgementWithoutDuplicatePost() async throws {
        let (root, service, host) = try setup(exists: true); defer { try? FileManager.default.removeItem(at: root) }
        try queue(root, capture: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("captures/" + id + "/upload-attempt.json"))
        try await service.flush()
        let status = try await service.snapshot()
        XCTAssertEqual(status.delivered, 1)
        XCTAssertFalse(MockServerProtocol.state.recorded(host).contains { $0.httpMethod == "POST" })
    }

    func testUnauthorizedKeyDoesNotCreateEvent() async throws {
        let (root, service, host) = try setup(authorized: false); defer { try? FileManager.default.removeItem(at: root) }
        try queue(root, capture: true)
        try await service.flush()
        let status = try await service.snapshot()
        XCTAssertFalse(status.authenticated); XCTAssertEqual(status.pending, 1)
        XCTAssertFalse(MockServerProtocol.state.recorded(host).contains { $0.httpMethod == "POST" })
    }

    func testOlderIncompleteCapturesDoNotBlockLaterReadyCapture() async throws {
        let (root, service, host) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        try queue(root, capture: true)
        for index in 0..<8 {
            try Data("{}".utf8).write(to: root.appendingPathComponent("outbox/000-old-\(index).json"))
        }
        try await service.flush()
        let status = try await service.snapshot()
        XCTAssertEqual(status.delivered, 1)
        XCTAssertEqual(status.pending, 8)
        XCTAssertEqual(MockServerProtocol.state.recorded(host).filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testSuccessfulNullErrorResponseIsAccepted() async throws {
        let (root, service, _) = try setup(nullError: true); defer { try? FileManager.default.removeItem(at: root) }
        try queue(root, capture: true)
        try await service.flush()
        let status = try await service.snapshot()
        XCTAssertEqual(status.delivered, 1)
        XCTAssertEqual(status.pending, 0)
    }

    func testRequestContainsActualCapturedDuration() async throws {
        let (root, service, host) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        try queue(root, capture: true)
        let manifest = CaptureManifest(eventId: id, complete: true, frames: ["frame-0.jpg"], durationSeconds: 1.99, error: nil)
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("captures/" + id + "/capture.json"))
        try await service.flush()
        let request = try XCTUnwrap(MockServerProtocol.state.recorded(host).first { $0.httpMethod == "POST" })
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"duration_s\"\r\n\r\n1.99\r\n"))
    }

    func testMalformedOldManifestDoesNotBlockReadyCapture() async throws {
        let (root, service, _) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        try queue(root, capture: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("outbox/000-malformed.json"))
        let directory = root.appendingPathComponent("captures/000-malformed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("capture.json"))
        try await service.flush()
        let status = try await service.snapshot()
        XCTAssertEqual(status.delivered, 1); XCTAssertEqual(status.pending, 0)
        XCTAssertEqual(status.blockedCaptures, 1)
    }

    func testTLSFailureRetainsCaptureAndRecordsPhaseWithoutCredentials() async throws {
        let (root, service, host) = try setup(post: URLError.secureConnectionFailed.rawValue)
        defer { try? FileManager.default.removeItem(at: root) }
        try queue(root, capture: true)
        try await service.flush()
        let status = try await service.snapshot()
        XCTAssertEqual(status.pending, 1); XCTAssertEqual(status.delivered, 0)
        XCTAssertTrue(status.message.contains("TLS connection failed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("captures/" + id + "/frame-0.jpg").path))
        let log = try String(contentsOf: root.appendingPathComponent("network.jsonl"), encoding: .utf8)
        XCTAssertTrue(log.contains("http_error")); XCTAssertTrue(log.contains("analyze")); XCTAssertTrue(log.contains("-1200"))
        XCTAssertFalse(log.contains("test-only-key")); XCTAssertFalse(log.contains("x-api-key"))
        try await service.flush()
        XCTAssertEqual(MockServerProtocol.state.recorded(host).filter { $0.httpMethod == "POST" }.count, 1)
    }
}
