import Foundation
import Observation

/// Connection metadata only: never URLs, credentials, audio or reply transcripts.
@MainActor @Observable
final class ConnectionDiagnostics {
    struct Entry: Codable, Identifiable, Sendable {
        let id: UUID
        let time: Date
        let event: String
        let detail: String
        var line: String { "\(time.formatted(date: .omitted, time: .standard))  \(event)  \(detail)" }
    }
    private(set) var entries: [Entry] = []
    private(set) var snapshot: [String: String] = [:]
    private(set) var persistenceError: String?
    @ObservationIgnored private let store: ConnectionDiagnosticStore
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?

    init(root: URL) { store = ConnectionDiagnosticStore(root: root) }

    var text: String {
        snapshot.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            + "\n\n" + entries.map(\.line).joined(separator: "\n")
    }

    func record(_ event: String, _ detail: String = "") {
        let entry = Entry(id: UUID(), time: Date(), event: event, detail: Self.redact(detail))
        entries.append(entry)
        if entries.count > 100 { entries.removeFirst(entries.count - 100) }
        enqueue { try await $0.append(entry) }
    }

    func update(_ values: [String: String]) {
        let safe = values.mapValues(Self.redact)
        guard safe != snapshot else { return }
        var before = snapshot, after = safe
        before["samples"] = nil; after["samples"] = nil
        snapshot = safe
        if before != after {
            record("connection_state", after.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " · "))
        }
        enqueue { try await $0.save(safe) }
    }

    private func enqueue(_ operation: @escaping @Sendable (ConnectionDiagnosticStore) async throws -> Void) {
        let previous = pendingWrite
        pendingWrite = Task { [weak self, store] in
            await previous?.value
            do { try await operation(store) }
            catch { self?.persistenceError = "Unable to save local connection diagnostics" }
        }
    }

    private static func redact(_ value: String) -> String {
        value.replacingOccurrences(of: #"\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s]+"#, with: "[URL omitted]", options: .regularExpression)
            .replacingOccurrences(of: #"sk[-_][A-Za-z0-9_-]{20,}"#, with: "[credential omitted]", options: .regularExpression)
    }
}

private actor ConnectionDiagnosticStore {
    let root: URL
    init(root: URL) { self.root = root }

    func append(_ entry: ConnectionDiagnostics.Entry) throws {
        try prepare()
        let file = root.appendingPathComponent("connection.jsonl")
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 {
            let archive = root.appendingPathComponent("connection.previous.jsonl")
            if FileManager.default.fileExists(atPath: archive.path) { try FileManager.default.removeItem(at: archive) }
            try FileManager.default.moveItem(at: file, to: archive)
        }
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(entry); line.append(0x0a)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: line)
    }

    func save(_ values: [String: String]) throws {
        try prepare()
        var row = values; row["checkedAtUTC"] = ISO8601DateFormatter().string(from: Date())
        try JSONEncoder().encode(row).write(to: root.appendingPathComponent("connection-status.json"), options: .atomic)
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
    }
}
