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
    func set(_ host: String, handler: @escaping @Sendable (URLRequest) -> (Int, String)) {
        lock.lock(); defer { lock.unlock() }; handlers[host] = handler; requests[host] = []
    }
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
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: result.0,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ModalTransportTests: XCTestCase {
    private let id = "session-test-1"
    private let image = Data([0xff, 0xd8, 1, 2, 3, 0xff, 0xd9]) // Transport fixture only; no live server requests.

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
        XCTAssertEqual(status.pending, 1)
        XCTAssertTrue(status.message.contains("exceeds seven frames"))
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
        XCTAssertEqual(status.delivered, 1); XCTAssertEqual(status.pending, 1)
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
