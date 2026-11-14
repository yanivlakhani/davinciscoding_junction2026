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
    public var blockedCaptures = 0
    public var captureQueueMessage = ""
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
    private var lastNetworkActivity = Date.distantPast
    private var warmingConnection = false
    private let restoredEventIDs: Set<String>
    private var sending = false
    private var authenticated = false
    private var message: String
    private var blockedCaptureIDs: Set<String> = []
    private var captureQueueMessage = ""
    private var nextAttempt: [String: Date] = [:]
    private var checkInReply: CheckInReply?
    private var checkInMessage = ""
    private var sendingCheckIn = false
    private var checkInRetryAfter: [String: Date] = [:]
    private var questionAudio: [String: Data] = [:]
    private var audioRevision: String?
    private var questionLoads: [String: Task<Data, Error>] = [:]

    public init(root: URL, settings: ModalServerSettings?, configurationMessage: String = "Server setup pending", session: URLSession? = nil) {
        let events = AsyncStream<ServerAssessment>.makeStream()
        assessments = events.stream; assessmentContinuation = events.continuation
        self.root = root; self.settings = settings; self.message = configurationMessage
        networkLog = NetworkLog(root: root)
        let restored = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("outbox"), includingPropertiesForKeys: nil)) ?? []
        restoredEventIDs = Set(restored.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent })
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
        let queuedIDs = Set(try files("outbox").map { $0.deletingPathExtension().lastPathComponent })
        result.blockedCaptures = queuedIDs.intersection(blockedCaptureIDs).count
        result.pending = queuedIDs.count - result.blockedCaptures
        result.delivered = try files("delivered").count
        result.authenticated = authenticated; result.message = message
        result.captureQueueMessage = captureQueueMessage
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
            acceptAudioRevision(body["voice_audio_revision"] as? String)
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
        let ready = try refreshCaptureQueue()
        if !authenticated, !(await verifyConnection()) { return }
        // A spoken follow-up should not wait behind an older image upload.
        await flushCheckIns()
        let completed = root.appendingPathComponent("delivered", isDirectory: true)
        let responses = root.appendingPathComponent("server-responses", isDirectory: true)
        try FileManager.default.createDirectory(at: completed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true)
        var attempted = 0
        for (file, manifest) in ready {
            guard attempted < 8 else { break }
            let id = file.deletingPathExtension().lastPathComponent
            if let next = nextAttempt[id], next > Date() { continue }
            let capture = root.appendingPathComponent("captures", isDirectory: true).appendingPathComponent(id, isDirectory: true)
            attempted += 1
            do {
                let attemptFile = capture.appendingPathComponent("upload-attempt.json")
                var recovered: Data?
                // Fresh captures POST directly. Persisted attempts and restored
                // notices need a lookup to recover a potentially lost response.
                if FileManager.default.fileExists(atPath: attemptFile.path) || restoredEventIDs.contains(id) {
                    var lookup = URLRequest(url: settings.baseURL.appendingPathComponent("event/" + id))
                    lookup.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
                    let (existing, response) = try await perform(lookup, phase: "event_lookup", eventID: id)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 200 { recovered = existing }
                    else if code == 401 || code == 403 { throw DeliveryError.unauthorized }
                    else if code != 404 { throw DeliveryError.server(code) }
                }
                let responseData: Data
                if let recovered { responseData = recovered }
                else {
                    let frames = try manifest.frames.map { name -> (String, Data) in
                        guard name.hasSuffix(".jpg"), !name.contains("/"), !name.contains("..") else { throw DeliveryError.invalidRequest }
                        return (name, try Data(contentsOf: capture.appendingPathComponent(name)))
                    }
                    let request = try ModalRequest.analyze(settings: settings, eventId: id, frames: frames, boundary: "FallApp-" + UUID().uuidString,
                                                          durationSeconds: manifest.durationSeconds)
                    networkLog.record("frame_upload", fields: ["eventID": id, "frameCount": String(frames.count),
                        "durationSeconds": String(manifest.durationSeconds), "bodyBytes": String(request.httpBody?.count ?? 0)])
                    // Record before sending so a restart never blindly reposts
                    // a request that may already have been accepted.
                    try Data("{}".utf8).write(to: attemptFile, options: .atomic)
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
                var timing = ["eventID": id, "recoveredResponse": String(recovered != nil)]
                for key in ["latency_queue_and_lookup_ms", "latency_preprocess_ms", "latency_model_ms", "latency_store_ms", "latency_server_ms", "processing_ms"] {
                    if let value = response[key] as? NSNumber { timing[key] = value.stringValue }
                }
                if let version = response["prompt_version"] as? String { timing["promptVersion"] = version }
                networkLog.record("analysis_timing", fields: timing)
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
        saveConnectionStatus()
        await networkLog.drain()
    }

    /// Best effort: iOS or the server can still close idle sockets. The same
    /// URLSession is reused, and metrics report whether a connection was reused.
    public func keepConnectionWarm(ifIdleFor seconds: TimeInterval = 45) async {
        guard let settings, authenticated, !sending, !sendingCheckIn, !warmingConnection,
              Date().timeIntervalSince(lastNetworkActivity) >= seconds else { return }
        warmingConnection = true; defer { warmingConnection = false }
        var request = URLRequest(url: settings.baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 5
        do {
            let (data, response) = try await perform(request, phase: "keep_alive")
            if (response as? HTTPURLResponse)?.statusCode == 200,
               let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                acceptAudioRevision(body["voice_audio_revision"] as? String)
            } else { networkLog.record("keep_alive_failed", fields: [:]) }
        } catch { networkLog.record("keep_alive_failed", fields: [:]) }
        await networkLog.drain()
    }

    /// Failed captures have nothing to upload. Keep their original evidence locally,
    /// but exclude them from the upload count. Rescan so a repaired/late manifest
    /// automatically becomes eligible without deleting or recreating the notice.
    private func refreshCaptureQueue() throws -> [(URL, CaptureManifest)] {
        let notices = try files("outbox")
        var queued: [(URL, Date)] = notices.map { file in
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            return (file, values?.contentModificationDate ?? Date.distantPast)
        }
        queued.sort { left, right in
            if left.1 == right.1 { return left.0.lastPathComponent < right.0.lastPathComponent }
            return left.1 > right.1
        }
        let previousBlocked = blockedCaptureIDs
        blockedCaptureIDs = []
        var issues: [String] = []
        var ready: [(URL, CaptureManifest)] = []
        for (file, modified) in queued {
            let id = file.deletingPathExtension().lastPathComponent
            func blocked(_ reason: String) {
                blockedCaptureIDs.insert(id); issues.append(reason)
                if !previousBlocked.contains(id) {
                    networkLog.record("capture_blocked", fields: ["eventID": id, "reason": reason])
                }
            }
            guard ModalRequest.validID(id) else { blocked("Invalid queued event ID"); continue }
            let directory = root.appendingPathComponent("captures").appendingPathComponent(id)
            let manifestFile = directory.appendingPathComponent("capture.json")
            guard FileManager.default.fileExists(atPath: manifestFile.path) else {
                if Date().timeIntervalSince(modified) > 120 { blocked("No frames saved · capture interrupted") }
                else { issues.append("Waiting for camera frames") }
                continue
            }
            guard let manifest = try? JSONDecoder().decode(CaptureManifest.self, from: Data(contentsOf: manifestFile)) else {
                blocked("Invalid capture manifest"); continue
            }
            guard manifest.eventId == id, manifest.complete, !manifest.frames.isEmpty,
                  manifest.durationSeconds.isFinite, manifest.durationSeconds > 0 else {
                blocked("Incomplete capture"); continue
            }
            guard manifest.frames.count <= ModalRequest.maximumFrames else {
                blocked("Archived capture exceeds seven frames"); continue
            }
            ready.append((file, manifest))
        }
        captureQueueMessage = Dictionary(grouping: issues, by: { $0 }).sorted { $0.key < $1.key }
            .map { "\($0.value.count) × \($0.key)" }.joined(separator: " · ")
        return ready
    }

    /// Explicit synthetic confirmation; normal captured events use /analyze.
    public func confirmedFallTest() async throws -> ServerAssessment {
        guard let settings else { throw DeliveryError.invalidRequest }
        let id = "test-" + UUID().uuidString
        var request = URLRequest(url: settings.baseURL.appendingPathComponent("test/confirmed-fall/" + id))
        request.httpMethod = "POST"
        request.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
        let (data, response) = try await perform(request, phase: "confirmed_fall_test", eventID: id)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw DeliveryError.unauthorized }
        guard (200..<300).contains(code),
              let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              row["test_mode"] as? Bool == true else { throw DeliveryError.invalidResponse }
        let assessment = try ServerAssessment.parse(data, expectedEventId: id, triggeredAt: Date())
        guard assessment.fallDetected == true else { throw DeliveryError.invalidResponse }
        let responses = root.appendingPathComponent("server-responses")
        try FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true)
        try data.write(to: responses.appendingPathComponent(id + ".json"), options: .atomic)
        message = "TEST · simulated fall confirmed"
        saveConnectionStatus()
        await networkLog.drain()
        return assessment
    }

    public func preloadCheckInPrompts(language: String) async throws {
        if !authenticated, !(await verifyConnection()) { throw DeliveryError.invalidResponse }
        for kind in ["check_in", "contact", "decline", "call", "email_submitted", "email_failed", "call_handoff"] {
            try Task.checkCancellation()
            _ = try await checkInPrompt(language: language, kind: kind)
        }
    }

    private func acceptAudioRevision(_ revision: String?) {
        let valid = revision.flatMap { value in
            value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } ? value : nil
        }
        if valid != audioRevision { questionAudio.removeAll(); audioRevision = valid }
    }

    private func audioCacheFile(_ key: String) -> URL? {
        guard let audioRevision else { return nil }
        return root.appendingPathComponent("prompt-audio").appendingPathComponent(audioRevision).appendingPathComponent(key + ".mp3")
    }

    public func checkInPrompt(language: String, kind: String = "check_in") async throws -> Data {
        guard settings != nil, ["en", "it"].contains(language),
              ["check_in", "contact", "decline", "call", "email_submitted", "email_failed", "call_handoff"].contains(kind) else { throw DeliveryError.invalidRequest }
        let key = language + "-" + kind
        if let cached = questionAudio[key] {
            networkLog.record("prompt_cache_hit", fields: ["source": "memory", "kindName": kind]); return cached
        }
        if let file = audioCacheFile(key), let cached = try? Data(contentsOf: file), !cached.isEmpty, cached.count <= 2 * 1024 * 1024 {
            questionAudio[key] = cached
            networkLog.record("prompt_cache_hit", fields: ["source": "disk", "kindName": kind]); return cached
        }
        let loadKey = (audioRevision ?? "unversioned") + "-" + key
        if let load = questionLoads[loadKey] { return try await load.value }
        let load = Task { try await self.fetchCheckInPrompt(language: language, kind: kind, key: key) }
        questionLoads[loadKey] = load
        defer { questionLoads[loadKey] = nil }
        return try await load.value
    }

    private func fetchCheckInPrompt(language: String, kind: String, key: String) async throws -> Data {
        guard let settings else { throw DeliveryError.invalidRequest }
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
        acceptAudioRevision(http.value(forHTTPHeaderField: "X-Check-In-Audio-Revision"))
        questionAudio[key] = data
        if let file = audioCacheFile(key) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            #if os(iOS)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            #endif
        }
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
        let started = DispatchTime.now().uptimeNanoseconds
        lastNetworkActivity = Date()
        defer { lastNetworkActivity = Date() }
        let context = ["requestID": id, "phase": phase, "eventId": eventID]
        networkLog.record("http_begin", fields: context)
        do {
            let response = try await session.data(for: request, delegate: NoRedirect(log: networkLog, requestID: id))
            var row = context; row["status"] = String((response.1 as? HTTPURLResponse)?.statusCode ?? 0)
            row["elapsedMs"] = String(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            networkLog.record("http_end", fields: row)
            return response
        } catch {
            let underlying = error as NSError
            var row = context; row["errorDomain"] = underlying.domain; row["errorCode"] = String(underlying.code)
            row["elapsedMs"] = String(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
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
                "pending": status.pending, "delivered": status.delivered, "blockedCaptures": status.blockedCaptures,
                "captureQueueMessage": captureQueueMessage,
                "checkedAtUTC": ISO8601DateFormatter().string(from: Date())]
            try JSONSerialization.data(withJSONObject: row).write(to: root.appendingPathComponent("server-status.json"), options: .atomic)
        } catch { /* Status export is diagnostic; outbox durability is independent. */ }
    }
}

