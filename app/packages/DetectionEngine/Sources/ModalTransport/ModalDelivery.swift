import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ModalServerSettings: Sendable {
    public let baseURL: URL
    public let apiKey: String
    public init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL; self.apiKey = apiKey
    }
}

public struct DeliveryStatus: Sendable {
    public var pending = 0
    public var delivered = 0
    public var authenticated = false
    public var message = "Server setup pending"
    public var checkInReply: CheckInReply?
    public var checkInMessage = ""
    public init() {}
}

public struct CaptureManifest: Codable, Sendable {
    public let eventId: String
    public let complete: Bool
    public let frames: [String]
    public let durationSeconds: Double
    public let error: String?
    public init(eventId: String, complete: Bool, frames: [String], durationSeconds: Double, error: String?) {
        self.eventId = eventId; self.complete = complete; self.frames = frames
        self.durationSeconds = durationSeconds; self.error = error
    }
}

public enum ModalRequest {
    public static let maximumFrames = 7
    public static func analyze(settings: ModalServerSettings, eventId: String, frames: [(String, Data)], boundary: String, durationSeconds: Double = 1) throws -> URLRequest {
        guard settings.baseURL.scheme == "https", settings.baseURL.host != nil,
              settings.baseURL.user == nil, settings.baseURL.password == nil,
              !settings.apiKey.isEmpty, !frames.isEmpty, frames.count <= maximumFrames,
              validID(eventId), durationSeconds.isFinite, durationSeconds > 0 else {
            throw DeliveryError.invalidRequest
        }
        var body = Data()
        func append(_ value: String) { body.append(Data(value.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"event_id\"\r\n\r\n\(eventId)\r\n")
        // Published OpenAPI default, not an invented severity mapping.
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"imu_level\"\r\n\r\n1\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"duration_s\"\r\n\r\n\(durationSeconds)\r\n")
        for (index, frame) in frames.enumerated() {
            guard frame.1.starts(with: [0xff, 0xd8]) else { throw DeliveryError.invalidRequest }
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"frames\"; filename=\"frame-\(index).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
            body.append(frame.1); append("\r\n")
        }
        append("--\(boundary)--\r\n")
        var request = URLRequest(url: settings.baseURL.appendingPathComponent("analyze"))
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(eventId, forHTTPHeaderField: "Idempotency-Key")
        return request
    }

    public static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 160 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

public enum DeliveryError: Error {
    case invalidRequest, invalidResponse, unauthorized, server(Int)
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    private let log: NetworkLog?
    private let requestID: String
    init(log: NetworkLog? = nil, requestID: String = "") { self.log = log; self.requestID = requestID }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward the API key to a redirected host.
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        for transaction in metrics.transactionMetrics {
            var row = ["requestID": requestID, "connectionReused": String(transaction.isReusedConnection),
                       "protocol": transaction.networkProtocolName ?? "unknown"]
            func duration(_ name: String, _ start: Date?, _ end: Date?) {
                if let start, let end { row[name] = String(end.timeIntervalSince(start) * 1000) }
            }
            duration("dnsMs", transaction.domainLookupStartDate, transaction.domainLookupEndDate)
            duration("connectMs", transaction.connectStartDate, transaction.connectEndDate)
            duration("tlsMs", transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
            duration("sendMs", transaction.requestStartDate, transaction.requestEndDate)
            duration("serverWaitMs", transaction.requestEndDate, transaction.responseStartDate)
            if transaction.secureConnectionStartDate != nil { row["tlsCompleted"] = String(transaction.secureConnectionEndDate != nil) }
            log?.record("http_metrics", fields: row)
        }
    }
}

/// Camera-dependent events stay queued until a complete real capture is present.
public actor ModalDelivery {
    public nonisolated let assessments: AsyncStream<ServerAssessment>
    private let assessmentContinuation: AsyncStream<ServerAssessment>.Continuation
    private let root: URL
    private let settings: ModalServerSettings?
    private let session: URLSession
    private let networkLog: NetworkLog
    private var sending = false
    private var authenticated = false
    private var message: String
    private var nextAttempt: [String: Date] = [:]
    private var checkInReply: CheckInReply?
    private var checkInMessage = ""
    private var sendingCheckIn = false
    private var checkInRetryAfter: [String: Date] = [:]
    private var questionAudio: [String: Data] = [:]

    public init(root: URL, settings: ModalServerSettings?, configurationMessage: String = "Server setup pending", session: URLSession? = nil) {
        let events = AsyncStream<ServerAssessment>.makeStream()
        assessments = events.stream; assessmentContinuation = events.continuation
        self.root = root; self.settings = settings; self.message = configurationMessage
        networkLog = NetworkLog(root: root)
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 90
            configuration.timeoutIntervalForResource = 120
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        }
    }

    public func snapshot() throws -> DeliveryStatus {
        var result = DeliveryStatus()
        result.pending = try files("outbox").count; result.delivered = try files("delivered").count
        result.authenticated = authenticated; result.message = message
        result.checkInReply = checkInReply; result.checkInMessage = checkInMessage
        return result
    }

    @discardableResult public func verifyConnection() async -> Bool {
        guard let settings else { return false }
        do {
            let (healthData, health) = try await perform(URLRequest(url: settings.baseURL.appendingPathComponent("health")), phase: "health")
            guard (health as? HTTPURLResponse)?.statusCode == 200,
                  let body = try JSONSerialization.jsonObject(with: healthData) as? [String: Any], body["ok"] as? Bool == true else {
                throw DeliveryError.invalidResponse
            }
            var request = URLRequest(url: settings.baseURL.appendingPathComponent("event/fallapp-connection-check-" + UUID().uuidString))
            request.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
            let (data, response) = try await perform(request, phase: "authentication")
            let status = (response as? HTTPURLResponse)?.statusCode
            if status == 401 || status == 403 { throw DeliveryError.unauthorized }
            guard status == 404, let detail = try JSONSerialization.jsonObject(with: data) as? [String: String], detail["detail"] == "unknown event" else {
                throw DeliveryError.invalidResponse
            }
            authenticated = true; message = "Connected · ready for fall captures"
        } catch DeliveryError.unauthorized {
            authenticated = false; message = "Server rejected API key"
        } catch {
            authenticated = false; message = "Server unavailable · events stay queued"
        }
        saveConnectionStatus()
        await networkLog.drain()
        return authenticated
    }

    public func flush() async throws {
        guard !sending, let settings else { return }
        sending = true; defer { sending = false }
        if !authenticated, !(await verifyConnection()) { return }
        let completed = root.appendingPathComponent("delivered", isDirectory: true)
        let responses = root.appendingPathComponent("server-responses", isDirectory: true)
        try FileManager.default.createDirectory(at: completed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true)
        var attempted = 0
        for file in try files("outbox") {
            guard attempted < 8 else { break }
            let id = file.deletingPathExtension().lastPathComponent
            guard ModalRequest.validID(id) else { message = "Invalid queued event ID"; continue }
            if let next = nextAttempt[id], next > Date() { continue }
            let capture = root.appendingPathComponent("captures", isDirectory: true).appendingPathComponent(id, isDirectory: true)
            let manifestFile = capture.appendingPathComponent("capture.json")
            guard FileManager.default.fileExists(atPath: manifestFile.path) else {
                message = "Connected · waiting for camera frames"; continue
            }
            guard let manifest = try? JSONDecoder().decode(CaptureManifest.self, from: Data(contentsOf: manifestFile)) else {
                message = "Invalid capture manifest · event stays queued"; continue
            }
            guard manifest.eventId == id, manifest.complete, !manifest.frames.isEmpty,
                  manifest.durationSeconds.isFinite, manifest.durationSeconds > 0 else {
                message = "Capture incomplete · event stays queued"; continue
            }
            guard manifest.frames.count <= ModalRequest.maximumFrames else {
                message = "Archived capture exceeds seven frames · retained locally"; continue
            }
            attempted += 1
            do {
                // Recover a previous accepted request after a lost response.
                var lookup = URLRequest(url: settings.baseURL.appendingPathComponent("event/" + id))
                lookup.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
                let (existing, lookupResponse) = try await perform(lookup, phase: "event_lookup", eventID: id)
                let lookupStatus = (lookupResponse as? HTTPURLResponse)?.statusCode ?? 0
                let responseData: Data
                if lookupStatus == 200 { responseData = existing }
                else {
                    if lookupStatus == 401 || lookupStatus == 403 { throw DeliveryError.unauthorized }
                    guard lookupStatus == 404 else { throw DeliveryError.server(lookupStatus) }
                    let frames = try manifest.frames.map { name -> (String, Data) in
                        guard name.hasSuffix(".jpg"), !name.contains("/"), !name.contains("..") else { throw DeliveryError.invalidRequest }
                        return (name, try Data(contentsOf: capture.appendingPathComponent(name)))
                    }
                    let request = try ModalRequest.analyze(settings: settings, eventId: id, frames: frames, boundary: "FallApp-" + UUID().uuidString,
                                                          durationSeconds: manifest.durationSeconds)
                    networkLog.record("frame_upload", fields: ["eventID": id, "frameCount": String(frames.count),
                        "durationSeconds": String(manifest.durationSeconds), "bodyBytes": String(request.httpBody?.count ?? 0)])
                    let (data, response) = try await perform(request, phase: "analyze", eventID: id)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 401 || code == 403 { throw DeliveryError.unauthorized }
                    guard (200..<300).contains(code) else { throw DeliveryError.server(code) }
                    responseData = data
                }
                guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                    throw DeliveryError.invalidResponse
                }
                if let error = response["error"], !(error is NSNull), (error as? Bool) != false {
                    throw DeliveryError.invalidResponse
                }
                let notice = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
                let triggeredAt = (notice?["detectedAtUTC"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                let assessment = try ServerAssessment.parse(responseData, expectedEventId: id, triggeredAt: triggeredAt)
                try responseData.write(to: responses.appendingPathComponent(id + ".json"), options: .atomic)
                try FileManager.default.moveItem(at: file, to: completed.appendingPathComponent(file.lastPathComponent))
                nextAttempt[id] = nil
                message = assessment.fallDetected == true ? "Fall confirmed by server" :
                    (assessment.fallDetected == false ? "No fall · monitoring continues" : "Analysis unavailable · monitoring continues")
                assessmentContinuation.yield(assessment)
            } catch DeliveryError.unauthorized {
                authenticated = false; message = "Server rejected API key · event stays queued"; return
            } catch DeliveryError.server(let code) {
                message = "Server HTTP \(code) · event stays queued"; nextAttempt[id] = Date().addingTimeInterval(30)
            } catch let error as URLError {
                let tls: Set<URLError.Code> = [.secureConnectionFailed, .serverCertificateHasBadDate,
                    .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                    .clientCertificateRejected, .clientCertificateRequired]
                message = tls.contains(error.code) ? "TLS connection failed · frames saved; retry queued"
                    : (error.code == .timedOut ? "Request timed out · frames saved; retry queued" : "Network unavailable · frames saved; retry queued")
                nextAttempt[id] = Date().addingTimeInterval(30)
            } catch {
                message = "Upload unavailable · event stays queued"; nextAttempt[id] = Date().addingTimeInterval(30)
            }
        }
        await flushCheckIns()
        saveConnectionStatus()
        await networkLog.drain()
    }

    public func checkInPrompt(language: String, kind: String = "check_in") async throws -> Data {
        guard let settings, ["en", "it"].contains(language),
              ["check_in", "contact", "decline", "call", "email_submitted", "email_failed", "call_handoff"].contains(kind) else { throw DeliveryError.invalidRequest }
        let cacheKey = language + "-" + kind
        if let cached = questionAudio[cacheKey] { return cached }
        var components = URLComponents(url: settings.baseURL.appendingPathComponent("check-in/prompt"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "language", value: language)]
        if kind != "check_in" { components.queryItems?.append(.init(name: "kind", value: kind)) }
        var request = URLRequest(url: components.url!)
        request.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
        let (data, response) = try await perform(request, phase: "check_in_prompt")
        if (response as? HTTPURLResponse)?.statusCode == 503 { throw CheckInError.voiceUnavailable }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("audio/") == true,
              (kind == "check_in" || http.value(forHTTPHeaderField: "X-Check-In-Protocol") == "2"),
              !data.isEmpty, data.count <= 2 * 1024 * 1024 else { throw DeliveryError.invalidResponse }
        questionAudio[cacheKey] = data
        return data
    }

    @discardableResult public func queueCheckIn(_ submission: CheckInSubmission) async throws -> CheckInReply? {
        try submission.validate()
        if let completed = try savedCheckInReply(for: submission) { return completed }
        let directory = root.appendingPathComponent("check-in-outbox")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        let file = directory.appendingPathComponent(submission.queueID + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            guard try JSONDecoder().decode(CheckInSubmission.self, from: Data(contentsOf: file)) == submission else { throw DeliveryError.invalidRequest }
        } else { try JSONEncoder().encode(submission).write(to: file, options: .atomic) }
        await flushCheckIns()
        return try savedCheckInReply(for: submission)
    }

    public func savedCheckInReply(for submission: CheckInSubmission) throws -> CheckInReply? {
        let file = root.appendingPathComponent("check-in-responses").appendingPathComponent(submission.queueID + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        if let row = try JSONSerialization.jsonObject(with: data) as? [String: Any], let text = row["transcript"] as? String,
           text != (submission.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines) { throw DeliveryError.invalidRequest }
        let reply = try JSONDecoder().decode(CheckInReply.self, from: data)
        try reply.validate(for: submission)
        return reply
    }

    private func flushCheckIns() async {
        guard !sendingCheckIn, let settings else { return }
        sendingCheckIn = true; defer { sendingCheckIn = false }
        do {
            let responses = root.appendingPathComponent("check-in-responses")
            try FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true)
            for file in try files("check-in-outbox") {
                let submission = try JSONDecoder().decode(CheckInSubmission.self, from: Data(contentsOf: file))
                try submission.validate()
                if let next = checkInRetryAfter[submission.queueID], next > Date() { continue }
                do {
                    var request = URLRequest(url: settings.baseURL.appendingPathComponent("event/" + submission.eventId + "/check-in"))
                    request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(submission)
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue(submission.queueID + "-check-in", forHTTPHeaderField: "Idempotency-Key")
                    let (data, response) = try await perform(request, phase: "check_in_answer", eventID: submission.eventId)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(code) else { throw DeliveryError.server(code) }
                    let reply = try JSONDecoder().decode(CheckInReply.self, from: data)
                    try reply.validate(for: submission)
                    try data.write(to: responses.appendingPathComponent(file.lastPathComponent), options: .atomic)
                    try FileManager.default.removeItem(at: file)
                    checkInReply = reply; checkInRetryAfter[submission.queueID] = nil
                    checkInMessage = reply.displayMessage
                } catch {
                    checkInMessage = "Check-in upload pending · transcript retained"
                    checkInRetryAfter[submission.queueID] = Date().addingTimeInterval(30)
                }
            }
        } catch { checkInMessage = "Check-in queue needs attention" }
    }

    private func perform(_ request: URLRequest, phase: String, eventID: String = "") async throws -> (Data, URLResponse) {
        let id = UUID().uuidString
        let context = ["requestID": id, "phase": phase, "eventId": eventID]
        networkLog.record("http_begin", fields: context)
        do {
            let response = try await session.data(for: request, delegate: NoRedirect(log: networkLog, requestID: id))
            var row = context; row["status"] = String((response.1 as? HTTPURLResponse)?.statusCode ?? 0)
            networkLog.record("http_end", fields: row)
            return response
        } catch {
            let underlying = error as NSError
            var row = context; row["errorDomain"] = underlying.domain; row["errorCode"] = String(underlying.code)
            if let nested = underlying.userInfo[NSUnderlyingErrorKey] as? NSError {
                row["underlyingDomain"] = nested.domain; row["underlyingCode"] = String(nested.code)
            }
            networkLog.record("http_error", fields: row)
            throw error
        }
    }

    private func files(_ name: String) throws -> [URL] {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func saveConnectionStatus() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let status = try snapshot()
            let row: [String: Any] = ["authenticated": authenticated, "message": message,
                "pending": status.pending, "delivered": status.delivered,
                "checkedAtUTC": ISO8601DateFormatter().string(from: Date())]
            try JSONSerialization.data(withJSONObject: row).write(to: root.appendingPathComponent("server-status.json"), options: .atomic)
        } catch { /* Status export is diagnostic; outbox durability is independent. */ }
    }
}
