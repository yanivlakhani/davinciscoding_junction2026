import Foundation

/// Diagnostics never include request headers, bodies, credentials or query strings.
/// Writes run on a bounded utility queue, outside capture and inference.
final class NetworkLog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "FallApp.network-log", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private let file: URL
    init(root: URL) { file = root.appendingPathComponent("network.jsonl") }

    func record(_ kind: String, fields: [String: String]) {
        lock.lock()
        guard pending < 512 else { lock.unlock(); return }
        pending += 1; lock.unlock()
        var row = fields; row["kind"] = kind; row["phoneUptimeNs"] = String(DispatchTime.now().uptimeNanoseconds)
        let value = row
        queue.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: file.path) {
                    guard FileManager.default.createFile(atPath: file.path, contents: nil) else { return }
                }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
                try handle.write(contentsOf: data)
            } catch { /* Diagnostic failure never destroys the durable outbox. */ }
        }
    }

    func drain() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