/// Explicit local test maintenance. Call only before creating the delivery actor
/// or starting capture tasks; no upload or recording may be in flight.
public enum ModalQueueMaintenance {
    public struct Cleared: Codable, Sendable {
        public let captureEvents: Int
        public let checkInReplies: Int
    }

    public static func clearPending(root: URL) throws -> Cleared {
        let manager = FileManager.default
        func notices(_ directory: String) throws -> [URL] {
            let path = root.appendingPathComponent(directory, isDirectory: true)
            guard manager.fileExists(atPath: path.path) else { return [] }
            return try manager.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
        }
        let captures = try notices("outbox")
        let replies = try notices("check-in-outbox")
        for file in captures {
            let id = file.deletingPathExtension().lastPathComponent
            // Never derive a path from an unvalidated queued ID or remove a
            // capture that already belongs to the delivered history.
            if ModalRequest.validID(id), !manager.fileExists(atPath: root.appendingPathComponent("delivered").appendingPathComponent(file.lastPathComponent).path) {
                let directory = root.appendingPathComponent("captures").appendingPathComponent(id)
                if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
            }
            try manager.removeItem(at: file)
        }
        for file in replies { try manager.removeItem(at: file) }
        return Cleared(captureEvents: captures.count, checkInReplies: replies.count)
    }
}
