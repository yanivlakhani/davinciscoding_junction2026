// FallBackendClient.swift — invio frame e risposta al server Modal.
import Foundation

struct FallAnalysis: Decodable {
    let event_id: String
    let level: Int
    let status: String
    let vision: Vision
    struct Vision: Decodable { let place: String; let hazards: [String]; let reason: String; let usable_frames: Int }
}

final class FallBackendClient {
    let baseURL: URL          // es. https://<workspace>--fall-detection-backend-fastapi-app.modal.run
    let apiKey: String        // lo stesso API_KEY messo nel secret "fall-secrets"

    init(baseURL: URL, apiKey: String) { self.baseURL = baseURL; self.apiKey = apiKey }

    /// frames: JPEG dalla camera degli occhiali (1-7). bestN: migliori frame utilizzabili (1-7).
    func analyze(frames: [Data], imuLevel: Int, lat: Double?, lon: Double?, bestN: Int = 7) async throws -> FallAnalysis {
        var req = URLRequest(url: baseURL.appendingPathComponent("analyze"))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        let boundary = "fall-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("imu_level", String(imuLevel))
        field("best_n", String(bestN))
        if let lat, let lon { field("lat", String(lat)); field("lon", String(lon)) }
        for (i, jpg) in frames.prefix(7).enumerated() {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"frames\"; filename=\"f\(i).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(jpg)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(FallAnalysis.self, from: data)
    }

    /// answer: "fine" | "help" | "confused" | "silence"  (da FallVoiceManager)
    func sendAnswer(eventId: String, answer: String, transcript: String? = nil) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("event/\(eventId)/answer"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["answer": answer, "transcript": transcript as Any])
        _ = try await URLSession.shared.data(for: req)
    }
}

// Uso dopo la caduta:
// let a = try await client.analyze(frames: jpegs, imuLevel: 2, lat: loc?.latitude, lon: loc?.longitude)
// let answer = await voice.askAreYouOK()
// try await client.sendAnswer(eventId: a.event_id, answer: answer.rawValue)
//
// Se /analyze fallisce (rete, timeout): NON bloccare l'allarme. Senza rete -> SMS dal telefono.
